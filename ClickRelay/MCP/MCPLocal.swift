import Foundation

/// What the app and its stdio bridge (`MCPBridge`) agree on: where the local
/// socket lives, how to launch the bridge, and how messages are framed.
///
/// The bridge is this same executable started with `--mcp`. An agent launches
/// it as an ordinary stdio MCP server; it relays to the running app over a Unix
/// socket in `~/Library/Application Support/ClickRelay/`.
///
/// Nothing in this file may touch ScreenCaptureKit, Accessibility or `CGEvent`:
/// the bridge uses it, and anything the bridge did would be charged to the
/// agent's terminal (`BridgeIsolationTests` checks this).
nonisolated enum MCPLocal {
    /// Command-line flag that starts the executable as a stdio bridge instead
    /// of the app. Checked before any SwiftUI or AppKit setup runs.
    static let bridgeArgument = "--mcp"

    static let bundleIdentifier = "io.mergeable.ClickRelay"

    /// `~/Library/Application Support/ClickRelay`. Holds the socket and the
    /// audit log. The app isn't sandboxed, so this is the real home directory.
    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/ClickRelay", directoryHint: .isDirectory)
    }

    static let socketName = "mcp.sock"

    /// Creates the support directory (mode 0700) if needed, makes it the
    /// process's current directory, and returns the socket's path relative to
    /// it.
    ///
    /// Relative because a Unix socket path must fit in `sun_path` (104 bytes),
    /// and the absolute path is long enough to overflow it on a long home
    /// directory. Neither process uses its current directory for anything else.
    /// Call only from the main thread, before anything resolves the path.
    static func enterSocketDirectory() -> String? {
        let path = supportDirectory.path(percentEncoded: false)
        do {
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }
        // An existing directory keeps whatever mode it had; tighten it.
        chmod(path, 0o700)
        guard FileManager.default.changeCurrentDirectoryPath(path) else { return nil }
        return socketName
    }

    /// Id the bridge uses for its own `initialize` handshake with the app, so
    /// its response can be told apart from relayed requests.
    static let handshakeId = "clickrelay-bridge-handshake"

    // Handshake params the bridge adds to its `initialize`.
    static let sessionParam = "clickrelaySession"
    static let workingDirectoryParam = "clickrelayCwd"
    static let termProgramParam = "clickrelayTermProgram"
    static let parentPIDParam = "clickrelayParentPid"

    /// Checked in order, then `PWD`. Claude Code sets `CLAUDE_PROJECT_DIR` to
    /// its project root for the servers it starts.
    static let projectDirectoryVariables = ["CLAUDE_PROJECT_DIR"]

    static func agentWorkingDirectory(environment: [String: String],
                                      currentDirectory: String) -> String? {
        for key in projectDirectoryVariables + ["PWD"] {
            if let value = environment[key], !value.isEmpty { return value }
        }
        // The bridge moves into the support directory to connect, after which
        // its current directory says nothing about the agent.
        if currentDirectory.hasPrefix(supportDirectory.path(percentEncoded: false)) { return nil }
        return currentDirectory.isEmpty ? nil : currentDirectory
    }

    /// Darwin notification the app posts once the socket is listening. Bridges
    /// waiting to reconnect connect straight away instead of sitting out their
    /// backoff.
    static let readyNotification = bundleIdentifier + ".mcp-ready"

    /// Largest framed message either side accepts. Screenshots travel as
    /// base64, so this is generous; a peer that sends more is dropped.
    static let maxMessageBytes = 16 * 1024 * 1024

    /// What to put in an agent's MCP config to launch the bridge.
    static var bridgeExecutablePath: String {
        Bundle.main.executablePath ?? "/Applications/ClickRelay.app/Contents/MacOS/ClickRelay"
    }

    /// The one-line Claude Code setup, as shown in the main window.
    static var claudeAddCommand: String {
        "claude mcp add --scope user clickrelay -- \(shellQuoted(bridgeExecutablePath)) \(bridgeArgument)"
    }

    static func shellQuoted(_ path: String) -> String {
        path.contains(" ") || path.contains("'")
            ? "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'" : path
    }

    // MARK: Framing

    /// MCP's stdio framing: one JSON-RPC message per line. Removes every
    /// complete line from `buffer` (leaving a trailing partial one in place)
    /// and returns them, skipping blank lines. Shared by both ends of the
    /// socket and by the bridge's stdin, so all three split identically.
    static func takeLines(from buffer: inout Data) -> [Data] {
        var lines: [Data] = []
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            var line = buffer[start..<newline]
            if line.last == 0x0D { line = line.dropLast() }   // tolerate CRLF
            if !line.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { lines.append(Data(line)) }
            start = buffer.index(after: newline)
        }
        if start != buffer.startIndex { buffer = Data(buffer[start...]) }
        return lines
    }

    /// Whether an unterminated partial line has grown past the size cap.
    static func isOversized(_ buffer: Data) -> Bool {
        buffer.count > maxMessageBytes
    }

    /// One message, ready to write. `JSONSerialization` never emits a raw
    /// newline without `.prettyPrinted`, so the delimiter can't be forged.
    static func frame(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    // MARK: Restarting after an update

    /// Team that signs every ClickRelay build, Debug and Release alike.
    static let teamIdentifier = "D3NCG82LUC"

    /// What the executable on disk must satisfy before a bridge restarts into
    /// it: any ClickRelay signed by the team, so a Debug bridge can move to a
    /// Developer ID build and back. A copy that's still being written fails.
    static let updateRequirement = "anchor apple generic and identifier \"\(bundleIdentifier)\" "
        + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""

    /// Environment variable that carries a bridge's state into the copy it
    /// restarts as. Read and cleared at startup.
    static let handoffVariable = "CLICKRELAY_BRIDGE_HANDOFF"

    /// A file's identity on disk. Replacing the app (Finder copy, unzip, an
    /// installer) gives the executable a new inode, size or modification time.
    struct FileIdentity: Equatable {
        var device: Int32
        var inode: UInt64
        var size: Int64
        var modified: timespec

        init?(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            modified = info.st_mtimespec
        }

        static func == (a: Self, b: Self) -> Bool {
            a.device == b.device && a.inode == b.inode && a.size == b.size
                && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
        }
    }

    /// A bridge's state, handed to the updated copy it restarts as so the
    /// agent never notices: same session, same client, and any input it had
    /// read but not yet relayed.
    struct BridgeHandoff {
        var session: String
        var clientInfo: [String: Any]?
        var launchDirectory: String
        /// Unrelayed agent input, replayed in order: queued tool calls as
        /// lines, then any partial line.
        var pending: Data

        /// Environment variables have to stay well inside `ARG_MAX`.
        static let maxPendingBytes = 256 * 1024

        func encoded() -> String? {
            var object: [String: Any] = [
                "session": session,
                "launchDirectory": launchDirectory,
                "pending": pending.base64EncodedString()
            ]
            if let clientInfo { object["clientInfo"] = clientInfo }
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return data.base64EncodedString()
        }

        init(session: String, clientInfo: [String: Any]?, launchDirectory: String, pending: Data) {
            self.session = session
            self.clientInfo = clientInfo
            self.launchDirectory = launchDirectory
            self.pending = pending
        }

        init?(encoded: String) {
            guard let data = Data(base64Encoded: encoded),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let session = object["session"] as? String, !session.isEmpty,
                  let launchDirectory = object["launchDirectory"] as? String,
                  let pending = (object["pending"] as? String).flatMap({ Data(base64Encoded: $0) })
            else { return nil }
            self.init(session: session, clientInfo: object["clientInfo"] as? [String: Any],
                      launchDirectory: launchDirectory, pending: pending)
        }
    }

    // MARK: Client names

    /// Display label for an agent, from the `clientInfo` it sends at
    /// `initialize`.
    static func clientLabel(clientInfo: [String: Any]?) -> String {
        if let title = clientInfo?["title"] as? String,
           !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        guard let name = (clientInfo?["name"] as? String)?
            .trimmingCharacters(in: .whitespaces), !name.isEmpty else { return "AI Agent" }
        let known: [String: String] = [
            "claude-code": "Claude Code",
            "codex-mcp-client": "Codex",
            "codex": "Codex",
            "cursor-vscode": "Cursor",
            "visual studio code": "VS Code",
            "zed": "Zed",
            "windsurf-client": "Windsurf"
        ]
        if let label = known[name.lowercased()] { return label }
        return name.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// `~/xcode/Foo` rather than `/Users/me/xcode/Foo`, for display.
    static func abbreviatingHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == trimmedHome { return "~" }
        if path.hasPrefix(trimmedHome + "/") { return "~" + path.dropFirst(trimmedHome.count) }
        return path
    }
}
