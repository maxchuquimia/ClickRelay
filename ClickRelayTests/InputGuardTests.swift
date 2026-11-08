import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Testing
@testable import ClickRelay

/// Simulator allowed, Notes not, as in the manual acceptance tests.
@Suite("Input guard")
struct InputGuardTests {
    let simulatorFrame = CGRect(x: 100, y: 100, width: 400, height: 800)
    let policy = AccessPolicy(allowedBundleIDs: ["com.apple.iphonesimulator"])

    var inputGuard: InputGuard {
        InputGuard(policy: policy, resolver: Fixtures.resolver, ignoredWindowIDs: [999])
    }

    func snapshot(_ windows: [WindowInfo]) -> WindowSnapshot { WindowSnapshot(windows: windows) }

    var simulator: WindowInfo { Fixtures.window(1, pid: Fixtures.simulatorPID, frame: simulatorFrame) }

    func check(_ point: CGPoint, window: CGWindowID = 1, windows: [WindowInfo],
               elementPID: pid_t? = Fixtures.simulatorPID) -> Result<WindowInfo, InputRefusal> {
        inputGuard.checkPoint(windowID: window, point: point, snapshot: snapshot(windows), elementPID: { _ in elementPID })
    }

    func refusal(_ result: Result<WindowInfo, InputRefusal>) -> InputRefusal? {
        if case .failure(let refusal) = result { return refusal }
        return nil
    }

    @Test func allowsAClickOnAnUncoveredAllowedWindow() throws {
        let result = check(CGPoint(x: 200, y: 300), windows: [simulator])
        #expect(try result.get().id == 1)
    }

    @Test func refusesAWindowThatIsGone() {
        let refused = refusal(check(CGPoint(x: 200, y: 300), window: 7, windows: [simulator]))
        #expect(refused?.check == .window)
        #expect(refused?.message.contains("isn't on screen") == true)
    }

    @Test func refusesAWindowOfADeniedApp() {
        let notes = Fixtures.window(2, pid: Fixtures.notesPID, frame: simulatorFrame)
        let refused = refusal(check(CGPoint(x: 200, y: 300), window: 2, windows: [notes]))
        #expect(refused?.check == .window)
        #expect(refused?.message.contains("Notes") == true)
    }

    @Test func refusesAPointOutsideTheWindow() {
        let refused = refusal(check(CGPoint(x: 600, y: 300), windows: [simulator]))
        #expect(refused?.check == .frame)
        #expect(refused?.message.contains("(500, 200)") == true)   // window-relative
    }

    @Test func refusesAPointCoveredByADeniedApp() {
        let notes = Fixtures.window(2, pid: Fixtures.notesPID, frame: CGRect(x: 150, y: 150, width: 300, height: 300))
        let refused = refusal(check(CGPoint(x: 200, y: 200), windows: [notes, simulator]))
        #expect(refused?.check == .topmost)
        #expect(refused?.message == "The point (100, 100) is covered by a window from Notes, which isn't allowed. Bring window 1 to the front with clickrelay_focus_window and click again.")
    }

    @Test func coveredOnlyWhereTheOtherWindowIs() throws {
        let notes = Fixtures.window(2, pid: Fixtures.notesPID, frame: CGRect(x: 150, y: 150, width: 100, height: 100))
        let result = check(CGPoint(x: 400, y: 700), windows: [notes, simulator])
        #expect(try result.get().id == 1)
    }

    @Test func aMenuOfTheSameAppIsFine() throws {
        let menu = Fixtures.window(3, pid: Fixtures.simulatorPID, frame: CGRect(x: 150, y: 150, width: 200, height: 300), layer: 101)
        let result = check(CGPoint(x: 200, y: 200), windows: [menu, simulator])
        #expect(try result.get().id == 1)
    }

    @Test func clickRelaysOwnOverlayIsIgnored() throws {
        let overlay = Fixtures.window(999, pid: getpid(), frame: CGRect(x: 0, y: 0, width: 3000, height: 3000), layer: 1000)
        let result = check(CGPoint(x: 200, y: 200), windows: [overlay, simulator])
        #expect(try result.get().id == 1)
    }

    @Test func clickRelaysOtherWindowsBlock() {
        let mainWindow = Fixtures.window(50, pid: getpid(), frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        let refused = refusal(check(CGPoint(x: 200, y: 200), windows: [mainWindow, simulator]))
        #expect(refused?.check == .topmost)
        // Focusing the window wouldn't move ClickRelay's panel, so the
        // refusal points at press by ref instead.
        #expect(refused?.message.contains("ClickRelay's own panels") == true)
        #expect(refused?.message.contains("clickrelay_focus_window") == false)
    }

    @Test func fullyTransparentWindowsDontCount() throws {
        let invisible = Fixtures.window(4, pid: Fixtures.notesPID, frame: CGRect(x: 0, y: 0, width: 3000, height: 3000), alpha: 0)
        let result = check(CGPoint(x: 200, y: 200), windows: [invisible, simulator])
        #expect(try result.get().id == 1)
    }

    @Test func refusesWhenAccessibilityCantSay() {
        let refused = refusal(check(CGPoint(x: 200, y: 300), windows: [simulator], elementPID: nil))
        #expect(refused?.check == .element)
    }

    @Test func refusesAnElementOfADeniedApp() {
        let refused = refusal(check(CGPoint(x: 200, y: 300), windows: [simulator], elementPID: Fixtures.notesPID))
        #expect(refused?.check == .element)
        #expect(refused?.message.contains("Notes") == true)
    }

    @Test func keyboardNeedsAnAllowedFrontmostApp() {
        #expect(inputGuard.checkKeyboard(frontmostPID: Fixtures.simulatorPID) == nil)
        let refused = inputGuard.checkKeyboard(frontmostPID: Fixtures.notesPID)
        #expect(refused?.check == .frontmost)
        #expect(refused?.message.contains("clickrelay_focus_window") == true)
        #expect(inputGuard.checkKeyboard(frontmostPID: nil)?.check == .frontmost)
    }

    @Test func elementsByRefNeedAnAllowedApp() {
        #expect(inputGuard.checkElement(pid: Fixtures.simulatorPID) == nil)
        #expect(inputGuard.checkElement(pid: Fixtures.settingsPID)?.check == .element)
    }

    @Test func topmostSkipsIgnoredAndTransparent() {
        let snapshot = WindowSnapshot(windows: [
            Fixtures.window(9, pid: 1, frame: CGRect(x: 0, y: 0, width: 10, height: 10), alpha: 0),
            Fixtures.window(8, pid: 1, frame: CGRect(x: 0, y: 0, width: 10, height: 10)),
            Fixtures.window(7, pid: 1, frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        ])
        #expect(snapshot.topmost(at: CGPoint(x: 5, y: 5))?.id == 8)
        #expect(snapshot.topmost(at: CGPoint(x: 5, y: 5), ignoring: [8])?.id == 7)
        #expect(snapshot.topmost(at: CGPoint(x: 50, y: 5)) == nil)
    }
}

@Suite("Blocked shortcuts")
struct ShortcutPolicyTests {
    @Test(arguments: [
        ("tab", [Modifier.cmd]), ("tab", [.cmd, .shift]), ("space", [.cmd]), ("space", [.cmd, .option]),
        ("space", [.ctrl, .cmd]), ("left", [.ctrl]), ("right", [.ctrl]), ("up", [.ctrl]), ("down", [.ctrl]),
        ("escape", [.cmd, .option]), ("q", [.cmd, .shift]), ("q", [.ctrl, .cmd]), ("a", [.fn]),
        ("f2", [.ctrl]), ("f3", [.ctrl]), ("f5", [.cmd]), ("esc", [.cmd, .option])
    ] as [(String, [Modifier])])
    func refused(key: String, modifiers: [Modifier]) {
        #expect(ShortcutPolicy.refusal(key: key, modifiers: Set(modifiers)) != nil)
    }

    @Test(arguments: [
        ("c", [Modifier.cmd]), ("v", [.cmd]), ("z", [.cmd, .shift]), ("return", []), ("tab", []),
        ("left", []), ("left", [.cmd]), ("a", []), ("space", []), ("w", [.cmd]), ("f5", [])
    ] as [(String, [Modifier])])
    func allowed(key: String, modifiers: [Modifier]) {
        #expect(ShortcutPolicy.refusal(key: key, modifiers: Set(modifiers)) == nil)
    }

    @Test func quitDependsOnTheApp() {
        #expect(ShortcutPolicy.refusal(key: "q", modifiers: [.cmd], frontmostAllowed: true) == nil)
        #expect(ShortcutPolicy.refusal(key: "q", modifiers: [.cmd], frontmostAllowed: false) != nil)
    }

    @Test func refusalNamesTheShortcut() {
        let message = ShortcutPolicy.refusal(key: "tab", modifiers: [.cmd])
        #expect(message?.hasPrefix("⌘Tab is blocked") == true)
        #expect(ShortcutPolicy.refusal(key: "q", modifiers: [.ctrl, .cmd])?.hasPrefix("⌃⌘Q") == true)
    }

    @Test func aliasesAreNormalised() {
        #expect(ShortcutPolicy.refusal(key: "ArrowLeft", modifiers: [.ctrl]) != nil)
        #expect(ShortcutPolicy.refusal(key: "Space", modifiers: [.cmd]) != nil)
    }
}

@Suite("Keys and modifiers")
struct KeyMapTests {
    @Test func keyNames() {
        #expect(KeyMap.keyCode(for: "a") == 0)
        #expect(KeyMap.keyCode(for: "A") == 0)
        #expect(KeyMap.keyCode(for: "return") == 36)
        #expect(KeyMap.keyCode(for: "Enter") == 36)
        #expect(KeyMap.keyCode(for: "f5") == 96)
        #expect(KeyMap.keyCode(for: "page-down") == 121)
        #expect(KeyMap.keyCode(for: "ArrowUp") == 126)
        #expect(KeyMap.keyCode(for: "/") == 44)
        #expect(KeyMap.keyCode(for: "nope") == nil)
    }

    @Test func modifierSpellings() {
        #expect(Modifier.parse(["command", "Shift", "alt", "control"]) == .success([.cmd, .shift, .option, .ctrl]))
        #expect(Modifier.parse(["hyper"]) == .failure(Modifier.UnknownModifier(name: "hyper")))
        #expect(Modifier.flags([.cmd, .shift]) == [.maskCommand, .maskShift])
    }

    @Test func killShortcutDisplay() {
        #expect(KeyCombo.defaultKill.display == "⌃⌥⌘L")
        #expect(KeyCombo.defaultKill.matches(keyCode: 0x25, flags: [.control, .option, .command, .capsLock]))
        #expect(!KeyCombo.defaultKill.matches(keyCode: 0x25, flags: [.control, .command]))
    }
}

@Suite("Capture errors")
struct CaptureErrorTests {
    /// ScreenCaptureKit's "The user declined TCCs…" becomes plain words and a
    /// next step, not macOS jargon.
    @Test func declinedPromptIsExplained() {
        let declined = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue,
                               userInfo: [NSLocalizedDescriptionKey: "The user declined TCCs for application, window, display capture"])
        let error = CaptureError(declined)
        #expect(error == .declined)
        #expect(!error.message.contains("TCC"))
        #expect(error.message.contains("Take Test Screenshot"))
        #expect(CaptureError(NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])) == .failed("boom"))
    }
}
