//
//  MacStorageScanner.swift
//  DevicePulseMac
//
//  Detection/review foundation for Maintenance. Scans well-known,
//  user-accessible locations for reclaimable data. Never deletes
//  anything itself — callers get sizes to review and choose from.
//  Locations outside sandbox/permission reach are reported as
//  "Access Required", never as a fabricated 0 bytes.
//

import Foundation

struct MaintenanceCategory: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    var sizeBytes: Int64?
    var accessDenied: Bool = false
    let risk: String
    let explanation: String
}

enum MacStorageScanner {
    static func categories() -> [MaintenanceCategory] {
        let home = NSHomeDirectory()
        return [
            MaintenanceCategory(name: "User Caches", path: "\(home)/Library/Caches", sizeBytes: nil, risk: "Low", explanation: "Regenerated automatically by apps as needed."),
            MaintenanceCategory(name: "Logs", path: "\(home)/Library/Logs", sizeBytes: nil, risk: "Low", explanation: "Diagnostic logs; safe to remove, may be useful for troubleshooting."),
            MaintenanceCategory(name: "Downloads", path: "\(home)/Downloads", sizeBytes: nil, risk: "Review Needed", explanation: "May contain files you still want — review before deleting anything."),
            MaintenanceCategory(name: "Trash", path: "\(home)/.Trash", sizeBytes: nil, risk: "Low", explanation: "Already marked for deletion by you."),
            MaintenanceCategory(name: "Application Support", path: "\(home)/Library/Application Support", sizeBytes: nil, risk: "Review Needed", explanation: "Contains real app data (settings, saved state) — not just cache. Review per-app."),
            MaintenanceCategory(name: "Xcode DerivedData", path: "\(home)/Library/Developer/Xcode/DerivedData", sizeBytes: nil, risk: "Low", explanation: "Build intermediates Xcode regenerates automatically."),
            MaintenanceCategory(name: "Xcode Archives", path: "\(home)/Library/Developer/Xcode/Archives", sizeBytes: nil, risk: "Review Needed", explanation: "Your app release archives — needed if you ever re-submit an old build."),
            MaintenanceCategory(name: "iOS Simulator Data", path: "\(home)/Library/Developer/CoreSimulator/Devices", sizeBytes: nil, risk: "Review Needed", explanation: "Simulator device data, including any simulator-installed app data."),
            MaintenanceCategory(name: "iOS Device Support", path: "\(home)/Library/Developer/Xcode/iOS DeviceSupport", sizeBytes: nil, risk: "Low", explanation: "Per-iOS-version debug symbols Xcode redownloads when needed."),
        ]
    }

    /// Computes directory size asynchronously. Returns nil size with
    /// accessDenied=true if the directory can't be read (permissions),
    /// distinct from a genuinely empty/missing directory (size 0).
    static func size(of category: MaintenanceCategory) -> MaintenanceCategory {
        var updated = category
        let url = URL(fileURLWithPath: category.path)

        guard FileManager.default.fileExists(atPath: category.path) else {
            updated.sizeBytes = 0
            return updated
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [], errorHandler: nil
        ) else {
            updated.accessDenied = true
            return updated
        }

        var total: Int64 = 0
        var touchedAny = false
        for case let fileURL as URL in enumerator {
            touchedAny = true
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == false, let size = values?.fileSize {
                total += Int64(size)
            }
        }

        if !touchedAny {
            // Could be empty, or could be permission-restricted with no
            // children enumerable. Try a direct listing to disambiguate.
            if (try? FileManager.default.contentsOfDirectory(atPath: category.path)) == nil {
                updated.accessDenied = true
                return updated
            }
        }

        updated.sizeBytes = total
        return updated
    }

    /// Moves every immediate child of a category's folder to the Trash
    /// (Finder's own move-to-trash, via `FileManager.trashItem`) — never
    /// a permanent delete, and always reversible from the Trash (records
    /// are returned so callers can offer Undo). The containing folder
    /// itself is left in place.
    ///
    /// Includes hidden children (no `.skipsHiddenFiles`), matching
    /// `size(of:)`'s enumerator above — otherwise a reported size could
    /// include hidden content that cleanup then silently leaves behind.
    /// `movedBytes` is measured from the children actually trashed here,
    /// not the (possibly stale) scan-time `sizeBytes`, so callers can
    /// report an honest post-clean total.
    static func trashContents(of category: MaintenanceCategory) -> (records: [TrashRecord], failed: Int, movedBytes: Int64) {
        let url = URL(fileURLWithPath: category.path)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: []
        ) else { return ([], 0, 0) }

        var records: [TrashRecord] = []
        var failed = 0
        var movedBytes: Int64 = 0
        for child in children {
            let size = sizeOfItem(at: child)
            if let record = MacTrashUndo.trash(child) {
                records.append(record)
                movedBytes += size
            } else {
                failed += 1
            }
        }
        return (records, failed, movedBytes)
    }

    /// Recursively sums file sizes under `url` (or the size of `url`
    /// itself if it's a file), used to measure what a trash operation
    /// actually moved.
    private static func sizeOfItem(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory != true {
            return Int64(values?.fileSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [], errorHandler: nil
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let childValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if childValues?.isDirectory == false, let size = childValues?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Permanently removes everything already sitting in ~/.Trash. This
    /// IS a permanent, irreversible delete — callers must confirm with
    /// the user explicitly before calling this, distinct from
    /// `trashContents`, which only ever moves files to the Trash.
    static func emptyTrash() -> (moved: Int, failed: Int) {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".Trash")
        let url = URL(fileURLWithPath: path)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return (0, 0) }

        var removed = 0
        var failed = 0
        for child in children {
            if (try? FileManager.default.removeItem(at: child)) != nil {
                removed += 1
            } else {
                failed += 1
            }
        }
        return (removed, failed)
    }
}
