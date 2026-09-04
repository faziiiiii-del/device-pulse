//
//  MacStorageView.swift
//  DevicePulseMac
//

import SwiftUI
import AppKit

struct MacStorageView: View {
    @State private var volumes: [VolumeInfo] = []
    @State private var categories: [StorageCategory] = MacStorageCategoryScanner.categories()
    @State private var isScanning = false
    @State private var hasScanned = false
    @State private var selectedCategory: StorageCategory?
    @State private var diskHealth: [DiskHealthInfo] = []
    @State private var isLoadingDiskHealth = true
    @State private var timeMachineStatus: TimeMachineStatus?
    @State private var isLoadingTimeMachine = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Storage").font(.largeTitle).bold()

                ForEach(volumes) { volume in
                    MacCard(title: volume.name, systemImage: volume.isInternal ? "internaldrive" : "externaldrive", tint: MacSection.storage.tint) {
                        MacUsageBar(
                            usedLabel: "Used \(ByteFormat.string(volume.used))",
                            totalLabel: "of \(ByteFormat.string(volume.total))",
                            fraction: volume.usedFraction,
                            tint: .blue
                        )
                        HStack {
                            Text("\(ByteFormat.string(volume.available)) available")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(volume.path).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }

                if volumes.isEmpty {
                    Text("Loading volumes…").font(.caption).foregroundStyle(.secondary)
                }

                MacCard(title: "What's Using Space", systemImage: "chart.pie", tint: MacSection.storage.tint) {
                    HStack {
                        Text("Built from real folder sizes — not the same source as About This Mac's breakdown, which uses a private Apple framework third-party apps can't call. Click a category to see what's in it.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
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
                    }

                    if hasScanned {
                        MacStorageBreakdownView(
                            categories: categories,
                            otherBytes: otherBytes,
                            totalBytes: mainVolumeUsed,
                            onSelect: { selectedCategory = $0 }
                        )
                    }
                }

                diskHealthCard
                timeMachineCard
            }
            .padding(24)
        }
        .onAppear {
            volumes = MacStorageMonitor.allVolumes()
            loadDiskHealth()
            loadTimeMachineStatus()
        }
        .sheet(item: $selectedCategory) { category in
            MacStorageCategoryDetailView(category: category)
        }
    }

    private var diskHealthCard: some View {
        MacCard(title: "Disk Health", systemImage: "heart.text.square", tint: MacSection.storage.tint) {
            if isLoadingDiskHealth {
                Text("Checking S.M.A.R.T. status…").font(.caption).foregroundStyle(.secondary)
            } else if diskHealth.isEmpty {
                Text("No physical disks reported S.M.A.R.T. status.").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(diskHealth) { disk in
                        HStack(alignment: .top, spacing: 10) {
                            StatusDot(level: disk.smart.level)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(disk.mediaName).font(.subheadline).bold()
                                Text(disk.smart.label).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let size = disk.totalSizeBytes {
                                Text(ByteFormat.string(size)).font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 6)
                        if disk.id != diskHealth.last?.id { Divider() }
                    }
                }
                Text("Read directly from each drive's own controller via diskutil — the same documented mechanism Disk Utility uses. \"Not Supported\" means the drive itself doesn't report SMART data, not that anything's wrong.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func loadDiskHealth() {
        DispatchQueue.global(qos: .utility).async {
            let result = MacDiskHealthMonitor.scan()
            DispatchQueue.main.async {
                diskHealth = result
                isLoadingDiskHealth = false
            }
        }
    }

    private var timeMachineCard: some View {
        MacCard(title: "Time Machine", systemImage: "clock.arrow.circlepath", tint: MacSection.storage.tint) {
            if isLoadingTimeMachine {
                Text("Checking backup status…").font(.caption).foregroundStyle(.secondary)
            } else if let tm = timeMachineStatus {
                if !tm.isConfigured {
                    Text("Time Machine isn't set up — no backup destination is configured.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        StatusDot(level: timeMachineLevel(tm))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tm.destinationName ?? "Time Machine").font(.subheadline).bold()
                            if let kind = tm.destinationKind {
                                Text(kind).font(.caption2).foregroundStyle(.tertiary)
                            }
                            if tm.isRunning {
                                if let percent = tm.percentComplete {
                                    Text("Backup in progress — \(Int(percent * 100))%").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("Backup in progress…").font(.caption).foregroundStyle(.secondary)
                                }
                            } else if let lastDate = tm.lastBackupDate {
                                Text("Last backup: \(lastDate.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text(tm.lastBackupUnavailableReason ?? "No successful backup found yet.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private func timeMachineLevel(_ tm: TimeMachineStatus) -> StatusLevel {
        if tm.isRunning { return .good }
        guard let last = tm.lastBackupDate else { return .bad }
        let daysSince = Date().timeIntervalSince(last) / 86_400
        if daysSince <= 1 { return .good }
        if daysSince <= 7 { return .warning }
        return .bad
    }

    private func loadTimeMachineStatus() {
        DispatchQueue.global(qos: .utility).async {
            let result = MacTimeMachineMonitor.currentStatus()
            DispatchQueue.main.async {
                timeMachineStatus = result
                isLoadingTimeMachine = false
            }
        }
    }

    private var mainVolumeUsed: Int64 {
        volumes.first(where: { $0.path == "/" })?.used ?? volumes.first?.used ?? 0
    }

    private var otherBytes: Int64 {
        let categorized = categories.reduce(Int64(0)) { $0 + ($1.sizeBytes ?? 0) }
        return max(0, mainVolumeUsed - categorized)
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

private struct MacStorageCategoryDetailView: View {
    let category: StorageCategory
    @State private var items: [StorageSubitem] = []
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

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
                ProgressView("Loading…").frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
            } else if items.isEmpty {
                Text("Nothing found, or contents aren't individually readable.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 20)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(items) { item in
                            HStack {
                                Image(systemName: item.isDirectory ? "folder" : "doc")
                                    .foregroundStyle(.secondary)
                                Text(item.name).font(.subheadline).lineLimit(1)
                                Spacer()
                                Text(ByteFormat.string(item.sizeBytes)).font(.subheadline).bold()
                                Button("Reveal") {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(.vertical, 5)
                            if item.id != items.last?.id { Divider() }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 480, height: 480)
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
