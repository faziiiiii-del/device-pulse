//
//  MacAppUninstaller.swift
//  DevicePulseMac
//
//  Lists apps in /Applications and ~/Applications via public Bundle/
//  FileManager APIs. "Leftover file" detection is a best-effort
//  substring match against well-known Library locations — macOS has no
//  public API to reliably enumerate an app's full on-disk footprint, so
//  this is shown to the user for review, never auto-deleted. Removal
//  always goes through Trash, never a permanent delete.
//

import Foundation

struct InstalledApp: Identifiable, Equatable {
    let id: String
    let name: String
    let bundleIdentifier: String?
    let version: String?
    let path: String
    var sizeBytes: Int64?
    let isProtected: Bool

    static func == (lhs: InstalledApp, rhs: InstalledApp) -> Bool { lhs.id == rhs.id }
}

enum MacAppUninstaller {
    static func scan() -> [InstalledApp] {
        let dirs = ["/Applications", (NSHomeDirectory() as NSString).appendingPathComponent("Applications")]
        var apps: [InstalledApp] = []

        for dir in dirs {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let fullPath = (dir as NSString).appendingPathComponent(item)
                let bundle = Bundle(path: fullPath)
                let name = (bundle?.infoDictionary?["CFBundleName"] as? String)
                    ?? (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (item as NSString).deletingPathExtension
                let version = bundle?.infoDictionary?["CFBundleShortVersionString"] as? String

                let bundleID = bundle?.bundleIdentifier
                apps.append(InstalledApp(
                    id: fullPath,
                    name: name,
                    bundleIdentifier: bundleID,
                    version: version,
                    path: fullPath,
                    sizeBytes: nil,
                    // Everything actually scanned lives in /Applications or
                    // ~/Applications, so a "/System/" path prefix (kept for
                    // defense in depth) never fires in practice — the real
                    // signal is the bundle identifier: Apple ships its own
                    // apps under "com.apple.*", which is the same heuristic
                    // MacStartupMonitor already uses to classify Apple items.
                    isProtected: fullPath.hasPrefix("/System/") || (bundleID?.hasPrefix("com.apple.") ?? false)
                ))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func size(of app: InstalledApp) -> InstalledApp {
        var updated = app
        updated.sizeBytes = directorySize(URL(fileURLWithPath: app.path))
        return updated
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == false, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Tiered by how sure we can be this file actually belongs to the
    /// app. `.exact` means the item's name (or name minus extension)
    /// matches the bundle identifier or the app's display name exactly
    /// — e.g. "com.example.app.plist" or an "Xcode" folder for Xcode.app.
    /// `.possible` means the app name/bundle ID merely appears as a
    /// *substring* of the item's name — e.g. a "MyCodeBackup" folder
    /// would match an app named "Code". Substring matching alone used to
    /// treat both cases identically and offer a single "delete
    /// everything" action; a generically-named app (Mail, Music, Code)
    /// could then match totally unrelated folders. Only `.exact` matches
    /// are pre-selected for deletion — `.possible` matches are shown for
    /// manual review and never auto-selected.
    enum LeftoverConfidence { case exact, possible }

    struct LeftoverMatch: Identifiable {
        var id: String { url.path }
        let url: URL
        let confidence: LeftoverConfidence
    }

    static func leftovers(for app: InstalledApp) -> [LeftoverMatch] {
        let home = NSHomeDirectory()
        let searchDirs = [
            "\(home)/Library/Application Support",
            "\(home)/Library/Caches",
            "\(home)/Library/Preferences",
            "\(home)/Library/Logs",
            "\(home)/Library/Saved Application State",
            "\(home)/Library/Containers",
            "\(home)/Library/HTTPStorages",
            "\(home)/Library/WebKit",
        ]

        let bundleIDLower = app.bundleIdentifier?.lowercased()
        let appNameLower = app.name.lowercased()
        guard bundleIDLower != nil || !appNameLower.isEmpty else { return [] }

        var matches: [LeftoverMatch] = []
        for dir in searchDirs {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for item in items {
                let path = (dir as NSString).appendingPathComponent(item)
                let url = URL(fileURLWithPath: path)
                let lowerItem = item.lowercased()
                let stem = (item as NSString).deletingPathExtension.lowercased()

                if let bundleIDLower, stem == bundleIDLower || lowerItem == bundleIDLower {
                    matches.append(LeftoverMatch(url: url, confidence: .exact))
                } else if !appNameLower.isEmpty, stem == appNameLower {
                    matches.append(LeftoverMatch(url: url, confidence: .exact))
                } else if let bundleIDLower, lowerItem.contains(bundleIDLower) {
                    matches.append(LeftoverMatch(url: url, confidence: .possible))
                } else if !appNameLower.isEmpty, lowerItem.contains(appNameLower) {
                    matches.append(LeftoverMatch(url: url, confidence: .possible))
                }
            }
        }
        return matches
    }

    static func trash(_ url: URL) -> TrashRecord? {
        MacTrashUndo.trash(url)
    }
}
