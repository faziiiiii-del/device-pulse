//
//  MacStorageBreakdown.swift
//  DevicePulseMac
//

import SwiftUI

let categoryColors: [String: Color] = [
    "applications": .blue,
    "photos": .pink,
    "documents": .orange,
    "desktop": .yellow,
    "downloads": .teal,
    "movies": .purple,
    "music": .green,
    "developer": .indigo,
    "other": .gray,
]

struct MacStorageStackedBar: View {
    let segments: [(id: String, fraction: Double)]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(segments, id: \.id) { segment in
                    if segment.fraction > 0 {
                        (categoryColors[segment.id] ?? .gray)
                            .frame(width: max(2, geo.size.width * segment.fraction))
                    }
                }
            }
        }
        .frame(height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct MacStorageBreakdownView: View {
    let categories: [StorageCategory]
    let otherBytes: Int64
    let totalBytes: Int64
    let onSelect: (StorageCategory) -> Void

    private var otherFraction: Double {
        totalBytes == 0 ? 0 : Double(otherBytes) / Double(totalBytes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MacStorageStackedBar(segments: segments)

            VStack(spacing: 0) {
                ForEach(categories) { category in
                    Button {
                        onSelect(category)
                    } label: {
                        row(name: category.name, colorKey: category.id, size: category.sizeBytes, accessDenied: category.accessDenied, showChevron: true)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
                row(name: "Other (System & Unscanned)", colorKey: "other", size: otherBytes, accessDenied: false, showChevron: false)
            }
        }
    }

    private var segments: [(id: String, fraction: Double)] {
        var result = categories.map { (id: $0.id, fraction: fraction(for: $0.sizeBytes)) }
        result.append((id: "other", fraction: otherFraction))
        return result
    }

    private func fraction(for bytes: Int64?) -> Double {
        guard let bytes, totalBytes > 0 else { return 0 }
        return Double(bytes) / Double(totalBytes)
    }

    @ViewBuilder
    private func row(name: String, colorKey: String, size: Int64?, accessDenied: Bool, showChevron: Bool) -> some View {
        HStack {
            Circle().fill(categoryColors[colorKey] ?? .gray).frame(width: 10, height: 10)
            Text(name).font(.subheadline)
            Spacer()
            if accessDenied {
                Text("Access Required").font(.caption).foregroundStyle(.orange)
            } else if let size {
                Text(ByteFormat.string(size)).font(.subheadline).bold()
                if totalBytes > 0 {
                    Text("\(Int((Double(size) / Double(totalBytes)) * 100))%")
                        .font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
            } else {
                ProgressView().controlSize(.small)
            }
            if showChevron {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
