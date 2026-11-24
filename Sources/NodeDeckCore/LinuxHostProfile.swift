import CryptoKit
import Foundation

public enum LinuxHostDisplayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case physicalDesktop
    case isolatedVirtualDesktop

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .physicalDesktop: return "物理桌面直采 (单用户)"
        case .isolatedVirtualDesktop: return "隔离虚拟桌面 (多用户 :99)"
        }
    }
}

public struct LinuxHostProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var hostAlias: String
    public var mode: LinuxHostDisplayMode
    public var display: String
    public var basePort: Int
    public var encoder: String
    public var cudaDeviceIndex: String
    public var drmRenderNode: String
    public var virtualAudioSink: Bool
    public var clipboardSync: Bool
    public var autoReconcileOnStart: Bool

    public init(
        id: UUID = UUID(),
        hostAlias: String,
        mode: LinuxHostDisplayMode = .isolatedVirtualDesktop,
        display: String = ":99",
        basePort: Int = 47989,
        encoder: String = "nvenc",
        cudaDeviceIndex: String = "0",
        drmRenderNode: String = "/dev/dri/renderD128",
        virtualAudioSink: Bool = true,
        clipboardSync: Bool = true,
        autoReconcileOnStart: Bool = true
    ) {
        self.id = id
        self.hostAlias = hostAlias
        self.mode = mode
        self.display = display
        self.basePort = basePort
        self.encoder = encoder
        self.cudaDeviceIndex = cudaDeviceIndex
        self.drmRenderNode = drmRenderNode
        self.virtualAudioSink = virtualAudioSink
        self.clipboardSync = clipboardSync
        self.autoReconcileOnStart = autoReconcileOnStart
    }

    /// Deterministic SHA-256 hash of all fields that affect remote host config files.
    public var configDigest: String {
        let canonical = [
            mode.rawValue,
            display.trimmingCharacters(in: .whitespaces),
            String(basePort),
            encoder.trimmingCharacters(in: .whitespaces),
            cudaDeviceIndex.trimmingCharacters(in: .whitespaces),
            drmRenderNode.trimmingCharacters(in: .whitespaces),
            virtualAudioSink ? "1" : "0",
            clipboardSync ? "1" : "0"
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum HostProfileReconcileResult: Equatable, Sendable {
    case upToDate
    case updated(restarted: Bool)
}

public enum LinuxHostProfileError: LocalizedError {
    case sshFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sshFailed(let msg):
            return "Host profile sync failed: \(msg)"
        }
    }
}

public enum LinuxHostProfileManager {
    public static var defaultConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NodeDeck/host-profiles.json")
    }

    public static func loadProfiles(from url: URL = defaultConfigURL) -> [LinuxHostProfile] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([LinuxHostProfile].self, from: data)
        else {
            return []
        }
        return decoded
    }

    public static func saveProfiles(_ profiles: [LinuxHostProfile], to url: URL = defaultConfigURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profiles)
        try data.write(to: url, options: .atomic)
    }

    /// Checks remote `~/.config/nodedeck/host-profile.sha256`; if it differs from `profile.configDigest`
    /// (or `force == true`), rewrites `host.conf`, desktop script (for isolated mode), and `nodedeck-host.service`,
    /// then reloads `systemd --user` and restarts `nodedeck-host.service`.
    public static func reconcile(
        profile: LinuxHostProfile,
        host: SSHHost,
        force: Bool = false
    ) async throws -> HostProfileReconcileResult {
        let digest = profile.configDigest
        let profileJSON = (try? String(data: JSONEncoder().encode(profile), encoding: .utf8)) ?? "{}"
        let profileB64 = Data(profileJSON.utf8).base64EncodedString()

        let remotePy = """
        import base64, json, os, subprocess, sys

        digest = "\(digest)"
        force = \(force ? "True" : "False")
        prof = json.loads(base64.b64decode("\(profileB64)").decode("utf-8"))

        home = os.path.expanduser("~")
        uid = os.getuid()
        nd_conf = os.path.join(home, ".config", "nodedeck")
        host_conf_dir = os.path.join(nd_conf, "host")
        os.makedirs(host_conf_dir, exist_ok=True)

        sha_path = os.path.join(nd_conf, "host-profile.sha256")
        if not force and os.path.exists(sha_path):
            current = open(sha_path, "r", encoding="utf-8").read().strip()
            if current == digest:
                print("RESULT:UP_TO_DATE")
                sys.exit(0)

        mode = prof["mode"]
        display = prof["display"].strip() or ":99"
        base_port = int(prof["basePort"])
        encoder = prof["encoder"].strip() or "nvenc"
        cuda_idx = prof["cudaDeviceIndex"].strip()
        render_node = prof["drmRenderNode"].strip()
        virtual_audio = bool(prof["virtualAudioSink"])
        clipboard = bool(prof["clipboardSync"])
        alias = prof["hostAlias"]

        # 1. Write ~/.config/nodedeck/host/host.conf
        conf_lines = [
            f"sunshine_name = {alias}",
            "capture = x11",
            f"encoder = {encoder}",
            f"port = {base_port}",
            f"clipboard_sync = {'enabled' if clipboard else 'disabled'}",
            "upnp = disabled",
            f"file_state = {os.path.join(host_conf_dir, 'sunshine_state.json')}",
            f"file_apps = {os.path.join(host_conf_dir, 'apps.json')}",
            f"credentials_file = {os.path.join(host_conf_dir, 'sunshine_state.json')}",
        ]
        if render_node and mode == "isolatedVirtualDesktop":
            conf_lines.append(f"adapter_name = {render_node}")
        if virtual_audio:
            conf_lines.append("audio_sink = sunshine_virtual_sink")
        with open(os.path.join(host_conf_dir, "host.conf"), "w", encoding="utf-8") as f:
            f.write("\\n".join(conf_lines) + "\\n")

        # 2. Detect nodedeck-host binary
        host_bin = None
        for cand in [
            "/opt/nodedeck/host/bin/nodedeck-host",
            os.path.join(home, ".local/share/nodedeck/host/bin/nodedeck-host"),
            "/opt/foundation-sunshine/bin/sunshine",
            "/usr/bin/sunshine",
        ]:
            if os.path.isfile(cand) and os.access(cand, os.X_OK):
                host_bin = cand
                break

        # 3. Update user systemd unit if nodedeck-host binary exists
        restarted = False
        if host_bin:
            unit_dir = os.path.join(home, ".config/systemd/user")
            os.makedirs(unit_dir, exist_ok=True)
            env_lines = []
            after_line = "After=graphical-session.target pipewire-pulse.service"
            wants_line = ""
            if mode == "isolatedVirtualDesktop":
                env_lines.append(f"Environment=DISPLAY={display}")
                env_lines.append(f"Environment=XAUTHORITY={os.path.join(home, '.Xauthority')}")
                env_lines.append(f"Environment=PULSE_SERVER=unix:/run/user/{uid}/pulse/native")
                if cuda_idx != "":
                    env_lines.append(f"Environment=CUDA_VISIBLE_DEVICES={cuda_idx}")
                user_desktop_svc = f"{os.getenv('USER', 'user')}-desktop.service"
                if os.path.exists(os.path.join(unit_dir, user_desktop_svc)):
                    after_line = f"After={user_desktop_svc} pipewire-pulse.service"
                    wants_line = f"Wants={user_desktop_svc}"

            unit_content = "\\n".join(filter(None, [
                "[Unit]",
                f"Description=NodeDeck Integrated Remote Desktop Host ({alias})",
                after_line,
                wants_line,
                "",
                "[Service]",
                "Type=simple",
                *env_lines,
                f"ExecStart={host_bin} {os.path.join(host_conf_dir, 'host.conf')}",
                "Restart=always",
                "RestartSec=3",
                "",
                "[Install]",
                "WantedBy=default.target",
                ""
            ]))
            with open(os.path.join(unit_dir, "nodedeck-host.service"), "w", encoding="utf-8") as f:
                f.write(unit_content)

            subprocess.run(["systemctl", "--user", "daemon-reload"], check=False)
            r = subprocess.run(["systemctl", "--user", "restart", "nodedeck-host.service"], check=False)
            restarted = (r.returncode == 0)

        with open(os.path.join(nd_conf, "host-profile.json"), "w", encoding="utf-8") as f:
            json.dump(prof, f, indent=2)
        with open(sha_path, "w", encoding="utf-8") as f:
            f.write(digest + "\\n")

        print(f"RESULT:UPDATED:{int(restarted)}")
        """

        let res = await Task.detached(priority: .userInitiated) {
            ProcessRunner.run(
                executable: "/usr/bin/ssh",
                arguments: [
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=6",
                    "-o", "ControlMaster=no",
                    host.alias,
                    "python3", "-"
                ],
                input: remotePy,
                timeout: 18
            )
        }.value

        guard res.status == 0 else {
            let err = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LinuxHostProfileError.sshFailed(err.isEmpty ? "SSH exit \(res.status)" : err)
        }

        if res.stdout.contains("RESULT:UP_TO_DATE") {
            return .upToDate
        }
        let restarted = res.stdout.contains("RESULT:UPDATED:1")
        return .updated(restarted: restarted)
    }
}
