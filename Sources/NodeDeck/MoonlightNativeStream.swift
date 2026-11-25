import AppKit
import AVFoundation
import CMoonlightCommon
import CoreMedia
import Foundation
import NodeDeckCore
import SwiftUI
import VideoToolbox

// MARK: - Singleton Active Session Bridge & Serialized Limelight Lifecycle

private final class ActiveMoonlightBridge: @unchecked Sendable {
    static let shared = ActiveMoonlightBridge()
    let lock = NSLock()
    weak var session: MoonlightStreamSession?
    weak var pipeline: MoonlightMediaPipeline?
    var generation: UInt64 = 0
}

/// Strictly serializes all global C `LiStartConnection` / `LiStopConnection` calls across
/// the entire process and gates all `LiSend*` input calls so they can never race with
/// `destroyInputStream()` / `initializeInputStream()` when switching resolution/refresh rate
/// or closing/reopening stream windows.
private final class LimelightLifecycle: @unchecked Sendable {
    static let shared = LimelightLifecycle()

    private let lifecycleQueue = DispatchQueue(label: "com.nodedeck.limelight.lifecycle", qos: .userInitiated)
    private let inputLock = NSLock()
    private var inputAllowed = false
    private var hasActiveConnection = false // Only accessed on `lifecycleQueue`.

    private let generationLock = NSLock()
    private var currentGeneration: UInt64 = 0

    func nextGeneration() -> UInt64 {
        generationLock.withLock {
            currentGeneration &+= 1
            return currentGeneration
        }
    }

    func isCurrent(generation: UInt64) -> Bool {
        generationLock.withLock { currentGeneration == generation }
    }

    func setInputAllowed(_ allowed: Bool) {
        inputLock.withLock {
            inputAllowed = allowed
        }
    }

    var isInputAllowed: Bool {
        inputLock.withLock { inputAllowed }
    }

    /// Synchronously prevents any further `LiSend*` calls and interrupts an in-flight `LiStartConnection()`.
    func interruptAndDisableInput() {
        setInputAllowed(false)
        LiInterruptConnection()
    }

    /// Runs `body` only while input is active and while holding `inputLock`, making it impossible
    /// for `LiStopConnection()` to destroy `InputStream` queues underneath an in-flight input event.
    func sendInput(_ body: () -> Void) {
        inputLock.lock()
        defer { inputLock.unlock() }
        guard inputAllowed else { return }
        body()
    }

    /// Waits on the global serial queue for any active C connection to stop cleanly.
    func stopConnection() async {
        interruptAndDisableInput()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lifecycleQueue.async {
                self.setInputAllowed(false)
                if self.hasActiveConnection {
                    LiStopConnection()
                    self.hasActiveConnection = false
                }
                continuation.resume()
            }
        }
    }

    /// Serializes `LiStartConnection()` after any prior `LiStopConnection()`.
    /// Returns `nil` if `generation` was superseded before or during connection establishment.
    func startConnection(
        generation: UInt64,
        beforeStart: @escaping @Sendable () -> Void,
        startBlock: @escaping @Sendable () -> Int32
    ) async -> Int32? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
            lifecycleQueue.async {
                self.setInputAllowed(false)
                if self.hasActiveConnection {
                    LiStopConnection()
                    self.hasActiveConnection = false
                }

                guard self.isCurrent(generation: generation) else {
                    continuation.resume(returning: nil)
                    return
                }

                beforeStart()
                self.hasActiveConnection = true
                let rc = startBlock()
                if rc == 0 {
                    if self.isCurrent(generation: generation) {
                        self.setInputAllowed(true)
                        continuation.resume(returning: 0)
                    } else {
                        self.setInputAllowed(false)
                        LiStopConnection()
                        self.hasActiveConnection = false
                        continuation.resume(returning: nil)
                    }
                } else {
                    // LiStartConnection's internal Cleanup path already invokes LiStopConnection().
                    self.setInputAllowed(false)
                    self.hasActiveConnection = false
                    continuation.resume(returning: rc)
                }
            }
        }
    }
}

// MARK: - Stream Performance Snapshot

struct StreamPerformanceStats: Equatable, Sendable {
    var codec: String = "HEVC (Hardware)"
    var resolution: String = "1920×1080"
    var videoAspectRatio: Double = 16.0 / 9.0
    var fps: Int = 0
    var bitrateMbps: Double = 0.0
    var hostLatencyMs: Double = 0.0
    var networkRttMs: Int = 0
    var networkJitterMs: Int = 0
    var transportRoute: String = "Direct"
    var decodedFrames: Int = 0
    var rendererStatus: String = "Ready"
}

// MARK: - Nonisolated Media Pipeline (VideoToolbox + AVSampleBufferDisplayLayer + Opus)

private final class MoonlightMediaPipeline: @unchecked Sendable {
    let displayLayer = AVSampleBufferDisplayLayer()

    private let renderLock = NSLock()
    private var formatDescription: CMVideoFormatDescription?
    private var videoFormat: Int32 = 0
    private var vpsData: Data?
    private var spsData: Data?
    private var ppsData: Data?
    private var hasSubmittedKeyframe: Bool = false
    private var frameCounter: Int = 0
    private var bytesCounter: Int = 0
    private var totalDecodedFrames: Int = 0
    private var lastHostLatencySumMs: Double = 0
    private var lastHostLatencyCount: Int = 0
    private var lastFPSCheck: CFTimeInterval = CACurrentMediaTime()
    private var lastRendererStatus: String = "Ready"

    private var opusDecoder: NDOpusDecoder?
    private var audioEngine: AVAudioEngine?
    private var audioPlayerNode: AVAudioPlayerNode?
    private var audioChannels: Int = 2
    private var audioSampleRate: Int = 48000
    private var audioSamplesPerFrame: Int = 240
    private var pcmScratch: [Float] = []

    var onStatsUpdate: (@Sendable (StreamPerformanceStats) -> Void)?

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        configureTimebase()
    }

    private func configureTimebase() {
        var timebase: CMTimebase?
        if CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        ) == noErr, let tb = timebase {
            CMTimebaseSetTime(tb, time: .zero)
            CMTimebaseSetRate(tb, rate: 1.0)
            displayLayer.controlTimebase = tb
        }
    }

    func resetVideoState() {
        renderLock.lock()
        formatDescription = nil
        vpsData = nil
        spsData = nil
        ppsData = nil
        hasSubmittedKeyframe = false
        frameCounter = 0
        bytesCounter = 0
        totalDecodedFrames = 0
        lastRendererStatus = "Ready"
        renderLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
    }

    func handleVideoSetup(videoFormat: Int32, width: Int32, height: Int32) -> Int32 {
        renderLock.lock()
        self.videoFormat = videoFormat
        self.formatDescription = nil
        self.vpsData = nil
        self.spsData = nil
        self.ppsData = nil
        self.hasSubmittedKeyframe = false
        self.frameCounter = 0
        self.bytesCounter = 0
        self.totalDecodedFrames = 0
        self.lastFPSCheck = CACurrentMediaTime()
        let isHEVC = (videoFormat & Int32(VIDEO_FORMAT_MASK_H265)) != 0
        let codec = isHEVC ? "HEVC (VideoToolbox)" : "H.264 (VideoToolbox)"
        let resolution = "\(width)×\(height)"
        let aspect = (width > 0 && height > 0) ? (Double(width) / Double(height)) : (16.0 / 9.0)
        renderLock.unlock()

        onStatsUpdate?(StreamPerformanceStats(
            codec: codec,
            resolution: resolution,
            videoAspectRatio: aspect,
            fps: 0,
            bitrateMbps: 0,
            hostLatencyMs: 0,
            networkRttMs: 0,
            networkJitterMs: 0,
            decodedFrames: 0,
            rendererStatus: "Initialized"
        ))
        return 0
    }

    func handleSubmitDecodeUnit(_ duPtr: PDECODE_UNIT?) -> Int32 {
        autoreleasepool {
            handleSubmitDecodeUnitBody(duPtr)
        }
    }

    private func handleSubmitDecodeUnitBody(_ duPtr: PDECODE_UNIT?) -> Int32 {
        guard let du = duPtr?.pointee else { return Int32(DR_OK) }

        renderLock.lock()
        let isHEVC = (videoFormat & Int32(VIDEO_FORMAT_MASK_H265)) != 0
        let isIDR = (du.frameType == Int32(FRAME_TYPE_IDR))
        // IMPORTANT: moonlight-common-c splits a single NALU across multiple BUFFER_TYPE_PICDATA LENTRY
        // fragments (one per RTP packet). Concatenate ALL picdata fragments BEFORE scanning Annex-B start codes!
        var rawPicData = Data(capacity: Int(du.fullLength))
        var paramsUpdated = false

        var entryPtr = du.bufferList
        while let entry = entryPtr?.pointee {
            if let rawBuf = entry.data, entry.length > 0 {
                let bytes = Data(bytes: rawBuf, count: Int(entry.length))

                switch entry.bufferType {
                case Int32(BUFFER_TYPE_VPS):
                    vpsData = Self.stripAnnexBStartCode(bytes)
                    paramsUpdated = true
                case Int32(BUFFER_TYPE_SPS):
                    spsData = Self.stripAnnexBStartCode(bytes)
                    paramsUpdated = true
                case Int32(BUFFER_TYPE_PPS):
                    ppsData = Self.stripAnnexBStartCode(bytes)
                    paramsUpdated = true
                default:
                    rawPicData.append(bytes)
                }
            }
            entryPtr = entry.next
        }

        var avccData = Data(capacity: rawPicData.count + 64)
        if !rawPicData.isEmpty {
            Self.appendAnnexBAsAVCC(rawPicData, to: &avccData)
        }

        if paramsUpdated || formatDescription == nil {
            if isHEVC, let vps = vpsData, let sps = spsData, let pps = ppsData {
                formatDescription = Self.createHEVCFormatDescription(vps: vps, sps: sps, pps: pps)
            } else if !isHEVC, let sps = spsData, let pps = ppsData {
                formatDescription = Self.createH264FormatDescription(sps: sps, pps: pps)
            }
        }

        guard let fmtDesc = formatDescription, !avccData.isEmpty else {
            renderLock.unlock()
            return isIDR ? Int32(DR_NEED_IDR) : Int32(DR_OK)
        }

        if !isIDR && !hasSubmittedKeyframe {
            renderLock.unlock()
            return Int32(DR_NEED_IDR)
        }
        if isIDR {
            hasSubmittedKeyframe = true
        }

        frameCounter += 1
        totalDecodedFrames += 1
        bytesCounter += Int(du.fullLength)
        if du.frameHostProcessingLatency > 0 {
            lastHostLatencySumMs += Double(du.frameHostProcessingLatency) / 10.0
            lastHostLatencyCount += 1
        }

        let enqueueResult = enqueueAVCCFrame(avccData, formatDescription: fmtDesc, isIDR: isIDR)
        if !enqueueResult.ok {
            hasSubmittedKeyframe = false
            lastRendererStatus = enqueueResult.statusText
        } else {
            lastRendererStatus = enqueueResult.statusText
        }

        let now = CACurrentMediaTime()
        let elapsed = now - lastFPSCheck
        if elapsed >= 1.0 {
            let measuredFPS = Int(round(Double(frameCounter) / elapsed))
            let mbps = (Double(bytesCounter) * 8.0) / (elapsed * 1_000_000.0)
            let avgHostMs = lastHostLatencyCount > 0 ? (lastHostLatencySumMs / Double(lastHostLatencyCount)) : 0
            let codec = isHEVC ? "HEVC (VideoToolbox)" : "H.264 (VideoToolbox)"
            let dims = CMVideoFormatDescriptionGetDimensions(fmtDesc)
            let res = "\(dims.width)×\(dims.height)"
            let aspect = (dims.width > 0 && dims.height > 0) ? (Double(dims.width) / Double(dims.height)) : (16.0 / 9.0)
            let total = totalDecodedFrames
            let statusStr = lastRendererStatus
            var rttVal: UInt32 = 0
            var rttVar: UInt32 = 0
            _ = LiGetEstimatedRttInfo(&rttVal, &rttVar)

            frameCounter = 0
            bytesCounter = 0
            lastHostLatencySumMs = 0
            lastHostLatencyCount = 0
            lastFPSCheck = now
            renderLock.unlock()

            onStatsUpdate?(StreamPerformanceStats(
                codec: codec,
                resolution: res,
                videoAspectRatio: aspect,
                fps: measuredFPS,
                bitrateMbps: mbps,
                hostLatencyMs: avgHostMs,
                networkRttMs: Int(rttVal),
                networkJitterMs: Int(rttVar),
                decodedFrames: total,
                rendererStatus: statusStr
            ))
            return enqueueResult.ok ? Int32(DR_OK) : Int32(DR_NEED_IDR)
        }

        renderLock.unlock()
        return enqueueResult.ok ? Int32(DR_OK) : Int32(DR_NEED_IDR)
    }

    private func enqueueAVCCFrame(
        _ data: Data,
        formatDescription: CMVideoFormatDescription,
        isIDR: Bool
    ) -> (ok: Bool, statusText: String) {
        let count = data.count
        var blockBuffer: CMBlockBuffer?
        let status1 = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status1 == kCMBlockBufferNoErr, let block = blockBuffer else {
            return (false, "CMBlockBuffer err \(status1)")
        }

        let status2 = data.withUnsafeBytes { rawPtr in
            CMBlockBufferReplaceDataBytes(
                with: rawPtr.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: count
            )
        }
        guard status2 == kCMBlockBufferNoErr else {
            return (false, "ReplaceBytes err \(status2)")
        }

        var sampleSize = count
        var sampleBuffer: CMSampleBuffer?
        let status3 = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status3 == noErr, let sb = sampleBuffer else {
            return (false, "CMSampleBuffer err \(status3)")
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
            if !isIDR {
                CFDictionarySetValue(
                    dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }

        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            let errDesc = renderer.error?.localizedDescription ?? "Renderer failed"
            renderer.flush()
            return (false, "Recovered: \(errDesc)")
        }

        renderer.enqueue(sb)

        if renderer.status == .failed {
            let errDesc = renderer.error?.localizedDescription ?? "Enqueue failed"
            renderer.flush()
            return (false, "Failed: \(errDesc)")
        }
        return (true, "Rendering")
    }

    private static func stripAnnexBStartCode(_ data: Data) -> Data {
        if data.count >= 4 && data[0] == 0 && data[1] == 0 && data[2] == 0 && data[3] == 1 {
            return data.subdata(in: 4..<data.count)
        }
        if data.count >= 3 && data[0] == 0 && data[1] == 0 && data[2] == 1 {
            return data.subdata(in: 3..<data.count)
        }
        return data
    }

    private static func appendAnnexBAsAVCC(_ data: Data, to output: inout Data) {
        let bytes = [UInt8](data)
        let n = bytes.count
        var i = 0
        var naluStart = -1

        func emitNALU(start: Int, end: Int) {
            let length = end - start
            guard length > 0 else { return }
            var bigLen = UInt32(length).bigEndian
            withUnsafeBytes(of: &bigLen) { output.append(contentsOf: $0) }
            output.append(contentsOf: bytes[start..<end])
        }

        while i < n {
            if i + 3 < n && bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                if naluStart >= 0 { emitNALU(start: naluStart, end: i) }
                i += 4
                naluStart = i
            } else if i + 2 < n && bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                if naluStart >= 0 { emitNALU(start: naluStart, end: i) }
                i += 3
                naluStart = i
            } else {
                i += 1
            }
        }
        if naluStart >= 0 && naluStart < n {
            emitNALU(start: naluStart, end: n)
        } else if naluStart == -1 && n > 0 {
            emitNALU(start: 0, end: n)
        }
    }

    private static func createH264FormatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var desc: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsPtr in
            pps.withUnsafeBytes { ppsPtr in
                let ptrs: [UnsafePointer<UInt8>] = [
                    spsPtr.bindMemory(to: UInt8.self).baseAddress!,
                    ppsPtr.bindMemory(to: UInt8.self).baseAddress!
                ]
                let sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: ptrs,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc
                )
            }
        }
        return status == noErr ? desc : nil
    }

    private static func createHEVCFormatDescription(vps: Data, sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var desc: CMVideoFormatDescription?
        let status = vps.withUnsafeBytes { vpsPtr in
            sps.withUnsafeBytes { spsPtr in
                pps.withUnsafeBytes { ppsPtr in
                    let ptrs: [UnsafePointer<UInt8>] = [
                        vpsPtr.bindMemory(to: UInt8.self).baseAddress!,
                        spsPtr.bindMemory(to: UInt8.self).baseAddress!,
                        ppsPtr.bindMemory(to: UInt8.self).baseAddress!
                    ]
                    let sizes: [Int] = [vps.count, sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: ptrs,
                        parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &desc
                    )
                }
            }
        }
        return status == noErr ? desc : nil
    }

    // MARK: - Audio Decode Path (libopus + AVAudioEngine)

    func handleAudioInit(_ opusConfigPtr: POPUS_MULTISTREAM_CONFIGURATION?) -> Int32 {
        guard let cfg = opusConfigPtr?.pointee else { return -1 }

        var mapping = [UInt8](repeating: 0, count: 8)
        withUnsafeBytes(of: cfg.mapping) { src in
            for i in 0..<min(8, src.count) { mapping[i] = src[i] }
        }

        let decoder = mapping.withUnsafeBufferPointer { mapPtr in
            nd_opus_create(
                cfg.sampleRate,
                cfg.channelCount,
                cfg.streams,
                cfg.coupledStreams,
                mapPtr.baseAddress
            )
        }
        guard let decoder else { return -2 }

        let channels = Int(cfg.channelCount)
        let sampleRate = Int(cfg.sampleRate)
        let samplesPerFrame = Int(cfg.samplesPerFrame)

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        if let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: false
        ) {
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try? engine.start()
            player.play()
        }

        renderLock.lock()
        self.opusDecoder = decoder
        self.audioEngine = engine
        self.audioPlayerNode = player
        self.audioChannels = channels
        self.audioSampleRate = sampleRate
        self.audioSamplesPerFrame = samplesPerFrame
        self.pcmScratch = [Float](repeating: 0, count: samplesPerFrame * channels * 2)
        renderLock.unlock()

        return 0
    }

    func handleAudioDecodeAndPlay(_ sampleData: UnsafeMutablePointer<CChar>?, length: Int32) {
        autoreleasepool {
            handleAudioDecodeAndPlayBody(sampleData, length: length)
        }
    }

    private func handleAudioDecodeAndPlayBody(_ sampleData: UnsafeMutablePointer<CChar>?, length: Int32) {
        guard let sampleData, length > 0 else { return }

        renderLock.lock()
        guard let decoder = opusDecoder, let player = audioPlayerNode else {
            renderLock.unlock()
            return
        }
        let channels = audioChannels
        let sampleRate = audioSampleRate
        let maxFrames = audioSamplesPerFrame
        let decodedFrames: Int32 = pcmScratch.withUnsafeMutableBufferPointer { outPtr in
            sampleData.withMemoryRebound(to: UInt8.self, capacity: Int(length)) { inPtr in
                nd_opus_decode_float(decoder, inPtr, length, outPtr.baseAddress, Int32(maxFrames))
            }
        }
        guard decodedFrames > 0,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: Double(sampleRate),
                  channels: AVAudioChannelCount(channels),
                  interleaved: false
              ),
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(decodedFrames))
        else {
            renderLock.unlock()
            return
        }

        pcmBuffer.frameLength = AVAudioFrameCount(decodedFrames)
        if let chData = pcmBuffer.floatChannelData {
            let frames = Int(decodedFrames)
            for f in 0..<frames {
                for ch in 0..<channels {
                    chData[ch][f] = pcmScratch[f * channels + ch]
                }
            }
        }
        renderLock.unlock()

        player.scheduleBuffer(pcmBuffer, completionHandler: nil)
    }

    func cleanupAudio() {
        renderLock.lock()
        let dec = opusDecoder
        let eng = audioEngine
        let ply = audioPlayerNode
        opusDecoder = nil
        audioEngine = nil
        audioPlayerNode = nil
        renderLock.unlock()

        ply?.stop()
        eng?.stop()
        if let dec {
            nd_opus_destroy(dec)
        }
    }
}

// MARK: - Native Moonlight Stream Session

@MainActor
final class MoonlightStreamSession: ObservableObject {
    enum ConnectionState: Equatable {
        case idle
        case connecting(String)
        case streaming
        case disconnected(String?)
    }

    @Published var state: ConnectionState = .idle
    @Published var streamTitle: String = ""
    @Published var stats = StreamPerformanceStats()
    @Published var targetWidth: Int = 1920
    @Published var targetHeight: Int = 1080
    @Published var targetFPS: Int = 60
    @Published var errorMessage: String?
    @Published var isPrivacyScreenEnabled: Bool = false
    @Published var isTogglingPrivacyScreen: Bool = false
    @Published var showPerformanceHUD: Bool = false
    @Published var swapCmdToCtrl: Bool = false
    @Published var relativeMouseEnabled: Bool = false
    private static let clipboardAutoSyncKey = "nodedeck.clipboardAutoSync"

    @Published var clipboardAutoSync: Bool = {
        if UserDefaults.standard.object(forKey: "nodedeck.clipboardAutoSync") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "nodedeck.clipboardAutoSync")
    }() {
        didSet {
            UserDefaults.standard.set(clipboardAutoSync, forKey: Self.clipboardAutoSyncKey)
            updateClipboardAutoSyncTask()
        }
    }
    @Published var clipboardStatusMessage: String?

    var onStreamConfigChanged: ((Int, Int, Int) -> Void)?

    private let pipeline = MoonlightMediaPipeline()
    var displayLayer: AVSampleBufferDisplayLayer { pipeline.displayLayer }

    private var activeLaunchSession: SunshineLaunchSession?
    private var sshHostAlias: String?
    private var currentAddress: String = ""
    private var currentHTTPPort: Int = 47989
    private var currentAppTitle: String = "Desktop"
    private var isStopping = false
    private var launchTask: Task<Void, Never>?
    private var activeGeneration: UInt64 = 0
    private var clipboardPollTask: Task<Void, Never>?
    private var lastSyncedChangeCount: Int = NSPasteboard.general.changeCount
    private var lastSyncedText: String?
    private var lastRemoteText: String?
    private var hasInitializedRemoteClipboardBaseline = false
    private var isClipboardSyncInFlight = false
    private var isStreamWindowKey = true
    var canSyncClipboard: Bool { !(sshHostAlias ?? "").isEmpty }

    init() {
        pipeline.onStatsUpdate = { [weak self] newStats in
            Task { @MainActor in
                guard let self else { return }
                var enriched = newStats
                enriched.transportRoute = Self.classifyTransportRoute(address: self.currentAddress)
                self.stats = enriched
            }
        }
    }

    private static func classifyTransportRoute(address: String) -> String {
        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if addr == "127.0.0.1" || addr == "::1" || addr == "localhost" {
            return "Tunnel / Relay"
        }
        if addr.hasPrefix("100.") {
            return "Mesh / Tailscale"
        }
        if addr.hasPrefix("192.168.") || addr.hasPrefix("10.") || addr.hasPrefix("172.16.") || addr.hasPrefix("172.17.") || addr.hasPrefix("172.18.") || addr.hasPrefix("172.19.") || addr.hasPrefix("172.2") || addr.hasPrefix("172.30.") || addr.hasPrefix("172.31.") {
            return "LAN / VPN Direct"
        }
        return "WAN Direct"
    }

    func start(
        hostAlias: String? = nil,
        address: String,
        httpPort: Int = 47989,
        preferredAppTitle: String = "Desktop",
        width: Int = 1920,
        height: Int = 1080,
        fps: Int = 60,
        bitrateKbps: Int? = nil,
        enablePrivacyScreen: Bool = false
    ) {
        stop(quitRemoteApp: false, restorePrivacyScreen: !enablePrivacyScreen)
        let myGen = LimelightLifecycle.shared.nextGeneration()
        activeGeneration = myGen
        isStopping = false
        errorMessage = nil
        sshHostAlias = hostAlias
        currentAddress = address
        currentHTTPPort = httpPort
        currentAppTitle = preferredAppTitle
        targetWidth = width
        targetHeight = height
        targetFPS = fps
        onStreamConfigChanged?(width, height, fps)
        let resolvedBitrateKbps = bitrateKbps ?? StreamQualityMath.recommendedBitrateKbps(
            width: width,
            height: height,
            fps: fps
        )
        isPrivacyScreenEnabled = false
        streamTitle = hostAlias ?? address
        stats = StreamPerformanceStats(codec: "Connecting…", resolution: "\(width)×\(height)", fps: 0)
        state = .connecting("Negotiating with Sunshine (\(address):\(httpPort))…")

        launchTask = Task { [weak self] in
            guard let self else { return }
            await LimelightLifecycle.shared.stopConnection()
            guard !Task.isCancelled, LimelightLifecycle.shared.isCurrent(generation: myGen) else { return }

            do {
                let launched = try await SunshineClient.shared.launchStream(
                    address: address,
                    httpPort: httpPort,
                    preferredAppTitle: preferredAppTitle,
                    width: width,
                    height: height,
                    fps: fps
                )
                guard !Task.isCancelled, LimelightLifecycle.shared.isCurrent(generation: myGen) else { return }

                self.activeLaunchSession = launched
                self.streamTitle = "\(hostAlias ?? address) · \(launched.appTitle)"
                self.state = .connecting("Starting native Moonlight stream (\(width)×\(height) @ \(fps)Hz)…")

                let started = try await startLimelightConnection(
                    generation: myGen,
                    session: launched,
                    width: width,
                    height: height,
                    fps: fps,
                    bitrateKbps: resolvedBitrateKbps
                )
                guard started, !Task.isCancelled, LimelightLifecycle.shared.isCurrent(generation: myGen) else { return }

                self.updateClipboardAutoSyncTask()

                if enablePrivacyScreen {
                    await setPrivacyScreen(enabled: true)
                }
            } catch {
                guard !Task.isCancelled, LimelightLifecycle.shared.isCurrent(generation: myGen) else { return }
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.errorMessage = msg
                self.state = .disconnected(msg)
            }
        }
    }

    func restartWithResolution(width: Int, height: Int, fps: Int) {
        guard !currentAddress.isEmpty else { return }
        start(
            hostAlias: sshHostAlias,
            address: currentAddress,
            httpPort: currentHTTPPort,
            preferredAppTitle: currentAppTitle,
            width: width,
            height: height,
            fps: fps,
            enablePrivacyScreen: isPrivacyScreenEnabled
        )
    }

    func switchResolution(_ preset: StreamResolutionPreset) {
        guard preset.width != targetWidth || preset.height != targetHeight else { return }
        restartWithResolution(width: preset.width, height: preset.height, fps: targetFPS)
    }

    func switchRefreshRate(_ rate: StreamRefreshRate) {
        guard rate.fps != targetFPS else { return }
        restartWithResolution(width: targetWidth, height: targetHeight, fps: rate.fps)
    }

    func togglePrivacyScreen() {
        Task {
            await setPrivacyScreen(enabled: !isPrivacyScreenEnabled)
        }
    }

    func setPrivacyScreen(enabled: Bool) async {
        guard let alias = sshHostAlias, !alias.isEmpty else { return }
        guard !isTogglingPrivacyScreen else { return }
        isTogglingPrivacyScreen = true
        defer { isTogglingPrivacyScreen = false }

        let linuxCmd = enabled
            ? "DISPLAY=:0 xset dpms force off 2>/dev/null || xset -display :0 dpms force off 2>/dev/null || true"
            : "DISPLAY=:0 xset dpms force on 2>/dev/null || xset -display :0 dpms force on 2>/dev/null || true"
        let winMonitorArg = enabled ? "2" : "-1"
        let winCmd = "powershell -NoProfile -Command \"Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class M { [DllImport(\\\"user32.dll\\\")] public static extern int SendMessage(int h, int m, int w, int l); }'; [M]::SendMessage(-1, 0x0112, 0xF170, \(winMonitorArg)) | Out-Null\""

        let ok = await Task.detached(priority: .userInitiated) {
            let probe = ProcessRunner.run(
                executable: "/usr/bin/ssh",
                arguments: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=4", "-o", "ControlMaster=no", alias, "uname -s"],
                timeout: 6
            )
            let isLinux = probe.status == 0 && probe.stdout.localizedCaseInsensitiveContains("linux")
            let remoteCommand = isLinux ? linuxCmd : winCmd
            let result = ProcessRunner.run(
                executable: "/usr/bin/ssh",
                arguments: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=4", "-o", "ControlMaster=no", alias, remoteCommand],
                timeout: 8
            )
            return result.status == 0
        }.value

        if ok {
            isPrivacyScreenEnabled = enabled
        }
    }

    func pushMacClipboardToRemote() {
        guard let alias = sshHostAlias, !alias.isEmpty else {
            clipboardStatusMessage = AppLocalization.shared.t("未绑定 SSH 别名", "No SSH alias bound")
            return
        }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            clipboardStatusMessage = AppLocalization.shared.t("本机剪贴板无文本", "Mac clipboard has no text")
            return
        }
        clipboardStatusMessage = AppLocalization.shared.t("发送中…", "Pushing…")
        Task {
            do {
                try await ClipboardSyncManager.pushText(text, to: alias)
                lastSyncedText = text
                lastRemoteText = text
                lastSyncedChangeCount = NSPasteboard.general.changeCount
                clipboardStatusMessage = AppLocalization.shared.t("已发送到远端 (\(text.count) 字)", "Pushed to host (\(text.count) chars)")
            } catch {
                clipboardStatusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func pullRemoteClipboardToMac() {
        guard let alias = sshHostAlias, !alias.isEmpty else {
            clipboardStatusMessage = AppLocalization.shared.t("未绑定 SSH 别名", "No SSH alias bound")
            return
        }
        clipboardStatusMessage = AppLocalization.shared.t("拉取中…", "Pulling…")
        Task {
            do {
                let text = try await ClipboardSyncManager.pullText(from: alias)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                lastSyncedChangeCount = NSPasteboard.general.changeCount
                lastSyncedText = text
                lastRemoteText = text
                hasInitializedRemoteClipboardBaseline = true
                clipboardStatusMessage = AppLocalization.shared.t("已拉取到 Mac (\(text.count) 字)", "Pulled to Mac (\(text.count) chars)")
            } catch {
                clipboardStatusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func handleWindowDidBecomeKey() {
        isStreamWindowKey = true
        guard clipboardAutoSync, state == .streaming, let alias = sshHostAlias, !alias.isEmpty else { return }
        Task {
            await syncMacClipboardIfChanged(to: alias, forceIfUnsynced: true)
        }
    }

    func handleWindowDidResignKey() {
        isStreamWindowKey = false
        guard clipboardAutoSync, state == .streaming, let alias = sshHostAlias, !alias.isEmpty else { return }
        Task {
            await syncRemoteClipboardIfChanged(from: alias)
        }
    }

    private func syncMacClipboardIfChanged(to alias: String, forceIfUnsynced: Bool = false) async {
        guard !isClipboardSyncInFlight else { return }
        let count = NSPasteboard.general.changeCount
        guard forceIfUnsynced || count != lastSyncedChangeCount else { return }
        lastSyncedChangeCount = count

        guard let text = NSPasteboard.general.string(forType: .string),
              !text.isEmpty,
              text.utf8.count <= ClipboardSyncManager.maxBytes,
              text != lastSyncedText
        else {
            return
        }

        isClipboardSyncInFlight = true
        defer { isClipboardSyncInFlight = false }
        do {
            try await ClipboardSyncManager.pushText(text, to: alias)
            lastSyncedText = text
            lastRemoteText = text
            clipboardStatusMessage = AppLocalization.shared.t("已自动同步到远端 (\(text.count) 字)", "Synced to host (\(text.count) chars)")
        } catch {
            clipboardStatusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func syncRemoteClipboardIfChanged(from alias: String) async {
        guard !isClipboardSyncInFlight else { return }
        isClipboardSyncInFlight = true
        defer { isClipboardSyncInFlight = false }

        do {
            let remoteText = try await ClipboardSyncManager.pullText(from: alias)
            if !hasInitializedRemoteClipboardBaseline {
                hasInitializedRemoteClipboardBaseline = true
                lastRemoteText = remoteText
                return
            }
            guard remoteText != lastRemoteText, remoteText != lastSyncedText else {
                return
            }
            guard remoteText.utf8.count <= ClipboardSyncManager.maxBytes else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(remoteText, forType: .string)
            lastSyncedChangeCount = NSPasteboard.general.changeCount
            lastSyncedText = remoteText
            lastRemoteText = remoteText
            clipboardStatusMessage = AppLocalization.shared.t("已自动同步到 Mac (\(remoteText.count) 字)", "Synced to Mac (\(remoteText.count) chars)")
        } catch ClipboardSyncError.emptyClipboard {
            hasInitializedRemoteClipboardBaseline = true
        } catch {
            // Keep transient network hiccups quiet unless user manually triggers
        }
    }

    private func updateClipboardAutoSyncTask() {
        clipboardPollTask?.cancel()
        clipboardPollTask = nil
        hasInitializedRemoteClipboardBaseline = false
        lastRemoteText = nil
        lastSyncedText = nil
        guard clipboardAutoSync, let alias = sshHostAlias, !alias.isEmpty else { return }
        lastSyncedChangeCount = NSPasteboard.general.changeCount

        clipboardPollTask = Task { [weak self] in
            // Initial push if user already had text on Mac clipboard when opening remote desktop
            guard let self else { return }
            if self.state == .streaming {
                await self.syncMacClipboardIfChanged(to: alias, forceIfUnsynced: true)
            }
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled, self.state == .streaming, self.clipboardAutoSync else { continue }
                // Local-only NSPasteboard changeCount check (0 syscalls unless user actually copied on Mac)
                await self.syncMacClipboardIfChanged(to: alias)
                tick += 1
                // Pull remote clipboard every ~2.4s while window is active (plus instant pull on window blur)
                if self.isStreamWindowKey && tick % 3 == 0 {
                    guard !Task.isCancelled, self.state == .streaming, self.clipboardAutoSync else { continue }
                    await self.syncRemoteClipboardIfChanged(from: alias)
                }
            }
        }
    }

    func stop(quitRemoteApp: Bool, restorePrivacyScreen: Bool = true) {
        guard !isStopping else { return }
        isStopping = true
        _ = LimelightLifecycle.shared.nextGeneration()
        LimelightLifecycle.shared.interruptAndDisableInput()
        launchTask?.cancel()
        launchTask = nil
        clipboardPollTask?.cancel()
        clipboardPollTask = nil
        relativeMouseEnabled = false

        let launched = activeLaunchSession
        let restoreAlias = (restorePrivacyScreen && isPrivacyScreenEnabled) ? sshHostAlias : nil
        activeLaunchSession = nil
        isPrivacyScreenEnabled = false

        ActiveMoonlightBridge.shared.lock.withLock {
            if ActiveMoonlightBridge.shared.session === self {
                ActiveMoonlightBridge.shared.session = nil
                ActiveMoonlightBridge.shared.pipeline = nil
            }
        }

        Task.detached(priority: .userInitiated) {
            await LimelightLifecycle.shared.stopConnection()
            if let alias = restoreAlias {
                let probe = ProcessRunner.run(
                    executable: "/usr/bin/ssh",
                    arguments: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=4", "-o", "ControlMaster=no", alias, "uname -s"],
                    timeout: 5
                )
                let restoreCmd = (probe.status == 0 && probe.stdout.localizedCaseInsensitiveContains("linux"))
                    ? "DISPLAY=:0 xset dpms force on 2>/dev/null || true"
                    : "powershell -NoProfile -Command \"Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class M { [DllImport(\\\"user32.dll\\\")] public static extern int SendMessage(int h, int m, int w, int l); }'; [M]::SendMessage(-1, 0x0112, 0xF170, -1) | Out-Null\""
                _ = ProcessRunner.run(
                    executable: "/usr/bin/ssh",
                    arguments: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=4", "-o", "ControlMaster=no", alias, restoreCmd],
                    timeout: 6
                )
            }
            if quitRemoteApp, let launched {
                await SunshineClient.shared.cancelSession(address: launched.address, httpsPort: launched.httpsPort)
            }
        }

        pipeline.cleanupAudio()
        pipeline.resetVideoState()
        state = .disconnected(nil)
        isStopping = false
    }

    func handleRemoteTermination(errorCode: Int32) {
        let gen = activeGeneration
        guard LimelightLifecycle.shared.isCurrent(generation: gen) else { return }
        LimelightLifecycle.shared.setInputAllowed(false)
        let msg = errorCode == 0 ? nil : "Stream terminated (error \(errorCode))."
        errorMessage = msg
        state = .disconnected(msg)
        Task.detached(priority: .userInitiated) {
            await LimelightLifecycle.shared.stopConnection()
        }
    }

    func sendCtrlAltDel() {
        let mods = Int8(MODIFIER_CTRL | MODIFIER_ALT)
        LimelightLifecycle.shared.sendInput {
            LiSendKeyboardEvent(0x2E, Int8(KEY_ACTION_DOWN), mods)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            LimelightLifecycle.shared.sendInput {
                LiSendKeyboardEvent(0x2E, Int8(KEY_ACTION_UP), mods)
            }
        }
    }

    // MARK: - Limelight Connection Setup

    private func startLimelightConnection(
        generation: UInt64,
        session: SunshineLaunchSession,
        width: Int,
        height: Int,
        fps: Int,
        bitrateKbps: Int
    ) async throws -> Bool {
        let pipelineRef = pipeline
        let rc = await LimelightLifecycle.shared.startConnection(
            generation: generation,
            beforeStart: { [weak self] in
                ActiveMoonlightBridge.shared.lock.withLock {
                    ActiveMoonlightBridge.shared.session = self
                    ActiveMoonlightBridge.shared.pipeline = pipelineRef
                    ActiveMoonlightBridge.shared.generation = generation
                }
            },
            startBlock: {
                var serverInfo = SERVER_INFORMATION()
                LiInitializeServerInformation(&serverInfo)

                var streamConfig = STREAM_CONFIGURATION()
                LiInitializeStreamConfiguration(&streamConfig)
                streamConfig.width = Int32(width)
                streamConfig.height = Int32(height)
                streamConfig.fps = Int32(fps)
                streamConfig.clientRefreshRateX100 = Int32(fps * 100)
                streamConfig.bitrate = Int32(bitrateKbps)
                streamConfig.packetSize = 1392
                streamConfig.streamingRemotely = STREAM_CFG_AUTO
                streamConfig.audioConfiguration = 0x000302CA
                streamConfig.supportedVideoFormats = Int32(VIDEO_FORMAT_H265 | VIDEO_FORMAT_H264)
                streamConfig.colorSpace = COLORSPACE_REC_709
                streamConfig.colorRange = COLOR_RANGE_LIMITED

                withUnsafeMutableBytes(of: &streamConfig.remoteInputAesKey) { dst in
                    session.rikey.withUnsafeBytes { src in
                        let count = min(dst.count, src.count)
                        dst.copyMemory(from: UnsafeRawBufferPointer(start: src.baseAddress, count: count))
                    }
                }

                var bigKeyId = UInt32(bitPattern: session.rikeyId).bigEndian
                withUnsafeMutableBytes(of: &streamConfig.remoteInputAesIv) { dst in
                    withUnsafeBytes(of: &bigKeyId) { src in
                        dst.copyMemory(from: UnsafeRawBufferPointer(start: src.baseAddress, count: 4))
                    }
                }

                var drCallbacks = DECODER_RENDERER_CALLBACKS()
                LiInitializeVideoCallbacks(&drCallbacks)
                drCallbacks.setup = moonlightVideoSetup
                drCallbacks.cleanup = moonlightVideoCleanup
                drCallbacks.submitDecodeUnit = moonlightSubmitDecodeUnit
                drCallbacks.capabilities = Int32(CAPABILITY_DIRECT_SUBMIT)

                var arCallbacks = AUDIO_RENDERER_CALLBACKS()
                LiInitializeAudioCallbacks(&arCallbacks)
                arCallbacks.`init` = moonlightAudioInit
                arCallbacks.cleanup = moonlightAudioCleanup
                arCallbacks.decodeAndPlaySample = moonlightAudioDecodeAndPlay
                arCallbacks.capabilities = Int32(CAPABILITY_DIRECT_SUBMIT)

                var clCallbacks = CONNECTION_LISTENER_CALLBACKS()
                LiInitializeConnectionCallbacks(&clCallbacks)
                clCallbacks.stageStarting = moonlightStageStarting
                clCallbacks.stageFailed = moonlightStageFailed
                clCallbacks.connectionStarted = moonlightConnectionStarted
                clCallbacks.connectionTerminated = moonlightConnectionTerminated

                return session.address.withCString { addrCStr in
                    session.appVersion.withCString { appVerCStr in
                        session.gfeVersion.withCString { gfeVerCStr in
                            session.rtspSessionURL.withCString { rtspCStr in
                                serverInfo.address = addrCStr
                                serverInfo.serverInfoAppVersion = appVerCStr
                                serverInfo.serverInfoGfeVersion = gfeVerCStr
                                serverInfo.rtspSessionUrl = rtspCStr
                                serverInfo.serverCodecModeSupport = Int32(session.serverCodecModeSupport)

                                return LiStartConnection(
                                    &serverInfo,
                                    &streamConfig,
                                    &clCallbacks,
                                    &drCallbacks,
                                    &arCallbacks,
                                    nil,
                                    0,
                                    nil,
                                    0
                                )
                            }
                        }
                    }
                }
            }
        )

        guard let rc else {
            return false
        }
        if rc != 0 {
            throw SunshineError.launchFailed("LiStartConnection returned error code \(rc).")
        }
        return true
    }
}

// MARK: - C Callbacks Bridging to ActiveMoonlightBridge

private func moonlightVideoSetup(
    videoFormat: Int32,
    width: Int32,
    height: Int32,
    redrawRate: Int32,
    context: UnsafeMutableRawPointer?,
    drFlags: Int32
) -> Int32 {
    let pipeline = ActiveMoonlightBridge.shared.lock.withLock { ActiveMoonlightBridge.shared.pipeline }
    return pipeline?.handleVideoSetup(videoFormat: videoFormat, width: width, height: height) ?? 0
}

private func moonlightVideoCleanup() {}

private func moonlightSubmitDecodeUnit(_ decodeUnit: PDECODE_UNIT?) -> Int32 {
    let pipeline = ActiveMoonlightBridge.shared.lock.withLock { ActiveMoonlightBridge.shared.pipeline }
    return pipeline?.handleSubmitDecodeUnit(decodeUnit) ?? Int32(DR_OK)
}

private func moonlightAudioInit(
    audioConfiguration: Int32,
    opusConfig: POPUS_MULTISTREAM_CONFIGURATION?,
    context: UnsafeMutableRawPointer?,
    arFlags: Int32
) -> Int32 {
    let pipeline = ActiveMoonlightBridge.shared.lock.withLock { ActiveMoonlightBridge.shared.pipeline }
    return pipeline?.handleAudioInit(opusConfig) ?? -1
}

private func moonlightAudioCleanup() {
    let pipeline = ActiveMoonlightBridge.shared.lock.withLock { ActiveMoonlightBridge.shared.pipeline }
    pipeline?.cleanupAudio()
}

private func moonlightAudioDecodeAndPlay(_ sampleData: UnsafeMutablePointer<CChar>?, _ sampleLength: Int32) {
    let pipeline = ActiveMoonlightBridge.shared.lock.withLock { ActiveMoonlightBridge.shared.pipeline }
    pipeline?.handleAudioDecodeAndPlay(sampleData, length: sampleLength)
}

private func moonlightStageStarting(_ stage: Int32) {
    let name = LiGetStageName(stage).map { String(cString: $0) } ?? "Stage \(stage)"
    let (session, gen) = ActiveMoonlightBridge.shared.lock.withLock {
        (ActiveMoonlightBridge.shared.session, ActiveMoonlightBridge.shared.generation)
    }
    guard LimelightLifecycle.shared.isCurrent(generation: gen) else { return }
    Task { @MainActor in
        guard LimelightLifecycle.shared.isCurrent(generation: gen) else { return }
        session?.state = .connecting("Connecting: \(name)…")
    }
}

private func moonlightStageFailed(_ stage: Int32, _ errorCode: Int32) {
    let name = LiGetStageName(stage).map { String(cString: $0) } ?? "Stage \(stage)"
    let (session, gen) = ActiveMoonlightBridge.shared.lock.withLock {
        (ActiveMoonlightBridge.shared.session, ActiveMoonlightBridge.shared.generation)
    }
    guard LimelightLifecycle.shared.isCurrent(generation: gen) else { return }
    Task { @MainActor in
        guard LimelightLifecycle.shared.isCurrent(generation: gen) else { return }
        let msg = "\(name) failed (error \(errorCode))."
        session?.errorMessage = msg
        session?.state = .disconnected(msg)
    }
}

private func moonlightConnectionStarted() {
    let (session, gen) = ActiveMoonlightBridge.shared.lock.withLock {
        (ActiveMoonlightBridge.shared.session, ActiveMoonlightBridge.shared.generation)
    }
    guard LimelightLifecycle.shared.isCurrent(generation: gen) else { return }
    Task { @MainActor in
        guard LimelightLifecycle.shared.isCurrent(generation: gen) else { return }
        session?.state = .streaming
    }
}

private func moonlightConnectionTerminated(_ errorCode: Int32) {
    LimelightLifecycle.shared.setInputAllowed(false)
    let (session, gen) = ActiveMoonlightBridge.shared.lock.withLock {
        (ActiveMoonlightBridge.shared.session, ActiveMoonlightBridge.shared.generation)
    }
    guard LimelightLifecycle.shared.isCurrent(generation: gen) else { return }
    Task { @MainActor in
        guard LimelightLifecycle.shared.isCurrent(generation: gen) else { return }
        session?.handleRemoteTermination(errorCode: errorCode)
    }
}

// MARK: - Interactive Backing-Layer NSView (AVSampleBufferDisplayLayer + Input)

private final class MoonlightCanvasNSView: NSView {
    let displayLayer: AVSampleBufferDisplayLayer
    private var trackingAreaRef: NSTrackingArea?
    var videoAspectRatio: CGFloat = 16.0 / 9.0
    var swapCmdToCtrl: Bool = false
    var onRelativeMouseChange: ((Bool) -> Void)?
    private var isCursorHidden = false
    var relativeMouseEnabled: Bool = false {
        didSet {
            guard oldValue != relativeMouseEnabled else { return }
            applyRelativeMouseState(relativeMouseEnabled)
        }
    }
    private var pressedKeys: Set<UInt16> = [] // stores Win32 VK codes currently held down
    private var activeModifierVKs: Set<UInt16> = []
    private var resignObserver: NSObjectProtocol?

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        self.wantsLayer = true
        self.layerContentsRedrawPolicy = .duringViewResize
    }

    deinit {
        applyRelativeMouseState(false)
        if let obs = resignObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    private func applyRelativeMouseState(_ enabled: Bool) {
        if enabled {
            CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
            if !isCursorHidden {
                NSCursor.hide()
                isCursorHidden = true
            }
        } else {
            CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
            if isCursorHidden {
                NSCursor.unhide()
                isCursorHidden = false
            }
        }
    }

    override func makeBackingLayer() -> CALayer {
        displayLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let obs = resignObserver {
            NotificationCenter.default.removeObserver(obs)
            resignObserver = nil
        }
        if let win = window {
            win.acceptsMouseMovedEvents = true
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: win,
                queue: .main
            ) { [weak self] _ in
                self?.releaseAllPressedKeys()
                if self?.relativeMouseEnabled == true {
                    self?.relativeMouseEnabled = false
                    self?.onRelativeMouseChange?(false)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        } else {
            applyRelativeMouseState(false)
        }
    }

    override func resignFirstResponder() -> Bool {
        releaseAllPressedKeys()
        if relativeMouseEnabled {
            relativeMouseEnabled = false
            onRelativeMouseChange?(false)
        }
        return super.resignFirstResponder()
    }

    func releaseAllPressedKeys() {
        for vk in pressedKeys {
            sendVK(vk, down: false, extended: Self.isExtendedVK(vk), modifiers: 0)
        }
        pressedKeys.removeAll()
        for vk in activeModifierVKs {
            sendVK(vk, down: false, extended: Self.isExtendedVK(vk), modifiers: 0)
        }
        activeModifierVKs.removeAll()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    private func videoContentRect() -> CGRect {
        let bw = bounds.width
        let bh = bounds.height
        guard bw > 0, bh > 0, videoAspectRatio > 0 else { return bounds }
        let viewAspect = bw / bh
        if viewAspect > videoAspectRatio {
            // Pillarbox (bars on left/right)
            let w = bh * videoAspectRatio
            return CGRect(x: (bw - w) / 2.0, y: 0, width: w, height: bh)
        } else {
            // Letterbox (bars on top/bottom)
            let h = bw / videoAspectRatio
            return CGRect(x: 0, y: (bh - h) / 2.0, width: bw, height: h)
        }
    }

    private func sendMouseMotion(from event: NSEvent) {
        guard LimelightLifecycle.shared.isInputAllowed else { return }
        if relativeMouseEnabled {
            let dx = Int16(clamping: Int(event.deltaX.rounded()))
            let dy = Int16(clamping: Int(event.deltaY.rounded()))
            if dx != 0 || dy != 0 {
                LimelightLifecycle.shared.sendInput {
                    LiSendMouseMoveEvent(dx, dy)
                }
            }
            return
        }
        let pt = convert(event.locationInWindow, from: nil)
        let rect = videoContentRect()
        let w = max(1, Int(rect.width))
        let h = max(1, Int(rect.height))
        let relX = pt.x - rect.minX
        let relY = rect.maxY - pt.y
        let x = max(0, min(w - 1, Int(relX)))
        let y = max(0, min(h - 1, Int(relY)))
        LimelightLifecycle.shared.sendInput {
            _ = LiSendMousePositionEvent(
                Int16(clamping: x),
                Int16(clamping: y),
                Int16(clamping: w),
                Int16(clamping: h)
            )
        }
    }

    private func sendAbsolutePositionIfNeeded(from event: NSEvent) {
        if !relativeMouseEnabled {
            sendMouseMotion(from: event)
        }
    }

    override func mouseMoved(with event: NSEvent) { sendMouseMotion(from: event) }
    override func mouseDragged(with event: NSEvent) { sendMouseMotion(from: event) }
    override func rightMouseDragged(with event: NSEvent) { sendMouseMotion(from: event) }
    override func otherMouseDragged(with event: NSEvent) { sendMouseMotion(from: event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendAbsolutePositionIfNeeded(from: event)
        LimelightLifecycle.shared.sendInput {
            LiSendMouseButtonEvent(Int8(BUTTON_ACTION_PRESS), Int32(BUTTON_LEFT))
        }
    }

    override func mouseUp(with event: NSEvent) {
        sendAbsolutePositionIfNeeded(from: event)
        LimelightLifecycle.shared.sendInput {
            LiSendMouseButtonEvent(Int8(BUTTON_ACTION_RELEASE), Int32(BUTTON_LEFT))
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendAbsolutePositionIfNeeded(from: event)
        LimelightLifecycle.shared.sendInput {
            LiSendMouseButtonEvent(Int8(BUTTON_ACTION_PRESS), Int32(BUTTON_RIGHT))
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        sendAbsolutePositionIfNeeded(from: event)
        LimelightLifecycle.shared.sendInput {
            LiSendMouseButtonEvent(Int8(BUTTON_ACTION_RELEASE), Int32(BUTTON_RIGHT))
        }
    }

    private func moonlightButton(for buttonNumber: Int) -> Int32 {
        switch buttonNumber {
        case 2: return Int32(BUTTON_MIDDLE)
        case 3: return Int32(BUTTON_X1)
        case 4: return Int32(BUTTON_X2)
        default: return Int32(BUTTON_MIDDLE)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendAbsolutePositionIfNeeded(from: event)
        let btn = moonlightButton(for: event.buttonNumber)
        LimelightLifecycle.shared.sendInput {
            LiSendMouseButtonEvent(Int8(BUTTON_ACTION_PRESS), btn)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        sendAbsolutePositionIfNeeded(from: event)
        let btn = moonlightButton(for: event.buttonNumber)
        LimelightLifecycle.shared.sendInput {
            LiSendMouseButtonEvent(Int8(BUTTON_ACTION_RELEASE), btn)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard LimelightLifecycle.shared.isInputAllowed else { return }
        let dy = Int16(clamping: Int(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 2.0 : 120.0)))
        if dy != 0 {
            LimelightLifecycle.shared.sendInput {
                LiSendHighResScrollEvent(dy)
            }
        }
        let dx = Int16(clamping: Int(-event.scrollingDeltaX * (event.hasPreciseScrollingDeltas ? 2.0 : 120.0)))
        if dx != 0 {
            LimelightLifecycle.shared.sendInput {
                LiSendHighResHScrollEvent(dx)
            }
        }
    }

    private func sendVK(_ vk: UInt16, down: Bool, extended: Bool, modifiers: Int8) {
        var mods = modifiers
        if extended {
            mods |= Int8(MODIFIER_EXTENDED)
        }
        let encodedKey = Int16(bitPattern: 0x8000 | (vk & 0xFF))
        LimelightLifecycle.shared.sendInput {
            LiSendKeyboardEvent2(encodedKey, Int8(down ? KEY_ACTION_DOWN : KEY_ACTION_UP), mods, 0)
        }
    }

    private func currentModifierBits() -> Int8 {
        var bits: Int32 = 0
        if activeModifierVKs.contains(0xA0) || activeModifierVKs.contains(0xA1) { bits |= Int32(MODIFIER_SHIFT) }
        if activeModifierVKs.contains(0xA2) || activeModifierVKs.contains(0xA3) { bits |= Int32(MODIFIER_CTRL) }
        if activeModifierVKs.contains(0xA4) || activeModifierVKs.contains(0xA5) { bits |= Int32(MODIFIER_ALT) }
        if activeModifierVKs.contains(0x5B) || activeModifierVKs.contains(0x5C) { bits |= Int32(MODIFIER_META) }
        return Int8(bits)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Intercept Cmd/Ctrl/Tab/Esc shortcuts before macOS menu bar eats them
        guard window?.isKeyWindow == true, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        // Keep Cmd+H (Hide) and Cmd+M (Minimize) native if desired; forward everything else to remote Linux
        if event.modifierFlags.contains(.command) && !swapCmdToCtrl {
            if event.keyCode == 4 || event.keyCode == 46 { // H or M
                return super.performKeyEquivalent(with: event)
            }
        }
        handleKeyDown(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        handleKeyDown(event)
    }

    private func handleKeyDown(_ event: NSEvent) {
        // Ignore macOS software key repeats so ENet reliable keyboard channel never backs up;
        // the remote Linux X11 server handles key repeat natively with zero lag.
        if event.isARepeat { return }

        // Local stream control shortcuts: Ctrl + Option + Shift + M (Relative Mouse) / Z (Release Mouse & Keys)
        let comboFlags: NSEvent.ModifierFlags = [.control, .option, .shift]
        if event.modifierFlags.intersection([.control, .option, .shift]) == comboFlags {
            if event.keyCode == 46 { // M
                let next = !relativeMouseEnabled
                releaseAllPressedKeys()
                relativeMouseEnabled = next
                onRelativeMouseChange?(next)
                return
            }
            if event.keyCode == 6 { // Z
                releaseAllPressedKeys()
                if relativeMouseEnabled {
                    relativeMouseEnabled = false
                    onRelativeMouseChange?(false)
                }
                return
            }
        }

        syncModifiers(from: event.modifierFlags)
        guard let mapped = Self.macKeyCodeToVK(event.keyCode) else { return }
        if pressedKeys.insert(mapped.vk).inserted {
            sendVK(mapped.vk, down: true, extended: mapped.extended, modifiers: currentModifierBits())
        }
    }

    override func keyUp(with event: NSEvent) {
        syncModifiers(from: event.modifierFlags)
        guard let mapped = Self.macKeyCodeToVK(event.keyCode) else { return }
        pressedKeys.remove(mapped.vk)
        sendVK(mapped.vk, down: false, extended: mapped.extended, modifiers: currentModifierBits())
    }

    override func flagsChanged(with event: NSEvent) {
        // Caps Lock (keyCode 57) is a toggle key on macOS
        if event.keyCode == 57 {
            let mods = currentModifierBits()
            sendVK(0x14, down: true, extended: false, modifiers: mods)
            sendVK(0x14, down: false, extended: false, modifiers: mods)
            return
        }
        syncModifiers(from: event.modifierFlags)
    }

    private func syncModifiers(from flags: NSEvent.ModifierFlags) {
        let raw = flags.rawValue
        let lShift = (raw & UInt(NX_DEVICELSHIFTKEYMASK)) != 0
        let rShift = (raw & UInt(NX_DEVICERSHIFTKEYMASK)) != 0
        let lCtrl = (raw & UInt(NX_DEVICELCTLKEYMASK)) != 0
        let rCtrl = (raw & UInt(NX_DEVICERCTLKEYMASK)) != 0
        let lAlt = (raw & UInt(NX_DEVICELALTKEYMASK)) != 0
        let rAlt = (raw & UInt(NX_DEVICERALTKEYMASK)) != 0
        let lCmd = (raw & UInt(NX_DEVICELCMDKEYMASK)) != 0
        let rCmd = (raw & UInt(NX_DEVICERCMDKEYMASK)) != 0

        let desired: [(vk: UInt16, down: Bool, extended: Bool)] = [
            (0xA0, lShift, false),
            (0xA1, rShift, true),
            (swapCmdToCtrl ? 0x5B : 0xA2, lCtrl, swapCmdToCtrl ? true : false),
            (swapCmdToCtrl ? 0x5C : 0xA3, rCtrl, true),
            (0xA4, lAlt, false),
            (0xA5, rAlt, true),
            (swapCmdToCtrl ? 0xA2 : 0x5B, lCmd, swapCmdToCtrl ? false : true),
            (swapCmdToCtrl ? 0xA3 : 0x5C, rCmd, true)
        ]

        for item in desired {
            let wasDown = activeModifierVKs.contains(item.vk)
            if item.down && !wasDown {
                activeModifierVKs.insert(item.vk)
                sendVK(item.vk, down: true, extended: item.extended, modifiers: currentModifierBits())
            } else if !item.down && wasDown {
                activeModifierVKs.remove(item.vk)
                sendVK(item.vk, down: false, extended: item.extended, modifiers: currentModifierBits())
            }
        }
    }

    private static func isExtendedVK(_ vk: UInt16) -> Bool {
        switch vk {
        case 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2D, 0x2E,
             0x5B, 0x5C, 0xA1, 0xA3, 0xA5, 0x6F:
            return true
        default:
            return false
        }
    }

    private static func macKeyCodeToVK(_ code: UInt16) -> (vk: UInt16, extended: Bool)? {
        switch code {
        // Letters A-Z (US ANSI hardware keycodes)
        case 0: return (0x41, false)
        case 11: return (0x42, false)
        case 8: return (0x43, false)
        case 2: return (0x44, false)
        case 14: return (0x45, false)
        case 3: return (0x46, false)
        case 5: return (0x47, false)
        case 4: return (0x48, false)
        case 34: return (0x49, false)
        case 38: return (0x4A, false)
        case 40: return (0x4B, false)
        case 37: return (0x4C, false)
        case 46: return (0x4D, false)
        case 45: return (0x4E, false)
        case 31: return (0x4F, false)
        case 35: return (0x50, false)
        case 12: return (0x51, false)
        case 15: return (0x52, false)
        case 1: return (0x53, false)
        case 17: return (0x54, false)
        case 32: return (0x55, false)
        case 9: return (0x56, false)
        case 13: return (0x57, false)
        case 7: return (0x58, false)
        case 16: return (0x59, false)
        case 6: return (0x5A, false)
        // Top-row digits 0-9
        case 29: return (0x30, false)
        case 18: return (0x31, false)
        case 19: return (0x32, false)
        case 20: return (0x33, false)
        case 21: return (0x34, false)
        case 23: return (0x35, false)
        case 22: return (0x36, false)
        case 26: return (0x37, false)
        case 28: return (0x38, false)
        case 25: return (0x39, false)
        // Core control keys
        case 36: return (0x0D, false)  // Return
        case 76: return (0x0D, true)   // Numpad Enter
        case 48: return (0x09, false)  // Tab
        case 49: return (0x20, false)  // Space
        case 51: return (0x08, false)  // Backspace
        case 53: return (0x1B, false)  // Escape
        case 117: return (0x2E, true)  // Forward Delete
        case 114: return (0x2D, true)  // Help / Insert
        // Navigation (extended keys)
        case 123: return (0x25, true)  // Left
        case 124: return (0x27, true)  // Right
        case 125: return (0x28, true)  // Down
        case 126: return (0x26, true)  // Up
        case 115: return (0x24, true)  // Home
        case 119: return (0x23, true)  // End
        case 116: return (0x21, true)  // PageUp
        case 121: return (0x22, true)  // PageDown
        // OEM Punctuation
        case 27: return (0xBD, false)  // - _
        case 24: return (0xBB, false)  // = +
        case 33: return (0xDB, false)  // [ {
        case 30: return (0xDD, false)  // ] }
        case 42: return (0xDC, false)  // \ |
        case 41: return (0xBA, false)  // ; :
        case 39: return (0xDE, false)  // ' "
        case 43: return (0xBC, false)  // , <
        case 47: return (0xBE, false)  // . >
        case 44: return (0xBF, false)  // / ?
        case 50: return (0xC0, false)  // ` ~
        // Function keys F1-F12
        case 122: return (0x70, false)
        case 120: return (0x71, false)
        case 99: return (0x72, false)
        case 118: return (0x73, false)
        case 96: return (0x74, false)
        case 97: return (0x75, false)
        case 98: return (0x76, false)
        case 100: return (0x77, false)
        case 101: return (0x78, false)
        case 109: return (0x79, false)
        case 103: return (0x7A, false)
        case 111: return (0x7B, false)
        // Numpad
        case 82: return (0x60, false)
        case 83: return (0x61, false)
        case 84: return (0x62, false)
        case 85: return (0x63, false)
        case 86: return (0x64, false)
        case 87: return (0x65, false)
        case 88: return (0x66, false)
        case 89: return (0x67, false)
        case 91: return (0x68, false)
        case 92: return (0x69, false)
        case 67: return (0x6A, false)  // Numpad *
        case 69: return (0x6B, false)  // Numpad +
        case 78: return (0x6D, false)  // Numpad -
        case 65: return (0x6E, false)  // Numpad .
        case 75: return (0x6F, true)   // Numpad /
        default: return nil
        }
    }
}

private struct MoonlightCanvasView: NSViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer
    let videoAspectRatio: CGFloat
    let swapCmdToCtrl: Bool
    let relativeMouseEnabled: Bool
    let onRelativeMouseChange: (Bool) -> Void

    func makeNSView(context: Context) -> MoonlightCanvasNSView {
        let view = MoonlightCanvasNSView(displayLayer: displayLayer)
        view.videoAspectRatio = videoAspectRatio
        view.swapCmdToCtrl = swapCmdToCtrl
        view.relativeMouseEnabled = relativeMouseEnabled
        view.onRelativeMouseChange = onRelativeMouseChange
        return view
    }

    func updateNSView(_ nsView: MoonlightCanvasNSView, context: Context) {
        nsView.videoAspectRatio = videoAspectRatio
        nsView.swapCmdToCtrl = swapCmdToCtrl
        nsView.relativeMouseEnabled = relativeMouseEnabled
        nsView.onRelativeMouseChange = onRelativeMouseChange
    }
}

// MARK: - UU-Style Edge-Docked Floating Ball & Control Panel

private struct MoonlightStreamContentView: View {
    @ObservedObject var session: MoonlightStreamSession
    @ObservedObject private var l10n = AppLocalization.shared
    let onToggleFullscreen: () -> Void
    let onClose: () -> Void

    @State private var isMenuOpen = false
    @State private var isHoveringOrb = false
    @State private var dockedRight = true
    @State private var orbYRatio: CGFloat = 0.28
    @State private var dragOffset: CGSize = .zero

    private let orbSize: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Full edge-to-edge hardware video canvas (no top bar!)
                MoonlightCanvasView(
                    displayLayer: session.displayLayer,
                    videoAspectRatio: CGFloat(session.stats.videoAspectRatio),
                    swapCmdToCtrl: session.swapCmdToCtrl,
                    relativeMouseEnabled: session.relativeMouseEnabled,
                    onRelativeMouseChange: { enabled in
                        session.relativeMouseEnabled = enabled
                    }
                )
                    .ignoresSafeArea()

                // Optional pinned compact performance HUD
                if session.showPerformanceHUD && session.state == .streaming {
                    VStack {
                        HStack {
                            performanceHUDPill
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(14)
                    .allowsHitTesting(false)
                }

                // Connection / Disconnection center overlay
                switch session.state {
                case .idle, .streaming:
                    EmptyView()
                case .connecting(let msg):
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text(msg)
                            .font(.callout)
                            .foregroundStyle(.white)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                case .disconnected(let reason):
                    VStack(spacing: 10) {
                        Image(systemName: "display.trianglebadge.exclamationmark")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text(reason ?? "Stream disconnected")
                            .font(.callout)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                        Button("Close Window", action: onClose)
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                // UU-style always-present edge-docked floating orb (half-hidden at side when idle)
                floatingEdgeOrb(in: geo.size)
            }
        }
        .background(Color.black)
        .frame(minWidth: 960, minHeight: 580)
    }

    private func floatingEdgeOrb(in size: CGSize) -> some View {
        let isExpanded = isHoveringOrb || isMenuOpen || dragOffset != .zero
        let clampedY = min(max(44, size.height * orbYRatio + dragOffset.height), max(44, size.height - 44))
        // Half-hidden on the side edge when idle, slides out on hover/open
        let baseX: CGFloat = dockedRight
            ? (isExpanded ? size.width - (orbSize / 2 + 10) : size.width - 6)
            : (isExpanded ? (orbSize / 2 + 10) : 6)

        // IMPORTANT: Attach .onHover, .simultaneousGesture, and .popover BEFORE positioning
        // so the gesture/hover hit area is strictly limited to the 44×44 orb and NEVER blocks
        // mouse clicks on the underlying remote desktop canvas!
        let orbControl = Button {
            isMenuOpen.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(isExpanded ? 0.35 : 0.2), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 2)

                VStack(spacing: 2) {
                    Image(systemName: isMenuOpen ? "xmark" : "slider.horizontal.3")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Circle()
                        .fill(statusColor)
                        .frame(width: 5.5, height: 5.5)
                }
            }
            .frame(width: orbSize, height: orbSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                isHoveringOrb = hovering
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    dragOffset = value.translation
                }
                .onEnded { value in
                    let finalX = baseX + value.translation.width
                    let finalY = clampedY
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        dockedRight = finalX >= size.width / 2
                        orbYRatio = min(max(0.08, finalY / max(1, size.height)), 0.92)
                        dragOffset = .zero
                    }
                }
        )
        .popover(isPresented: $isMenuOpen, arrowEdge: dockedRight ? .leading : .trailing) {
            floatingControlPanel
        }
        .help("NodeDeck Stream Controls (drag to reposition along edge)")

        return orbControl
            .offset(
                x: (baseX + dragOffset.width) - size.width / 2,
                y: clampedY - size.height / 2
            )
    }

    private var floatingControlPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(session.streamTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                        isMenuOpen = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.65))
                }
                .buttonStyle(.plain)
            }

            // Performance Monitor Block (inside floating panel + pin toggle)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(l10n.t("性能监测", "Telemetry"), systemImage: "gauge.with.dots.needle.67percent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Toggle(l10n.t("常驻浮窗", "Pin HUD"), isOn: $session.showPerformanceHUD)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    statCell("FPS", "\(session.stats.fps) / \(session.targetFPS) fps")
                    statCell(l10n.t("码率", "Bitrate"), String(format: "%.1f Mbps", session.stats.bitrateMbps))
                    statCell(l10n.t("分辨率", "Resolution"), session.stats.resolution)
                    statCell(l10n.t("编解码", "Codec"), session.stats.codec.replacingOccurrences(of: " (VideoToolbox)", with: ""))
                    statCell(l10n.t("网络 RTT", "Network RTT"), session.stats.networkRttMs > 0 ? "\(session.stats.networkRttMs) ms (±\(session.stats.networkJitterMs))" : "—")
                    statCell(l10n.t("传输路径", "Route"), session.stats.transportRoute)
                    statCell(l10n.t("主机编码", "Host Encode"), session.stats.hostLatencyMs > 0 ? String(format: "%.1f ms", session.stats.hostLatencyMs) : "—")
                    statCell(l10n.t("渲染状态", "Renderer"), session.stats.rendererStatus)
                }
            }
            .padding(10)
            .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            // Quick Switches: Privacy Screen & Fullscreen
            HStack(spacing: 8) {
                Button {
                    session.togglePrivacyScreen()
                } label: {
                    Label(
                        session.isPrivacyScreenEnabled ? l10n.t("隐私屏已开", "Privacy On") : l10n.t("隐私屏", "Privacy Screen"),
                        systemImage: session.isPrivacyScreenEnabled ? "eye.slash.fill" : "eye.slash"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(session.isPrivacyScreenEnabled ? .orange : Color.white.opacity(0.18))
                .controlSize(.small)
                .disabled(session.state != .streaming || session.isTogglingPrivacyScreen)

                Button {
                    onToggleFullscreen()
                } label: {
                    Label(l10n.t("全屏", "Fullscreen"), systemImage: "arrow.up.left.and.arrow.down.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Toggle(l10n.t("⌘ 键映射为 Linux Ctrl（⌘C/⌘V 直接用）", "Map ⌘ Command to Linux Ctrl"), isOn: $session.swapCmdToCtrl)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.88))

            Toggle(l10n.t("相对鼠标锁定（3D/FPS · ⌃⌥⇧M 切换）", "Relative Mouse Lock (3D/FPS · ⌃⌥⇧M)"), isOn: $session.relativeMouseEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.88))

            if session.canSyncClipboard {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(l10n.t("剪贴板同步", "Clipboard Sync"), systemImage: "doc.on.clipboard")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.8))
                        Spacer()
                        Toggle(l10n.t("自动双向同步", "Auto Sync"), isOn: $session.clipboardAutoSync)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    HStack(spacing: 6) {
                        Button(l10n.t("发到远端 →", "Push to Host →")) {
                            session.pushMacClipboardToRemote()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)

                        Button(l10n.t("← 拉到 Mac", "← Pull to Mac")) {
                            session.pullRemoteClipboardToMac()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                    }
                    if let msg = session.clipboardStatusMessage {
                        Text(msg)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                }
                .padding(8)
                .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            // Resolution & Refresh Rate Switcher
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(l10n.t("切换分辨率", "Resolution"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    HStack(spacing: 6) {
                        ForEach(StreamResolutionPreset.allCases) { preset in
                            resButton(preset)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(l10n.t("刷新率 / 帧率", "Refresh Rate"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    HStack(spacing: 6) {
                        ForEach(StreamRefreshRate.allCases) { rate in
                            fpsButton(rate)
                        }
                    }
                }
            }

            Divider().overlay(Color.white.opacity(0.15))

            // System Actions
            HStack(spacing: 8) {
                Button("Ctrl+Alt+Del") {
                    session.sendCtrlAltDel()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(session.state != .streaming)

                Button(l10n.t("结束远端应用", "Quit App")) {
                    session.stop(quitRemoteApp: true)
                    onClose()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button(l10n.t("断开", "Disconnect")) {
                    session.stop(quitRemoteApp: false)
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
        .preferredColorScheme(.dark)
    }

    private func statCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.55))
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func resButton(_ preset: StreamResolutionPreset) -> some View {
        let isSelected = session.targetWidth == preset.width && session.targetHeight == preset.height
        if isSelected {
            Button(preset.label) {
                isMenuOpen = false
                session.switchResolution(preset)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
        } else {
            Button(preset.label) {
                isMenuOpen = false
                session.switchResolution(preset)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func fpsButton(_ rate: StreamRefreshRate) -> some View {
        let isSelected = session.targetFPS == rate.fps
        if isSelected {
            Button(rate.label) {
                isMenuOpen = false
                session.switchRefreshRate(rate)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
        } else {
            Button(rate.label) {
                isMenuOpen = false
                session.switchRefreshRate(rate)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
        }
    }

    private var performanceHUDPill: some View {
        HStack(spacing: 10) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text("\(session.stats.fps)/\(session.targetFPS) fps")
            Text("·")
            Text(String(format: "%.1f Mbps", session.stats.bitrateMbps))
            Text("·")
            Text(session.stats.resolution)
            if session.stats.networkRttMs > 0 {
                Text("·")
                Text("RTT \(session.stats.networkRttMs)ms")
            }
            Text("·")
            Text(session.stats.transportRoute)
            if session.stats.hostLatencyMs > 0 {
                Text("·")
                Text(String(format: "Enc %.1fms", session.stats.hostLatencyMs))
            }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.62), in: Capsule(style: .continuous))
        .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
    }

    private var statusColor: Color {
        switch session.state {
        case .streaming: return .green
        case .connecting: return .orange
        default: return .red
        }
    }
}

@MainActor
final class MoonlightStreamWindowController: NSObject, NSWindowDelegate {
    static let shared = MoonlightStreamWindowController()

    private var window: NSWindow?
    private var session: MoonlightStreamSession?

    func openStream(
        hostAlias: String? = nil,
        address: String,
        httpPort: Int = 47989,
        appTitle: String = "Desktop",
        width: Int = 1920,
        height: Int = 1080,
        fps: Int = 60,
        enablePrivacyScreen: Bool = false,
        onStreamConfigChanged: ((Int, Int, Int) -> Void)? = nil
    ) {
        closeCurrentWindow()

        let newSession = MoonlightStreamSession()
        newSession.onStreamConfigChanged = onStreamConfigChanged
        self.session = newSession

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "NodeDeck — \(hostAlias ?? address)"
        win.backgroundColor = .black
        win.center()
        win.delegate = self
        win.isReleasedWhenClosed = false

        let contentView = MoonlightStreamContentView(
            session: newSession,
            onToggleFullscreen: { [weak win] in
                win?.toggleFullScreen(nil)
            },
            onClose: { [weak self] in
                self?.closeCurrentWindow()
            }
        )
        win.contentView = NSHostingView(rootView: contentView)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win

        newSession.start(
            hostAlias: hostAlias,
            address: address,
            httpPort: httpPort,
            preferredAppTitle: appTitle,
            width: width,
            height: height,
            fps: fps,
            enablePrivacyScreen: enablePrivacyScreen
        )
    }

    func closeCurrentWindow() {
        session?.stop(quitRemoteApp: false)
        session = nil
        window?.delegate = nil
        window?.close()
        window = nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        session?.handleWindowDidBecomeKey()
    }

    func windowDidResignKey(_ notification: Notification) {
        session?.handleWindowDidResignKey()
    }

    func windowWillClose(_ notification: Notification) {
        session?.stop(quitRemoteApp: false)
        session = nil
        window = nil
    }
}
