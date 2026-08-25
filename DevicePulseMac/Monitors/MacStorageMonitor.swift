//
//  MacStorageMonitor.swift
//  DevicePulseMac
//
//  Volume capacity via the PUBLIC URLResourceValues API — the same
//  numbers Finder's "Get Info" and Disk Utility show for each volume.
//

import Foundation

struct VolumeInfo: Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let total: Int64
    let available: Int64
    var used: Int64 { max(total - available, 0) }
    var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
    let isRemovable: Bool
    let isInternal: Bool
}

enum MacStorageMonitor {
    static func mainVolume() -> VolumeInfo? {
        readVolume(at: URL(fileURLWithPath: "/"))
    }

    static func allVolumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeIsRemovableKey, .volumeIsInternalKey]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else {
            return mainVolume().map { [$0] } ?? []
        }
        return urls.compactMap { readVolume(at: $0) }
    }

    private static func readVolume(at url: URL) -> VolumeInfo? {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsRemovableKey, .volumeIsInternalKey
        ]) else { return nil }

        guard let total = values.volumeTotalCapacity else { return nil }
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        let name = values.volumeName ?? url.path

        return VolumeInfo(
            name: name,
            path: url.path,
            total: Int64(total),
            available: available,
            isRemovable: values.volumeIsRemovable ?? false,
            isInternal: values.volumeIsInternal ?? true
        )
    }
}
