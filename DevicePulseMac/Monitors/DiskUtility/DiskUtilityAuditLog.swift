//
//  DiskUtilityAuditLog.swift
//  DevicePulseMac
//
//  A persisted history of Disk Utility operations — never file contents,
//  never passphrases, just what was done, to what, and whether it
//  succeeded. Same persisted-JSON-in-UserDefaults pattern already used
//  elsewhere in this app (e.g. SecurityStatusCache).
//

import Foundation

struct DiskUtilityAuditEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let title: String
    let target: String
    let succeeded: Bool
    let note: String?
}

enum DiskUtilityAuditLog {
    private static let key = "diskUtilityAuditLog"
    private static let maxEntries = 200

    static func record(title: String, target: String, succeeded: Bool, note: String? = nil) {
        var entries = all()
        entries.insert(DiskUtilityAuditEntry(id: UUID(), date: Date(), title: title, target: target, succeeded: succeeded, note: note), at: 0)
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
        save(entries)
    }

    static func all() -> [DiskUtilityAuditEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([DiskUtilityAuditEntry].self, from: data)
        else { return [] }
        return entries
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func save(_ entries: [DiskUtilityAuditEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
