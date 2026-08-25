//
//  MacSpaceMapView.swift
//  DevicePulseMac
//
//  Visual "where did my space go" view — a squarified treemap (see
//  Treemap.swift) over the exact same real folder-size data Storage's
//  "What's Using Space" already computes via MacStorageCategoryScanner.
//  This is a different lens on real numbers, not a new data source.
//  Tapping a tile drills one level down into that category's own
//  subfolders, rendered as their own treemap.
//

import SwiftUI
import AppKit

struct MacSpaceMapView: View {
    @State private var volume: VolumeInfo?
    @State private var categories: [StorageCategory] = MacStorageCategoryScanner.categories()
    @State private var isScanning = false
    @State private var hasScanned = false
    @State private var drillDown: StorageCategory?

    private var mainVolumeUsed: Int64 { volume?.used ?? 0 }

    private var otherBytes: Int64 {
        let categorized = categories.reduce(Int64(0)) { $0 + ($1.sizeBytes ?? 0) }
        return max(0, mainVolumeUsed - categorized)
    }

    private var treemapItems: [Treemap.Item] {
        var items = categories.compactMap { category -> Treemap.Item? in
            guard let size = category.sizeBytes, size > 0 else { return nil }
            return Treemap.Item(id: category.id, value: Double(size))
        }
        if otherBytes > 0 { items.append(Treemap.Item(id: "other", value: Double(otherBytes))) }
        return items
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Space Map").font(.largeTitle).bold()
                Text("A visual breakdown of the same real folder sizes Storage computes — bigger tile means more space used. Click a tile to see what's inside it. \"Other\" is the honest remainder after subtracting every scanned category from the volume's actual used space, same as Storage's breakdown.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let volume {
                    MacCard(title: volume.name, systemImage: "internaldrive", tint: MacSection.storage.tint) {
                        MacUsageBar(
                            usedLabel: "Used \(ByteFormat.string(volume.used))",
                            totalLabel: "of \(ByteFormat.string(volume.total))",
                            fraction: volume.usedFraction,
                            tint: .blue
                        )
                    }
                }

                MacCard(title: "Map", systemImage: "square.grid.3x3", tint: MacSection.storage.tint) {
                    HStack {
                        Text("Category sizes are computed the same way as Storage's breakdown — this can take a moment for large folders.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            scan()
                        } label: {
                            if isScanning {
                                HStack { ProgressView().controlSize(.small); Text("Scanning…") }
                            } else {
                                Label(hasScanned ? "Rescan" : "Scan", systemImage: "square.grid.3x3.fill")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isScanning)
                    }

                    if hasScanned {
                        if treemapItems.isEmpty {
                            Text("Nothing scanned yet, or every category is empty.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            MacTreemapView(
                                items: treemapItems,
                                colorFor: { categoryColors[$0] ?? .gray },
                                labelFor: { id in id == "other" ? "Other" : (categories.first { $0.id == id }?.name ?? id) },
                                iconFor: { id in id == "other" ? "questionmark.folder" : categories.first { $0.id == id }?.icon },
                                onTap: { id in
                                    if id != "other", let category = categories.first(where: { $0.id == id }) {
                                        drillDown = category
                                    }
                                }
                            )
                            .frame(height: 420)

                            legend
                        }
                    }
                }
            }
            .padding(24)
        }
        .onAppear {
            volume = MacStorageMonitor.mainVolume()
        }
        .sheet(item: $drillDown) { category in
            MacSpaceMapDrillDownView(category: category)
        }
    }

    private var legend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], alignment: .leading, spacing: 6) {
            ForEach(treemapItems, id: \.id) { item in
                HStack(spacing: 6) {
                    Circle().fill(categoryColors[item.id] ?? .gray).frame(width: 8, height: 8)
                    Text(item.id == "other" ? "Other" : (categories.first { $0.id == item.id }?.name ?? item.id))
                        .font(.caption2)
                    Spacer()
                    Text(ByteFormat.string(Int64(item.value))).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func scan() {
        isScanning = true
        let toScan = categories
        DispatchQueue.global(qos: .utility).async {
            let results = toScan.map { MacStorageCategoryScanner.size(of: $0) }
            DispatchQueue.main.async {
                categories = results
                isScanning = false
                hasScanned = true
            }
        }
    }
}

/// One level of drill-down — the category's own children, laid out as
/// their own treemap. Not recursive further than this (matches Storage's
/// existing drill-down depth); Big Files Finder covers deeper exploration.
private struct MacSpaceMapDrillDownView: View {
    let category: StorageCategory
    @State private var items: [StorageSubitem] = []
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    private let palette: [Color] = [.blue, .pink, .orange, .teal, .purple, .green, .indigo, .mint, .cyan, .yellow, .red, .brown]

    private func color(for id: String) -> Color {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return .gray }
        return palette[index % palette.count]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(category.name).font(.title2).bold()
                Spacer()
                Button("Done") { dismiss() }
            }
            Text(category.sizeBytes.map { "\(ByteFormat.string($0)) total" } ?? "")
                .font(.caption).foregroundStyle(.secondary)

            if isLoading {
                ProgressView("Loading…").frame(maxWidth: .infinity, alignment: .center).padding(.top, 60)
            } else if items.isEmpty {
                Text("Nothing found, or contents aren't individually readable.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 20)
            } else {
                MacTreemapView(
                    items: items.map { Treemap.Item(id: $0.id, value: Double($0.sizeBytes)) },
                    colorFor: color(for:),
                    labelFor: { id in items.first { $0.id == id }?.name ?? id },
                    iconFor: { id in (items.first { $0.id == id }?.isDirectory ?? false) ? "folder.fill" : "doc.fill" },
                    onTap: { id in
                        if let item = items.first(where: { $0.id == id }) {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                        }
                    }
                )
                .frame(minHeight: 320, maxHeight: .infinity)
                Text("Click a tile to reveal it in Finder.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .onAppear(perform: load)
    }

    private func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = MacStorageCategoryScanner.subitems(of: category)
            DispatchQueue.main.async {
                items = found
                isLoading = false
            }
        }
    }
}

/// Generic squarified-treemap renderer — used both for the top-level
/// category map and the one-level drill-down, so the two look and
/// behave identically.
struct MacTreemapView: View {
    let items: [Treemap.Item]
    let colorFor: (String) -> Color
    let labelFor: (String) -> String
    var iconFor: ((String) -> String?)?
    var onTap: ((String) -> Void)?

    var body: some View {
        GeometryReader { geo in
            let rects = Treemap.layout(items, in: CGRect(origin: .zero, size: geo.size))
            ForEach(items, id: \.id) { item in
                if let rect = rects[item.id] {
                    tile(item: item, rect: rect)
                }
            }
        }
    }

    @ViewBuilder
    private func tile(item: Treemap.Item, rect: CGRect) -> some View {
        let tint = colorFor(item.id)
        let icon = iconFor?(item.id)
        let showsDetail = rect.width > 46 && rect.height > 28
        let showsIcon = icon != nil && rect.width > 64 && rect.height > 56
        Button {
            onTap?(item.id)
        } label: {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing))
                // Glossy top highlight, matching MacIconTile's treatment
                // elsewhere in the app, so tiles read as tactile surfaces
                // rather than flat filled rectangles.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.24), .clear], startPoint: .top, endPoint: .center))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.28), lineWidth: 1)

                if showsDetail {
                    VStack(alignment: .leading, spacing: 0) {
                        if showsIcon, let icon {
                            Image(systemName: icon)
                                .font(.system(size: min(18, rect.height * 0.16), weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.bottom, 6)
                        }
                        Spacer(minLength: 0)
                        Text(labelFor(item.id)).font(.caption).bold().foregroundStyle(.white).lineLimit(1)
                            .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                        if rect.height > 44 {
                            Text(ByteFormat.string(Int64(item.value))).font(.caption2).foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .padding(8)
                }
            }
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1.5)
        }
        .buttonStyle(MacPressableButtonStyle())
        .macHoverLift(tint: tint)
        .help("\(labelFor(item.id)) — \(ByteFormat.string(Int64(item.value)))")
        .frame(width: max(0, rect.width - 3), height: max(0, rect.height - 3))
        .position(x: rect.midX, y: rect.midY)
    }
}
