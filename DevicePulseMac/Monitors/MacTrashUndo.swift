//
//  MacTrashUndo.swift
//  DevicePulseMac
//
//  Wraps FileManager.trashItem to also capture the URL each item lands
//  at inside the Trash, so a "Undo" action can move it straight back to
//  where it came from. Never a permanent delete.
//

import Foundation

struct TrashRecord: Identifiable {
    let id = UUID()
    let originalURL: URL
    let trashedURL: URL
}

enum MacTrashUndo {
    static func trash(_ url: URL) -> TrashRecord? {
        var resultingURL: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        } catch {
            return nil
        }
        guard let trashedURL = resultingURL as URL? else { return nil }
        return TrashRecord(originalURL: url, trashedURL: trashedURL)
    }

    @discardableResult
    static func restore(_ record: TrashRecord) -> Bool {
        (try? FileManager.default.moveItem(at: record.trashedURL, to: record.originalURL)) != nil
    }

    @discardableResult
    static func restore(_ records: [TrashRecord]) -> Int {
        records.reduce(into: 0) { count, record in
            if restore(record) { count += 1 }
        }
    }
}
