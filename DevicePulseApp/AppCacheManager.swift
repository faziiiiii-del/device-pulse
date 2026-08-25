//
//  AppCacheManager.swift
//  DevicePulse
//
//  IMPORTANT HONESTY NOTE:
//  On iOS, every app is sandboxed. This app can only see and delete files
//  inside ITS OWN container (its own Caches/ and tmp/ folders). There is
//  no public API — and no way around the sandbox without jailbreaking —
//  for a third-party app to clear Safari's cache, other apps' caches, or
//  any system-level cache. Any app that claims to do that on a stock
//  iPhone is not actually doing it.
//
//  What this screen legitimately does: measures and clears THIS app's own
//  Caches and temporary directories, which is real and accurate for those
//  two folders.
//

import Foundation

enum AppCacheManager {
    static func cachesDirectorySize() -> Int64 {
        guard let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return 0 }
        return directorySize(at: url)
    }

    static func tempDirectorySize() -> Int64 {
        directorySize(at: FileManager.default.temporaryDirectory)
    }

    static func documentsDirectorySize() -> Int64 {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return 0 }
        return directorySize(at: url)
    }

    /// Library directory size, EXCLUDING Caches (which is a subfolder of
    /// Library but already measured/cleared separately above).
    static func libraryDirectorySizeExcludingCaches() -> Int64 {
        guard let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first,
              let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return 0 }
        return directorySize(at: libraryURL, excluding: cachesURL)
    }

    /// This app's total on-disk footprint (Documents + Library incl. Caches + tmp).
    static func appContainerTotalSize() -> Int64 {
        documentsDirectorySize() + libraryDirectorySizeExcludingCaches() + cachesDirectorySize() + tempDirectorySize()
    }

    @discardableResult
    static func clearCachesDirectory() -> Bool {
        guard let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return false }
        return clearDirectory(at: url)
    }

    @discardableResult
    static func clearTempDirectory() -> Bool {
        clearDirectory(at: FileManager.default.temporaryDirectory)
    }

    private static func directorySize(at url: URL, excluding excludedURL: URL? = nil) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [],
            errorHandler: nil
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let excludedURL, fileURL.path.hasPrefix(excludedURL.path) {
                enumerator.skipDescendants()
                continue
            }
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == false, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private static func clearDirectory(at url: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        ) else { return false }

        var allSucceeded = true
        for item in contents {
            do {
                try FileManager.default.removeItem(at: item)
            } catch {
                allSucceeded = false
            }
        }
        return allSucceeded
    }
}
