//
//  MacDiskUtilityView.swift
//  DevicePulseMac
//
//  Erase/format/partition/mount/verify/repair any disk via
//  DiskOperationService — no restriction by disk type, including
//  internal disks, per an explicit product decision. What protects the
//  boot disk here is NOT "diskutil will refuse it": DiskOperationService
//  hard-blocks any destructive action against the disk hosting the
//  current boot volume itself, in-app, before any process even runs —
//  diskutil's own refusal is a real, independent second layer, not the
//  mechanism this UI relies on. Every erase/partition action also
//  requires typing an exact confirmation phrase plus a checkbox, since
//  unlike every other destructive action already in this app (Trash,
//  Quarantine, Disable), there is no undo here at all.
//

import SwiftUI

struct MacDiskUtilityView: View {
    @State private var disks: [DiskInfo] = []
    @State private var isLoading = true
    @State private var selectedDisk: DiskInfo?
    @State private var toastMessage: String?
    @State private var showAuditLog = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Disk Utility").font(.largeTitle).bold()
                        Text("Erase, format, partition, and repair disks — the same diskutil operations Apple's own Disk Utility uses. Every action here is permanent and cannot be undone once it runs.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { load() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .accessibilityLabel("Refresh disk list")
                    Button { showAuditLog = true } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                        .accessibilityLabel("Show operation history")
                }

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
        .onAppear {
            load()
            registerVolumeChangeObservers()
        }
        .onDisappear { removeVolumeChangeObservers() }
        .sheet(item: $selectedDisk) { disk in
            MacDiskDetailSheet(disk: disk, onActionComplete: { message in
                toastMessage = message
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { toastMessage = nil }
                load()
            })
        }
        .sheet(isPresented: $showAuditLog) {
            MacDiskAuditLogSheet()
        }
    }

    // MARK: - Disk card (hierarchy overview)

    private func diskCard(_ disk: DiskInfo) -> some View {
        MacCard(title: disk.mediaName, systemImage: disk.isInternal ? "internaldrive" : "externaldrive", tint: MacSection.diskUtility.tint) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            badge(disk.deviceIdentifier)
                            badge(ByteFormat.string(disk.totalSizeBytes))
                            badge(disk.isInternal ? "Internal" : "External")
                            if disk.isRemovable { badge("Removable") }
                            if let proto = disk.busProtocol { badge(proto) }
                            if disk.isSolidState == true { badge("SSD") }
                        }
                        if disk.containsBootVolume {
                            Label("BOOT DISK — PROTECTED", systemImage: "lock.shield.fill")
                                .font(.caption.bold()).foregroundStyle(.orange)
                                .accessibilityLabel("This disk hosts your current startup volume and is protected from destructive operations")
                        }
                        if let smart = disk.smart {
                            Label(smart.label, systemImage: smart.level == .good ? "checkmark.circle" : "exclamationmark.triangle")
                                .font(.caption2).foregroundStyle(smart.level.color)
                        }
                    }
                    Spacer()
                    Button("Manage…") { selectedDisk = disk }.buttonStyle(.bordered).controlSize(.small)
                }

                // Hierarchy preview: partition map, one row per partition, APFS volumes nested.
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(disk.partitions) { partition in
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.tertiary)
                            Text(partition.kind).font(.caption).foregroundStyle(.secondary)
                            Text(ByteFormat.string(partition.sizeBytes)).font(.caption2).foregroundStyle(.tertiary)
                        }
                        ForEach(partition.apfsVolumes) { vol in
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.clear)
                                Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.tertiary)
                                Text(vol.name).font(.caption).bold()
                                Text(vol.role.label).font(.caption2).foregroundStyle(.tertiary)
                                if let size = vol.sizeBytes { Text(ByteFormat.string(size)).font(.caption2).foregroundStyle(.tertiary) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
            .background(.secondary.opacity(0.15)).clipShape(Capsule())
    }

    private func load() {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let result = DiskDiscoveryService.listDisks()
            await MainActor.run {
                disks = result
                isLoading = false
            }
        }
    }

    // MARK: - Auto-refresh on volume mount/unmount (NSWorkspace notifications — public API,
    // no extra entitlement; simpler and sufficient vs. raw DiskArbitration callbacks for
    // this use case, which only needs "something changed, rescan").

    @State private var mountObserver: NSObjectProtocol?
    @State private var unmountObserver: NSObjectProtocol?
    @State private var renameObserver: NSObjectProtocol?

    private func registerVolumeChangeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        mountObserver = center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { _ in load() }
        unmountObserver = center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { _ in load() }
        renameObserver = center.addObserver(forName: NSWorkspace.didRenameVolumeNotification, object: nil, queue: .main) { _ in load() }
    }

    private func removeVolumeChangeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        [mountObserver, unmountObserver, renameObserver].compactMap { $0 }.forEach(center.removeObserver)
    }
}

// MARK: - Disk detail sheet

private struct VolumeActionTarget: Identifiable { let id: String; let name: String; let mountPoint: String? }

private struct MacDiskDetailSheet: View {
    let disk: DiskInfo
    let onActionComplete: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var pendingEraseDisk = false
    @State private var pendingPartition = false
    @State private var pendingEraseVolume: DiskVolumeInfo?
    @State private var pendingRename: VolumeActionTarget?
    @State private var operationHandle: DiskOperationHandle?
    @State private var showAdvancedInfo = false

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
                Label("BOOT DISK — PROTECTED. Device Pulse blocks erase/partition actions against this disk.", systemImage: "lock.shield.fill")
                    .font(.caption.bold()).foregroundStyle(.orange)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(disk.partitions) { partition in
                        partitionRow(partition)
                        if partition.id != disk.partitions.last?.id { Divider() }
                    }
                }
            }
            .frame(maxHeight: 240)

            Divider()

            HStack(spacing: 10) {
                if !disk.containsBootVolume {
                    Button(role: .destructive) { pendingEraseDisk = true } label: {
                        Label("Erase Whole Disk…", systemImage: "trash")
                    }
                    Button { pendingPartition = true } label: {
                        Label("Partition Disk…", systemImage: "square.split.2x1")
                    }
                }
                if !disk.isInternal {
                    Button { startOperation(title: "Eject", plannedSteps: ["Unmount and eject"]) { handle in
                        await DiskOperationService.eject(disk, handle: handle)
                    } } label: { Label("Eject", systemImage: "eject") }
                }
                Button { showAdvancedInfo = true } label: { Label("Advanced Info…", systemImage: "info.circle") }
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 620, height: 640)
        .sheet(isPresented: $pendingEraseDisk) {
            MacFormatConfirmSheet(
                title: "Erase Whole Disk",
                targetName: disk.mediaName,
                targetDeviceID: disk.deviceIdentifier,
                warning: "This destroys ALL partitions and ALL data on \(disk.deviceIdentifier) (\(disk.mediaName)) — every volume on it, permanently.",
                onConfirm: { newName, format, passphrase in
                    startOperation(title: "Erase Disk", plannedSteps: format.needsPassphrase ? ["Validate disk identity", "Erase disk", "Encrypt new volume"] : ["Validate disk identity", "Erase disk"]) { handle in
                        await DiskOperationService.eraseDisk(disk, newName: newName, format: format, passphrase: passphrase, handle: handle)
                    }
                }
            )
        }
        .sheet(isPresented: $pendingPartition) {
            MacPartitionConfirmSheet(disk: disk) { partitions in
                startOperation(title: "Partition Disk", plannedSteps: ["Validate disk identity", "Partition disk"]) { handle in
                    await DiskOperationService.partitionDisk(disk, partitions: partitions, handle: handle)
                }
            }
        }
        .sheet(item: $pendingEraseVolume) { target in
            MacFormatConfirmSheet(
                title: "Erase Volume",
                targetName: target.name,
                targetDeviceID: target.deviceIdentifier,
                warning: "This destroys all data on \u{201C}\(target.name)\u{201D} (\(target.deviceIdentifier)), permanently. Other partitions on this disk are not affected.",
                onConfirm: { newName, format, passphrase in
                    startOperation(title: "Erase Volume", plannedSteps: format.needsPassphrase ? ["Validate volume identity", "Erase volume", "Encrypt new volume"] : ["Validate volume identity", "Erase volume"]) { handle in
                        await DiskOperationService.eraseVolume(target, newName: newName, format: format, passphrase: passphrase, handle: handle)
                    }
                }
            )
        }
        .sheet(item: $pendingRename) { target in
            MacRenameSheet(currentName: target.name) { newName in
                startOperation(title: "Rename Volume", plannedSteps: ["Rename volume"]) { handle in
                    await DiskOperationService.rename(deviceIdentifier: target.id, oldName: target.name, newName: newName, handle: handle)
                }
            }
        }
        .sheet(isPresented: $showAdvancedInfo) {
            MacAdvancedInfoSheet(disk: disk)
        }
        .sheet(item: $operationHandle) { handle in
            MacOperationConsoleView(handle: handle) {
                operationHandle = nil
                onActionComplete(handle.summary.isEmpty ? (handle.succeeded ? "Completed." : "Failed.") : handle.summary)
            }
        }
    }

    @ViewBuilder
    private func partitionRow(_ partition: DiskPartitionInfo) -> some View {
        if partition.isEFI {
            HStack {
                Text("EFI").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(ByteFormat.string(partition.sizeBytes)).font(.caption).foregroundStyle(.tertiary)
            }
        } else if !partition.apfsVolumes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("APFS Container · \(ByteFormat.string(partition.sizeBytes))").font(.caption).foregroundStyle(.secondary)
                ForEach(partition.apfsVolumes) { volume in
                    volumeRow(volume)
                }
            }
        } else if let volume = partition.plainVolume {
            volumeRow(DiskVolumeInfo(
                deviceIdentifier: volume.deviceIdentifier, name: volume.name, sizeBytes: volume.sizeBytes ?? partition.sizeBytes,
                freeBytes: volume.freeBytes, filesystemName: volume.filesystemName, mountPoint: volume.mountPoint,
                volumeUUID: volume.volumeUUID, role: volume.role, encryption: volume.encryption, isBootVolume: volume.isBootVolume
            ))
        } else {
            HStack {
                Text(partition.isFreeSpace ? "Free Space" : partition.content).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(ByteFormat.string(partition.sizeBytes)).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func volumeRow(_ volume: DiskVolumeInfo) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(volume.name).font(.subheadline).bold()
                    if volume.isBootVolume {
                        Label("BOOT", systemImage: "lock.shield.fill").font(.caption2.bold()).foregroundStyle(.orange)
                    }
                }
                Text("\(volume.deviceIdentifier)\(volume.filesystemName.map { " · \($0)" } ?? "")\(volume.mountPoint.map { " · \($0)" } ?? " · Not mounted")")
                    .font(.caption2).foregroundStyle(.secondary)
                if let size = volume.sizeBytes {
                    spaceBar(used: size, free: volume.freeBytes)
                }
                Text(volume.encryption.label).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    if volume.mountPoint == nil {
                        Button("Mount") { startOperation(title: "Mount", plannedSteps: ["Mount volume"]) { handle in
                            await DiskOperationService.mount(deviceIdentifier: volume.deviceIdentifier, name: volume.name, handle: handle)
                        } }.buttonStyle(.bordered).controlSize(.small)
                    } else if !volume.isBootVolume {
                        Button("Unmount") { startOperation(title: "Unmount", plannedSteps: ["Unmount volume"]) { handle in
                            await DiskOperationService.unmount(deviceIdentifier: volume.deviceIdentifier, name: volume.name, force: false, handle: handle)
                        } }.buttonStyle(.bordered).controlSize(.small)
                    }
                    Button("Verify") { startOperation(title: "Verify", plannedSteps: ["Verify volume"]) { handle in
                        await DiskOperationService.verify(deviceIdentifier: volume.deviceIdentifier, name: volume.name, handle: handle)
                    } }.buttonStyle(.bordered).controlSize(.small)
                }
                HStack(spacing: 6) {
                    if !volume.isBootVolume {
                        Button("Repair") { startOperation(title: "Repair", plannedSteps: ["Repair volume"]) { handle in
                            await DiskOperationService.repair(deviceIdentifier: volume.deviceIdentifier, name: volume.name, handle: handle)
                        } }.buttonStyle(.bordered).controlSize(.small)
                        Button("Rename") { pendingRename = VolumeActionTarget(id: volume.deviceIdentifier, name: volume.name, mountPoint: volume.mountPoint) }
                            .buttonStyle(.bordered).controlSize(.small)
                        Button("Erase…", role: .destructive) { pendingEraseVolume = volume }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(volume.name), \(volume.filesystemName ?? "unknown format")\(volume.isBootVolume ? ", boot volume, protected" : "")")
    }

    private func spaceBar(used: Int64, free: Int64?) -> some View {
        let total = used + (free ?? 0)
        let fraction = total > 0 ? Double(used) / Double(total) : 0
        return VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.2))
                    Capsule().fill(Color.accentColor).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 6)
            if let free {
                Text("Used: \(ByteFormat.string(used)) · Free: \(ByteFormat.string(free))").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func startOperation(title: String, plannedSteps: [String], _ action: @escaping (DiskOperationHandle) async -> Void) {
        let handle = DiskOperationHandle(title: title, plannedSteps: plannedSteps)
        operationHandle = handle
        Task { await action(handle) }
    }
}

// MARK: - Operation console

private struct MacOperationConsoleView: View {
    @ObservedObject var handle: DiskOperationHandle
    let onDone: () -> Void
    @State private var showDiagnostics = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(handle.title).font(.title2).bold()
            Text(handle.stage.label).font(.callout).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(handle.steps) { step in
                    HStack(spacing: 8) {
                        stepIcon(step.state)
                        Text(step.label).font(.callout)
                    }
                }
            }

            if handle.isFinished {
                Label(handle.summary, systemImage: handle.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(handle.succeeded ? .green : .red)
                    .font(.callout.bold())
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Working…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { handle.cancel() }
                }
            }

            DisclosureGroup("Show Diagnostic Output", isExpanded: $showDiagnostics) {
                ScrollView {
                    Text(handle.liveOutput.isEmpty ? "(no output)" : handle.liveOutput)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
            .font(.caption)

            HStack {
                Spacer()
                Button(handle.isFinished ? "Done" : "Close") { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 420)
    }

    @ViewBuilder
    private func stepIcon(_ state: DiskOperationStep.State) -> some View {
        switch state {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

// MARK: - Format / erase confirmation

/// Requires typing a generated confirmation phrase AND a checkbox before the destructive
/// button enables — stronger than a plain name-match, since unlike every other
/// destructive action already in this app (Trash, Quarantine, Disable), there is no undo.
private struct MacFormatConfirmSheet: View {
    let title: String
    let targetName: String
    let targetDeviceID: String
    let warning: String
    let onConfirm: (String, MacDiskFormat, String?) -> Void
    @Environment(\.dismiss) private var dismiss

    private var confirmationPhrase: String { "ERASE \(targetName.uppercased())" }

    @State private var typedPhrase = ""
    @State private var acknowledged = false
    @State private var newName = "Untitled"
    @State private var format: MacDiskFormat = .apfs
    @State private var passphrase = ""
    @State private var confirmPassphrase = ""

    private var passphraseOK: Bool { !format.needsPassphrase || (!passphrase.isEmpty && passphrase == confirmPassphrase) }
    private var canConfirm: Bool { typedPhrase == confirmationPhrase && acknowledged && !newName.isEmpty && passphraseOK }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2).bold()
            VStack(alignment: .leading, spacing: 4) {
                Text("You are about to erase:").font(.callout)
                Text("\(targetName) (\(targetDeviceID))").font(.callout.bold())
            }
            Text(warning).font(.callout).foregroundStyle(.red)

            Picker("Format", selection: $format) {
                ForEach(MacDiskFormat.allCases) { f in Text(f.displayName).tag(f) }
            }
            Text(format.explanation).font(.caption2).foregroundStyle(.secondary)

            TextField("New Volume Name", text: $newName).textFieldStyle(.roundedBorder)

            if format.needsPassphrase {
                SecureField("Passphrase", text: $passphrase).textFieldStyle(.roundedBorder)
                SecureField("Confirm Passphrase", text: $confirmPassphrase).textFieldStyle(.roundedBorder)
                if !confirmPassphrase.isEmpty && passphrase != confirmPassphrase {
                    Text("Passphrases don't match.").font(.caption2).foregroundStyle(.red)
                }
            }

            Divider()
            Text("Type \u{201C}\(confirmationPhrase)\u{201D} to confirm:").font(.caption).foregroundStyle(.secondary)
            TextField(confirmationPhrase, text: $typedPhrase).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Type the confirmation phrase \(confirmationPhrase) to enable the erase button")

            Toggle("I understand that all data on this disk will be permanently destroyed.", isOn: $acknowledged)
                .font(.caption)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(title, role: .destructive) {
                    onConfirm(newName, format, format.needsPassphrase ? passphrase : nil)
                    dismiss()
                }
                .disabled(!canConfirm)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - Partition manager

private struct MacPartitionConfirmSheet: View {
    let disk: DiskInfo
    let onConfirm: ([(name: String, format: MacDiskFormat, sizeSpec: String)]) -> Void
    @Environment(\.dismiss) private var dismiss

    private struct Row: Identifiable {
        let id = UUID()
        var name: String
        var format: MacDiskFormat
        /// nil means "Remaining" — at most one row may have this, matching diskutil's
        /// own "R" sentinel for "everything left over".
        var gigabytes: Double?
    }

    @State private var rows: [Row] = [
        Row(name: "DATA", format: .apfs, gigabytes: nil),
    ]
    @State private var typedPhrase = ""
    @State private var acknowledged = false

    private var totalDiskGB: Double { Double(disk.totalSizeBytes) / 1_000_000_000 }
    private var allocatedGB: Double { rows.compactMap { $0.gigabytes }.reduce(0, +) }
    private var remainingCount: Int { rows.filter { $0.gigabytes == nil }.count }
    private var confirmationPhrase: String { "PARTITION \(disk.mediaName.uppercased())" }

    private var validationError: String? {
        if rows.isEmpty { return "Add at least one partition." }
        if rows.contains(where: { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }) { return "Every partition needs a name." }
        if remainingCount > 1 { return "Only one partition can use \u{201C}Remaining\u{201D}." }
        if allocatedGB > totalDiskGB + 0.01 { return "Total size (\(String(format: "%.1f", allocatedGB)) GB) exceeds the disk's capacity (\(String(format: "%.1f", totalDiskGB)) GB)." }
        if rows.contains(where: { ($0.gigabytes ?? 1) <= 0 }) { return "Every partition needs a size greater than 0." }
        return nil
    }

    private var canConfirm: Bool { validationError == nil && typedPhrase == confirmationPhrase && acknowledged }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Partition Disk").font(.title2).bold()
            Text("This destroys ALL existing partitions and data on \(disk.deviceIdentifier) (\(disk.mediaName)) and replaces them with the layout below.")
                .font(.callout).foregroundStyle(.red)

            // Visual partition map preview.
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(rows) { row in
                        let gb = row.gigabytes ?? max(totalDiskGB - allocatedGB, 0)
                        let fraction = totalDiskGB > 0 ? gb / totalDiskGB : 0
                        VStack(spacing: 2) {
                            Text(row.name).font(.caption2).lineLimit(1)
                        }
                        .frame(width: max(geo.size.width * fraction, 4), height: 36)
                        .background(Color.accentColor.opacity(0.25))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1))
                    }
                }
            }
            .frame(height: 36)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach($rows) { $row in
                        HStack(spacing: 8) {
                            TextField("Name", text: $row.name).frame(width: 120)
                            Picker("", selection: $row.format) {
                                ForEach(MacDiskFormat.allCases) { f in Text(f.displayName).tag(f) }
                            }.labelsHidden().frame(width: 170)
                            if row.gigabytes == nil {
                                Text("Remaining").font(.caption).foregroundStyle(.secondary).frame(width: 90)
                            } else {
                                TextField("GB", value: Binding(
                                    get: { row.gigabytes ?? 0 },
                                    set: { row.gigabytes = $0 }
                                ), format: .number).frame(width: 60)
                                Text("GB").font(.caption).foregroundStyle(.secondary)
                            }
                            // Selecting "Remaining" on a second row isn't blocked here — it's
                            // caught by validationError ("Only one partition can use
                            // \u{201C}Remaining\u{201D}") instead, which is clearer feedback
                            // than a silently-disabled checkbox would be.
                            Toggle("Remaining", isOn: Binding(
                                get: { row.gigabytes == nil },
                                set: { isRemaining in row.gigabytes = isRemaining ? nil : max(totalDiskGB - allocatedGB, 1) }
                            )).toggleStyle(.checkbox).font(.caption)
                            Button {
                                rows.removeAll { $0.id == row.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .disabled(rows.count <= 1)
                            .accessibilityLabel("Remove partition \(row.name)")
                        }
                    }
                }
            }
            .frame(maxHeight: 180)

            HStack {
                Button {
                    rows.append(Row(name: "Untitled \(rows.count + 1)", format: .apfs, gigabytes: max(totalDiskGB - allocatedGB, 1)))
                } label: {
                    Label("Add Partition", systemImage: "plus")
                }
                Spacer()
                Text("Allocated: \(String(format: "%.1f", allocatedGB)) GB of \(String(format: "%.1f", totalDiskGB)) GB")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let validationError {
                Text(validationError).font(.caption2).foregroundStyle(.red)
            }

            Divider()
            Text("Type \u{201C}\(confirmationPhrase)\u{201D} to confirm:").font(.caption).foregroundStyle(.secondary)
            TextField(confirmationPhrase, text: $typedPhrase).textFieldStyle(.roundedBorder)
            Toggle("I understand that all data on this disk will be permanently destroyed.", isOn: $acknowledged).font(.caption)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Partition Disk", role: .destructive) {
                    let partitions = rows.map { row -> (name: String, format: MacDiskFormat, sizeSpec: String) in
                        let sizeSpec = row.gigabytes.map { "\(String(format: "%.2f", $0))G" } ?? "R"
                        return (row.name, row.format, sizeSpec)
                    }
                    onConfirm(partitions)
                    dismiss()
                }
                .disabled(!canConfirm)
            }
        }
        .padding(20)
        .frame(width: 600, height: 560)
    }
}

// MARK: - Rename

private struct MacRenameSheet: View {
    let currentName: String
    let onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var newName: String

    init(currentName: String, onConfirm: @escaping (String) -> Void) {
        self.currentName = currentName
        self.onConfirm = onConfirm
        _newName = State(initialValue: currentName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Volume").font(.title2).bold()
            TextField("Volume Name", text: $newName).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Rename") { onConfirm(newName); dismiss() }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || newName == currentName)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

// MARK: - Advanced info

private struct MacAdvancedInfoSheet: View {
    let disk: DiskInfo
    @Environment(\.dismiss) private var dismiss

    private var technicalText: String {
        var lines = [
            "Model: \(disk.mediaName)",
            "BSD Identifier: \(disk.deviceIdentifier)",
            "Capacity: \(ByteFormat.string(disk.totalSizeBytes))",
            "Protocol: \(disk.busProtocol ?? "Unknown")",
            "Connection: \(disk.isInternal ? "Internal" : "External")",
            "Removable: \(disk.isRemovable ? "Yes" : "No")",
            "Solid State: \(disk.isSolidState.map { $0 ? "Yes" : "No" } ?? "Unknown")",
            "Partition Map: \(disk.partitionScheme ?? "Unknown")",
            "SMART: \(disk.smart?.label ?? "Unavailable")",
            "Disk UUID: \(disk.mediaUUID ?? "Unknown")",
        ]
        for partition in disk.partitions {
            lines.append("")
            lines.append("Partition \(partition.deviceIdentifier): \(partition.kind), \(ByteFormat.string(partition.sizeBytes))")
            if let containerUUID = partition.containerUUID { lines.append("  Container UUID: \(containerUUID)") }
            for vol in partition.apfsVolumes {
                lines.append("  Volume \(vol.deviceIdentifier): \(vol.name) (\(vol.role.label))")
                lines.append("    Volume UUID: \(vol.volumeUUID ?? "Unknown")")
                lines.append("    Encryption: \(vol.encryption.label)")
                lines.append("    Mount Point: \(vol.mountPoint ?? "Not mounted")")
            }
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Device Information").font(.title2).bold()
                Spacer()
                Button("Done") { dismiss() }
            }
            ScrollView {
                Text(technicalText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(technicalText, forType: .string)
                } label: {
                    Label("Copy Technical Information", systemImage: "doc.on.doc")
                }
            }
        }
        .padding(20)
        .frame(width: 480, height: 520)
    }
}

// MARK: - Audit log

private struct MacDiskAuditLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [DiskUtilityAuditEntry] = DiskUtilityAuditLog.all()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Operation History").font(.title2).bold()
                Spacer()
                Button("Clear History") {
                    DiskUtilityAuditLog.clear()
                    entries = []
                }
                .disabled(entries.isEmpty)
                Button("Done") { dismiss() }
            }
            if entries.isEmpty {
                Text("No operations recorded yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(entries) { entry in
                            HStack(alignment: .top) {
                                Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(entry.succeeded ? .green : .red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(entry.title) — \(entry.target)").font(.subheadline).bold()
                                    Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                                    if let note = entry.note { Text(note).font(.caption2).foregroundStyle(.secondary) }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            if entry.id != entries.last?.id { Divider() }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 460, height: 480)
    }
}
