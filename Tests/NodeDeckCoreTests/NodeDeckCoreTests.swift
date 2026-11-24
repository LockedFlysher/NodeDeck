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

    func testNetworkProbeAndBundledHostPaths() throws {
        // Bind a temporary TCP listener on loopback to verify NetworkProbe.isTCPPortOpen
        let listenFD = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listenFD, 0)
        defer { close(listenFD) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        XCTAssertEqual(
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            },
            0
        )
        XCTAssertEqual(Darwin.listen(listenFD, 4), 0)

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listenFD, $0, &len)
            }
        }
        let openPort = Int(UInt16(bigEndian: addr.sin_port))
        XCTAssertTrue(NetworkProbe.isTCPPortOpen(host: "127.0.0.1", port: openPort, timeoutMs: 250))
        XCTAssertFalse(NetworkProbe.isTCPPortOpen(host: "127.0.0.1", port: 0, timeoutMs: 50))
        XCTAssertTrue(SunshineHostManager.bundledBinaryPath.hasSuffix("Contents/Helpers/NodeDeckHost.app/Contents/MacOS/nodedeck-host"))
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
