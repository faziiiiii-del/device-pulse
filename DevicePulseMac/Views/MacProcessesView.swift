//
//  MacProcessesView.swift
//  DevicePulseMac
//
//  Sortable process table: CPU, RAM, Network (real, via nettop), plus
//  GPU and Energy Impact shown honestly as unavailable — macOS has no
//  public, non-root API for per-process GPU usage or energy impact on
//  this system, so those columns are never faked.
//
//  Quit/Force Quit only ever act on regular, user-facing applications
//  (the same NSWorkspace-scoped population MacMemoryOptimizer already
//  uses) — never arbitrary background/system processes from the ps
//  listing, which could destabilize the Mac.
//

import Combine
import SwiftUI

private struct ProcessRow: Identifiable {
    let entry: ProcessInfoEntry
    let networkBytesPerSecond: Double
    var id: Int32 { entry.pid }
}

struct MacProcessesView: View {
    @State private var processes: [ProcessInfoEntry] = []
    @State private var networkRates: [Int32: Double] = [:]
    @State private var previousNetworkSample: (date: Date, totals: [Int32: (bytesIn: Int64, bytesOut: Int64)])?
    @State private var regularAppPIDs: Set<Int32> = []
    @State private var sortOrder = [KeyPathComparator(\ProcessRow.entry.cpuPercent, order: .reverse)]
    @State private var selection = Set<Int32>()
    @State private var pendingAction: (entry: ProcessInfoEntry, force: Bool)?
    @State private var actionError: String?

    private let processTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    private let networkTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    private var rows: [ProcessRow] {
        processes.map { ProcessRow(entry: $0, networkBytesPerSecond: networkRates[$0.pid] ?? 0) }
    }

    private var sortedRows: [ProcessRow] { rows.sorted(using: sortOrder) }

    private var selectedRow: ProcessRow? {
        guard let pid = selection.first else { return nil }
        return rows.first { $0.entry.pid == pid }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Processes").font(.largeTitle).bold()
                .padding([.horizontal, .top], 24)

            Table(sortedRows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Process", value: \.entry.name) { row in
                    HStack(spacing: 6) {
                        if regularAppPIDs.contains(row.entry.pid) {
                            Image(systemName: "app.fill").font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(row.entry.name)
                    }
                }
                TableColumn("CPU", value: \.entry.cpuPercent) { row in
                    Text(String(format: "%.1f%%", row.entry.cpuPercent))
                }
                TableColumn("RAM", value: \.entry.residentBytes) { row in
                    Text(ByteFormat.memoryString(row.entry.residentBytes))
                }
                TableColumn("GPU") { _ in
                    Text("—").foregroundStyle(.tertiary)
                }
                TableColumn("Network", value: \.networkBytesPerSecond) { row in
                    Text(row.networkBytesPerSecond > 0 ? rateString(row.networkBytesPerSecond) : "—")
                        .foregroundStyle(row.networkBytesPerSecond > 0 ? .primary : .tertiary)
                }
                TableColumn("Energy") { _ in
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 24)

            if let row = selectedRow {
                detailBar(for: row)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            } else {
                Text("Select a process to inspect or quit it. GPU and Energy Impact use Activity Monitor's private APIs, not exposed to non-root apps — shown as unavailable rather than guessed.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .onAppear {
            refreshProcesses()
            refreshNetwork()
            regularAppPIDs = MacProcessMonitor.regularAppPIDs()
        }
        .onReceive(processTimer) { _ in
            refreshProcesses()
            regularAppPIDs = MacProcessMonitor.regularAppPIDs()
        }
        .onReceive(networkTimer) { _ in refreshNetwork() }
        .alert(
            pendingAction.map { "\($0.force ? "Force Quit" : "Quit") \($0.entry.name)?" } ?? "",
            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } })
        ) {
            Button("Cancel", role: .cancel) { pendingAction = nil }
            Button(pendingAction?.force == true ? "Force Quit" : "Quit", role: .destructive) {
                if let action = pendingAction { performAction(action) }
                pendingAction = nil
            }
        } message: {
            if let action = pendingAction {
                Text(action.force
                    ? "This immediately terminates \(action.entry.name) without giving it a chance to save unsaved work."
                    : "This asks \(action.entry.name) to quit, the same as Cmd-Q — it may still prompt you about unsaved changes.")
            }
        }
        .alert(
            "Couldn't complete that",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    @ViewBuilder
    private func detailBar(for row: ProcessRow) -> some View {
        let entry = row.entry
        let quittable = regularAppPIDs.contains(entry.pid)
        MacCard(title: entry.name, systemImage: "info.circle", tint: MacSection.processes.tint) {
            VStack(alignment: .leading, spacing: 8) {
                MacInfoRow(label: "PID", value: "\(entry.pid)")
                MacInfoRow(label: "Path", value: entry.path)
                MacInfoRow(label: "CPU", value: String(format: "%.1f%%", entry.cpuPercent))
                MacInfoRow(label: "Memory", value: "\(ByteFormat.memoryString(entry.residentBytes)) (\(String(format: "%.1f%%", entry.memoryPercent)))")
                MacInfoRow(label: "Network", value: row.networkBytesPerSecond > 0 ? rateString(row.networkBytesPerSecond) : "No recent activity")

                if !quittable {
                    Text("Background or system process — quitting isn't offered here, to avoid destabilizing macOS. Only regular, user-facing apps can be quit from Processes.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Quit") { pendingAction = (entry, false) }
                        .buttonStyle(.bordered)
                        .disabled(!quittable)
                    Button("Force Quit") { pendingAction = (entry, true) }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .disabled(!quittable)
                }
            }
        }
    }

    private func rateString(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1024 { return String(format: "%.0f B/s", bytesPerSecond) }
        let kb = bytesPerSecond / 1024
        if kb < 1024 { return String(format: "%.1f KB/s", kb) }
        return String(format: "%.1f MB/s", kb / 1024)
    }

    private func performAction(_ action: (entry: ProcessInfoEntry, force: Bool)) {
        let candidates = MacMemoryOptimizer.quitCandidates(processes: processes)
        guard let candidate = candidates.first(where: { $0.app.processIdentifier == action.entry.pid }) else {
            actionError = "\(action.entry.name) is no longer running, or can't be quit from here."
            return
        }
        let success = action.force ? MacMemoryOptimizer.forceQuit(candidate) : MacMemoryOptimizer.quit(candidate)
        if !success {
            actionError = "Couldn't \(action.force ? "force quit" : "quit") \(action.entry.name)."
        }
    }

    private func refreshProcesses() {
        DispatchQueue.global(qos: .utility).async {
            let list = MacProcessMonitor.snapshot()
            DispatchQueue.main.async { processes = list }
        }
    }

    private func refreshNetwork() {
        DispatchQueue.global(qos: .utility).async {
            let totals = MacProcessMonitor.networkTotals()
            let now = Date()
            DispatchQueue.main.async {
                if let previous = previousNetworkSample {
                    let elapsed = now.timeIntervalSince(previous.date)
                    if elapsed > 0 {
                        var rates: [Int32: Double] = [:]
                        for (pid, current) in totals {
                            if let prior = previous.totals[pid] {
                                let deltaBytes = Double((current.bytesIn - prior.bytesIn) + (current.bytesOut - prior.bytesOut))
                                rates[pid] = max(0, deltaBytes / elapsed)
                            }
                        }
                        networkRates = rates
                    }
                }
                previousNetworkSample = (now, totals)
            }
        }
    }
}
