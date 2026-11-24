import Darwin
import Foundation

public struct SSHHostDraft: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var originalAlias: String?
    public var alias: String
    public var alternateAliases: String
    public var hostName: String
    public var user: String
    public var port: String
    public var identityFile: String
    public var proxyJump: String
    public var serverAliveInterval: String
    public var compression: Bool
    public var comment: String
    public var extraOptions: String

    public init(
        id: UUID = UUID(),
        originalAlias: String? = nil,
        alias: String = "",
        alternateAliases: String = "",
        hostName: String = "",
        user: String = NSUserName(),
        port: String = "22",
        identityFile: String = "",
        proxyJump: String = "",
        serverAliveInterval: String = "30",
        compression: Bool = false,
        comment: String = "",
        extraOptions: String = ""
    ) {
        self.id = id
        self.originalAlias = originalAlias
        self.alias = alias
        self.alternateAliases = alternateAliases
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.proxyJump = proxyJump
        self.serverAliveInterval = serverAliveInterval
        self.compression = compression
        self.comment = comment
        self.extraOptions = extraOptions
    }

    public var isEditing: Bool {
        originalAlias != nil
    }

    public var parsedAlternateAliases: [String] {
        alternateAliases
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

public enum SSHConfigEditorError: LocalizedError, Equatable {
    case emptyAlias
    case invalidAlias(String)
    case emptyHostName
    case invalidPort(String)
    case duplicateAlias(String)
    case hostNotFound(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyAlias:
            return "Device alias cannot be empty."
        case .invalidAlias(let value):
            return "Invalid alias \"\(value)\". Avoid spaces and wildcard characters (*, ?, !)."
        case .emptyHostName:
            return "HostName / IP address cannot be empty."
        case .invalidPort(let value):
            return "Invalid port \"\(value)\". Port must be a number between 1 and 65535."
        case .duplicateAlias(let value):
            return "A device with alias \"\(value)\" already exists in SSH config."
        case .hostNotFound(let value):
            return "Could not find Host \"\(value)\" in SSH config."
        case .writeFailed(let detail):
            return "Failed to save SSH config: \(detail)"
        }
    }
}

public enum SSHConfigEditor {
    private struct HostBlockRange {
        /// Inclusive start line index (including immediately attached `#` comment lines above `Host ...`).
        let startLine: Int
        /// Inclusive line index of the `Host ...` directive itself.
        let hostLine: Int
        /// Exclusive end line index of the block.
        let endLine: Int
        /// Concrete aliases declared on the `Host ...` line.
        let aliases: [String]
    }

    public static func makeDefaultNewDraft() -> SSHHostDraft {
        let defaultEd25519 = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/id_ed25519").path
        let identity = FileManager.default.fileExists(atPath: defaultEd25519)
            ? "~/.ssh/id_ed25519"
            : ""
        return SSHHostDraft(
            originalAlias: nil,
            alias: "",
            alternateAliases: "",
            hostName: "",
            user: NSUserName(),
            port: "22",
            identityFile: identity,
            proxyJump: "",
            serverAliveInterval: "30",
            compression: false,
            comment: "",
            extraOptions: ""
        )
    }

    public static func makeDraft(from host: SSHHost, configURL: URL = SSHConfigParser.defaultConfigURL) -> SSHHostDraft {
        if let parsed = loadDraft(for: host.alias, configURL: configURL) {
            return parsed
        }
        return SSHHostDraft(
            originalAlias: host.alias,
            alias: host.alias,
            alternateAliases: host.alternateAliases.joined(separator: " "),
            hostName: host.hostName,
            user: host.user,
            port: String(host.port),
            identityFile: host.identityFile ?? "",
            proxyJump: host.proxyJump ?? "",
            serverAliveInterval: host.serverAliveInterval.map(String.init) ?? "",
            compression: host.compression,
            comment: "",
            extraOptions: ""
        )
    }

    public static func loadDraft(
        for alias: String,
        configURL: URL = SSHConfigParser.defaultConfigURL
    ) -> SSHHostDraft? {
        guard let raw = try? String(contentsOf: configURL, encoding: .utf8) else {
            return nil
        }
        let lines = splitLinesPreservingEmpty(raw)
        let blocks = findHostBlocks(in: lines)
        guard let block = blocks.first(where: { $0.aliases.contains(alias) }) else {
            return nil
        }

        let commentLines = lines[block.startLine..<block.hostLine]
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") {
                    return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                return trimmed
            }
            .filter { !$0.isEmpty }

        let primary = block.aliases.first ?? alias
        let alternates = Array(block.aliases.dropFirst())

        var hostName = ""
        var user = ""
        var port = "22"
        var identityFile = ""
        var proxyJump = ""
        var serverAliveInterval = ""
        var compression = false
        var extraLines: [String] = []

        for idx in (block.hostLine + 1)..<block.endLine {
            let rawLine = lines[idx]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") {
                extraLines.append(trimmed)
                continue
            }

            let parts = splitDirective(trimmed)
            guard let key = parts.key?.lowercased(), let value = parts.value else {
                extraLines.append(trimmed)
                continue
            }

            switch key {
            case "hostname":
                hostName = value
            case "user":
                user = value
            case "port":
                port = value
            case "identityfile":
                if identityFile.isEmpty {
                    identityFile = value
                } else {
                    extraLines.append(trimmed)
                }
            case "proxyjump":
                proxyJump = value
            case "serveraliveinterval":
                serverAliveInterval = value
            case "compression":
                compression = value.lowercased() == "yes"
            default:
                extraLines.append(trimmed)
            }
        }

        return SSHHostDraft(
            originalAlias: primary,
            alias: primary,
            alternateAliases: alternates.joined(separator: " "),
            hostName: hostName,
            user: user,
            port: port,
            identityFile: identityFile,
            proxyJump: proxyJump,
            serverAliveInterval: serverAliveInterval,
            compression: compression,
            comment: commentLines.joined(separator: "\n"),
            extraOptions: extraLines.joined(separator: "\n")
        )
    }

    public static func renderBlock(for draft: SSHHostDraft) throws -> String {
        let validated = try validate(draft)

        var out: [String] = []
        let commentLines = validated.comment
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for line in commentLines {
            if line.hasPrefix("#") {
                out.append(line)
            } else {
                out.append("# \(line)")
            }
        }

        let hostTokens = [validated.alias] + validated.alternates
        out.append("Host \(hostTokens.joined(separator: " "))")
        out.append("  HostName \(validated.hostName)")

        if !validated.user.isEmpty {
            out.append("  User \(validated.user)")
        }
        if let port = validated.port, port != 22 {
            out.append("  Port \(port)")
        }
        if !validated.identityFile.isEmpty {
            out.append("  IdentityFile \(validated.identityFile)")
        }
        if !validated.proxyJump.isEmpty {
            out.append("  ProxyJump \(validated.proxyJump)")
        }
        if !validated.serverAliveInterval.isEmpty {
            out.append("  ServerAliveInterval \(validated.serverAliveInterval)")
        }
        if validated.compression {
            out.append("  Compression yes")
        }

        for extra in validated.extraLines {
            out.append("  \(extra)")
        }

        return out.joined(separator: "\n")
    }

    public static func upsertHost(
        _ draft: SSHHostDraft,
        configURL: URL = SSHConfigParser.defaultConfigURL
    ) throws {
        let validated = try validate(draft)
        let renderedBlock = try renderBlock(for: draft)

        let existingText = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        var lines = existingText.isEmpty ? [] : splitLinesPreservingEmpty(existingText)
        let blocks = findHostBlocks(in: lines)

        let targetAliases = Set([validated.alias] + validated.alternates)

        if let originalAlias = draft.originalAlias,
           let existingBlock = blocks.first(where: { $0.aliases.contains(originalAlias) }) {
            // Check for alias collisions with other blocks
            for other in blocks where other.hostLine != existingBlock.hostLine {
                if let conflict = other.aliases.first(where: { targetAliases.contains($0) }) {
                    throw SSHConfigEditorError.duplicateAlias(conflict)
                }
            }

            let replacementLines = splitLinesPreservingEmpty(renderedBlock)
            lines.replaceSubrange(existingBlock.startLine..<existingBlock.endLine, with: replacementLines)
        } else {
            // Adding a new host: ensure no alias conflicts with existing entries
            for block in blocks {
                if let conflict = block.aliases.first(where: { targetAliases.contains($0) }) {
                    throw SSHConfigEditorError.duplicateAlias(conflict)
                }
            }

            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeLast()
            }
            if !lines.isEmpty {
                lines.append("")
            }
            lines.append(contentsOf: splitLinesPreservingEmpty(renderedBlock))
        }

        let normalized = normalizeTrailingWhitespace(lines)
        try writeConfigAtomically(normalized, to: configURL)
    }

    public static func deleteHost(
        alias: String,
        alternateAliases: [String] = [],
        configURL: URL = SSHConfigParser.defaultConfigURL
    ) throws {
        guard let existingText = try? String(contentsOf: configURL, encoding: .utf8) else {
            throw SSHConfigEditorError.hostNotFound(alias)
        }

        var lines = splitLinesPreservingEmpty(existingText)
        let blocks = findHostBlocks(in: lines)
        let searchSet = Set([alias] + alternateAliases)

        guard let target = blocks.first(where: { block in
            block.aliases.contains(alias) || block.aliases.contains(where: { searchSet.contains($0) })
        }) else {
            throw SSHConfigEditorError.hostNotFound(alias)
        }

        var removeStart = target.startLine
        var removeEnd = target.endLine

        // Clean up one surrounding blank line so we don't leave double blank gaps
        if removeEnd < lines.count, lines[removeEnd].trimmingCharacters(in: .whitespaces).isEmpty {
            removeEnd += 1
        } else if removeStart > 0, lines[removeStart - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            removeStart -= 1
        }

        lines.removeSubrange(removeStart..<removeEnd)
        let normalized = normalizeTrailingWhitespace(lines)
        try writeConfigAtomically(normalized, to: configURL)
    }

    // MARK: - Validation & Parsing Helpers

    private struct ValidatedDraft {
        let alias: String
        let alternates: [String]
        let hostName: String
        let user: String
        let port: Int?
        let identityFile: String
        let proxyJump: String
        let serverAliveInterval: String
        let compression: Bool
        let comment: String
        let extraLines: [String]
    }

    private static func validate(_ draft: SSHHostDraft) throws -> ValidatedDraft {
        let alias = draft.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty else {
            throw SSHConfigEditorError.emptyAlias
        }
        guard isValidAliasToken(alias) else {
            throw SSHConfigEditorError.invalidAlias(alias)
        }

        var alternates: [String] = []
        var seen = Set([alias])
        for alt in draft.parsedAlternateAliases {
            guard isValidAliasToken(alt) else {
                throw SSHConfigEditorError.invalidAlias(alt)
            }
            if seen.insert(alt).inserted {
                alternates.append(alt)
            }
        }

        let hostName = draft.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostName.isEmpty else {
            throw SSHConfigEditorError.emptyHostName
        }

        let portTrimmed = draft.port.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedPort: Int?
        if portTrimmed.isEmpty {
            parsedPort = nil
        } else if let portNum = Int(portTrimmed), (1...65535).contains(portNum) {
            parsedPort = portNum
        } else {
            throw SSHConfigEditorError.invalidPort(portTrimmed)
        }

        let extraLines = draft.extraOptions
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return ValidatedDraft(
            alias: alias,
            alternates: alternates,
            hostName: hostName,
            user: draft.user.trimmingCharacters(in: .whitespacesAndNewlines),
            port: parsedPort,
            identityFile: draft.identityFile.trimmingCharacters(in: .whitespacesAndNewlines),
            proxyJump: draft.proxyJump.trimmingCharacters(in: .whitespacesAndNewlines),
            serverAliveInterval: draft.serverAliveInterval.trimmingCharacters(in: .whitespacesAndNewlines),
            compression: draft.compression,
            comment: draft.comment,
            extraLines: extraLines
        )
    }

    private static func isValidAliasToken(_ token: String) -> Bool {
        !token.isEmpty &&
            !token.hasPrefix("!") &&
            !token.contains("*") &&
            !token.contains("?") &&
            token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    private static func findHostBlocks(in lines: [String]) -> [HostBlockRange] {
        var blockHeaders: [(hostLine: Int, aliases: [String], isMatch: Bool)] = []

        for (index, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = splitDirective(trimmed)
            guard let key = parts.key?.lowercased() else { continue }
            if key == "host" {
                let rawValue = parts.value ?? ""
                let aliases = rawValue
                    .split(whereSeparator: \.isWhitespace)
                    .map(String.init)
                    .filter { isValidAliasToken($0) }
                blockHeaders.append((hostLine: index, aliases: aliases, isMatch: false))
            } else if key == "match" {
                blockHeaders.append((hostLine: index, aliases: [], isMatch: true))
            }
        }

        var result: [HostBlockRange] = []
        for (i, header) in blockHeaders.enumerated() {
            // Find attached comment lines immediately above `Host ...`
            var startLine = header.hostLine
            while startLine > 0 {
                let prev = lines[startLine - 1].trimmingCharacters(in: .whitespaces)
                if prev.hasPrefix("#") {
                    startLine -= 1
                } else {
                    break
                }
            }

            // Determine endLine: stop right before the next Host/Match block's leading comments (or EOF)
            var endLine: Int
            if i + 1 < blockHeaders.count {
                var nextStart = blockHeaders[i + 1].hostLine
                while nextStart > header.hostLine + 1 {
                    let prev = lines[nextStart - 1].trimmingCharacters(in: .whitespaces)
                    if prev.hasPrefix("#") {
                        nextStart -= 1
                    } else {
                        break
                    }
                }
                endLine = nextStart
            } else {
                endLine = lines.count
            }

            // Trim trailing blank lines from the block itself so blank separators stay outside
            while endLine > header.hostLine + 1 &&
                    lines[endLine - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                endLine -= 1
            }

            if !header.isMatch && !header.aliases.isEmpty {
                result.append(
                    HostBlockRange(
                        startLine: startLine,
                        hostLine: header.hostLine,
                        endLine: endLine,
                        aliases: header.aliases
                    )
                )
            }
        }
        return result
    }

    private static func splitDirective(_ trimmedLine: String) -> (key: String?, value: String?) {
        // Strip inline comments that are not inside quotes
        var cleaned = ""
        var quote: Character?
        for ch in trimmedLine {
            if let active = quote {
                if ch == active { quote = nil }
                cleaned.append(ch)
            } else if ch == "\"" || ch == "'" {
                quote = ch
                cleaned.append(ch)
            } else if ch == "#" {
                break
            } else {
                cleaned.append(ch)
            }
        }
        let s = cleaned.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return (nil, nil) }

        if let sepIdx = s.firstIndex(where: { $0.isWhitespace || $0 == "=" }) {
            let key = String(s[..<sepIdx])
            let rest = s[sepIdx...].drop(while: { $0.isWhitespace || $0 == "=" })
            return (key, String(rest).trimmingCharacters(in: .whitespaces))
        }
        return (s, "")
    }

    private static func splitLinesPreservingEmpty(_ text: String) -> [String] {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        if normalized.hasSuffix("\n") {
            normalized.removeLast()
        }
        if normalized.isEmpty {
            return []
        }
        return normalized.components(separatedBy: "\n")
    }

    private static func normalizeTrailingWhitespace(_ lines: [String]) -> String {
        var result: [String] = []
        var previousWasBlank = true
        for line in lines {
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank {
                if !previousWasBlank {
                    result.append("")
                }
            } else {
                result.append(line)
            }
            previousWasBlank = isBlank
        }
        while let last = result.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            result.removeLast()
        }
        if result.isEmpty {
            return ""
        }
        return result.joined(separator: "\n") + "\n"
    }

    private static func writeConfigAtomically(_ content: String, to configURL: URL) throws {
        let dirURL = configURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            _ = chmod(dirURL.path, 0o700)
            try content.write(to: configURL, atomically: true, encoding: .utf8)
            _ = chmod(configURL.path, 0o600)
        } catch {
            throw SSHConfigEditorError.writeFailed(error.localizedDescription)
        }
    }
}
