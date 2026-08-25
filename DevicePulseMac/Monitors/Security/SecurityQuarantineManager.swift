//
//  SecurityQuarantineManager.swift
//  DevicePulseMac
//
//  Two distinct notions of "quarantine" live here:
//
//  1. Reading macOS's own `com.apple.quarantine` extended attribute via
//     the public `URLResourceValues.quarantineProperties` API — this is
//     what tells you a file was recently downloaded/received and hasn't
//     been opened/cleared by the user yet.
//
//  2. Device Pulse's OWN quarantine store — a managed folder under
//     Application Support that suspicious files get MOVED into (never
//     deleted), with enough metadata recorded to restore them exactly.
//     This is analogous to MacTrashUndo but persists across app
//     launches, since a quarantined item may sit reviewed for a while.
//

import Foundation

struct DevicePulseQuarantineRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let originalPath: String
    let quarantinedPath: String
    let quarantinedAt: Date
    let findingName: String
    let reason: String
}

enum SecurityQuarantineManager {
    static let quarantineDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = base.appendingPathComponent("Device Pulse/Security Quarantine", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let recordsFileURL = quarantineDirectory.appendingPathComponent("records.json")

    /// System paths this app must never move, even if a scan somehow
    /// flags something inside them.
    private static let protectedPrefixes = [
        "/System/", "/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/usr/lib/", "/usr/libexec/", "/Library/Apple/",
    ]

    static func inspectQuarantineAttribute(path: String) -> SecurityQuarantineStatus {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.quarantinePropertiesKey]) else {
            return .unknown
        }
        guard let props = values.quarantineProperties, !props.isEmpty else {
            return .notQuarantined
        }
        return .quarantinedByMacOS
    }

    static func canQuarantine(path: String) -> Bool {
        if protectedPrefixes.contains(where: { path.hasPrefix($0) }) { return false }
        let ownBundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        if URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(ownBundlePath) { return false }
        return true
    }

    static func loadRecords() -> [DevicePulseQuarantineRecord] {
        guard let data = try? Data(contentsOf: recordsFileURL),
              let records = try? JSONDecoder().decode([DevicePulseQuarantineRecord].self, from: data)
        else { return [] }
        return records
    }

    private static func saveRecords(_ records: [DevicePulseQuarantineRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: recordsFileURL, options: .atomic)
    }

    /// Moves the file at `path` into Device Pulse's quarantine folder.
    /// Never a delete — always reversible via `restore`.
    @discardableResult
    static func quarantine(path: String, findingName: String, reason: String) -> DevicePulseQuarantineRecord? {
        guard canQuarantine(path: path) else { return nil }
        let sourceURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let destName = "\(UUID().uuidString)-\(sourceURL.lastPathComponent)"
        let destURL = quarantineDirectory.appendingPathComponent(destName)
        guard (try? FileManager.default.moveItem(at: sourceURL, to: destURL)) != nil else { return nil }

        let record = DevicePulseQuarantineRecord(
            id: UUID(), originalPath: path, quarantinedPath: destURL.path,
            quarantinedAt: Date(), findingName: findingName, reason: reason
        )
        var records = loadRecords()
        records.append(record)
        saveRecords(records)
        return record
    }

    /// Moves a quarantined item back to its original location. Fails
    /// (returns false, leaves the record alone) if something already
    /// occupies that path, so nothing is silently overwritten.
    @discardableResult
    static func restore(_ record: DevicePulseQuarantineRecord) -> Bool {
        let destination = URL(fileURLWithPath: record.originalPath)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return false }
        let source = URL(fileURLWithPath: record.quarantinedPath)
        guard (try? FileManager.default.moveItem(at: source, to: destination)) != nil else { return false }
        var records = loadRecords()
        records.removeAll { $0.id == record.id }
        saveRecords(records)
        return true
    }

    /// Permanent delete of an already-quarantined item. Callers must
    /// confirm with the user before calling this.
    @discardableResult
    static func deletePermanently(_ record: DevicePulseQuarantineRecord) -> Bool {
        let source = URL(fileURLWithPath: record.quarantinedPath)
        let removed = (try? FileManager.default.removeItem(at: source)) != nil
        var records = loadRecords()
        records.removeAll { $0.id == record.id }
        saveRecords(records)
        return removed
    }
}
