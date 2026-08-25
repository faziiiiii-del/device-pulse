//
//  Treemap.swift
//  DevicePulseMac
//
//  Squarified treemap layout (Bruls, Huizing, van Wijk 1999) — the same
//  approach DaisyDisk/CleanMyMac's Space Lens use for "where did my
//  space go" visualizations. Pure geometry, no SwiftUI dependency, so
//  it can lay out any sized collection of items (top-level storage
//  categories, or a category's own subfolders for the drill-down view)
//  the same way. Always tiles the given rect exactly — every byte
//  reported by the scanner ends up visually represented, nothing is
//  invented to fill gaps.
//

import Foundation
import CoreGraphics

enum Treemap {
    struct Item {
        let id: String
        let value: Double
    }

    static func layout(_ items: [Item], in rect: CGRect) -> [String: CGRect] {
        let positive = items.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        guard !positive.isEmpty, rect.width > 0, rect.height > 0 else { return [:] }

        let totalValue = positive.reduce(0) { $0 + $1.value }
        guard totalValue > 0 else { return [:] }
        let areaScale = Double(rect.width) * Double(rect.height) / totalValue
        let scaled = positive.map { Item(id: $0.id, value: $0.value * areaScale) }

        var result: [String: CGRect] = [:]
        squarify(scaled, row: [], rect: rect, result: &result)
        return result
    }

    private static func squarify(_ items: [Item], row: [Item], rect: CGRect, result: inout [String: CGRect]) {
        guard !items.isEmpty else {
            if !row.isEmpty { layoutRow(row, rect: rect, result: &result) }
            return
        }
        let side = min(rect.width, rect.height)
        var candidateRow = row
        candidateRow.append(items[0])
        let remaining = Array(items.dropFirst())

        if row.isEmpty || worstAspect(row, side: side) >= worstAspect(candidateRow, side: side) {
            squarify(remaining, row: candidateRow, rect: rect, result: &result)
        } else {
            let leftover = layoutRow(row, rect: rect, result: &result)
            squarify(items, row: [], rect: leftover, result: &result)
        }
    }

    private static func worstAspect(_ row: [Item], side: CGFloat) -> Double {
        guard !row.isEmpty, side > 0 else { return .infinity }
        let sum = row.reduce(0) { $0 + $1.value }
        guard sum > 0, let maxV = row.map(\.value).max(), let minV = row.map(\.value).min(), minV > 0 else { return .infinity }
        let s2 = Double(side) * Double(side)
        return max((s2 * maxV) / (sum * sum), (sum * sum) / (s2 * minV))
    }

    @discardableResult
    private static func layoutRow(_ row: [Item], rect: CGRect, result: inout [String: CGRect]) -> CGRect {
        let sum = row.reduce(0) { $0 + $1.value }
        guard sum > 0, rect.width > 0, rect.height > 0 else { return rect }

        if rect.width >= rect.height {
            let stripWidth = CGFloat(sum) / rect.height
            var y = rect.minY
            for item in row {
                let h = rect.height * CGFloat(item.value / sum)
                result[item.id] = CGRect(x: rect.minX, y: y, width: stripWidth, height: h)
                y += h
            }
            return CGRect(x: rect.minX + stripWidth, y: rect.minY, width: max(0, rect.width - stripWidth), height: rect.height)
        } else {
            let stripHeight = CGFloat(sum) / rect.width
            var x = rect.minX
            for item in row {
                let w = rect.width * CGFloat(item.value / sum)
                result[item.id] = CGRect(x: x, y: rect.minY, width: w, height: stripHeight)
                x += w
            }
            return CGRect(x: rect.minX, y: rect.minY + stripHeight, width: rect.width, height: max(0, rect.height - stripHeight))
        }
    }
}
