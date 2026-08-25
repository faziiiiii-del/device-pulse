//
//  MacBigFilesScanner.swift
//  DevicePulseMac
//
//  Finds individually large files under a folder the user explicitly
//  chooses (never scans the whole disk unasked). Skips inside app/
//  bundle packages so it surfaces stray media/archives/disk images
//  rather than an app's internal resources — those belong to the
//  Uninstaller instead.
//

import Foundation

struct BigFileEntry: Identifiable, Equatable {
    let id: String
    let url: URL
    let sizeBytes: Int64

    var name: String { url.lastPathComponent }
    var path: String { url.path }

    init(url: URL, sizeBytes: Int64) {
        self.id = url.path
        self.url = url
        self.sizeBytes = sizeBytes
    }
}

enum MacBigFilesScanner {
    /// `onProgress` is called periodically (every ~200 files walked) off
    /// the main thread so a caller can show a live "scanned so far"
    /// counter — the total file count isn't known ahead of time, so this
    /// is a running count, not a fraction.
    static func scan(root: URL, minSizeBytes: Int64, limit: Int = 300, onProgress: ((Int) -> Void)? = nil) -> [BigFileEntry] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else { return [] }

        var results: [BigFileEntry] = []
        var walked = 0
        for case let url as URL in enumerator {
            walked += 1
            if walked % 200 == 0 { onProgress?(walked) }
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize, Int64(size) >= minSizeBytes
            else { continue }
            results.append(BigFileEntry(url: url, sizeBytes: Int64(size)))
        }
        onProgress?(walked)

        results.sort { $0.sizeBytes > $1.sizeBytes }
        return Array(results.prefix(limit))
    }

    static func trash(_ entry: BigFileEntry) -> TrashRecord? {
        MacTrashUndo.trash(entry.url)
    }
}
