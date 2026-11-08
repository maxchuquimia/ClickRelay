import Foundation
import Testing
@testable import ClickRelay

@Suite("Audit log")
struct AuditLogTests {
    func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "ClickRelayTests-\(UUID().uuidString)",
                                                         directoryHint: .isDirectory)
    }

    @Test func typedTextIsRedactedByDefault() {
        let logged = AuditLog.loggedArguments(tool: "clickrelay_type", arguments: ["text": "hunter2", "delay_ms": 5],
                                              keepText: false)
        #expect(logged["text"] == .string("<redacted, 7 characters>"))
        #expect(logged["delay_ms"] == .number(5))
        let kept = AuditLog.loggedArguments(tool: "clickrelay_type", arguments: ["text": "hunter2"], keepText: true)
        #expect(kept["text"] == .string("hunter2"))
        let value = AuditLog.loggedArguments(tool: "clickrelay_set_value", arguments: ["value": "secret"], keepText: false)
        #expect(value["value"] == .string("<redacted, 6 characters>"))
        let click = AuditLog.loggedArguments(tool: "clickrelay_click", arguments: ["x": 1], keepText: false)
        #expect(click["x"] == .number(1))
    }

    @Test func jsonValueKeepsBooleans() {
        #expect(JSONValue(true) == .bool(true))
        #expect(JSONValue(NSNumber(value: 1)) == .number(1))
        #expect(JSONValue(["a": [1, "b"]]) == .object(["a": .array([.number(1), .string("b")])]))
    }

    @Test func writesOneFilePerDayWithMode0600() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = AuditLog(directory: directory)
        let now = Date()
        await log.append(AuditEntry(timestamp: now, event: .call, sessionID: "s", tool: "clickrelay_status", outcome: .ok))
        await log.append(AuditEntry(timestamp: now, event: .locked, reason: LockReason.expired.rawValue),
                         thumbnail: Data([0xFF, 0xD8]))
        await log.flush()
        let url = await log.fileURL(for: now)
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let first = try decoder.decode(AuditEntry.self, from: Data(lines[0].utf8))
        #expect(first.tool == "clickrelay_status")
        let second = try decoder.decode(AuditEntry.self, from: Data(lines[1].utf8))
        #expect(second.reason == "expired")
        #expect(second.thumbnail?.hasSuffix(".jpg") == true)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func purgeRemovesOldDays() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = AuditLog(directory: directory)
        let now = Date()
        let old = Calendar(identifier: .gregorian).date(byAdding: .day, value: -10, to: now)!
        await log.append(AuditEntry(timestamp: old, event: .call), thumbnail: Data([1]))
        await log.append(AuditEntry(timestamp: now, event: .call))
        let removed = await log.purge(olderThanDays: 7, now: now)
        #expect(removed.count == 2)   // the day's file and its thumbnails
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(remaining == [AuditLog.dayName(for: now) + ".jsonl"])
    }

    @Test func dayNamesRoundTrip() {
        let date = AuditLog.date(fromDayName: "2026-11-04")
        #expect(date.map(AuditLog.dayName(for:)) == "2026-11-04")
        #expect(AuditLog.date(fromDayName: "notes") == nil)
    }
}

@Suite("Input queue")
struct InputQueueTests {
    /// Two sequences never interleave: the second starts after the first ends.
    @Test func runsOneSequenceAtATime() async {
        let queue = InputQueue()
        let log = await MainActor.run { EventLog() }
        await withTaskGroup(of: Void.self) { group in
            for name in ["a", "b", "c"] {
                group.addTask {
                    await queue.run { @MainActor in
                        log.events.append("\(name) start")
                        try? await Task.sleep(for: .milliseconds(20))
                        log.events.append("\(name) end")
                    }
                }
            }
        }
        let events = await MainActor.run { log.events }
        #expect(events.count == 6)
        for index in stride(from: 0, to: events.count, by: 2) {
            let name = events[index].prefix(1)
            #expect(events[index] == "\(name) start")
            #expect(events[index + 1] == "\(name) end")
        }
    }

    @MainActor
    final class EventLog {
        var events: [String] = []
    }
}
