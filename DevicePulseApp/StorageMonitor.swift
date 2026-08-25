//
//  StorageMonitor.swift
//  DevicePulse
//
//  Device-wide storage capacity via the PUBLIC URLResourceValues API.
//  This is a real, accurate total/free storage reading for the whole
//  device volume (matches what Settings > General > iPhone Storage
//  shows, roughly).
//

import Foundation

struct StorageStats {
    let total: Int64
    let free: Int64
    var used: Int64 { max(total - free, 0) }
    var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

enum StorageReader {
    static func read() -> StorageStats? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        do {
            let values = try url.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ])
            guard let total = values.volumeTotalCapacity else { return nil }
            let free = values.volumeAvailableCapacityForImportantUsage ?? 0
            return StorageStats(total: Int64(total), free: free)
        } catch {
            return nil
        }
    }
}
