import Foundation

/// A JSON value, so tool arguments can be logged as they arrived.
nonisolated enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(_ any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let string as String: self = .string(string)
        case let number as NSNumber:
            // NSNumber hides Bool; CFBoolean is the tell.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) }
            else { self = .number(number.doubleValue) }
        case let array as [Any]: self = .array(array.map { JSONValue($0) })
        case let object as [String: Any]: self = .object(object.mapValues { JSONValue($0) })
        default: self = .string(String(describing: any!))
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let bool = try? container.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? container.decode(Double.self) { self = .number(number) }
        else if let string = try? container.decode(String.self) { self = .string(string) }
        else if let array = try? container.decode([JSONValue].self) { self = .array(array) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// One line of the audit log: a tool call or a lease event.
nonisolated struct AuditEntry: Codable, Sendable, Equatable {
    enum Event: String, Codable, Sendable {
        case call, unlocked, extended, locked
    }

    enum Outcome: String, Codable, Sendable {
        case ok, refused, error
    }

    var timestamp: Date
    var event: Event
    var leaseID: String?
    var sessionID: String?
    var client: String?
    var workingDirectory: String?
    // Calls
    var tool: String?
    var arguments: [String: JSONValue]?
    var targetBundleID: String?
    var windowID: UInt32?
    var outcome: Outcome?
    /// The check that refused it (`InputRefusal.Check`), for refusals.
    var check: String?
    var message: String?
    var durationMs: Int?
    /// Thumbnail file name, beside the log.
    var thumbnail: String?
    /// For a step run by a script: the script (its path, or name) and step number.
    var script: String?
    var step: Int?
    /// How a script step found its element: identifier, exact, partial or model.
    var matchedBy: String?
    // Lease events
    var apps: [String]?
    var leaseSeconds: Int?
    var method: String?
    var reason: String?
}

/// One JSON Lines file per day in `~/Library/Application Support/ClickRelay/Logs/`,
/// mode 0600, with screenshot thumbnails in a folder beside each day's file.
actor AuditLog {
    let directory: URL
    private let encoder: JSONEncoder
    private var handles: [String: FileHandle] = [:]

    static var defaultDirectory: URL {
        MCPLocal.supportDirectory.appending(path: "Logs", directoryHint: .isDirectory)
    }

    init(directory: URL = AuditLog.defaultDirectory) {
        self.directory = directory
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    nonisolated static func dayName(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    nonisolated static func date(fromDayName name: String) -> Date? {
        let parts = name.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    func fileURL(for date: Date) -> URL {
        directory.appending(path: Self.dayName(for: date) + ".jsonl")
    }

    /// Appends one entry, saving `thumbnail` (a JPEG) beside the log first.
    func append(_ entry: AuditEntry, thumbnail: Data? = nil) {
        var entry = entry
        do {
            try ensureDirectory(directory)
            let day = Self.dayName(for: entry.timestamp)
            if let thumbnail {
                let folder = directory.appending(path: day + "-thumbnails", directoryHint: .isDirectory)
                try ensureDirectory(folder)
                let name = UUID().uuidString + ".jpg"
                let url = folder.appending(path: name)
                FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: thumbnail,
                                               attributes: [.posixPermissions: 0o600])
                entry.thumbnail = day + "-thumbnails/" + name
            }
            var line = try encoder.encode(entry)
            line.append(0x0A)
            try handle(for: day).write(contentsOf: line)
        } catch {
            // The log never blocks a call.
        }
    }

    private func handle(for day: String) throws -> FileHandle {
        if let handle = handles[day] { return handle }
        let url = directory.appending(path: day + ".jsonl")
        let path = url.path(percentEncoded: false)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        chmod(path, 0o600)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        // Only one day's file stays open.
        for (_, old) in handles { try? old.close() }
        handles = [day: handle]
        return handle
    }

    private func ensureDirectory(_ url: URL) throws {
        let path = url.path(percentEncoded: false)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(path, 0o700)
    }

    /// Deletes days older than `days`, with their thumbnails. Run at launch.
    @discardableResult
    func purge(olderThanDays days: Int, now: Date = Date()) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        else { return [] }
        let calendar = Calendar(identifier: .gregorian)
        guard let cutoff = calendar.date(byAdding: .day, value: -max(0, days), to: calendar.startOfDay(for: now))
        else { return [] }
        var removed: [String] = []
        for name in names {
            let day = name.hasSuffix(".jsonl") ? String(name.dropLast(6))
                : name.hasSuffix("-thumbnails") ? String(name.dropLast(11)) : nil
            guard let day, let date = Self.date(fromDayName: day), date < cutoff else { continue }
            handles[day].map { try? $0.close() }
            handles[day] = nil
            try? FileManager.default.removeItem(at: directory.appending(path: name))
            removed.append(name)
        }
        return removed
    }

    func flush() {
        for (_, handle) in handles { try? handle.synchronize() }
    }

    // MARK: - Redaction

    /// Arguments as logged. Text an agent types (and values it sets) is
    /// stored as its length unless the user chose to keep it.
    nonisolated static func loggedArguments(tool: String, arguments: [String: Any],
                                            keepText: Bool) -> [String: JSONValue] {
        var logged = arguments.mapValues { JSONValue($0) }
        if tool == ToolName.runScript.rawValue, let script = arguments["script"] as? [String: Any] {
            // Each step is logged on its own; the whole script needn't be.
            logged["script"] = .object([
                "name": JSONValue(script["name"]),
                "steps": .number(Double((script["steps"] as? [Any])?.count ?? 0))
            ])
        }
        guard !keepText else { return logged }
        let redactedKeys: [String]
        switch tool {
        case ToolName.type.rawValue: redactedKeys = ["text"]
        case ToolName.setValue.rawValue: redactedKeys = ["value"]
        case ToolName.runScript.rawValue, ToolName.saveScript.rawValue:
            // Param values are what gets typed or set.
            if let params = arguments["params"] as? [String: Any] {
                logged["params"] = .object(params.mapValues { value -> JSONValue in
                    JSONValue.string("<redacted, \((value as? String)?.count ?? String(describing: value).count) characters>")
                })
            }
            redactedKeys = []
        default: redactedKeys = []
        }
        for key in redactedKeys {
            if let value = arguments[key] {
                let length = (value as? String)?.count ?? String(describing: value).count
                logged[key] = .string("<redacted, \(length) characters>")
            }
        }
        return logged
    }
}
