//
//  MacSmartCareView.swift
//  DevicePulseMac
//
//  Scan → Diagnose → Recommend → Review → Clean. This used to run
//  diagnostics and immediately clean every low-risk category with no
//  chance to review what was about to move, which is too aggressive for
//  something framed as "Smart Care" — a user shouldn't wonder what it
//  just did. Now it only scans and recommends; nothing is touched until
//  you review the list and press Clean. Selected categories move to
//  Trash — reversible via Undo — never permanently deleted.
//

import SwiftUI

struct MacSmartCareView: View {
    @State private var isScanning = false
    @State private var isCleaning = false
    @State private var hasScanned = false
    @State private var checks: [DiagnosticCheck] = []
    @State private var recommendations: [MaintenanceCategory] = []
    @State private var selected: Set<String> = []
    @State private var movedBytes: Int64?
    @State private var lastRun: Date?
    @StateObject private var undoToast = UndoToastState()

    private var safeCategoryTemplates: [MaintenanceCategory] {
        MacStorageScanner.categories().filter { $0.risk == "Low" && $0.name != "Trash" }
    }

    private var reclaimableBytes: Int64 {
        recommendations.filter { selected.contains($0.name) }.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Smart Care").font(.largeTitle).bold()
                Text("Scans regenerable caches, logs, and Xcode build intermediates — the same categories already marked low-risk in Maintenance — and runs a full diagnostic. Nothing is touched until you review and choose what to clean.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button {
                    scan()
                } label: {
                    if isScanning {
                        HStack { ProgressView().controlSize(.small); Text("Scanning…") }
                    } else {
                        Label(hasScanned ? "Scan Again" : "Scan", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isScanning)

                if hasScanned {
                    MacCard(title: "Recommended (\(ByteFormat.string(recommendations.reduce(0) { $0 + ($1.sizeBytes ?? 0) })) potentially reclaimable)", systemImage: "checklist", tint: MacSection.smartCare.tint) {
                        VStack(spacing: 0) {
                            ForEach(recommendations) { category in
                                HStack {
                                    Button {
                                        toggle(category)
                                    } label: {
                                        Image(systemName: selected.contains(category.name) ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(selected.contains(category.name) ? Color.accentColor : .secondary)
                                    }
                                    .buttonStyle(.plain)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(category.name).font(.subheadline).bold()
                                        Text(category.explanation).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let size = category.sizeBytes {
                                        Text(ByteFormat.string(size)).font(.subheadline).bold()
                                    }
                                }
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                                .onTapGesture { toggle(category) }
                                if category.id != recommendations.last?.id { Divider() }
                            }
                        }

                        Button {
                            clean()
                        } label: {
                            if isCleaning {
                                HStack { ProgressView().controlSize(.small); Text("Cleaning…") }
                            } else {
                                Label("Review & Clean Selected (\(ByteFormat.string(reclaimableBytes)))", systemImage: "trash")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selected.isEmpty || isCleaning)
                        .padding(.top, 8)
                    }
                }

                if let movedBytes {
                    MacCard(title: "Result", systemImage: "checkmark.seal", tint: MacSection.smartCare.tint) {
                        Text("Moved \(ByteFormat.string(movedBytes)) to Trash.")
                            .font(.subheadline).bold()
                        Text("This doesn't free disk space yet — the files still occupy the volume until Trash is emptied. \(ByteFormat.string(movedBytes)) can be reclaimed by emptying Trash (Maintenance ▸ Trash ▸ Empty Trash).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let lastRun {
                            Text("Last run \(lastRun.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !checks.isEmpty {
                    MacCard(title: "Diagnostic Summary", systemImage: "stethoscope", tint: MacSection.smartCare.tint) {
                        HStack(spacing: 24) {
                            MacMiniStat(label: "Normal", value: "\(checks.filter { $0.status == .pass }.count)")
                            MacMiniStat(label: "Warnings", value: "\(checks.filter { $0.status == .warning }.count)")
                            MacMiniStat(label: "Checks", value: "\(checks.count)")
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(checks) { check in
                                HStack {
                                    StatusBadge(status: check.status)
                                    Text(check.name).font(.subheadline).bold()
                                    Text(check.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .undoToast(undoToast)
    }

    private func toggle(_ category: MaintenanceCategory) {
        if selected.contains(category.name) {
            selected.remove(category.name)
        } else {
            selected.insert(category.name)
        }
    }

    private func scan() {
        isScanning = true
        movedBytes = nil
        let templates = safeCategoryTemplates

        DispatchQueue.global(qos: .userInitiated).async {
            let diagnosticResults = MacDiagnosticsEngine.runAll()
            let sized = templates.map { MacStorageScanner.size(of: $0) }.filter { ($0.sizeBytes ?? 0) > 0 }

            DispatchQueue.main.async {
                checks = diagnosticResults
                recommendations = sized
                selected = Set(sized.map(\.name)) // recommended = pre-selected, but still reviewable
                isScanning = false
                hasScanned = true
            }
        }
    }

    private func clean() {
        isCleaning = true
        let toClean = recommendations.filter { selected.contains($0.name) }

        DispatchQueue.global(qos: .userInitiated).async {
            var allRecords: [TrashRecord] = []
            var moved: Int64 = 0

            for category in toClean {
                let result = MacStorageScanner.trashContents(of: category)
                if !result.records.isEmpty {
                    allRecords.append(contentsOf: result.records)
                    moved += result.movedBytes
                }
            }

            DispatchQueue.main.async {
                movedBytes = moved
                lastRun = Date()
                isCleaning = false
                hasScanned = false // force a re-scan before cleaning again, so sizes/selection can't go stale
                if !allRecords.isEmpty {
                    undoToast.show(records: allRecords, message: "Moved \(ByteFormat.string(moved)) to Trash") {
                        hasScanned = false
                    }
                }
            }
        }
    }
}
