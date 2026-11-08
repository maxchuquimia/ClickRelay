import AppKit
import UniformTypeIdentifiers

/// An app the user can allow, for the unlock screen.
struct AppEntry: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let url: URL?
    let isRunning: Bool
    var id: String { bundleID }
}

/// Names, icons and locations of apps by bundle ID.
@MainActor
enum AppCatalog {
    nonisolated static func name(for bundleID: String) -> String {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = running.localizedName { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path(percentEncoded: false))
                .replacingOccurrences(of: ".app", with: "")
        }
        if AccessPolicy.filePanelServices.contains(bundleID) { return "System file panels" }
        return bundleID
    }

    nonisolated static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static func icon(for bundleID: String) -> NSImage {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let icon = running.icon { return icon }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
        }
        return NSWorkspace.shared.icon(for: .application)
    }

    static func entry(for bundleID: String) -> AppEntry {
        AppEntry(bundleID: bundleID, name: name(for: bundleID),
                 url: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
                 isRunning: isRunning(bundleID))
    }

    /// Running apps with a Dock presence (regular activation policy), plus
    /// `extra` (the last selection, apps added by hand, apps an agent asked
    /// for), sorted by name.
    static func pickerEntries(extra: [String]) -> [AppEntry] {
        var seen = Set<String>()
        var entries: [AppEntry] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, !seen.contains(id) else { continue }
            seen.insert(id)
            entries.append(AppEntry(bundleID: id, name: app.localizedName ?? id, url: app.bundleURL, isRunning: true))
        }
        for id in extra where !seen.contains(id) {
            seen.insert(id)
            entries.append(entry(for: id))
        }
        return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A bundle ID for an app an agent named, by bundle ID or by name
    /// ("Safari", "Safari.app"). Running apps first, then the usual folders.
    static func resolve(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return nil }
        if trimmed.contains("."), !trimmed.lowercased().hasSuffix(".app"),
           isRunning(trimmed) || NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) != nil {
            return trimmed
        }
        let name = trimmed.lowercased().hasSuffix(".app") ? String(trimmed.dropLast(4)) : trimmed
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
        }), let id = app.bundleIdentifier {
            return id
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        for folder in ["/Applications", "/System/Applications", "/Applications/Utilities",
                       "/System/Applications/Utilities", home + "/Applications"] {
            let url = URL(filePath: folder).appending(path: name + ".app", directoryHint: .isDirectory)
            if let id = bundleID(ofAppAt: url) { return id }
        }
        return nil
    }

    /// The bundle ID of an `.app` the user picked.
    static func bundleID(ofAppAt url: URL) -> String? {
        Bundle(url: url)?.bundleIdentifier
    }
}
