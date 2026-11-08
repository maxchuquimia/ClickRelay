import SwiftUI

/// The process entry point. Normally the app; with `--mcp`, the stdio bridge an
/// agent launches (`MCPBridge`). The branch comes first so the bridge never
/// starts AppKit, SwiftUI or any app state.
@main
enum ClickRelayMain {
    static func main() {
        if CommandLine.arguments.dropFirst().contains(MCPLocal.bridgeArgument) {
            MCPBridge.run()
        }
        ClickRelayApp.main()
    }
}
