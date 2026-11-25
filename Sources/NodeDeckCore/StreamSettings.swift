import Foundation

public enum StreamResolutionPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case hd1080 = "1080p"
    case qhd1440 = "1440p"
    case uhd4k = "4K"

    public var id: String { rawValue }

    public var width: Int {
        switch self {
        case .hd1080: return 1920
        case .qhd1440: return 2560
        case .uhd4k: return 3840
        }
    }

    public var height: Int {
        switch self {
        case .hd1080: return 1080
        case .qhd1440: return 1440
        case .uhd4k: return 2160
        }
    }

    public var label: String { rawValue }

    public init?(width: Int, height: Int) {
        switch (width, height) {
        case (1920, 1080): self = .hd1080
        case (2560, 1440): self = .qhd1440
        case (3840, 2160): self = .uhd4k
        default: return nil
        }
    }

    public func modeString(fps: Int) -> String {
        "\(width)x\(height)x\(fps)"
    }
}

public enum StreamRefreshRate: Int, CaseIterable, Identifiable, Codable, Sendable {
    case hz60 = 60
    case hz120 = 120
    case hz144 = 144
    case hz165 = 165

    public var id: Int { rawValue }
    public var fps: Int { rawValue }
    public var label: String { "\(rawValue)Hz" }
    public var fpsLabel: String { "\(rawValue)fps" }
    public var clientRefreshRateX100: Int { rawValue * 100 }
}

public enum StreamQualityMath {
    /// Computes a recommended Moonlight/Sunshine video bitrate (in kbps) scaled smoothly
    /// by resolution pixel count and refresh rate, rounded to 5 Mbps increments.
    public static func recommendedBitrateKbps(width: Int, height: Int, fps: Int) -> Int {
        let clampedW = max(640, width)
        let clampedH = max(360, height)
        let clampedFPS = max(30, fps)
        let pixelRatio = Double(clampedW * clampedH) / Double(1920 * 1080)
        let fpsRatio = Double(clampedFPS) / 60.0
        let raw = 20_000.0 * pow(pixelRatio, 0.72) * pow(fpsRatio, 0.75)
        let rounded = Int((raw / 5_000.0).rounded()) * 5_000
        return min(max(rounded, 20_000), 120_000)
    }
}
