//
//  MacDuplicateScanner.swift
//  DevicePulseMac
//
//  Finds files that are byte-identical, not just same-named or
//  similar-sized. Two phases, cheapest check first:
//   1. Walk the chosen folder, bucket regular files by exact size.
//      Size alone is a free, instant way to rule out the vast majority
//      of files — nothing gets hashed unless at least one other file
//      shares its exact size.
//   2. Within each size bucket with more than one file, hash the
//      candidates (SHA-256) and group by hash. Only a genuine content
//      match — not size, not name — becomes a duplicate group.
//
//  Deliberately scoped to a folder the user picks (never the whole
//  disk), skips inside .app bundles, and never touches anything itself
//  — this only reports groups; trashing a specific file is a separate,
//  explicit action the caller drives.
//

import Foundation

struct DuplicateFileEntry: Identifiable, Equatable {
    let id: String
    let url: URL
    let sizeBytes: Int64
    let modifiedDate: Date?

    var name: String { url.lastPathComponent }
    var path: String { url.path }

    init(url: URL, sizeBytes: Int64, modifiedDate: Date?) {
        self.id = url.path
        self.url = url
        self.sizeBytes = sizeBytes
        self.modifiedDate = modifiedDate
    }
}

struct DuplicateGroup: Identifiable {
    let id: String // content hash
    let sizeBytes: Int64
    var files: [DuplicateFileEntry]

    /// Space recoverable by keeping exactly one copy and trashing the rest.
    var reclaimableBytes: Int64 { sizeBytes * Int64(max(0, files.count - 1)) }
}

enum MacDuplicateScanner {
    /// `onProgress` reports a running "items examined" count across both
    /// the walk and hash phases, off the main thread.
    static func scan(root: URL, minSizeBytes: Int64 = 1_000_000, onProgress: ((Int) -> Void)? = nil) -> [DuplicateGroup] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else { return [] }

        var bySize: [Int64: [URL]] = [:]
        var examined = 0
        for case let url as URL in enumerator {
            examined += 1
            if examined % 200 == 0 { onProgress?(examined) }
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true, values.isRegularFile == true,
                  let size = values.fileSize, Int64(size) >= minSizeBytes
            else { continue }
            bySize[Int64(size), default: []].append(url)
        }

        var groups: [DuplicateGroup] = []
        for (size, urls) in bySize where urls.count > 1 {
            var byHash: [String: [URL]] = [:]
            for url in urls {
                examined += 1
                if examined % 50 == 0 { onProgress?(examined) }
                guard let hash = MacFileHasher.sha256(ofFileAt: url.path) else { continue }
                byHash[hash, default: []].append(url)
            }
            for (hash, matches) in byHash where matches.count > 1 {
                let entries = matches.map { url -> DuplicateFileEntry in
                    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    return DuplicateFileEntry(url: url, sizeBytes: size, modifiedDate: modified)
                }
                groups.append(DuplicateGroup(id: hash, sizeBytes: size, files: entries.sorted {
                    ($0.modifiedDate ?? .distantFuture) < ($1.modifiedDate ?? .distantFuture)
                }))
            }
        }
        onProgress?(examined)

        return groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }
}
