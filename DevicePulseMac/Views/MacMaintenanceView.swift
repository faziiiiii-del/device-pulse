//
//  MacMaintenanceView.swift
//  DevicePulseMac
//
//  SCAN → REVIEW → CLEAN. Cleaning a normal category moves its contents
//  to the Trash (reversible). Cleaning the Trash category itself empties
//  the Trash, which is permanent — that path gets its own, stronger
//  confirmation wording. Nothing is ever deleted without an explicit
//  per-category confirmation.
//

import SwiftUI

struct MacMaintenanceView: View {
    @State private var categories: [MaintenanceCategory] = MacStorageScanner.categories()
    @State private var isScanning = false
    @State private var hasScanned = false
    @State private var pendingClean: MaintenanceCategory?
    @State private var cleanupLog: [(name: String, detail: String, date: Date)] = []
    @StateObject private var undoToast = UndoToastState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Maintenance").font(.largeTitle).bold()
                Text("Scan → Review → Clean. \"Clean\" moves a category's contents to the Trash — nothing is permanently deleted except emptying the Trash itself, which asks separately.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button {
                    scan()
                } label: {
                    if isScanning {
                        HStack { ProgressView().controlSize(.small); Text("Scanning…") }
                    } else {
                        Label("Scan", systemImage: "magnifyingglass")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isScanning)

                MacCard(title: "Categories", systemImage: "folder", tint: MacSection.maintenance.tint) {
                    VStack(spacing: 0) {
                        ForEach(categories) { category in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(category.name).font(.subheadline).bold()
                                    Text(category.path).font(.caption2).foregroundStyle(.secondary)
                                    Text(category.explanation).font(.caption2).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    if category.accessDenied {
                                        Text("Access Required").font(.caption).bold().foregroundStyle(.orange)
                                    } else if let size = category.sizeBytes {
                                        Text(ByteFormat.string(size)).font(.subheadline).bold()
                                    } else if hasScanned {
                                        Text("—").font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text("Not scanned").font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    Text(category.risk).font(.caption2).foregroundStyle(.secondary)
                                    Button(category.name == "Trash" ? "Empty Trash" : "Clean") {
                                        pendingClean = category
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(category.accessDenied || (category.sizeBytes ?? 0) == 0)
                                }
                            }
                            .padding(.vertical, 6)
                            if category.id != categories.last?.id { Divider() }
                        }
                    }
                }

                if !cleanupLog.isEmpty {
                    MacCard(title: "Recent Cleanups", systemImage: "checkmark.circle", tint: MacSection.maintenance.tint) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(cleanupLog.enumerated()), id: \.offset) { _, entry in
                                Text("\(entry.name): \(entry.detail) — \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                            }
                        }
                    }
                }

                Text("If a folder shows \"Access Required\", macOS's file permission model (or Full Disk Access) is blocking this app from reading it — that's shown honestly rather than reported as 0 bytes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .undoToast(undoToast)
        .alert(
            pendingClean.map { $0.name == "Trash" ? "Empty Trash?" : "Clean \($0.name)?" } ?? "",
            isPresented: Binding(get: { pendingClean != nil }, set: { if !$0 { pendingClean = nil } })
        ) {
            Button("Cancel", role: .cancel) { pendingClean = nil }
            Button(pendingClean?.name == "Trash" ? "Empty Trash" : "Move to Trash", role: .destructive) {
                if let category = pendingClean { clean(category) }
                pendingClean = nil
            }
        } message: {
            if let category = pendingClean {
                if category.name == "Trash" {
                    Text("This permanently deletes everything currently in the Trash. This cannot be undone.")
                } else {
                    Text("This moves the contents of \(category.path) to the Trash. Nothing is permanently deleted — you can restore any of it from the Trash afterward.")
                }
            }
        }
    }

    private func scan() {
        isScanning = true
        let toScan = categories
        DispatchQueue.global(qos: .utility).async {
            let results = toScan.map { MacStorageScanner.size(of: $0) }
            DispatchQueue.main.async {
                categories = results
                isScanning = false
                hasScanned = true
            }
        }
    }

    private func clean(_ category: MaintenanceCategory) {
        if category.name == "Trash" {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = MacStorageScanner.emptyTrash()
                DispatchQueue.main.async {
                    let detail = result.failed > 0
                        ? "Permanently removed \(result.moved) item(s), \(result.failed) couldn't be removed"
                        : "Permanently removed \(result.moved) item(s)"
                    cleanupLog.insert((category.name, detail, Date()), at: 0)
                    rescan(category)
                }
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let result = MacStorageScanner.trashContents(of: category)
            DispatchQueue.main.async {
                let detail = result.failed > 0
                    ? "Moved \(result.records.count) item(s) to Trash, \(result.failed) couldn't be removed"
                    : "Moved \(result.records.count) item(s) to Trash"
                cleanupLog.insert((category.name, detail, Date()), at: 0)
                undoToast.show(records: result.records, message: "\(category.name): moved \(result.records.count) item(s) to Trash") {
                    rescan(category)
                }
                rescan(category)
            }
        }
    }

    private func rescan(_ category: MaintenanceCategory) {
        if let index = categories.firstIndex(where: { $0.id == category.id }) {
            categories[index] = MacStorageScanner.size(of: categories[index])
        }
    }
}
