//
//  MacStorageCategoryScanner.swift
//  DevicePulseMac
//
//  A category breakdown built from real folder sizes on disk — NOT the
//  same data as About This Mac ▸ Storage, which macOS computes via a
//  private framework third-party apps can't call. This scans the
//  well-known top-level folders directly, the same approach DaisyDisk/
//  CleanMyMac use, so the numbers are real but won't necessarily match
//  Apple's own categorization pixel for pixel. "Other" is whatever's
//  left after subtracting every scanned category from the volume's
//  actual used space — an honest remainder, not a guess.
//

import Foundation

struct StorageCategory: Identifiable {
    let id: String
    let name: String
    let icon: String
    let paths: [String]
    var sizeBytes: Int64?
    var accessDenied: Bool = false
}

struct StorageSubitem: Identifiable {
    let id: String
    let name: String
    let path: String
    let sizeBytes: Int64
    let isDirectory: Bool
}

enum MacStorageCategoryScanner {
    static func categories() -> [StorageCategory] {
        let home = NSHomeDirectory()
        return [
            StorageCategory(id: "applications", name: "Applications", icon: "square.grid.2x2", paths: ["/Applications", "\(home)/Applications"]),
            StorageCategory(id: "photos", name: "Photos", icon: "photo", paths: ["\(home)/Pictures"]),
            StorageCategory(id: "documents", name: "Documents", icon: "doc", paths: ["\(home)/Documents"]),
            StorageCategory(id: "desktop", name: "Desktop", icon: "menubar.dock.rectangle", paths: ["\(home)/Desktop"]),
            StorageCategory(id: "downloads", name: "Downloads", icon: "arrow.down.circle", paths: ["\(home)/Downloads"]),
            StorageCategory(id: "movies", name: "Movies", icon: "film", paths: ["\(home)/Movies"]),
            StorageCategory(id: "music", name: "Music", icon: "music.note", paths: ["\(home)/Music"]),
            StorageCategory(id: "developer", name: "Developer", icon: "hammer", paths: ["\(home)/Developer", "\(home)/Library/Developer"]),
        ]
    }

    static func size(of category: StorageCategory) -> StorageCategory {
        var updated = category
        var total: Int64 = 0
        var anyAccessDenied = false
        var anyExisted = false

        for path in category.paths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            anyExisted = true
            if let size = directorySize(atPath: path) {
                total += size
            } else {
                anyAccessDenied = true
            }
        }

        if !anyExisted {
            updated.sizeBytes = 0
        } else if anyAccessDenied && total == 0 {
            updated.accessDenied = true
        } else {
            updated.sizeBytes = total
        }
        return updated
    }

    /// One level of subfolders/files inside a category, sorted by size
    /// descending — the "drill down" view. Not recursive further than
    /// this; deeper exploration belongs in Big Files Finder.
    static func subitems(of category: StorageCategory, limit: Int = 50) -> [StorageSubitem] {
        var items: [StorageSubitem] = []
        for path in category.paths {
            guard let children = try? FileManager.default.contentsOfDirectory(atPath: path) else { continue }
            for child in children {
                let childPath = (path as NSString).appendingPathComponent(child)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: childPath, isDirectory: &isDir) else { continue }
                let size = isDir.boolValue ? (directorySize(atPath: childPath) ?? 0) : (fileSize(atPath: childPath) ?? 0)
                items.append(StorageSubitem(id: childPath, name: child, path: childPath, sizeBytes: size, isDirectory: isDir.boolValue))
            }
        }
        items.sort { $0.sizeBytes > $1.sizeBytes }
        return Array(items.prefix(limit))
    }

    private static func fileSize(atPath path: String) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil
    }

    private static func directorySize(atPath path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [], errorHandler: nil
        ) else { return nil }

        var total: Int64 = 0
        var touchedAny = false
        for case let fileURL as URL in enumerator {
            touchedAny = true
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == false, let size = values?.fileSize {
                total += Int64(size)
            }
        }

        if !touchedAny, (try? FileManager.default.contentsOfDirectory(atPath: path)) == nil {
            return nil // permission-restricted, distinct from genuinely empty
        }
        return total
    }
}
