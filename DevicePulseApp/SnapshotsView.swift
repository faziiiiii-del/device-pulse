//
//  SnapshotsView.swift
//  DevicePulse
//
//  Manually-saved, full-detail points in time, compared side by side.
//  Stored locally only (SnapshotStore).
//

import SwiftUI

struct SnapshotsView: View {
    @StateObject private var battery = BatteryMonitor()
    @StateObject private var thermal = ThermalMonitor()
    @StateObject private var memoryPressure = MemoryPressureMonitor()
    @StateObject private var network = NetworkMonitor()

    @State private var snapshots: [DeviceSnapshot] = []
    @State private var selectedA: DeviceSnapshot?
    @State private var selectedB: DeviceSnapshot?
    @State private var labelText = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                StatCard(title: "Save a Snapshot", systemImage: "camera") {
                    TextField("Label (optional, e.g. \"Before update\")", text: $labelText)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        saveSnapshot()
                    } label: {
                        Label("Save Snapshot Now", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

                if snapshots.count >= 2 {
                    StatCard(title: "Compare", systemImage: "arrow.left.arrow.right") {
                        Picker("Before", selection: $selectedA) {
                            Text("Select…").tag(Optional<DeviceSnapshot>.none)
                            ForEach(snapshots) { snap in
                                Text(label(for: snap)).tag(Optional(snap))
                            }
                        }
                        Picker("Now / After", selection: $selectedB) {
                            Text("Select…").tag(Optional<DeviceSnapshot>.none)
                            ForEach(snapshots) { snap in
                                Text(label(for: snap)).tag(Optional(snap))
                            }
                        }
                    }

                    if let a = selectedA, let b = selectedB, a.id != b.id {
                        StatCard(title: "Changes", systemImage: "list.bullet.clipboard") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(diffLines(a, b), id: \.self) { line in
                                    Text("• " + line).font(.subheadline)
                                }
                            }
                        }
                    }
                }

                StatCard(title: "Saved Snapshots", systemImage: "tray.full") {
                    if snapshots.isEmpty {
                        Text("No snapshots yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(snapshots) { snap in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(label(for: snap)).font(.subheadline).bold()
                                        Text(snap.timestamp.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button(role: .destructive) {
                                        SnapshotStore.shared.delete(snap.id)
                                        snapshots = SnapshotStore.shared.all()
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                }
                                .padding(.vertical, 6)
                                if snap.id != snapshots.last?.id { Divider() }
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Snapshots")
        .onAppear { snapshots = SnapshotStore.shared.all() }
    }

    private func saveSnapshot() {
        let cache = AppCacheManager.cachesDirectorySize()
        let temp = AppCacheManager.tempDirectorySize()
        let label = labelText.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = SnapshotStore.captureNow(
            battery: battery, thermal: thermal, memoryPressure: memoryPressure, network: network,
            cacheSize: cache, tempSize: temp,
            label: label.isEmpty ? "Snapshot" : label
        )
        SnapshotStore.shared.save(snapshot)
        snapshots = SnapshotStore.shared.all()
        labelText = ""
    }

    private func label(for snap: DeviceSnapshot) -> String {
        "\(snap.label) — \(snap.timestamp.formatted(date: .abbreviated, time: .shortened))"
    }

    private func diffLines(_ a: DeviceSnapshot, _ b: DeviceSnapshot) -> [String] {
        var lines: [String] = []

        if let la = a.batteryLevel, let lb = b.batteryLevel {
            let delta = Int((lb - la) * 100)
            if delta != 0 {
                lines.append("Battery \(delta > 0 ? "increased" : "decreased") by \(abs(delta))% (\(Int(la * 100))% → \(Int(lb * 100))%).")
            } else {
                lines.append("Battery unchanged at \(Int(lb * 100))%.")
            }
        }

        if let sa = a.storageUsed, let sb = b.storageUsed {
            let delta = sb - sa
            if delta != 0 {
                lines.append("Storage used \(delta > 0 ? "increased" : "decreased") by \(ByteFormat.string(abs(delta))).")
            } else {
                lines.append("Storage used unchanged.")
            }
        }

        if let ma = a.memoryUsed, let mb = b.memoryUsed {
            let delta = Int64(mb) - Int64(ma)
            lines.append("Memory used \(delta > 0 ? "increased" : delta < 0 ? "decreased" : "unchanged by") \(ByteFormat.string(abs(delta))).")
        }

        if a.thermalState != b.thermalState {
            lines.append("Thermal state changed from \(a.thermalState ?? "?") to \(b.thermalState ?? "?").")
        }

        if a.networkType != b.networkType {
            lines.append("Network changed from \(a.networkType ?? "?") to \(b.networkType ?? "?").")
        }

        if let ca = a.appCacheSize, let cb = b.appCacheSize, ca != cb {
            lines.append("This app's cache changed by \(ByteFormat.string(cb - ca)).")
        }

        if lines.isEmpty {
            lines.append("No meaningful differences between these two snapshots.")
        }
        return lines
    }
}

extension DeviceSnapshot: Hashable {
    static func == (lhs: DeviceSnapshot, rhs: DeviceSnapshot) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

#Preview {
    NavigationStack { SnapshotsView() }
}
