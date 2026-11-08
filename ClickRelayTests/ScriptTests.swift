import CoreGraphics
import Foundation
import Testing
@testable import ClickRelay

/// Always gives the same answer, and remembers what it was asked.
final class FakeChooser: ElementChooser, @unchecked Sendable {
    let answer: ChooserAnswer
    private let lock = NSLock()
    private var asked: [ChooserRequest] = []

    init(_ answer: ChooserAnswer) { self.answer = answer }

    var requests: [ChooserRequest] { lock.withLock { asked } }

    func choose(_ request: ChooserRequest) async -> ChooserAnswer {
        lock.withLock { asked.append(request) }
        return answer
    }
}

@Suite("Script parsing")
struct ScriptParsingTests {
    func parse(_ object: [String: Any], params: [String: String] = [:]) -> Result<Script, ScriptError> {
        Script.parse(object, params: params)
    }

    func message(_ result: Result<Script, ScriptError>) -> String? {
        if case .failure(let error) = result { return error.message }
        return nil
    }

    @Test func readsEachKindOfStep() throws {
        let script = try parse([
            "name": "demo", "app": "com.apple.dt.Xcode",
            "steps": [
                ["press": ["role": "menu_bar_item", "title": "Product"]],
                ["press": "Build", "action": "AXShowMenu"],
                ["focus": ["identifier": "search"]],
                ["set_value": ["role": "text_field"], "value": "hello"],
                ["wait_for": ["title": "Done", "enabled": true], "timeout_s": 20],
                ["type": "abc"],
                ["key": "cmd+shift+k"],
                ["focus_window": true, "window": "Main"],
                ["launch_app": "com.apple.iphonesimulator"],
                ["wait": 0.5, "optional": true]
            ]
        ]).get()
        #expect(script.name == "demo")
        #expect(script.steps.count == 10)
        #expect(script.steps[0].action == .press(ElementTarget(role: "AXMenuBarItem", title: "Product", scope: .menus), action: nil))
        #expect(script.steps[1].action == .press(ElementTarget(title: "Build"), action: "AXShowMenu"))
        #expect(script.steps[3].action == .setValue(ElementTarget(role: "AXTextField"), value: "hello"))
        #expect(script.steps[4].timeout == 20)
        #expect(script.steps[4].effectiveTimeout == 20)
        #expect(script.steps[6].action == .key("k", modifiers: ["cmd", "shift"]))
        #expect(script.steps[7].window == "Main")
        #expect(script.steps[8].app == "com.apple.iphonesimulator")
        #expect(script.steps[9].optional)
    }

    @Test func rolesAreNormalised() {
        #expect(ElementTarget.normaliseRole("button") == "AXButton")
        #expect(ElementTarget.normaliseRole("menu_item") == "AXMenuItem")
        #expect(ElementTarget.normaliseRole("AXPopUpButton") == "AXPopUpButton")
    }

    @Test func paramsAreFilledIn() throws {
        let object: [String: Any] = [
            "name": "pick", "app": "com.apple.dt.Xcode",
            "params": ["scheme": "The scheme", "config": ["default": "Debug"]],
            "steps": [["press": ["title": "{{scheme}} ({{ config }})"]], ["type": "{{scheme}}"]]
        ]
        let script = try parse(object, params: ["scheme": "App"]).get()
        #expect(script.steps[0].action.target?.title == "App (Debug)")
        #expect(script.steps[1].action == .type("App"))
        let overridden = try parse(object, params: ["scheme": "App", "config": "Release"]).get()
        #expect(overridden.steps[0].action.target?.title == "App (Release)")
    }

    @Test func missingUnknownAndUndeclaredParamsFail() {
        let object: [String: Any] = ["app": "a.b", "params": ["scheme": "The scheme"],
                                     "steps": [["type": "{{scheme}}"]]]
        #expect(message(parse(object))?.contains("needs a value for \"scheme\"") == true)
        #expect(message(parse(object, params: ["scheme": "x", "sceme": "y"]))?.contains("\"sceme\"") == true)
        let undeclared: [String: Any] = ["app": "a.b", "steps": [["type": "{{who}}"]]]
        #expect(message(parse(undeclared))?.contains("{{who}}") == true)
    }

    @Test func badStepsSayWhichStep() {
        #expect(message(parse(["app": "a.b", "steps": [["type": "x"], ["press": "A", "type": "b"]]]))?
            .contains("Step 2 has more than one action") == true)
        #expect(message(parse(["app": "a.b", "steps": [["click": 1]]]))?.contains("Step 1 has no action") == true)
        #expect(message(parse(["steps": [["press": "Save"]]]))?.contains("needs an app") == true)
        #expect(message(parse(["app": "a.b", "steps": [["press": [String: Any]()]]]))?.contains("nothing to match on") == true)
        #expect(message(parse(["app": "a.b", "steps": [Any]()]))?.contains("empty") == true)
        #expect(message(parse(["app": "a.b", "steps": [["wait": 500]]]))?.contains("0 to 60") == true)
        #expect(message(parse(["app": "a.b", "steps": [["press": ["title": "A", "in": "dock"]]]]))?.contains("\"in\"") == true)
    }

    @Test func keyboardStepsDontNeedAnApp() throws {
        let script = try parse(["steps": [["key": "return"], ["type": "hi"], ["wait": 1]]]).get()
        #expect(script.app == nil)
        #expect(script.steps.count == 3)
    }

    @Test func roundTripsThroughItsFileFormat() throws {
        let original = try parse([
            "name": "trip", "description": "Round trip", "app": "com.apple.dt.Xcode", "window": "Proj",
            "params": ["scheme": ["description": "Scheme", "default": "App"]],
            "steps": [
                ["press": ["role": "menu_item", "title": "Run", "in": "windows"]],
                ["set_value": ["identifier": "field"], "value": "v"],
                ["key": "cmd+s"], ["wait": 2], ["focus_window": true, "optional": true, "timeout_s": 4]
            ]
        ]).get()
        let data = original.fileData
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let again = try parse(object).get()
        #expect(again.steps == original.steps)
        #expect(again.app == original.app)
        #expect(again.window == original.window)
        #expect(again.params == original.params)
    }

    @Test func waitForCanWaitLongerThanOtherSteps() throws {
        let script = try parse([
            "name": "long", "app": "com.apple.dt.Xcode",
            "steps": [
                ["wait_for": "Upload complete", "timeout_s": 600],
                ["wait_for": "Done", "timeout_s": 5000],
                ["press": "Done", "timeout_s": 600]
            ]
        ]).get()
        #expect(script.steps[0].effectiveTimeout == 600)
        #expect(script.steps[1].effectiveTimeout == ScriptStep.maxWaitTimeout)
        #expect(script.steps[2].effectiveTimeout == ScriptStep.maxTimeout)
    }

    @Test func warnsAboutCappedTimeoutsAndMenuBarPresses() {
        let (result, warnings) = Script.check([
            "name": "w", "app": "com.apple.dt.Xcode",
            "steps": [
                ["press": ["role": "menu_bar_item", "title": "Product"]],
                ["press": ["role": "menu_item", "title": "Archive"], "timeout_s": 300]
            ]
        ], requireParams: true)
        #expect((try? result.get()) != nil)
        #expect(warnings.contains { $0.hasPrefix("Step 1 presses a menu bar item") })
        #expect(warnings.contains { $0.hasPrefix("Step 2 asks to wait 300 s") })
    }

    /// A miss is only the model's to fill when the step gives a hint, and
    /// never on an optional or wait_for step: "Done" mustn't press "Cancel".
    @Test func whenTheModelMayGuess() throws {
        let script = try parse([
            "name": "m", "app": "com.apple.dt.Xcode",
            "steps": [
                ["press": ["title": "Done"]],
                ["press": ["hint": "the blue confirm button"]],
                ["press": ["hint": "the blue confirm button"], "optional": true],
                ["wait_for": ["hint": "upload finished"]],
                ["press": ["title": "Done", "hint": "closes the sheet"]]
            ]
        ]).get()
        #expect(script.steps.map(\.modelMayGuess) == [false, true, false, false, true])
    }
}

@Suite("Script validation")
struct ScriptValidationTests {
    func check(_ script: [String: Any], params: [String: Any]? = nil,
               installed: Set<String> = ["com.apple.dt.Xcode"]) -> ToolResult {
        ScriptCheck.result(script, params: params, label: "scripts/a.json", isInstalled: { installed.contains($0) })
    }

    @Test func aValidScriptIsDescribedStepByStep() throws {
        let result = check([
            "name": "build", "app": "com.apple.dt.Xcode",
            "params": ["scheme": "Scheme", "config": ["default": "Debug"]],
            "steps": [["press": ["role": "menu_item", "title": "{{scheme}}"], "timeout_s": 5],
                      ["key": "cmd+b"], ["wait_for": "Build Succeeded", "optional": true]]
        ])
        #expect(!result.isError)
        let text = try #require(result.firstText)
        #expect(text.contains("scripts/a.json is valid: \"build\", 3 steps, in com.apple.dt.Xcode."))
        #expect(text.contains("scheme (needs a value when you run it)"))
        #expect(text.contains("config (default \"Debug\")"))
        #expect(text.contains("1. press AXMenuItem \"{{scheme}}\" in the menus, waits up to 5.0 s"))
        #expect(text.contains("2. press cmd+b"))
        #expect(text.contains("3. wait for element \"Build Succeeded\", waits up to 10 s, optional"))
        #expect(!text.contains("Warnings"))
    }

    @Test func givenParamsAreFilledIn() {
        let result = check(["app": "com.apple.dt.Xcode", "params": ["scheme": "Scheme"],
                            "steps": [["press": "{{scheme}}"]]], params: ["scheme": "App"])
        #expect(result.firstText?.contains("press element \"App\"") == true)
        #expect(result.firstText?.contains("scheme = \"App\"") == true)
    }

    @Test func typosAndMissingAppsAreWarnings() throws {
        let result = check([
            "app": "com.example.nothere", "nmae": "x",
            "steps": [["press": ["titel": "Save", "role": "button"], "timeout": 5]]
        ])
        #expect(!result.isError)
        let text = try #require(result.firstText)
        #expect(text.contains("The script has \"nmae\""))
        #expect(text.contains("Step 1 has \"timeout\""))
        #expect(text.contains("Step 1's element has \"titel\""))
        #expect(text.contains("only matches when it's the only one of its role"))
        #expect(text.contains("No app with bundle ID com.example.nothere is installed"))
    }

    @Test func camelCaseKeysAreKnown() {
        let result = check(["app": "com.apple.dt.Xcode", "steps": [["setValue": "Name", "value": "x", "timeoutS": 2]]])
        #expect(result.firstText?.contains("Warnings") == false)
    }

    @Test func keyboardStepsWithNoAppAreFlagged() {
        let result = check(["steps": [["type": "hi"], ["wait": 1], ["key": "return"]]])
        #expect(result.firstText?.contains("Steps 1, 3 type into whichever allowed app is frontmost") == true)
    }

    @Test func anInvalidScriptIsAnError() {
        let result = check(["app": "com.apple.dt.Xcode", "steps": [["press": "A"], ["jump": true]]])
        #expect(result.isError)
        #expect(result.firstText?.contains("scripts/a.json isn't valid: Step 2 has no action") == true)
        #expect(check(["app": "a.b"]).firstText?.contains("no steps") == true)
        #expect(ScriptCheck.result(nil, params: nil, label: nil, isInstalled: { _ in true }).isError)
    }

    @Test func theBridgeAnswersValidationItself() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ClickRelayValidate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"name":"v","app":"x.y","steps":[{"press":"OK"}]}"#.utf8).write(to: directory.appending(path: "v.json"))
        func prepare(_ arguments: [String: Any]) -> ScriptFiles.Prepared {
            let message: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                          "params": ["name": "clickrelay_validate_script", "arguments": arguments]]
            let line = try! JSONSerialization.data(withJSONObject: message)
            return ScriptFiles.prepare(line, message: message, workingDirectory: directory.path(percentEncoded: false),
                                       isInstalled: { _ in true })
        }
        guard case .answer(let result) = prepare(["path": "v.json"]) else { Issue.record("expected answer"); return }
        #expect(result.firstText?.contains("v.json is valid") == true)
        guard case .answer(let missing) = prepare(["path": "gone.json"]) else { Issue.record("expected answer"); return }
        #expect(missing.isError)
        #expect(missing.firstText?.contains("There's no script at gone.json") == true)
        guard case .answer(let inline) = prepare(["script": ["steps": [["key": "a"]]]]) else {
            Issue.record("expected answer"); return
        }
        #expect(!inline.isError)
    }
}

@Suite("Element matching")
struct ElementMatchingTests {
    func button(_ title: String? = nil, label: String? = nil, id: String? = nil, role: String = "AXButton",
                enabled: Bool = true, rank: Int = 0) -> MatchCandidate {
        MatchCandidate(role: role, title: title, label: label, identifier: id, enabled: enabled, rank: rank)
    }

    @Test func identifierWinsOverText() {
        let candidates = [button("Save"), button("Store", id: "save-button")]
        #expect(ElementMatcher.match(ElementTarget(title: "Save", identifier: "save-button"), in: candidates)
            == .unique(1, .identifier))
    }

    @Test func titleMatchesALabelToo() {
        let candidates = [button(label: "Share"), button("Run")]
        #expect(ElementMatcher.match(ElementTarget(title: "share"), in: candidates) == .unique(0, .exact))
    }

    @Test func ellipsesAndColonsDontCount() {
        let candidates = [button("Export…"), button("Export As…")]
        #expect(ElementMatcher.match(ElementTarget(title: "Export"), in: candidates) == .unique(0, .exact))
        #expect(ElementMatcher.match(ElementTarget(title: "Name:"), in: [button("Name")]) == .unique(0, .exact))
    }

    @Test func partialTextIsTheFallback() {
        let candidates = [button("Build for Testing"), button("Clean")]
        #expect(ElementMatcher.match(ElementTarget(title: "testing"), in: candidates) == .unique(0, .partial))
        #expect(ElementMatcher.match(ElementTarget(title: "Build"), in: candidates + [button("Build Again")])
            == .ambiguous([0, 2]))
    }

    @Test func roleFilters() {
        let candidates = [button("Open", role: "AXMenuItem"), button("Open")]
        #expect(ElementMatcher.match(ElementTarget(role: "AXButton", title: "Open"), in: candidates) == .unique(1, .exact))
        #expect(ElementMatcher.match(ElementTarget(role: "AXCheckBox", title: "Open"), in: candidates) == .noMatch)
    }

    @Test func tiesGoToTheFrontWindowThenEnabled() {
        let candidates = [button("OK", rank: 1), button("OK", enabled: false), button("OK")]
        #expect(ElementMatcher.match(ElementTarget(title: "OK"), in: candidates) == .unique(2, .exact))
        let both = [button("OK"), button("OK")]
        #expect(ElementMatcher.match(ElementTarget(title: "OK"), in: both) == .ambiguous([0, 1]))
    }

    @Test func roleAloneWorksOnlyWhenItsTheOnlyOne() {
        #expect(ElementMatcher.match(ElementTarget(role: "AXTextField"),
                                     in: [button("A"), button(role: "AXTextField")]) == .unique(1, .exact))
        #expect(ElementMatcher.match(ElementTarget(role: "AXButton"), in: [button("A"), button("B")])
            == .ambiguous([0, 1]))
    }

    @Test func theModelSettlesATie() async {
        let chooser = FakeChooser(.picked(1))
        let both = [button("OK", id: "first"), button("OK", id: "second")]
        let result = await ElementMatcher.pick(ElementTarget(title: "OK", hint: "the second one"), step: "press OK",
                                               in: both, allowModel: true, chooser: chooser)
        #expect(result == .found(1, .model))
        #expect(chooser.requests.first?.options.count == 2)
        #expect(chooser.requests.first?.step == "press OK")
    }

    @Test func theModelCanSayNone() async {
        let result = await ElementMatcher.pick(ElementTarget(title: "OK"), step: "press OK",
                                               in: [button("OK"), button("OK")], allowModel: true,
                                               chooser: FakeChooser(.noMatch))
        #expect(result == .notFound(closest: [0, 1], note: nil))
    }

    @Test func aMissAsksTheModelOnlyIfAllowed() async {
        let candidates = [button("Archive project"), button("Run")]
        let chooser = FakeChooser(.picked(0))
        let found = await ElementMatcher.pick(ElementTarget(title: "Archive the app"), step: "press Archive",
                                              in: candidates, allowModel: true, chooser: chooser)
        #expect(found == .found(0, .model))
        let unasked = FakeChooser(.picked(0))
        let missed = await ElementMatcher.pick(ElementTarget(title: "Archive the app"), step: "press Archive",
                                               in: candidates, allowModel: false, chooser: unasked)
        #expect(missed == .notFound(closest: [0, 1], note: nil))
        #expect(unasked.requests.isEmpty)
    }

    @Test func anUnavailableModelIsExplained() async {
        let result = await ElementMatcher.pick(ElementTarget(title: "Go"), step: "press Go",
                                               in: [button("Go"), button("Go")], allowModel: true,
                                               chooser: NoModelChooser())
        guard case .notFound(_, let note) = result else { Issue.record("expected notFound"); return }
        #expect(note?.contains("off") == true)
    }

    @Test func aPickOutsideTheShortlistIsIgnored() async {
        let result = await ElementMatcher.pick(ElementTarget(title: "OK"), step: "press OK",
                                               in: [button("OK"), button("OK")], allowModel: true,
                                               chooser: FakeChooser(.picked(7)))
        #expect(result == .notFound(closest: [0, 1], note: nil))
    }

    @Test func promptListsEveryOptionWithAnID() {
        let prompt = OnDeviceChooser.prompt(for: ChooserRequest(step: "press Save", options: ["AXButton \"Save\"", "AXButton \"Cancel\""]))
        #expect(prompt.contains("Step: press Save"))
        #expect(prompt.contains("c1: AXButton \"Save\""))
        #expect(prompt.contains("c2: AXButton \"Cancel\""))
    }
}

@Suite("Script recording")
struct ScriptRecordingTests {
    @Test func buildPicksTheMainAppAndParams() {
        let steps = [
            ScriptStep(action: .press(ElementTarget(role: "AXMenuItem", title: "Release", scope: .windows), action: nil),
                       app: "com.apple.dt.Xcode"),
            ScriptStep(action: .type("Release build"), app: "com.apple.dt.Xcode"),
            ScriptStep(action: .focusWindow, app: "com.apple.iphonesimulator")
        ]
        let built = ScriptBuilder.build(name: "x", description: nil, steps: steps,
                                        params: ["config": "Release", "unused": "zzz"], skipped: 2)
        #expect(built.script.app == "com.apple.dt.Xcode")
        #expect(built.script.steps[0].app == nil)
        #expect(built.script.steps[2].app == "com.apple.iphonesimulator")
        #expect(built.script.steps[0].action.target?.title == "{{config}}")
        #expect(built.script.steps[1].action == .type("{{config}} build"))
        #expect(built.script.params == [ScriptParam(name: "config", defaultValue: "Release")])
        #expect(built.warnings.contains { $0.contains("\"unused\"") })
        #expect(built.warnings.contains { $0.contains("2 coordinate calls") })
    }

    @Test func roleOnlyStepsAreFlagged() {
        let built = ScriptBuilder.build(name: "x", description: nil,
                                        steps: [ScriptStep(action: .press(ElementTarget(role: "AXButton"), action: nil), app: "a.b")],
                                        params: [:], skipped: 0)
        #expect(built.warnings.first?.contains("role alone") == true)
    }

    @Test func aBuiltScriptParsesBack() throws {
        let built = ScriptBuilder.build(name: "x", description: "d",
                                        steps: [ScriptStep(action: .press(ElementTarget(role: "AXMenuItem", title: "Run", scope: .windows), action: nil), app: "a.b"),
                                                ScriptStep(action: .key("s", modifiers: ["cmd"]), app: "a.b")],
                                        params: [:], skipped: 0)
        let object = try #require(try JSONSerialization.jsonObject(with: built.script.fileData) as? [String: Any])
        let parsed = try Script.parse(object).get()
        #expect(parsed.steps == built.script.steps)
        // Recorded from a window tree, so a menu item stays in the windows scope.
        #expect(parsed.steps[0].action.target?.scope == .windows)
    }

    @MainActor @Test func recorderKeepsTheLatestSteps() {
        let recorder = ScriptRecorder()
        for index in 0..<(ScriptRecorder.limit + 5) {
            recorder.record(ScriptStep(action: .type("\(index)")), session: "s")
        }
        #expect(recorder.steps(for: "s").count == ScriptRecorder.limit)
        #expect(recorder.steps(for: "s").first?.action == .type("5"))
        recorder.skip(session: "s")
        #expect(recorder.skippedCount(for: "s") == 1)
        recorder.clear(session: "s")
        #expect(recorder.steps(for: "s").isEmpty)
        #expect(recorder.steps(for: "other").isEmpty)
    }
}

@Suite("Script files (bridge)")
struct ScriptFilesTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "ClickRelayScripts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func call(_ name: String, _ arguments: [String: Any]) -> (Data, [String: Any]) {
        let message: [String: Any] = ["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                                      "params": ["name": name, "arguments": arguments]]
        return (try! JSONSerialization.data(withJSONObject: message), message)
    }

    func arguments(_ data: Data) -> [String: Any]? {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["params"] as? [String: Any])?["arguments"] as? [String: Any]
    }

    @Test func runReadsTheFileIntoTheCall() throws {
        let scripts = directory.appending(path: "scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try Data(#"{"name":"a","app":"x.y","steps":[{"key":"return"}]}"#.utf8).write(to: scripts.appending(path: "a.json"))
        let (line, message) = call("clickrelay_run_script", ["path": "scripts/a.json", "params": ["k": "v"]])
        guard case .relay(let relayed, let saveTo) = ScriptFiles.prepare(line, message: message,
                                                                          workingDirectory: directory.path(percentEncoded: false)) else {
            Issue.record("expected relay"); return
        }
        #expect(saveTo == nil)
        let args = try #require(arguments(relayed))
        #expect((args["script"] as? [String: Any])?["name"] as? String == "a")
        #expect(args["path"] as? String == "scripts/a.json")
        #expect((args["params"] as? [String: Any])?["k"] as? String == "v")
    }

    @Test func runFailsClearlyForAMissingOrBadFile() throws {
        let dir = directory.path(percentEncoded: false)
        let (line, message) = call("clickrelay_run_script", ["path": "nope.json"])
        guard case .fail(let missing) = ScriptFiles.prepare(line, message: message, workingDirectory: dir) else {
            Issue.record("expected fail"); return
        }
        #expect(missing.contains("There's no script at nope.json"))

        try Data("{not json".utf8).write(to: directory.appending(path: "bad.json"))
        let (badLine, badMessage) = call("clickrelay_run_script", ["path": "bad.json"])
        guard case .fail(let bad) = ScriptFiles.prepare(badLine, message: badMessage, workingDirectory: dir) else {
            Issue.record("expected fail"); return
        }
        #expect(bad.contains("isn't valid JSON"))
    }

    @Test func inlineScriptsAndOtherToolsPassThrough() {
        let (line, message) = call("clickrelay_run_script", ["script": ["steps": [["key": "a"]]]])
        #expect(ScriptFiles.prepare(line, message: message, workingDirectory: nil) == .relay(line, saveTo: nil))
        let (other, otherMessage) = call("clickrelay_press", ["ref": "e1"])
        #expect(ScriptFiles.prepare(other, message: otherMessage, workingDirectory: nil) == .relay(other, saveTo: nil))
    }

    @Test func relativePathsNeedAWorkingDirectory() {
        let (line, message) = call("clickrelay_run_script", ["path": "a.json"])
        guard case .fail(let text) = ScriptFiles.prepare(line, message: message, workingDirectory: nil) else {
            Issue.record("expected fail"); return
        }
        #expect(text.contains("absolute path"))
    }

    @Test func saveRefusesToOverwriteUnlessAsked() throws {
        let dir = directory.path(percentEncoded: false)
        try Data("{}".utf8).write(to: directory.appending(path: "old.json"))
        let (line, message) = call("clickrelay_save_script", ["path": "old.json", "name": "x"])
        guard case .fail(let text) = ScriptFiles.prepare(line, message: message, workingDirectory: dir) else {
            Issue.record("expected fail"); return
        }
        #expect(text.contains("already exists"))
        let (again, againMessage) = call("clickrelay_save_script", ["path": "old.json", "name": "x", "overwrite": true])
        guard case .relay(_, let saveTo) = ScriptFiles.prepare(again, message: againMessage, workingDirectory: dir) else {
            Issue.record("expected relay"); return
        }
        #expect(saveTo?.lastPathComponent == "old.json")
        let (notJSON, notJSONMessage) = call("clickrelay_save_script", ["path": "x.txt", "name": "x"])
        guard case .fail = ScriptFiles.prepare(notJSON, message: notJSONMessage, workingDirectory: dir) else {
            Issue.record("expected fail"); return
        }
    }

    @Test func finishSaveWritesTheScriptAndShortensTheResult() throws {
        let url = directory.appending(path: "nested/new.json")
        let response: [String: Any] = ["jsonrpc": "2.0", "id": 7, "result": [
            "content": [["type": "text", "text": "Recorded 2 steps as \"x\"."],
                        ["type": "text", "text": "{\"name\": \"x\"}\n"]]
        ]]
        let line = try JSONSerialization.data(withJSONObject: response)
        let answered = ScriptFiles.finishSave(line, to: url, workingDirectory: directory.path(percentEncoded: false))
        #expect(try String(contentsOf: url, encoding: .utf8) == "{\"name\": \"x\"}\n")
        let json = try #require(try JSONSerialization.jsonObject(with: answered) as? [String: Any])
        let content = try #require((json["result"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(content.count == 1)
        let text = try #require(content[0]["text"] as? String)
        #expect(text.contains("Recorded 2 steps"))
        #expect(text.contains("Saved to nested/new.json"))
    }

    @Test func finishSaveLeavesErrorsAlone() throws {
        let response: [String: Any] = ["jsonrpc": "2.0", "id": 7, "result": [
            "content": [["type": "text", "text": "ClickRelay is locked."]], "isError": true
        ]]
        let line = try JSONSerialization.data(withJSONObject: response)
        let url = directory.appending(path: "never.json")
        #expect(ScriptFiles.finishSave(line, to: url, workingDirectory: nil) == line)
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }
}

@MainActor
@Suite("Script tools in the router")
struct ScriptRouterTests {
    let clock = FakeClock()
    let leases: LeaseController
    let router: ToolRouter
    let session = Fixtures.session()

    init() {
        leases = LeaseController(clock: clock, authenticator: FakeAuthenticator())
        let preferences = Preferences(defaults: Fixtures.defaults())
        preferences.unlockWaitSeconds = 0
        router = ToolRouter(leases: leases, preferences: preferences, catalog: FakeCatalog(windows: []),
                            resolver: Fixtures.resolver)
        router.chooser = NoModelChooser()
        leases.grant(sessions: [session], picked: ["com.apple.iphonesimulator"], allowFilePanels: false,
                     denyAgentHosts: true, duration: .seconds(300), method: .touchID)
    }

    func call(_ tool: ToolName, _ args: [String: Any]) async -> ToolOutcome {
        await router.handle(name: tool.rawValue, arguments: ToolArguments(args), session: session)
    }

    @Test func aScriptForADisallowedAppIsRefusedBeforeAnythingRuns() async {
        var steps = 0
        router.onScriptStep = { _ in steps += 1 }
        let outcome = await call(.runScript, ["script": [
            "app": "com.apple.iphonesimulator",
            "steps": [["press": "Home"], ["press": "Save", "app": "com.apple.Notes"]]
        ]])
        #expect(outcome.outcome == .refused)
        #expect(outcome.result.firstText?.contains("Notes") == true)
        #expect(steps == 0)
    }

    @Test func aDeniedAppCantBeNamedEither() async {
        let outcome = await call(.runScript, ["script": [
            "app": "com.apple.systempreferences", "steps": [["press": "Privacy & Security"]]
        ]])
        #expect(outcome.outcome == .refused)
    }

    @Test func anInvalidScriptIsAnArgumentsError() async {
        let outcome = await call(.runScript, ["script": ["app": "com.apple.iphonesimulator", "steps": [["fly": true]]]])
        #expect(outcome.result.isError)
        #expect(outcome.check == "arguments")
        #expect(outcome.result.firstText?.contains("Step 1 has no action") == true)
        let none = await call(.runScript, [:])
        #expect(none.check == "arguments")
    }

    @Test func aWaitOnlyScriptRunsAndLogsEachStep() async {
        var logged: [ScriptStepLog] = []
        router.onScriptStep = { logged.append($0) }
        let outcome = await call(.runScript, ["path": "scripts/w.json", "script": [
            "name": "pause", "steps": [["wait": 0], ["wait": 0]]
        ]])
        #expect(!outcome.result.isError)
        #expect(outcome.result.firstText?.contains("Ran \"pause\": all 2 steps") == true)
        #expect(logged.map(\.step) == [1, 2])
        #expect(logged.allSatisfy { $0.script == "scripts/w.json" && $0.outcome == .ok })
    }

    @Test func aScriptStopsWhenTheLeaseEnds() async {
        leases.lock(sessionID: session.id, reason: .lockNow)
        let outcome = await call(.runScript, ["script": ["steps": [["wait": 0]]]])
        #expect(outcome.check == "lease")
    }

    @Test func aMissingElementStopsTheRunAndSaysWhere() async {
        var logged: [ScriptStepLog] = []
        router.onScriptStep = { logged.append($0) }
        // Simulator isn't running in the test host, so the element can't be found.
        let outcome = await call(.runScript, ["script": [
            "name": "tap", "app": "com.apple.iphonesimulator",
            "steps": [["wait": 0], ["press": "Home", "timeout_s": 0], ["wait": 0]]
        ]])
        #expect(outcome.result.isError)
        let text = outcome.result.firstText ?? ""
        #expect(text.contains("stopped at step 2 of 3"))
        #expect(text.contains("Step 1 ran."))
        #expect(logged.count == 2)
        #expect(logged.last?.outcome == .error)
    }

    @Test func anOptionalMissingElementIsSkipped() async {
        let outcome = await call(.runScript, ["script": [
            "name": "maybe", "app": "com.apple.iphonesimulator",
            "steps": [["press": "Dismiss", "timeout_s": 0, "optional": true], ["wait": 0]]
        ]])
        #expect(!outcome.result.isError)
        #expect(outcome.result.firstText?.contains("Step 1 was optional and skipped") == true)
    }

    @Test func saveScriptNeedsRecordedCalls() async {
        let outcome = await call(.saveScript, ["name": "x", "path": "x.json"])
        #expect(outcome.check == "arguments")
        #expect(outcome.result.firstText?.contains("nothing to save") == true)
    }

    @Test func saveScriptReturnsTheFileAndClearsTheRecording() async throws {
        router.recorder.record(ScriptStep(action: .launchApp, app: "com.apple.iphonesimulator"), session: session.id)
        router.recorder.record(ScriptStep(action: .type("hello"), app: "com.apple.iphonesimulator"), session: session.id)
        let outcome = await call(.saveScript, ["name": "greet", "path": "greet.json", "params": ["word": "hello"]])
        #expect(!outcome.result.isError)
        let texts = outcome.result.content.compactMap { item -> String? in
            if case .text(let text) = item { return text }
            return nil
        }
        #expect(texts.count == 2)
        #expect(texts[0].contains("Recorded 2 steps as \"greet\""))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(texts[1].utf8)) as? [String: Any])
        let script = try Script.parse(object, params: ["word": "bye"]).get()
        #expect(script.app == "com.apple.iphonesimulator")
        #expect(script.steps[1].action == .type("bye"))
        #expect(router.recorder.steps(for: session.id).isEmpty)
    }

    @Test func coordinateCallsAreCountedNotRecorded() async {
        _ = await call(.click, ["window_id": 99, "x": 1, "y": 1])
        // A refused click isn't recorded at all; only successful calls are.
        #expect(router.recorder.skippedCount(for: session.id) == 0)
    }
}

@Suite("Script audit")
struct ScriptAuditTests {
    @Test func runScriptLogsTheScriptsShapeAndHidesParamValues() {
        let logged = AuditLog.loggedArguments(tool: "clickrelay_run_script", arguments: [
            "path": "a.json", "params": ["password": "hunter2"],
            "script": ["name": "login", "steps": [["type": "{{password}}"], ["key": "return"]]]
        ], keepText: false)
        #expect(logged["script"] == .object(["name": .string("login"), "steps": .number(2)]))
        #expect(logged["params"] == .object(["password": .string("<redacted, 7 characters>")]))
        #expect(logged["path"] == .string("a.json"))
        let kept = AuditLog.loggedArguments(tool: "clickrelay_run_script", arguments: ["params": ["p": "v"]], keepText: true)
        #expect(kept["params"] == .object(["p": .string("v")]))
    }
}
