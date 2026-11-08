import Foundation
import Testing
@testable import ClickRelay

@Suite("Framing and handshake")
struct MCPLocalTests {
    @Test func splitsCompleteLinesAndKeepsThePartialOne() {
        var buffer = Data("{\"a\":1}\n\n  \n{\"b\":2}\r\n{\"c\"".utf8)
        let lines = MCPLocal.takeLines(from: &buffer)
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["{\"a\":1}", "{\"b\":2}"])
        #expect(String(decoding: buffer, as: UTF8.self) == "{\"c\"")
        buffer.append(Data(":3}\n".utf8))
        #expect(MCPLocal.takeLines(from: &buffer).map { String(decoding: $0, as: UTF8.self) } == ["{\"c\":3}"])
        #expect(buffer.isEmpty)
    }

    @Test func framesAreOneLine() {
        let data = MCPLocal.frame(["text": "line one\nline two"])
        #expect(data.last == 0x0A)
        #expect(data.dropLast().contains(0x0A) == false)
    }

    @Test func oversizedBuffersAreCaught() {
        #expect(!MCPLocal.isOversized(Data(count: 1024)))
        #expect(MCPLocal.isOversized(Data(count: MCPLocal.maxMessageBytes + 1)))
    }

    @Test func workingDirectoryPrefersTheProject() {
        #expect(MCPLocal.agentWorkingDirectory(environment: ["CLAUDE_PROJECT_DIR": "/p", "PWD": "/w"],
                                               currentDirectory: "/c") == "/p")
        #expect(MCPLocal.agentWorkingDirectory(environment: ["PWD": "/w"], currentDirectory: "/c") == "/w")
        #expect(MCPLocal.agentWorkingDirectory(environment: [:], currentDirectory: "/c") == "/c")
        let support = MCPLocal.supportDirectory.path(percentEncoded: false)
        #expect(MCPLocal.agentWorkingDirectory(environment: [:], currentDirectory: support) == nil)
    }

    @Test func clientLabels() {
        #expect(MCPLocal.clientLabel(clientInfo: ["name": "claude-code"]) == "Claude Code")
        #expect(MCPLocal.clientLabel(clientInfo: ["name": "my-agent"]) == "My Agent")
        #expect(MCPLocal.clientLabel(clientInfo: ["name": "x", "title": "Custom"]) == "Custom")
        #expect(MCPLocal.clientLabel(clientInfo: nil) == "AI Agent")
    }

    @Test func setupCommand() {
        #expect(MCPLocal.shellQuoted("/Applications/ClickRelay.app/Contents/MacOS/ClickRelay")
                == "/Applications/ClickRelay.app/Contents/MacOS/ClickRelay")
        #expect(MCPLocal.shellQuoted("/Users/me/My Apps/ClickRelay") == "'/Users/me/My Apps/ClickRelay'")
        #expect(MCPLocal.claudeAddCommand.hasPrefix("claude mcp add --scope user clickrelay -- "))
        #expect(MCPLocal.claudeAddCommand.hasSuffix(" --mcp"))
    }

    @Test func handoffSurvivesARestart() throws {
        let pending = Data("{\"id\":3,\"method\":\"tools/call\"}\n{\"id\":4,\"met".utf8)
        let handoff = MCPLocal.BridgeHandoff(session: "abc", clientInfo: ["name": "claude-code"],
                                             launchDirectory: "/p", pending: pending)
        let encoded = try #require(handoff.encoded())
        let decoded = try #require(MCPLocal.BridgeHandoff(encoded: encoded))
        #expect(decoded.session == "abc")
        #expect(decoded.clientInfo?["name"] as? String == "claude-code")
        #expect(decoded.launchDirectory == "/p")
        #expect(decoded.pending == pending)
        // Before the agent's initialize there's no client yet.
        let early = MCPLocal.BridgeHandoff(session: "s", clientInfo: nil, launchDirectory: "/", pending: Data())
        let earlyEncoded = try #require(early.encoded())
        #expect(try #require(MCPLocal.BridgeHandoff(encoded: earlyEncoded)).clientInfo == nil)
        #expect(MCPLocal.BridgeHandoff(encoded: "not base64") == nil)
    }

    @Test func replacingAFileChangesItsIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "ClickRelay")
        try Data("old".utf8).write(to: file)
        let before = try #require(MCPLocal.FileIdentity(path: file.path))
        #expect(MCPLocal.FileIdentity(path: file.path) == before)
        let replacement = directory.appending(path: "new")
        try Data("new".utf8).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: replacement)
        #expect(MCPLocal.FileIdentity(path: file.path) != before)
    }

    @Test func socketPathFitsSunPath() {
        // Relative to the support directory, so it always fits in 104 bytes.
        #expect(MCPLocal.socketName.utf8.count < 104)
    }

    @Test func homeIsAbbreviated() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        #expect(MCPLocal.abbreviatingHome(home + "xcode/Foo").hasPrefix("~/"))
        #expect(MCPLocal.abbreviatingHome("/tmp/x") == "/tmp/x")
    }
}

@Suite("Tool definitions")
struct MCPToolsTests {
    @Test func everyToolIsListedAndPrefixed() {
        let tools = MCPTools.toolDefinitions
        #expect(tools.count == ToolName.allCases.count)
        let names = tools.compactMap { $0["name"] as? String }
        #expect(names == ToolName.allCases.map(\.rawValue))
        #expect(names.allSatisfy { $0.hasPrefix("clickrelay_") })
    }

    @Test func requiredArgumentsAreDeclared() {
        for tool in MCPTools.toolDefinitions {
            let schema = tool["inputSchema"] as? [String: Any]
            #expect(schema?["type"] as? String == "object")
            let properties = schema?["properties"] as? [String: Any] ?? [:]
            for required in schema?["required"] as? [String] ?? [] {
                #expect(properties[required] != nil, "\(tool["name"] ?? "") requires undeclared \(required)")
            }
            let description = tool["description"] as? String ?? ""
            #expect(!description.isEmpty)
        }
    }

    @Test func descriptionsStateTheRules() {
        for tool in MCPTools.toolDefinitions {
            guard let name = tool["name"] as? String, let known = ToolName(rawValue: name),
                  !known.worksWhileLocked else { continue }
            let description = tool["description"] as? String ?? ""
            #expect(description.contains("allowed"), "\(tool["name"] ?? "")")
        }
    }

    @Test func definitionsSerialise() throws {
        let data = try JSONSerialization.data(withJSONObject: ["tools": MCPTools.toolDefinitions])
        #expect(data.count > 1000)
        _ = try JSONSerialization.data(withJSONObject: MCPTools.initializeResult())
    }

    @Test func inputToolsAreSerialised() {
        #expect(ToolName.click.isInput && ToolName.type.isInput && ToolName.press.isInput)
        #expect(!ToolName.screenshot.isInput && !ToolName.status.isInput)
        #expect(!ToolName.requestAccess.isInput && !ToolName.notify.isInput)
    }

    @Test func onlyStatusRequestNotifyAndValidateWorkWhileLocked() {
        #expect(ToolName.allCases.filter(\.worksWhileLocked) == [.status, .requestAccess, .notify, .validateScript])
    }

    @Test func instructionsCoverFocusTimeAndNotify() {
        let text = MCPTools.serverInstructions
        #expect(text.contains("clickrelay_focus_window"))
        #expect(text.contains("clickrelay_request_access"))
        #expect(text.contains("clickrelay_notify"))
    }

    @Test func argumentsAreReadLeniently() {
        let args = ToolArguments([
            "window_id": "42", "x": 10.0, "count": 2.0, "windowId": 7, "flag": "true",
            "modifiers": "cmd+shift", "from": "{\"x\": 1, \"y\": 2}", "to": ["x": 3, "y": 4.5],
            "maxEdge": 800, "nothing": NSNull()
        ])
        #expect(args.int("window_id") == 42)
        #expect(args.double("x") == 10)
        #expect(args.int("count") == 2)
        #expect(args.int("max_edge") == 800)   // camelCase fallback
        #expect(args.bool("flag") == true)
        #expect(args.strings("modifiers") == ["cmd", "shift"])
        #expect(args.point("from")?.x == 1 && args.point("from")?.y == 2)
        #expect(args.point("to")?.y == 4.5)
        #expect(args.value("nothing") == nil)
        #expect(ToolArguments(["x": 1.5]).int("x") == nil)
    }

    @Test func toolResultJSON() {
        let result = ToolResult(content: [.text("hi"), .image(data: Data([1, 2, 3]), mimeType: "image/png")], isError: true)
        let object = result.jsonObject
        #expect(object["isError"] as? Bool == true)
        let content = object["content"] as? [[String: Any]]
        #expect(content?[1]["data"] as? String == "AQID")
        #expect(ToolResult.text("ok").jsonObject["isError"] == nil)
    }
}

/// The bridge is a child of the agent's terminal: anything it captured or
/// posted would be charged to the terminal's permissions. So the code it runs
/// must never reach ScreenCaptureKit, Accessibility or CGEvent.
@Suite("Bridge isolation")
struct BridgeIsolationTests {
    static let bridgeFiles = ["ClickRelayMain.swift", "MCP/MCPBridge.swift", "MCP/MCPLocal.swift", "MCP/MCPTools.swift",
                              "MCP/ScriptFiles.swift", "Scripts/Script.swift"]
    static let forbidden = ["ScreenCaptureKit", "SCScreenshotManager", "SCShareableContent", "SCContentFilter",
                            "CGEvent", "CGWindowList", "AXUIElement", "AXIsProcessTrusted",
                            "CGRequestScreenCaptureAccess", "CGPreflightScreenCaptureAccess",
                            "ClickRelayApp(", "AppModel", "LeaseController", "InputPoster", "Screenshotter"]

    static var sourceRoot: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "ClickRelay", directoryHint: .isDirectory)
    }

    @Test(arguments: bridgeFiles)
    func bridgeCodeNeverTouchesCaptureOrInput(file: String) throws {
        let source = try String(contentsOf: Self.sourceRoot.appending(path: file), encoding: .utf8)
        // Comments may mention the APIs (to say they're off limits).
        let code = source.split(separator: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }.joined(separator: "\n")
        for name in Self.forbidden {
            #expect(!code.contains(name), "\(file) mentions \(name)")
        }
    }

    @Test func mainBranchesBeforeTheApp() throws {
        let source = try String(contentsOf: Self.sourceRoot.appending(path: "ClickRelayMain.swift"), encoding: .utf8)
        let bridge = try #require(source.range(of: "MCPBridge.run()"))
        let app = try #require(source.range(of: "ClickRelayApp.main()"))
        #expect(bridge.lowerBound < app.lowerBound)
    }
}
