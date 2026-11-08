import Foundation
import Security
import notify

/// One piece of a tool result.
nonisolated enum ToolContent: Sendable, Equatable {
    case text(String)
    case image(data: Data, mimeType: String)
}

/// What a tool call returns. Refusals are `isError` results written for the
/// model (what failed and what to do), never protocol errors, which clients
/// tend to swallow or show as a broken server.
nonisolated struct ToolResult: Sendable, Equatable {
    var content: [ToolContent]
    var isError: Bool

    static func text(_ text: String) -> ToolResult {
        ToolResult(content: [.text(text)], isError: false)
    }

    static func error(_ text: String) -> ToolResult {
        ToolResult(content: [.text(text)], isError: true)
    }

    /// Pretty enough for a model to read, compact enough to be cheap.
    static func json(_ object: Any) -> ToolResult {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
        return .text(String(decoding: data, as: UTF8.self))
    }

    var firstText: String? {
        for item in content { if case .text(let text) = item { return text } }
        return nil
    }

    var jsonObject: [String: Any] {
        let items: [[String: Any]] = content.map { item in
            switch item {
            case .text(let text):
                return ["type": "text", "text": text]
            case .image(let data, let mimeType):
                return ["type": "image", "data": data.base64EncodedString(), "mimeType": mimeType]
            }
        }
        var object: [String: Any] = ["content": items]
        if isError { object["isError"] = true }
        return object
    }
}

/// What the server hands tool calls and session changes to (`AppModel`).
@MainActor
protocol MCPBackend: AnyObject {
    func sessionConnected(_ session: AgentSession)
    func sessionDisconnected(_ sessionID: String)
    func callTool(name: String, arguments: ToolArguments, session: AgentSession) async -> ToolResult
}

/// The local MCP server: a Unix socket in `~/Library/Application Support/ClickRelay/`
/// that `--mcp` bridges connect to, speaking newline-delimited JSON-RPC.
///
/// POSIX sockets rather than `NWListener`, because each accepted connection's
/// peer has to be checked (`LOCAL_PEERTOKEN`) and Network.framework doesn't
/// expose the descriptor. Only processes signed with this app's own designated
/// requirement (the bridge) are let in. Never reachable over the network.
@MainActor
final class MCPServer {
    private weak var backend: MCPBackend?
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [UUID: MCPConnection] = [:]

    private(set) var isListening = false
    private(set) var lastError: String?
    /// Processes turned away by the code-signing check, for the main window.
    /// By PID, since a refused bridge retries every few seconds.
    private(set) var rejectedPeers: Set<pid_t> = []
    /// Of those, the ones that look like an older ClickRelay bridge: an agent
    /// that was open while ClickRelay was updated, from a build that couldn't
    /// restart itself. A name match only, so it's a hint, never a pass.
    private(set) var outdatedBridges: Set<pid_t> = []
    var onStateChanged: (() -> Void)?

    /// This app's designated requirement, read once. Nil if the app isn't
    /// signed properly, in which case every connection is refused.
    private lazy var ownRequirement: SecRequirement? = Self.copyOwnRequirement()

    init(backend: MCPBackend) {
        self.backend = backend
    }

    // MARK: - Listening

    func start() {
        stop()
        lastError = nil
        guard let path = MCPLocal.enterSocketDirectory() else {
            fail("Couldn't create ~/Library/Application Support/ClickRelay")
            return
        }
        if Self.socketIsLive(path) {
            fail("Another copy of ClickRelay is already running and answering agents. Quit it first.")
            return
        }
        unlink(path)   // a socket file left by a previous run

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { fail("socket: \(String(cString: strerror(errno)))"); return }
        guard var address = Self.address(path) else {
            close(fd)
            fail("Socket path too long")
            return
        }
        // Created 0600: only this user can connect at all.
        let oldMask = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(oldMask)
        guard bound == 0 else {
            close(fd)
            fail("bind: \(String(cString: strerror(errno)))")
            return
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            close(fd)
            fail("listen: \(String(cString: strerror(errno)))")
            return
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.acceptPending() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
        isListening = true
        onStateChanged?()
        // Bridges waiting to reconnect come straight away.
        notify_post(MCPLocal.readyNotification)
    }

    func stop() {
        for connection in connections.values { connection.close() }
        connections = [:]
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            listenFD = -1
            if let path = MCPLocal.enterSocketDirectory() { unlink(path) }
        }
        isListening = false
        onStateChanged?()
    }

    private func fail(_ message: String) {
        lastError = message
        isListening = false
        onStateChanged?()
    }

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }   // EAGAIN: nothing more waiting
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // Accepted sockets inherit the listener's O_NONBLOCK. Writes are
            // blocking (on their own queue), with a timeout so a bridge that
            // stops reading can't wedge the queue forever.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var timeout = timeval(tv_sec: 30, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            guard let peerPID = verifyPeer(client) else {
                rejected(client)
                close(client)
                continue
            }
            let connection = MCPConnection(fd: client, peerPID: peerPID)
            connection.onLine = { [weak self, weak connection] line in
                guard let self, let connection else { return }
                self.handle(line, on: connection)
            }
            connection.onClose = { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.closed(connection)
            }
            connections[connection.id] = connection
            connection.start()
        }
    }

    // MARK: - Peer check

    private func rejected(_ fd: Int32) {
        let pid = Self.peerPID(fd)
        guard pid > 0 else { return }
        rejectedPeers.insert(pid)
        var name = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &name, UInt32(name.count)) > 0,
           String(cString: name) == ProcessInfo.processInfo.processName {
            outdatedBridges.insert(pid)
        }
        onStateChanged?()
    }

    /// Forgets turned-away processes that have since exited.
    func forgetExitedPeers() {
        let alive = rejectedPeers.filter { kill($0, 0) == 0 || errno == EPERM }
        guard alive != rejectedPeers else { return }
        rejectedPeers = alive
        outdatedBridges.formIntersection(alive)
        onStateChanged?()
    }

    private static func peerPID(_ fd: Int32) -> pid_t {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else { return 0 }
        return pid
    }

    /// The peer's PID if it's signed with this app's designated requirement
    /// (same team, same bundle ID): in practice, a bridge. Anything else is
    /// closed. Any process running as this user could still launch a bridge;
    /// the lease, Touch ID and the allowlist are what protect access.
    private func verifyPeer(_ fd: Int32) -> pid_t? {
        guard let ownRequirement else { return nil }
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return nil }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess,
              let guest,
              SecCodeCheckValidity(guest, [], ownRequirement) == errSecSuccess else { return nil }
        return Self.peerPID(fd)
    }

    private static func copyOwnRequirement() -> SecRequirement? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    // MARK: - Messages

    private func handle(_ line: Data, on connection: MCPConnection) {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            connection.send(MCPLocal.frame(Self.error(id: nil, code: -32700, message: "Parse error")))
            return
        }
        let method = json["method"] as? String ?? ""
        guard let rawID = json["id"], !(rawID is NSNull) else { return }   // notifications
        let id = JSONID(rawID)
        let params = json["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            introduce(connection, params: params)
            connection.send(MCPLocal.frame(Self.result(id: id, MCPTools.initializeResult())))
        case "ping":
            connection.send(MCPLocal.frame(Self.result(id: id, [:])))
        case "tools/list":
            connection.send(MCPLocal.frame(Self.result(id: id, ["tools": MCPTools.toolDefinitions])))
        case "tools/call":
            if connection.session == nil { introduce(connection, params: [:]) }
            guard let session = connection.session, let backend else { return }
            let name = params["name"] as? String ?? ""
            let arguments = ToolArguments(params["arguments"] as? [String: Any] ?? [:])
            let task = Task { [weak connection] in
                let result = await backend.callTool(name: name, arguments: arguments, session: session)
                connection?.send(MCPLocal.frame(Self.result(id: id, result.jsonObject)))
            }
            connection.tasks.append(task)
        default:
            connection.send(MCPLocal.frame(Self.error(id: id, code: -32601, message: "Unknown method: \(method)")))
        }
    }

    /// Records who the bridge says it's working for. The agent's terminal is
    /// found by walking up from the bridge's own process (verified by the peer
    /// check), plus the `TERM_PROGRAM` it reports.
    private func introduce(_ connection: MCPConnection, params: [String: Any]) {
        let args = ToolArguments(params)
        let sessionID = args.string(MCPLocal.sessionParam) ?? UUID().uuidString
        let termProgram = args.string(MCPLocal.termProgramParam)
        let ancestors = SystemProcessResolver.ancestorBundleIDs(of: connection.peerPID)
        let session = AgentSession(
            id: sessionID,
            clientName: MCPLocal.clientLabel(clientInfo: params["clientInfo"] as? [String: Any]),
            workingDirectory: args.string(MCPLocal.workingDirectoryParam),
            termProgram: termProgram,
            parentPID: args.int(MCPLocal.parentPIDParam).map { Int32(truncatingIfNeeded: $0) },
            hostBundleIDs: Denylist.agentHostApps(termProgram: termProgram, ancestorBundleIDs: ancestors),
            connectedAt: Date())
        // A session id seen on another live connection: the newer one wins.
        for other in connections.values where other !== connection && other.session?.id == sessionID {
            other.session = nil
            other.close()
        }
        connection.session = session
        backend?.sessionConnected(session)
    }

    private func closed(_ connection: MCPConnection) {
        connections.removeValue(forKey: connection.id)
        for task in connection.tasks { task.cancel() }
        if let session = connection.session { backend?.sessionDisconnected(session.id) }
    }

    /// The Disconnect button.
    func disconnect(sessionID: String) {
        for connection in connections.values where connection.session?.id == sessionID {
            connection.close()
        }
    }

    // MARK: - Helpers

    private static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    /// Whether something is already listening at `path` (another ClickRelay).
    private static func socketIsLive(_ path: String) -> Bool {
        guard var address = address(path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    private static func result(id: JSONID, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id.value, "result": result]
    }

    private static func error(id: JSONID?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id?.value ?? NSNull(), "error": ["code": code, "message": message]]
    }

    var connectedSessionIDs: [String] {
        connections.values.compactMap { $0.session?.id }
    }
}

/// A JSON-RPC id (string or number), carried across a task boundary.
nonisolated struct JSONID: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}

/// One accepted bridge connection. Reads on the main queue (calls are small);
/// writes on a queue of their own, since a screenshot result can be several
/// megabytes and the bridge may be slow to drain it.
@MainActor
final class MCPConnection {
    let id = UUID()
    let fd: Int32
    let peerPID: pid_t
    var session: AgentSession?
    var tasks: [Task<Void, Never>] = []
    var onLine: ((Data) -> Void)?
    var onClose: (() -> Void)?

    private var buffer = Data()
    private var readSource: DispatchSourceRead?
    private let writeQueue = DispatchQueue(label: "io.mergeable.ClickRelay.socket-write")
    private var isClosed = false

    init(fd: Int32, peerPID: pid_t) {
        self.fd = fd
        self.peerPID = peerPID
    }

    func start() {
        let fd = self.fd
        let writeQueue = self.writeQueue
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readAvailable() }
        }
        // Closed after any queued writes, so a reused descriptor never gets them.
        source.setCancelHandler { writeQueue.async { Darwin.close(fd) } }
        source.resume()
        readSource = source
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = recv(fd, &chunk, chunk.count, MSG_DONTWAIT)
        if count > 0 {
            buffer.append(contentsOf: chunk[0..<count])
            for line in MCPLocal.takeLines(from: &buffer) {
                onLine?(line)
                if isClosed { return }
            }
            if MCPLocal.isOversized(buffer) { close() }
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            close()
        }
    }

    func send(_ data: Data) {
        guard !isClosed else { return }
        let fd = self.fd
        writeQueue.async {
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.send(fd, base + offset, raw.count - offset, 0)
                    if written > 0 {
                        offset += written
                    } else if written < 0 && errno == EINTR {
                        continue
                    } else {
                        return
                    }
                }
            }
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        readSource?.cancel()
        readSource = nil
        onClose?()
    }
}
