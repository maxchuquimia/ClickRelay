import Foundation

/// Which processes one lease may see and control. Built once at unlock and
/// fixed for the lease's lifetime.
///
/// macOS doesn't scope Screen Recording or Accessibility per app, so this is
/// the boundary: capture is filtered through it and input is refused unless it
/// lands in a process it allows.
nonisolated struct AccessPolicy: Sendable, Equatable {
    /// Bundle IDs the lease covers, after the denylist and the agent's own
    /// terminal have been taken out.
    let allowedBundleIDs: Set<String>

    /// The processes that draw Open and Save panels for other apps. Allowed
    /// only when the user ticks "system file panels" at unlock.
    static let filePanelServices: Set<String> = [
        "com.apple.appkit.xpc.openAndSavePanelService",
        "com.apple.appkit.xpc.documentPickerUIService"
    ]

    init(allowedBundleIDs: Set<String>) {
        self.allowedBundleIDs = allowedBundleIDs.subtracting(Denylist.all)
    }

    /// What the user picked, minus what can never be allowed.
    ///
    /// - Parameters:
    ///   - picked: bundle IDs ticked in the unlock screen.
    ///   - allowFilePanels: also allow the system Open/Save panel service.
    ///   - agentHosts: the agent's terminal or editor (see
    ///     `Denylist.agentHostApps`), removed when `denyAgentHosts` is on.
    static func build(picked: Set<String>, allowFilePanels: Bool,
                      agentHosts: Set<String>, denyAgentHosts: Bool) -> AccessPolicy {
        var ids = picked
        if allowFilePanels { ids.formUnion(filePanelServices) }
        if denyAgentHosts { ids.subtract(agentHosts) }
        return AccessPolicy(allowedBundleIDs: ids)
    }

    /// The denylist is checked again here, not only at build time, so no path
    /// can produce a policy that lets one through.
    func allows(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return allowedBundleIDs.contains(bundleID) && !Denylist.isDenied(bundleID)
    }

    /// Every running process with an allowed bundle ID counts as allowed.
    func allows(pid: pid_t, resolver: ProcessResolver) -> Bool {
        guard pid > 0, pid != getpid() else { return false }
        return allows(bundleID: resolver.bundleID(for: pid))
    }
}
