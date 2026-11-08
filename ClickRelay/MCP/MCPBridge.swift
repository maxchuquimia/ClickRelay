import AppKit
import Foundation
import Network
import notify
import Security

/// `ClickRelay --mcp`: this executable run as a stdio MCP server, relaying to
/// the running app over the Unix socket (`MCPLocal.enterSocketDirectory`).
///
/// The bridge answers `initialize`, `ping` and `tools/list` itself, from the
/// same definitions the app uses, and relays only `tools/call`. So the server
/// looks healthy to the agent even while the app is closed; the app is opened,
/// in the background, on the first tool call.
///
/// The bridge is a child of the agent's terminal, so anything it did would be
/// charged to the terminal's permissions. It must never capture the screen,
/// read Accessibility or post events itself; only the app does that.
/// `BridgeIsolationTests` checks the files it's built from.
///
/// Runs on the main queue throughout, with no AppKit app or windows:
/// `ClickRelayMain` branches here before any of that is built. Nothing but
/// protocol messages may reach stdout.
///
/// When ClickRelay is updated while an agent is open, the bridge is still the
/// old build, and the new app turns it away (it no longer matches what's on
/// disk). So before each connection attempt the bridge checks whether its
/// executable was replaced and, if so, execs the new one in place, keeping
/// its PID, stdio, session and unrelayed input (`MCPLocal.BridgeHandoff`).
@MainActor
final class MCPBridge {
    static func run() -> Never {
        // A closed stdout must surface as a write error (and a clean exit), not
        // kill the process mid-relay.
        signal(SIGPIPE, SIG_IGN)
        let handoff = getenv(MCPLocal.handoffVariable)
            .flatMap { MCPLocal.BridgeHandoff(encoded: String(cString: $0)) }
        unsetenv(MCPLocal.handoffVariable)
        let bridge = MCPBridge(handoff: handoff)
        bridge.readStandardInput()
        bridge.observeAppLaunch()
        if let handoff {
            // Carry on where the previous build left off: replay what it hadn't
            // relayed, and reconnect if the agent had already said hello.
            bridge.receiveFromAgent(handoff.pending)
            bridge.connect()
        }
        dispatchMain()
    }

    private init(handoff: MCPLocal.BridgeHandoff?) {
        session = handoff?.session ?? UUID().uuidString
        launchDirectory = handoff?.launchDirectory ?? FileManager.default.currentDirectoryPath
        clientInfo = handoff?.clientInfo
    }

    /// Identifies this agent session to the app. A lease belongs to one
    /// session, so a second agent can't use an unlock meant for this one.
    private let session: String
    /// Read before connecting moves the current directory.
    private let launchDirectory: String
    /// The executable this process was started from, to notice an update.
    private let launchedExecutable = Bundle.main.executablePath.flatMap(MCPLocal.FileIdentity.init(path:))
    /// From the agent's `initialize`. Nil until then: the bridge doesn't reach
    /// for the app before it has an agent to introduce.
    private var clientInfo: [String: Any]?

    private var connection: NWConnection?
    private var isReady = false
    private var socketBuffer = Data()
    private var stdinBuffer = Data()

    /// Tool calls waiting for the app to come up.
    private var queued: [(id: Any, line: Data)] = []
    /// Tool calls relayed and not yet answered, by `idKey`. Failed back to the
    /// agent if the app goes away, so a call never hangs.
    private var inFlight: [String: Any] = [:]
    /// `clickrelay_save_script` calls in flight, by `idKey`: where to write
    /// the script when the app answers.
    private var pendingSaves: [String: URL] = [:]
    /// Where the agent is working, for script paths. Read at launch, before
    /// connecting moves the current directory.
    private lazy var agentDirectory: String? = MCPLocal.agentWorkingDirectory(
        environment: ProcessInfo.processInfo.environment, currentDirectory: launchDirectory)
    /// While set, failed connection attempts are retried quickly: the app is
    /// being launched (or was just found starting) for a queued call.
    private var launchDeadline: Date?
    private var reconnectDelay: TimeInterval = 1
    private var reconnectWork: DispatchWorkItem?

    // MARK: - Agent side (stdio)

    private var stdinSource: DispatchSourceRead?

    /// Reads on the main queue, so input is never read but unhandled between
    /// two main-queue blocks: anything not yet relayed is in `stdinBuffer` or
    /// `queued`, which is what a restart after an update hands on. End of
    /// input means the agent has gone.
    private func readStandardInput() {
        let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                let count = read(STDIN_FILENO, &chunk, chunk.count)
                if count == 0 { exit(0) }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { return }
                    exit(0)
                }
                self?.receiveFromAgent(Data(chunk[0..<count]))
            }
        }
        source.resume()
        stdinSource = source
    }

    private func receiveFromAgent(_ chunk: Data) {
        stdinBuffer.append(chunk)
        for line in MCPLocal.takeLines(from: &stdinBuffer) {
            handleAgentMessage(line)
        }
        if MCPLocal.isOversized(stdinBuffer) {
            stdinBuffer = Data()
            writeToAgent(Self.error(id: nil, code: -32600, message: "Message too large"))
        }
    }

    private func handleAgentMessage(_ line: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            writeToAgent(Self.error(id: nil, code: -32700, message: "Parse error"))
            return
        }
        // Responses (the bridge sends the agent no requests) and notifications
        // need nothing from the app.
        guard let method = json["method"] as? String,
              let id = json["id"], !(id is NSNull) else { return }
        switch method {
        case "initialize":
            let params = json["params"] as? [String: Any]
            clientInfo = params?["clientInfo"] as? [String: Any] ?? [:]
            writeToAgent(Self.result(id: id, MCPTools.initializeResult()))
            // Connect now if the app is already open, so the session shows up
            // in its window before the first call. Never launches it.
            connect()
        case "ping":
            writeToAgent(Self.result(id: id, [:]))
        case "tools/list":
            writeToAgent(Self.result(id: id, ["tools": MCPTools.toolDefinitions]))
        case "tools/call":
            // Script calls carry files to and from the agent's project.
            switch ScriptFiles.prepare(line, message: json, workingDirectory: agentDirectory,
                                       isInstalled: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }) {
            case .relay(let relayed, let saveTo):
                if let saveTo { pendingSaves[Self.idKey(id)] = saveTo }
                relay(id: id, line: relayed)
            case .fail(let message):
                writeToAgent(Self.toolError(id: id, message))
            case .answer(let result):
                // validate_script: checked here, without the app or a lease.
                writeToAgent(Self.result(id: id, result.jsonObject))
            }
        default:
            writeToAgent(Self.error(id: id, code: -32601, message: "Unknown method: \(method)"))
        }
    }

    private func writeToAgent(_ object: [String: Any]) {
        writeToAgent(MCPLocal.frame(object))
    }

    private func writeToAgent(_ data: Data) {
        do {
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch {
            exit(0)   // the agent has gone
        }
    }

    // MARK: - App side (socket)

    private func relay(id: Any, line: Data) {
        if isReady, let connection {
            inFlight[Self.idKey(id)] = id
            send(line + Data([0x0A]), over: connection)
            return
        }
        queued.append((id, line))
        if clientInfo == nil { clientInfo = [:] }
        if launchDeadline == nil {
            // An app that is already running gets a moment to finish starting
            // its listener; one that isn't is opened, which takes longer.
            let running = Self.appIsRunning
            launchDeadline = Date().addingTimeInterval(running ? 5 : 20)
            if !running { Self.launchApp() }
        }
        connect()
    }

    private func connect() {
        guard connection == nil, clientInfo != nil else { return }
        reconnectWork?.cancel()
        reconnectWork = nil
        restartIfUpdated()
        guard let path = MCPLocal.enterSocketDirectory() else {
            failQueued("ClickRelay couldn't create its folder in ~/Library/Application Support. "
                       + "Ask the user to check that folder's permissions.")
            return
        }
        let connection = NWConnection(to: .unix(path: path), using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.connectionChanged(connection, to: state) }
        }
        connection.start(queue: .main)
    }

    private func connectionChanged(_ connection: NWConnection, to state: NWConnection.State) {
        guard connection === self.connection else { return }
        switch state {
        case .ready:
            isReady = true
            launchDeadline = nil
            reconnectDelay = 1
            handshake(over: connection)
            receive(on: connection)
            let pending = queued
            queued = []
            for call in pending {
                inFlight[Self.idKey(call.id)] = call.id
                send(call.line + Data([0x0A]), over: connection)
            }
        case .waiting, .failed, .cancelled:
            // For a Unix socket, `waiting` means nothing is listening yet.
            drop(connection)
        default:
            break
        }
    }

    /// Introduces the agent to the app: session id, client, working directory,
    /// terminal and parent process (for the terminal denylist and the audit
    /// log). Sent before any relayed call on the same connection, and the app
    /// handles lines in order, so every call is attributed.
    private func handshake(over connection: NWConnection) {
        let environment = ProcessInfo.processInfo.environment
        var params: [String: Any] = [
            "protocolVersion": MCPTools.protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": clientInfo ?? [:],
            MCPLocal.sessionParam: session,
            MCPLocal.parentPIDParam: Int(getppid())
        ]
        if let directory = MCPLocal.agentWorkingDirectory(environment: environment,
                                                          currentDirectory: launchDirectory) {
            params[MCPLocal.workingDirectoryParam] = directory
        }
        if let term = environment["TERM_PROGRAM"], !term.isEmpty {
            params[MCPLocal.termProgramParam] = term
        }
        send(MCPLocal.frame(["jsonrpc": "2.0", "id": MCPLocal.handshakeId,
                             "method": "initialize", "params": params]), over: connection)
        send(MCPLocal.frame(["jsonrpc": "2.0", "method": "notifications/initialized"]),
             over: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) {
            [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, connection === self.connection else { return }
                if let data { self.socketBuffer.append(data) }
                for line in MCPLocal.takeLines(from: &self.socketBuffer) {
                    self.handleAppMessage(line)
                }
                if MCPLocal.isOversized(self.socketBuffer) || isComplete || error != nil {
                    self.drop(connection)
                } else {
                    self.receive(on: connection)
                }
            }
        }
    }

    private func handleAppMessage(_ line: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if json["method"] != nil {
            // Nothing is pushed in v1 (no channel notifications). The receive
            // path stays so a later version can tell the agent its lease ended.
            return
        }
        if let id = json["id"], !(id is NSNull) {
            if (id as? String) == MCPLocal.handshakeId { return }
            let key = Self.idKey(id)
            guard inFlight.removeValue(forKey: key) != nil else { return }
            if let saveTo = pendingSaves.removeValue(forKey: key) {
                writeToAgent(ScriptFiles.finishSave(line, to: saveTo, workingDirectory: agentDirectory) + Data([0x0A]))
                return
            }
            writeToAgent(line + Data([0x0A]))
        }
    }

    private func send(_ data: Data, over connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func drop(_ connection: NWConnection) {
        guard connection === self.connection else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        self.connection = nil
        isReady = false
        socketBuffer = Data()

        // The app went away mid-call. Input may or may not have been posted,
        // so the agent is told to look before repeating it.
        for id in inFlight.values {
            writeToAgent(Self.toolError(id: id, "ClickRelay closed before answering, and access "
                + "has ended. Ask the user to reopen and unlock it, then take a screenshot to "
                + "check what happened before trying again."))
        }
        inFlight = [:]
        for key in Array(pendingSaves.keys) where !queued.contains(where: { Self.idKey($0.id) == key }) {
            pendingSaves[key] = nil
        }

        if queued.isEmpty {
            scheduleReconnect()
        } else if let launchDeadline, Date() < launchDeadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                MainActor.assumeIsolated { self?.connect() }
            }
        } else {
            failQueued(Self.appIsRunning
                ? "ClickRelay is open but isn't accepting connections. Ask the user to quit "
                  + "and reopen ClickRelay, then try again."
                : "ClickRelay isn't running and couldn't be opened. Ask the user to open it, "
                  + "then try again.")
            scheduleReconnect()
        }
    }

    private func failQueued(_ message: String) {
        for call in queued { writeToAgent(Self.toolError(id: call.id, message)) }
        queued = []
        pendingSaves = [:]
        launchDeadline = nil
    }

    /// Backs off to a check every 10 seconds. Only the fallback: the app
    /// announces itself when it starts listening (`observeAppLaunch`).
    private func scheduleReconnect() {
        guard reconnectWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.reconnectWork = nil
                self?.connect()
            }
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay, execute: work)
        reconnectDelay = min(reconnectDelay * 2, 10)
    }

    /// Connects as soon as the app says its socket is up. `notify_register_dispatch`
    /// rather than the CF Darwin notify center, because the bridge runs
    /// `dispatchMain()`, which doesn't turn a run loop.
    private func observeAppLaunch() {
        var token: Int32 = 0
        notify_register_dispatch(MCPLocal.readyNotification, &token, .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.connection == nil else { return }
                self.reconnectDelay = 1
                self.connect()
            }
        }
    }

    // MARK: - Updates

    /// Execs the updated executable in place if ClickRelay was replaced since
    /// this bridge started. Doesn't return when it works. Called only between
    /// connections, so nothing is in flight; queued calls and partial input
    /// go with the handoff. If the new copy isn't complete and signed yet, or
    /// the exec fails, this carries on as before and the next attempt checks
    /// again.
    private func restartIfUpdated() {
        guard connection == nil, inFlight.isEmpty,
              let path = Bundle.main.executablePath, let launchedExecutable,
              let current = MCPLocal.FileIdentity(path: path), current != launchedExecutable,
              Self.isSignedClickRelay(Bundle.main.bundleURL) else { return }
        var pending = Data()
        for call in queued {
            pending.append(call.line)
            pending.append(0x0A)
        }
        pending.append(stdinBuffer)
        guard pending.count <= MCPLocal.BridgeHandoff.maxPendingBytes,
              let encoded = MCPLocal.BridgeHandoff(session: session, clientInfo: clientInfo,
                                                   launchDirectory: launchDirectory,
                                                   pending: pending).encoded() else { return }
        setenv(MCPLocal.handoffVariable, encoded, 1)
        let error = Self.exec(path)
        unsetenv(MCPLocal.handoffVariable)
        FileHandle.standardError.write(Data(
            "ClickRelay: couldn't restart the bridge after an update: \(String(cString: strerror(error)))\n".utf8))
    }

    /// Whether the bundle on disk is a complete ClickRelay signed by the team.
    private static func isSignedClickRelay(_ bundle: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(MCPLocal.updateRequirement as CFString, [], &requirement)
                == errSecSuccess, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// Replaces this process with `path`, same PID and arguments, keeping only
    /// stdin, stdout and stderr open. Returns the error if it couldn't.
    private static func exec(_ path: String) -> Int32 {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETEXEC | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addinherit_np(&actions, fd)
        }
        let arguments = [path] + CommandLine.arguments.dropFirst()
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, path, &actions, &attributes, argv, environ)
    }

    // MARK: - The app

    /// Whether a ClickRelay app (not this bridge) is running.
    private static var appIsRunning: Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: MCPLocal.bundleIdentifier)
            .contains { $0.processIdentifier != me }
    }

    /// Opens ClickRelay in the background. Launch Services starts it as its
    /// own responsible process, so its own Screen Recording and Accessibility
    /// grants apply, not the terminal's.
    private static func launchApp() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: configuration) { _, _ in }
    }

    // MARK: - Messages

    /// A JSON-RPC id as a dictionary key. Numbers and strings are distinct ids
    /// that could print alike, hence the prefix.
    nonisolated static func idKey(_ id: Any) -> String {
        if let string = id as? String { return "s:" + string }
        return "n:\(id)"
    }

    private static func result(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    /// A failure the model reads, as opposed to a protocol error its client
    /// would swallow or show as a broken server.
    private static func toolError(id: Any, _ message: String) -> [String: Any] {
        result(id: id, ["content": [["type": "text", "text": message]], "isError": true])
    }
}
