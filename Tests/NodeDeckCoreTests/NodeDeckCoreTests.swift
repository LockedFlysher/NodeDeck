import XCTest
@testable import NodeDeckCore

final class NodeDeckCoreTests: XCTestCase {
    func testDiscoversConcreteAliasesAndHostGroups() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NodeDeckTests-\(UUID().uuidString)")
        let configDirectory = root.appendingPathComponent("config.d")
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let mainConfig = root.appendingPathComponent("config")
        try """
        # primary hosts
        Host alpha beta
          HostName example.com

        Host *
          ServerAliveInterval 30

        Include config.d/*
        """.write(to: mainConfig, atomically: true, encoding: .utf8)

        try """
        Host gamma
          HostName 203.0.113.20
        """.write(
            to: configDirectory.appendingPathComponent("extra"),
            atomically: true,
            encoding: .utf8
        )

        let aliases = try SSHConfigParser.discoverAliases(configURL: mainConfig)
        XCTAssertEqual(aliases, ["alpha", "beta", "gamma"])

        let groups = try SSHConfigParser.discoverHostGroups(configURL: mainConfig)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].primary, "alpha")
        XCTAssertEqual(groups[0].alternates, ["beta"])
        XCTAssertEqual(groups[1].primary, "gamma")
        XCTAssertEqual(groups[1].alternates, [])
    }

    func testParsesRemoteMetricsAndDirectories() throws {
        let output = """
        SSHDECK_BEGIN
        HOSTNAME=lab-node
        OS=Ubuntu 24.04.1 LTS
        KERNEL=Linux 6.8.0
        ARCH=x86_64
        USER=operator
        HOME_DIR=/home/operator
        CANDIDATE_DIR=/home/operator/project
        CANDIDATE_DIR=/home/operator/server
        CPU_MODEL=AMD EPYC 7763
        CPU_CORES=128
        CPU_USAGE=23.5
        LOAD1=4.20
        LOAD5=3.80
        LOAD15=3.10
        UPTIME_SECONDS=259200
        MEM_TOTAL=1099511627776
        MEM_AVAILABLE=549755813888
        SWAP_TOTAL=17179869184
        SWAP_FREE=8589934592
        DISK_TOTAL=4000000000000
        DISK_USED=1000000000000
        DISK_AVAILABLE=3000000000000
        GPU=NVIDIA A800, 71, 40960, 81920, 63, 240.5, active
        GPU=AMD Radeon RX 9060 XT, 0, 57, 8144, N/A, N/A, suspended
        SLURM=1
        SLURM_NODE=cpu-40-1|cpu-40|idle|0/40/0/40|386000|(null)|cpu,40
        SLURM_NODE=cpu-40-2|cpu-40|allocated|40/0/0/40|386000|(null)|cpu,40
        SLURM_NODE=gpu-a100-1|gpu-a100|mixed|32/16/0/48|386000|gpu:a100:1|gpu,a100
        PROC=Web Content|120.5|2.4
        SCRIPT_MS=265.4
        SSHDECK_END
        """

        let metrics = try XCTUnwrap(RemoteMetricsParser.parse(output))
        XCTAssertEqual(metrics.hostname, "lab-node")
        XCTAssertEqual(metrics.homeDirectory, "/home/operator")
        XCTAssertEqual(metrics.candidateDirectories, ["/home/operator/project", "/home/operator/server"])
        XCTAssertEqual(metrics.cpuCores, 128)
        XCTAssertEqual(metrics.cpuUsage, 23.5, accuracy: 0.001)
        XCTAssertEqual(metrics.memoryFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(metrics.diskFraction, 0.25, accuracy: 0.001)
        XCTAssertEqual(metrics.gpus.count, 2)
        XCTAssertEqual(metrics.gpus[0].name, "NVIDIA A800")
        XCTAssertEqual(metrics.gpus[0].utilization, 71)
        XCTAssertFalse(metrics.gpus[0].isAMD)
        XCTAssertFalse(metrics.gpus[0].isSleeping)
        XCTAssertEqual(metrics.gpus[1].name, "AMD Radeon RX 9060 XT")
        XCTAssertTrue(metrics.gpus[1].isAMD)
        XCTAssertTrue(metrics.gpus[1].isSleeping)
        XCTAssertEqual(metrics.gpus[1].memoryTotalMB, 8144)
        XCTAssertEqual(metrics.processes.first?.name, "Web Content")
        XCTAssertEqual(try XCTUnwrap(metrics.scriptDurationMilliseconds), 265.4, accuracy: 0.01)

        let slurm = try XCTUnwrap(metrics.slurm)
        XCTAssertEqual(slurm.nodes.count, 3)
        XCTAssertEqual(slurm.idleNodeCount, 1)
        XCTAssertEqual(slurm.allocatedNodeCount, 1)
        XCTAssertEqual(slurm.mixedNodeCount, 1)
        XCTAssertEqual(slurm.idleCPUs, 56)
        XCTAssertEqual(slurm.totalCPUs, 128)
        XCTAssertEqual(
            slurm.nodes.first(where: { $0.name == "gpu-a100-1" })?.gpuDescription,
            "A100 x1"
        )
    }

    func testMountTableParsingAndHostMatching() throws {
        let mountOutput = """
        /dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)
        //operator@192.0.2.20/Workspace on /Users/demo/STUDIO-Workspace (smbfs, nodev, nosuid, mounted by demo)
        localhost:/ on /Users/demo/GPU-NODE-project (nfs, nodev, nosuid, mounted by demo)
        localhost:/ on /Users/demo/EDGE-BOX-server (nfs, nodev, nosuid, mounted by demo)
        """

        let parsed = MountManager.parseMountTable(mountOutput)
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed[0].fileSystemType, "smbfs")
        XCTAssertEqual(parsed[1].fileSystemType, "nfs")

        let gpuHost = SSHHost(
            alias: "gpu-node",
            alternateAliases: ["workstation-gpu-direct"],
            hostName: "127.0.0.1",
            user: "operator",
            port: 2222
        )
        XCTAssertEqual(gpuHost.routeKind, .localTunnel)

        let configs = [
            FolderMountConfig(
                hostAlias: "gpu-node",
                label: "GPU-NODE-project",
                remotePath: "/home/operator/project",
                localPath: "/Users/demo/GPU-NODE-project"
            )
        ]

        let itemsGPU = MountManager.buildItems(
            for: gpuHost,
            configs: configs,
            systemMounts: parsed
        )
        XCTAssertEqual(itemsGPU.count, 1)
        XCTAssertTrue(itemsGPU[0].isMounted)
        XCTAssertEqual(itemsGPU[0].sourceKind, .managedSFTP)

        let studioHost = SSHHost(
            alias: "ethernet-studio",
            hostName: "fe80::1234:56ff:fe78:9abc%en7",
            user: "operator",
            port: 22
        )
        XCTAssertEqual(studioHost.routeKind, .directLAN)

        let itemsStudio = MountManager.buildItems(
            for: studioHost,
            configs: configs,
            systemMounts: parsed
        )
        XCTAssertEqual(itemsStudio.count, 1)
        XCTAssertEqual(itemsStudio[0].sourceKind, .externalSystem)
        XCTAssertEqual(itemsStudio[0].fileSystemType, "SMBFS")
    }

    func testShellQuotesAliasesWithSpaces() {
        XCTAssertEqual(Shell.quote("lab"), "lab")
        XCTAssertEqual(Shell.quote("cloud (Tokyo)"), "'cloud (Tokyo)'")
        XCTAssertEqual(Shell.quote("my host"), "'my host'")
    }

    func testTunnelConfigParsingAndRedaction() throws {
        XCTAssertTrue(TunnelManager.defaultSeedConfigs().isEmpty)

        let sshTunnel = GostTunnelConfig(
            hostAlias: "gpu-node",
            label: "GPU SSH (QUIC)",
            role: .ssh,
            listenSpecs: ["tcp://127.0.0.1:2222/127.0.0.1:22"],
            forwardChain: "relay+quic://operator:example-token@198.51.100.10:18443?\(TunnelManager.defaultQuicQuery)",
            autoStart: true
        )
        XCTAssertEqual(sshTunnel.primaryLocalPort, 2222)
        XCTAssertEqual(sshTunnel.portSummary, ":2222 → :22")
        XCTAssertEqual(sshTunnel.redactedForwardEndpoint, "relay+quic://198.51.100.10:18443")

        let moonlight = GostTunnelConfig(
            hostAlias: "gpu-node",
            label: "GPU Moonlight (NVENC)",
            role: .moonlight,
            listenSpecs: [
                "tcp://127.0.0.1:47984/127.0.0.1:47984",
                "tcp://127.0.0.1:47989/127.0.0.1:47989",
                "tcp://127.0.0.1:47990/127.0.0.1:47990",
                "tcp://127.0.0.1:48010/127.0.0.1:48010",
                "udp-direct://127.0.0.1:47998/198.51.100.10:47998",
                "udp-direct://127.0.0.1:47999/198.51.100.10:47999",
                "udp-direct://127.0.0.1:48000/198.51.100.10:48000",
                "udp-direct://127.0.0.1:48010/198.51.100.10:48010"
            ],
            forwardChain: "relay+quic://operator:example-token@198.51.100.10:18446?\(TunnelManager.defaultQuicQuery)",
            autoStart: true
        )
        XCTAssertEqual(moonlight.primaryLocalPort, 47984)
        XCTAssertEqual(moonlight.moonlightHTTPPort, 47989)
        XCTAssertEqual(moonlight.redactedForwardEndpoint, "relay+quic://198.51.100.10:18446")
        XCTAssertEqual(moonlight.directUDPRules.count, 4)
        XCTAssertEqual(moonlight.gostListenSpecs.count, 4)

        let moonlightArgs = TunnelManager.buildArguments(for: moonlight)
        XCTAssertFalse(moonlightArgs.contains { $0.contains("udp-direct://") })
        XCTAssertEqual(moonlightArgs.filter { $0 == "-L" }.count, 4)

        let args = TunnelManager.buildArguments(for: sshTunnel)
        XCTAssertEqual(args.first, "-L")
        XCTAssertTrue(args.contains { $0.contains("retries=2") })
        XCTAssertTrue(args.contains("-F"))
    }

    func testLegacyMoonlightUDPConfigMigration() {
        let legacy = GostTunnelConfig(
            hostAlias: "gpu-node",
            label: "GPU Moonlight",
            role: .moonlight,
            listenSpecs: [
                "tcp://127.0.0.1:47989/127.0.0.1:47989",
                "udp://127.0.0.1:47998/127.0.0.1:47998",
                "udp://127.0.0.1:47999/127.0.0.1:47999"
            ],
            forwardChain: "relay+quic://operator:secret@198.51.100.10:18446?keepalive=true"
        )
        let (migrated, didMigrate) = TunnelManager.migrateConfigsIfNeeded([legacy])
        XCTAssertTrue(didMigrate)
        XCTAssertEqual(migrated[0].directUDPRules.count, 2)
        XCTAssertEqual(migrated[0].directUDPRules[0].remoteHost, "198.51.100.10")
        XCTAssertEqual(migrated[0].directUDPRules[0].remotePort, 47998)
        XCTAssertEqual(migrated[0].gostListenSpecs, ["tcp://127.0.0.1:47989/127.0.0.1:47989"])
    }

    func testDirectUDPRelayRoundTrip() throws {
        // Bind a temporary UDP echo socket on loopback
        let echoFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        XCTAssertGreaterThanOrEqual(echoFD, 0)
        defer { close(echoFD) }

        var echoAddr = sockaddr_in()
        echoAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        echoAddr.sin_family = sa_family_t(AF_INET)
        echoAddr.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &echoAddr.sin_addr)
        let bindRes = withUnsafePointer(to: &echoAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(echoFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindRes, 0)

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &echoAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(echoFD, $0, &len)
            }
        }
        let echoPort = Int(UInt16(bigEndian: echoAddr.sin_port))

        // Pick a free relay local port
        let probeFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        var probeAddr = echoAddr
        probeAddr.sin_port = 0
        _ = withUnsafePointer(to: &probeAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(probeFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        _ = withUnsafeMutablePointer(to: &probeAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(probeFD, $0, &len)
            }
        }
        let relayPort = Int(UInt16(bigEndian: probeAddr.sin_port))
        close(probeFD)

        let relay = try DirectUDPRelayEndpoint(
            rule: .init(localHost: "127.0.0.1", localPort: relayPort, remoteHost: "127.0.0.1", remotePort: echoPort)
        )
        defer { relay.stop() }

        let clientFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        defer { close(clientFD) }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(echoFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var relayAddr = sockaddr_in()
        relayAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        relayAddr.sin_family = sa_family_t(AF_INET)
        relayAddr.sin_port = in_port_t(UInt16(relayPort).bigEndian)
        inet_pton(AF_INET, "127.0.0.1", &relayAddr.sin_addr)

        let payload = Array("MOONLIGHT_RTP_FRAME".utf8)
        _ = payload.withUnsafeBytes { raw in
            withUnsafePointer(to: &relayAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(clientFD, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var peer = sockaddr_in()
        var peerLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        var rxBuf = [UInt8](repeating: 0, count: 128)
        let nEcho = rxBuf.withUnsafeMutableBytes { raw in
            withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.recvfrom(echoFD, raw.baseAddress, raw.count, 0, $0, &peerLen)
                }
            }
        }
        XCTAssertEqual(nEcho, payload.count)

        _ = rxBuf.withUnsafeBytes { raw in
            withUnsafePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(echoFD, raw.baseAddress, nEcho, 0, $0, peerLen)
                }
            }
        }

        var clientRx = [UInt8](repeating: 0, count: 128)
        let nClient = clientRx.withUnsafeMutableBytes { raw in
            Darwin.recvfrom(clientFD, raw.baseAddress, raw.count, 0, nil, nil)
        }
        XCTAssertEqual(nClient, payload.count)
        XCTAssertEqual(Array(clientRx.prefix(nClient)), payload)
    }

    func testLaunchAtLoginPlistLifecycle() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NodeDeckLaunchTest-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        XCTAssertFalse(LaunchAtLoginManager.isEnabled(plistURL: tempURL))

        try LaunchAtLoginManager.setEnabled(
            true,
            executablePath: "/Applications/NodeDeck.app/Contents/MacOS/NodeDeck",
            plistURL: tempURL
        )
        XCTAssertTrue(LaunchAtLoginManager.isEnabled(plistURL: tempURL))

        let data = try Data(contentsOf: tempURL)
        let dict = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(
            dict["ProgramArguments"] as? [String],
            ["/Applications/NodeDeck.app/Contents/MacOS/NodeDeck", "--background"]
        )

        try LaunchAtLoginManager.setEnabled(false, plistURL: tempURL)
        XCTAssertFalse(LaunchAtLoginManager.isEnabled(plistURL: tempURL))
    }

    func testVSCodeWorkspaceParsingAndHostMatching() throws {
        let hostAlpha = SSHHost(
            alias: "alpha-gpu",
            alternateAliases: ["workstation-alpha-gpu-direct"],
            hostName: "127.0.0.1",
            user: "alice",
            port: 2222
        )
        let hostEdgeLocal = SSHHost(
            alias: "edgebox",
            alternateAliases: ["workstation-edgebox-direct"],
            hostName: "127.0.0.1",
            user: "alice",
            port: 2230
        )
        let hostEdgeWAN = SSHHost(
            alias: "workstation-edgebox",
            hostName: "203.0.113.50",
            user: "alice",
            port: 6051
        )
        let hostCloud = SSHHost(
            alias: "cloud-gateway",
            hostName: "203.0.113.50",
            user: "ubuntu",
            port: 22
        )
        let hostStorage = SSHHost(
            alias: "storage-nas",
            hostName: "203.0.113.50",
            user: "alice",
            port: 6053
        )
        let allHosts = [hostAlpha, hostEdgeLocal, hostEdgeWAN, hostCloud, hostStorage]
        let mountConfigs = [
            FolderMountConfig(
                hostAlias: "edgebox",
                label: "EDGEBOX-services",
                remotePath: "/home/alice/services",
                localPath: "/Users/demo/EDGEBOX-services"
            ),
            FolderMountConfig(
                hostAlias: "storage-nas",
                label: "STORAGE-NAS-data",
                remotePath: "/data/alice",
                localPath: "/Users/demo/STORAGE-NAS-data"
            )
        ]

        let raw1 = try XCTUnwrap(VSCodeManager.parseRemoteURI(
            "vscode-remote://ssh-remote%2Bworkstation-alpha-gpu-direct/home/alice/workspace/vision-model",
            kind: .folder,
            isOpen: true,
            isLastActive: true
        ))
        let raw2 = try XCTUnwrap(VSCodeManager.parseRemoteURI(
            "vscode-remote://ssh-remote+workstation-alpha-gpu/home/alice/workspace",
            kind: .folder,
            isOpen: false
        ))
        let raw3 = try XCTUnwrap(VSCodeManager.parseRemoteURI(
            "vscode-remote://ssh-remote+alice@203.0.113.50/home/alice/services/agent-bot",
            kind: .folder,
            isOpen: false
        ))
        let raw4 = try XCTUnwrap(VSCodeManager.parseRemoteURI(
            "vscode-remote://ssh-remote+203.0.113.50/home/ubuntu/reverse-proxy",
            kind: .folder,
            isOpen: false
        ))
        // Hex-encoded JSON: {"hostName":"cluster-4xA100"}
        let rawHex = try XCTUnwrap(VSCodeManager.parseRemoteURI(
            "vscode-remote://ssh-remote+7b22686f73744e616d65223a22636c75737465722d347841313030227d/data/alice/vision-model",
            kind: .folder
        ))
        XCTAssertEqual(rawHex.authorityHost, "cluster-4xA100")

        let itemsAlpha = VSCodeManager.buildItems(
            for: hostAlpha,
            rawEntries: [raw1, raw2, raw3, raw4],
            allHosts: allHosts,
            mountConfigs: mountConfigs
        )
        XCTAssertEqual(itemsAlpha.count, 2)
        XCTAssertEqual(itemsAlpha.first?.name, "vision-model")
        XCTAssertEqual(itemsAlpha.first?.effectiveAuthority, "workstation-alpha-gpu-direct")
        XCTAssertTrue(itemsAlpha.first?.isLastActive == true)
        XCTAssertEqual(itemsAlpha.last?.effectiveAuthority, "alpha-gpu")

        let itemsEdge = VSCodeManager.buildItems(
            for: hostEdgeLocal,
            rawEntries: [raw1, raw2, raw3, raw4],
            allHosts: allHosts,
            mountConfigs: mountConfigs
        )
        XCTAssertEqual(itemsEdge.map(\.name), ["agent-bot"])
        XCTAssertEqual(itemsEdge.first?.effectiveAuthority, "edgebox")

        let itemsCloud = VSCodeManager.buildItems(
            for: hostCloud,
            rawEntries: [raw1, raw2, raw3, raw4],
            allHosts: allHosts,
            mountConfigs: mountConfigs
        )
        XCTAssertEqual(itemsCloud.map(\.name), ["reverse-proxy"])

        let itemsStorage = VSCodeManager.buildItems(
            for: hostStorage,
            rawEntries: [raw1, raw2, raw3, raw4],
            allHosts: allHosts,
            mountConfigs: mountConfigs
        )
        XCTAssertTrue(itemsStorage.isEmpty)
    }

    func testRcloneArgumentsDisableIdleTimeout() {
        let args = MountManager.buildRcloneArguments(
            remotePath: "/srv/projects",
            localPath: "/Users/operator/GPU-projects",
            sshCommand: "/usr/bin/ssh -o BatchMode=yes gpu-node",
            volName: "GPU-projects",
            logFilePath: "/tmp/sshdeck-rclone-GPU-projects.log"
        )
        XCTAssertEqual(args.first, "nfsmount")
        if let idleIdx = args.firstIndex(of: "--sftp-idle-timeout") {
            XCTAssertEqual(args[idleIdx + 1], "0")
        } else {
            XCTFail("Expected --sftp-idle-timeout 0 in rclone nfsmount arguments")
        }
        if let vfsIdx = args.firstIndex(of: "--vfs-cache-mode") {
            XCTAssertEqual(args[vfsIdx + 1], "full")
        } else {
            XCTFail("Expected --vfs-cache-mode full")
        }
        if let dirIdx = args.firstIndex(of: "--dir-cache-time") {
            XCTAssertEqual(args[dirIdx + 1], "5m")
        } else {
            XCTFail("Expected --dir-cache-time 5m")
        }
        XCTAssertTrue(args.contains("--vfs-fast-fingerprint"))
    }

    func testSMBFirstMountConfigResolutionAndFallbackBadges() throws {
        XCTAssertEqual(
            FolderMountConfig.inferredSMBShare(from: "/home/operator/Workspace", user: "operator"),
            "Workspace"
        )
        XCTAssertEqual(
            FolderMountConfig.inferredSMBShare(from: "/home/operator/work/sub", user: "operator"),
            "home/work/sub"
        )

        // Legacy JSON without strategy/smbEndpoints decodes as .sftpOnly
        let legacyJSON = """
        [
          {
            "id": "11110000-0000-4000-8000-000000000001",
            "hostAlias": "gpu-node",
            "label": "GPU-project",
            "remotePath": "/home/operator/project",
            "localPath": "/Users/demo/GPU-project",
            "autoMount": true
          }
        ]
        """.data(using: .utf8)!
        let decodedLegacy = try JSONDecoder().decode([FolderMountConfig].self, from: legacyJSON)
        XCTAssertEqual(decodedLegacy.first?.strategy, .sftpOnly)

        let lanHost = SSHHost(
            alias: "studio",
            alternateAliases: ["ethernet-studio"],
            hostName: "203.0.113.30",
            user: "operator",
            port: 22
        )
        let smbCfg = FolderMountConfig(
            hostAlias: "studio",
            label: "STUDIO-Workspace",
            remotePath: "/home/operator/Workspace",
            localPath: "/Users/demo/STUDIO-Workspace",
            autoMount: true,
            strategy: .smbFirst,
            smbEndpoints: ["192.0.2.20", "203.0.113.30"],
            smbShare: "Workspace",
            smbUser: "operator",
            rcloneFallbackAlias: "workstation-studio"
        )

        XCTAssertEqual(
            MountManager.resolveSMBEndpoints(for: smbCfg, host: lanHost),
            ["192.0.2.20", "203.0.113.30"]
        )
        XCTAssertEqual(
            MountManager.resolveSMBShares(for: smbCfg, user: "operator"),
            ["Workspace", "home/Workspace"]
        )

        // 1. Unmounted state shows SMB3 · rclone
        let unmountedItems = MountManager.buildItems(for: lanHost, configs: [smbCfg], systemMounts: [])
        XCTAssertEqual(unmountedItems.first?.sourceKind, .managedSMB)
        XCTAssertEqual(unmountedItems.first?.fileSystemType, "SMB3 · rclone")
        XCTAssertEqual(unmountedItems.first?.remoteDescription, "//operator@192.0.2.20/Workspace")

        // 2. Mounted via native SMBFS
        let smbMounted = MountManager.parseMountTable(
            "//operator@192.0.2.20/Workspace on /Users/demo/STUDIO-Workspace (smbfs, nodev, nosuid, mounted by demo)"
        )
        let smbItems = MountManager.buildItems(for: lanHost, configs: [smbCfg], systemMounts: smbMounted)
        XCTAssertEqual(smbItems.first?.sourceKind, .managedSMB)
        XCTAssertEqual(smbItems.first?.fileSystemType, "SMBFS")
        XCTAssertTrue(smbItems.first?.isMounted == true)

        // 3. Mounted via rclone fallback (NFS)
        let rcloneMounted = MountManager.parseMountTable(
            "localhost:/ on /Users/demo/STUDIO-Workspace (nfs, nodev, nosuid, mounted by demo)"
        )
        let fallbackItems = MountManager.buildItems(for: lanHost, configs: [smbCfg], systemMounts: rcloneMounted)
        XCTAssertEqual(fallbackItems.first?.sourceKind, .managedSFTP)
        XCTAssertEqual(fallbackItems.first?.fileSystemType, "NFS (rclone)")
        XCTAssertTrue(fallbackItems.first?.isMounted == true)
    }

    func testSSHConfigEditorAddEditDelete() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodedeck-ssh-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configURL = tempDir.appendingPathComponent("config")
        let initial = """
        # First machine
        Host alpha alpha-lan
          HostName 203.0.113.10
          User alice
          IdentityFile ~/.ssh/id_ed25519
          IPQoS none
          ControlMaster no

        # Secondary workstation
        Host beta beta-lan
          HostName 203.0.113.30
          User alice
          Port 2222
        """
        try initial.write(to: configURL, atomically: true, encoding: .utf8)

        // 1. Load draft and verify comments + extra options are preserved
        let loaded = try XCTUnwrap(SSHConfigEditor.loadDraft(for: "alpha", configURL: configURL))
        XCTAssertEqual(loaded.alias, "alpha")
        XCTAssertEqual(loaded.alternateAliases, "alpha-lan")
        XCTAssertEqual(loaded.hostName, "203.0.113.10")
        XCTAssertEqual(loaded.user, "alice")
        XCTAssertEqual(loaded.comment, "First machine")
        XCTAssertTrue(loaded.extraOptions.contains("IPQoS none"))
        XCTAssertTrue(loaded.extraOptions.contains("ControlMaster no"))

        // 2. Edit existing host in-place
        var edited = loaded
        edited.hostName = "203.0.113.100"
        edited.port = "2200"
        try SSHConfigEditor.upsertHost(edited, configURL: configURL)
        let afterEdit = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(afterEdit.contains("HostName 203.0.113.100"))
        XCTAssertTrue(afterEdit.contains("Port 2200"))
        XCTAssertTrue(afterEdit.contains("IPQoS none"))
        XCTAssertTrue(afterEdit.contains("Host beta beta-lan"))

        // 3. Add a new host
        let added = SSHHostDraft(
            alias: "new-box",
            hostName: "192.168.1.50",
            user: "ubuntu",
            port: "22",
            identityFile: "~/.ssh/id_ed25519",
            comment: "Fresh workstation"
        )
        try SSHConfigEditor.upsertHost(added, configURL: configURL)
        let groupsAfterAdd = try SSHConfigParser.discoverHostGroups(configURL: configURL)
        XCTAssertEqual(groupsAfterAdd.map(\.primary), ["alpha", "beta", "new-box"])

        // 4. Duplicate alias should be rejected
        XCTAssertThrowsError(try SSHConfigEditor.upsertHost(added, configURL: configURL))

        // 5. Delete beta and verify neighbors remain intact
        try SSHConfigEditor.deleteHost(alias: "beta", alternateAliases: ["beta-lan"], configURL: configURL)
        let afterDelete = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertFalse(afterDelete.contains("beta"))
        XCTAssertFalse(afterDelete.contains("Deceased laptop"))
        let groupsAfterDelete = try SSHConfigParser.discoverHostGroups(configURL: configURL)
        XCTAssertEqual(groupsAfterDelete.map(\.primary), ["alpha", "new-box"])
    }

    func testPortForwardConfigSpecsAndPersistence() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodedeck-pf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let localFwd = SSHPortForwardConfig(
            hostAlias: "gpu-node",
            label: "Jupyter",
            direction: .local,
            localHost: "127.0.0.1",
            localPort: 8888,
            remoteHost: "127.0.0.1",
            remotePort: 8888,
            autoStart: true,
            urlScheme: "http"
        )
        XCTAssertEqual(localFwd.sshForwardFlag, "-L")
        XCTAssertEqual(localFwd.sshForwardSpec, "127.0.0.1:8888:127.0.0.1:8888")
        XCTAssertEqual(localFwd.openableURLString, "http://127.0.0.1:8888")

        let remoteFwd = SSHPortForwardConfig(
            hostAlias: "gpu-node",
            label: "LocalProxy",
            direction: .remote,
            localHost: "127.0.0.1",
            localPort: 7890,
            remoteHost: "127.0.0.1",
            remotePort: 17890,
            urlScheme: ""
        )
        XCTAssertEqual(remoteFwd.sshForwardFlag, "-R")
        XCTAssertEqual(remoteFwd.sshForwardSpec, "127.0.0.1:17890:127.0.0.1:7890")
        XCTAssertNil(remoteFwd.openableURLString)

        let socksFwd = SSHPortForwardConfig(
            hostAlias: "gpu-node",
            label: "SOCKS5",
            direction: .dynamic,
            localHost: "127.0.0.1",
            localPort: 1080,
            remoteHost: "",
            remotePort: 0,
            urlScheme: ""
        )
        XCTAssertEqual(socksFwd.sshForwardFlag, "-D")
        XCTAssertEqual(socksFwd.sshForwardSpec, "127.0.0.1:1080")

        let fileURL = tempDir.appendingPathComponent("port-forwards.json")
        try PortForwardManager.saveConfigs([localFwd, remoteFwd, socksFwd], to: fileURL)
        let loaded = PortForwardManager.loadConfigs(from: fileURL)
        XCTAssertEqual(loaded, [localFwd, remoteFwd, socksFwd])
    }

    func testSunshineHostConfigPersistence() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodedeck-sunshine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("sunshine-hosts.json")
        let cfg = SunshineHostConfig(
            hostAlias: "gpu-node",
            address: "203.0.113.10",
            httpPort: 47989,
            httpsPort: 47984,
            serverName: "LAB-GPU",
            serverCertPEM: "-----BEGIN CERTIFICATE-----\nTEST\n-----END CERTIFICATE-----",
            isPaired: true
        )
        try SunshineClient.saveHosts([cfg], to: fileURL)
        let loaded = SunshineClient.loadSavedHosts(from: fileURL)
        XCTAssertEqual(loaded, [cfg])
        XCTAssertEqual(loaded.first?.webUIURLString, "https://203.0.113.10:47990")
    }

    func testLinuxHostProfileDigestAndPersistence() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodedeck-host-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var p1 = LinuxHostProfile(
            hostAlias: "gpu-node",
            mode: .isolatedVirtualDesktop,
            display: ":99",
            basePort: 47989,
            encoder: "nvenc",
            cudaDeviceIndex: "1",
            virtualAudioSink: true,
            clipboardSync: true,
            autoReconcileOnStart: true
        )
        let d1 = p1.configDigest
        p1.basePort = 48989
        let d2 = p1.configDigest
        XCTAssertNotEqual(d1, d2)

        let fileURL = tempDir.appendingPathComponent("host-profiles.json")
        try LinuxHostProfileManager.saveProfiles([p1], to: fileURL)
        let loaded = LinuxHostProfileManager.loadProfiles(from: fileURL)
        XCTAssertEqual(loaded, [p1])
    }

    func testClipboardSyncRejectsOversizedPayload() async {
        let huge = String(repeating: "A", count: ClipboardSyncManager.maxBytes + 128)
        do {
            try await ClipboardSyncManager.pushText(huge, to: "nonexistent-host")
            XCTFail("Expected payloadTooLarge error")
        } catch let err as ClipboardSyncError {
            if case .payloadTooLarge(let bytes) = err {
                XCTAssertGreaterThan(bytes, ClipboardSyncManager.maxBytes)
            } else {
                XCTFail("Unexpected ClipboardSyncError: \(err)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testPortForwardSpecsAndOpenableURL() {
        let local = SSHPortForwardConfig(
            hostAlias: "gpu-node",
            label: "Jupyter",
            direction: .local,
            localHost: "127.0.0.1",
            localPort: 8888,
            remoteHost: "127.0.0.1",
            remotePort: 8888,
            urlScheme: "http"
        )
        XCTAssertEqual(local.sshForwardFlag, "-L")
        XCTAssertEqual(local.sshForwardSpec, "127.0.0.1:8888:127.0.0.1:8888")
        XCTAssertEqual(local.openableURLString, "http://127.0.0.1:8888")

        let socks = SSHPortForwardConfig(
            hostAlias: "workstation",
            label: "Proxy",
            direction: .dynamic,
            localHost: "127.0.0.1",
            localPort: 1080,
            remoteHost: "127.0.0.1",
            remotePort: 0
        )
        XCTAssertEqual(socks.sshForwardFlag, "-D")
        XCTAssertEqual(socks.sshForwardSpec, "127.0.0.1:1080")
        XCTAssertNil(socks.openableURLString)
    }
}
