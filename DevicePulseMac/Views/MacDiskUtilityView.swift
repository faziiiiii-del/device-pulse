//
//  MacDiskUtilityView.swift
//  DevicePulseMac
//
//  Erase/format/partition any disk via diskutil (MacDiskUtilityManager) —
//  no restriction by disk type, including internal disks. macOS itself
//  refuses to erase the current startup disk or volume; this view does
//  not additionally block anything, but does surface that fact plainly
//  before any action, and requires typing the exact target name before
//  any erase/partition action is enabled, since these are permanent and
//  cannot be undone (see MacDiskUtilityManager's file header for the
//  full reasoning).
//

import SwiftUI

struct MacDiskUtilityView: View {
    @State private var disks: [DiskInfo] = []
    @State private var isLoading = true
    @State private var selectedDisk: DiskInfo?
    @State private var toastMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Disk Utility").font(.largeTitle).bold()
                Text("Erase, format, and partition disks — the same diskutil operations Apple's own Disk Utility uses. These actions are permanent and cannot be undone. macOS itself refuses to erase your current startup disk or volume, independent of anything here.")
                    .font(.callout).foregroundStyle(.secondary)

                if isLoading {
                    ProgressView("Scanning disks…").frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
                } else if disks.isEmpty {
                    Text("No disks found.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(disks) { disk in diskCard(disk) }
                }
            }
            .padding(24)
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.subheadline).padding(12).background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10)).shadow(radius: 8, y: 2).padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toastMessage)
        .onAppear(perform: load)
        .sheet(item: $selectedDisk) { disk in
            MacDiskDetailSheet(disk: disk, onActionComplete: { message in
                toastMessage = message
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { toastMessage = nil }
                load()
            })
        }
    }

    private func diskCard(_ disk: DiskInfo) -> some View {
        MacCard(title: disk.mediaName, systemImage: disk.isInternal ? "internaldrive" : "externaldrive", tint: MacSection.diskUtility.tint) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(disk.deviceIdentifier) · \(ByteFormat.string(disk.totalSizeBytes)) · \(disk.isInternal ? "Internal" : "External")\(disk.isRemovable ? " · Removable" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                    if disk.containsBootVolume {
                        Label("Contains your current startup disk", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    Text("\(volumeCount(disk)) volume(s) across \(disk.partitions.count) partition(s)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Manage…") { selectedDisk = disk }.buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    private func volumeCount(_ disk: DiskInfo) -> Int {
        disk.partitions.reduce(0) { $0 + ($1.apfsVolumes.isEmpty ? ($1.plainVolume == nil ? 0 : 1) : $1.apfsVolumes.count) }
    }

    private func load() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = MacDiskUtilityManager.listDisks()
            DispatchQueue.main.async {
                disks = result
                isLoading = false
            }
        }
    }
}

// MARK: - Disk detail / actions

private struct EraseVolumeTarget: Identifiable { let id: String; let name: String }

private struct MacDiskDetailSheet: View {
    let disk: DiskInfo
    let onActionComplete: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var pendingEraseDisk = false
    @State private var pendingPartition = false
    @State private var pendingEraseVolume: EraseVolumeTarget?
    @State private var isRunning = false
    @State private var lastOutput: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(disk.mediaName).font(.title2).bold()
                Spacer()
                Button("Done") { dismiss() }
            }
            Text("\(disk.deviceIdentifier) · \(ByteFormat.string(disk.totalSizeBytes))\(disk.partitionScheme.map { " · \($0)" } ?? "")")
                .font(.caption).foregroundStyle(.secondary)

            if disk.containsBootVolume {
                Label("This disk contains your current startup disk. macOS will refuse to erase the startup disk or volume, no matter what's chosen here.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(disk.partitions) { partition in
                        partitionRow(partition)
                        if partition.id != disk.partitions.last?.id { Divider() }
                    }
                }
            }
            .frame(maxHeight: 260)

            Divider()

            HStack(spacing: 10) {
                Button(role: .destructive) { pendingEraseDisk = true } label: {
                    Label("Erase Whole Disk…", systemImage: "trash")
                }
                Button { pendingPartition = true } label: {
                    Label("Partition Disk…", systemImage: "square.split.2x1")
                }
                Spacer()
                if isRunning { ProgressView().controlSize(.small) }
            }

            if let lastOutput {
                ScrollView {
                    Text(lastOutput)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 80)
            }
        }
        .padding(20)
        .frame(width: 560, height: 620)
        .sheet(isPresented: $pendingEraseDisk) {
            MacEraseConfirmSheet(
                title: "Erase Whole Disk",
                targetName: disk.mediaName,
                warning: "This destroys ALL partitions and ALL data on \(disk.deviceIdentifier) (\(disk.mediaName)) — every volume on it, permanently. This cannot be undone.",
                onConfirm: { newName, format in
                    runAction(name: "Erase Disk") {
                        MacDiskUtilityManager.eraseDisk(deviceIdentifier: disk.deviceIdentifier, newName: newName, format: format)
                    }
                }
            )
        }
        .sheet(isPresented: $pendingPartition) {
            MacPartitionConfirmSheet(disk: disk) { partitions in
                runAction(name: "Partition Disk") {
                    MacDiskUtilityManager.partitionDisk(deviceIdentifier: disk.deviceIdentifier, partitions: partitions)
                }
            }
        }
        .sheet(item: $pendingEraseVolume) { target in
            MacEraseConfirmSheet(
                title: "Erase Volume",
                targetName: target.name,
                warning: "This destroys all data on \u{201C}\(target.name)\u{201D} (\(target.id)), permanently. Other partitions on this disk are not affected. This cannot be undone.",
                onConfirm: { newName, format in
                    runAction(name: "Erase Volume") {
                        MacDiskUtilityManager.eraseVolume(deviceIdentifier: target.id, newName: newName, format: format)
                    }
                }
            )
        }
    }

    @ViewBuilder
    private func partitionRow(_ partition: DiskPartitionInfo) -> some View {
        if !partition.apfsVolumes.isEmpty {
            ForEach(partition.apfsVolumes) { volume in
                volumeRow(id: volume.deviceIdentifier, name: volume.name, fs: volume.filesystemName, size: volume.sizeBytes)
            }
        } else if let volume = partition.plainVolume {
            volumeRow(id: volume.deviceIdentifier, name: volume.name, fs: volume.filesystemName, size: volume.sizeBytes ?? partition.sizeBytes)
        } else {
            HStack {
                Text(partition.isFreeSpace ? "Free Space" : partition.content)
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(ByteFormat.string(partition.sizeBytes)).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func volumeRow(id: String, name: String, fs: String?, size: Int64?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline).bold()
                Text("\(id)\(fs.map { " · \($0)" } ?? "")").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if let size { Text(ByteFormat.string(size)).font(.caption).foregroundStyle(.tertiary) }
            Button("Erase…", role: .destructive) { pendingEraseVolume = EraseVolumeTarget(id: id, name: name) }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }

    private func runAction(name: String, _ action: @escaping () -> DiskUtilityActionResult) {
        isRunning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = action()
            DispatchQueue.main.async {
                isRunning = false
                lastOutput = result.output.isEmpty ? nil : result.output
                onActionComplete(result.succeeded ? "\(name) completed." : "\(name) failed — see details below.")
            }
        }
    }
}

// MARK: - Confirmation sheets

/// Requires typing the exact target name before the destructive button enables — the
/// same "type to confirm" pattern used for genuinely irreversible actions elsewhere
/// (e.g. GitHub's repo-delete flow), appropriate here since, unlike every other
/// destructive action in this app (Trash, Quarantine, Disable), there is no undo.
private struct MacEraseConfirmSheet: View {
    let title: String
    let targetName: String
    let warning: String
    let onConfirm: (String, MacDiskFormat) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var typedName = ""
    @State private var newName = "Untitled"
    @State private var format: MacDiskFormat = .apfs

    private var canConfirm: Bool { typedName == targetName && !newName.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2).bold()
            Text(warning).font(.callout).foregroundStyle(.red)

            Picker("New Format", selection: $format) {
                ForEach(MacDiskFormat.allCases) { f in Text(f.displayName).tag(f) }
            }
            TextField("New Volume Name", text: $newName).textFieldStyle(.roundedBorder)

            Divider()
            Text("Type the exact name \u{201C}\(targetName)\u{201D} to confirm:").font(.caption).foregroundStyle(.secondary)
            TextField(targetName, text: $typedName).textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(title, role: .destructive) {
                    onConfirm(newName, format)
                    dismiss()
                }
                .disabled(!canConfirm)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

private struct MacPartitionConfirmSheet: View {
    let disk: DiskInfo
    let onConfirm: ([(name: String, format: MacDiskFormat, sizeSpec: String)]) -> Void
    @Environment(\.dismiss) private var dismiss

    private struct Row: Identifiable { let id = UUID(); var name: String; var format: MacDiskFormat; var percent: Double }

    @State private var rows: [Row] = [
        Row(name: "Untitled 1", format: .apfs, percent: 50),
        Row(name: "Untitled 2", format: .apfs, percent: 50),
    ]
    @State private var typedName = ""

    private var totalPercent: Double { rows.reduce(0) { $0 + $1.percent } }
    private var canConfirm: Bool { typedName == disk.mediaName && !rows.isEmpty && rows.allSatisfy { !$0.name.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Partition Disk").font(.title2).bold()
            Text("This destroys ALL existing partitions and data on \(disk.deviceIdentifier) (\(disk.mediaName)) and replaces them with the partitions below. This cannot be undone.")
                .font(.callout).foregroundStyle(.red)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach($rows) { $row in
                        HStack(spacing: 8) {
                            TextField("Name", text: $row.name).frame(width: 130)
                            Picker("", selection: $row.format) {
                                ForEach(MacDiskFormat.allCases) { f in Text(f.displayName).tag(f) }
                            }.labelsHidden().frame(width: 170)
                            Slider(value: $row.percent, in: 1...100)
                            Text("\(Int(row.percent))%").font(.caption).frame(width: 36, alignment: .trailing)
                            Button {
                                rows.removeAll { $0.id == row.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .disabled(rows.count <= 1)
                        }
                    }
                }
            }
            .frame(maxHeight: 200)

            HStack {
                Button {
                    rows.append(Row(name: "Untitled \(rows.count + 1)", format: .apfs, percent: 10))
                } label: {
                    Label("Add Partition", systemImage: "plus")
                }
                Spacer()
                Text("Total: \(Int(totalPercent))%")
                    .font(.caption)
                    .foregroundStyle(totalPercent > 100 ? .red : .secondary)
            }
            if totalPercent > 100 {
                Text("Percentages add up to more than 100% — diskutil will report an error rather than silently adjusting them.")
                    .font(.caption2).foregroundStyle(.red)
            }

            Divider()
            Text("Type the exact disk name \u{201C}\(disk.mediaName)\u{201D} to confirm:").font(.caption).foregroundStyle(.secondary)
            TextField(disk.mediaName, text: $typedName).textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Partition Disk", role: .destructive) {
                    let partitions = rows.map { (name: $0.name, format: $0.format, sizeSpec: "\(Int($0.percent))%") }
                    onConfirm(partitions)
                    dismiss()
                }
                .disabled(!canConfirm)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }
}
