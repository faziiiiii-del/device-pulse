//
//  MacRAMOptimiserView.swift
//  DevicePulseMac
//

import SwiftUI

private struct MemorySnapshot {
    let stats: MacMemoryStats
    let swap: SwapStats?
    let pressure: MacMemoryMonitor.PressureLevel
}

struct MacRAMOptimiserView: View {
    @State private var before: MemorySnapshot?
    @State private var after: MemorySnapshot?
    @State private var findings: [MemoryFinding] = []
    @State private var candidates: [QuitCandidate] = []
    @State private var selectedPIDs: Set<pid_t> = []
    @State private var isAnalyzing = false
    @State private var isOptimising = false
    @State private var pendingConfirmation: QuitCandidate?
    @State private var confirmBatch = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("RAM Optimiser").font(.largeTitle).bold()
                Text("This identifies what's using memory and lets you choose what to quit. macOS already manages memory (paging, compression, reclaiming caches) better than any background \"cleaner\" trick — there is no legitimate always-on memory purge this app can trigger, and it won't pretend to.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                statusCard

                MacCard(title: "Analyse Memory", systemImage: "magnifyingglass", tint: MacSection.ramOptimiser.tint) {
                    Button {
                        analyze()
                    } label: {
                        if isAnalyzing {
                            HStack { ProgressView().controlSize(.small); Text("Analysing…") }
                        } else {
                            Label("Analyse Memory", systemImage: "wand.and.stars")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isAnalyzing)

                    if !findings.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(findings) { finding in
                                HStack(alignment: .top) {
                                    StatusBadge(status: finding.severity)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(finding.title).font(.subheadline).bold()
                                        Text(finding.detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                if !candidates.isEmpty {
                    quitCandidatesCard
                }

                if let before, let after {
                    beforeAfterCard(before: before, after: after)
                }
            }
            .padding(24)
        }
        .alert("Quit \(pendingConfirmation?.app.localizedName ?? "this app")?", isPresented: Binding(get: { pendingConfirmation != nil }, set: { if !$0 { pendingConfirmation = nil } })) {
            Button("Cancel", role: .cancel) { pendingConfirmation = nil }
            Button("Quit", role: .destructive) {
                if let candidate = pendingConfirmation {
                    _ = MacMemoryOptimizer.quit(candidate)
                }
                pendingConfirmation = nil
            }
        } message: {
            Text("This asks the app to quit normally (like Cmd-Q). It may prompt you to save unsaved work.")
        }
        .alert("Quit \(selectedPIDs.count) selected app\(selectedPIDs.count == 1 ? "" : "s")?", isPresented: $confirmBatch) {
            Button("Cancel", role: .cancel) {}
            Button("Quit Selected", role: .destructive) { performOptimise() }
        } message: {
            Text("Each selected app will be asked to quit normally. Unsaved work may prompt you before it closes.")
        }
    }

    private var statusCard: some View {
        MacCard(title: "Memory Status", systemImage: "memorychip", tint: MacSection.ramOptimiser.tint) {
            if let snapshot = before ?? currentSnapshot() {
                MacUsageBar(
                    usedLabel: "Used \(ByteFormat.memoryString(snapshot.stats.used))",
                    totalLabel: "of \(ByteFormat.memoryString(snapshot.stats.total))",
                    fraction: snapshot.stats.usedFraction,
                    tint: .purple
                )
                HStack(spacing: 20) {
                    MacMiniStat(label: "Available", value: ByteFormat.memoryString(snapshot.stats.free))
                    MacMiniStat(label: "Compressed", value: ByteFormat.memoryString(snapshot.stats.compressed))
                    MacMiniStat(label: "Swap", value: snapshot.swap.map { ByteFormat.memoryString($0.used) } ?? "Unavailable")
                    MacMiniStat(label: "Pressure", value: snapshot.pressure.rawValue)
                }
            } else {
                Text("Reading memory…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var quitCandidatesCard: some View {
        MacCard(title: "Top Memory Users", systemImage: "list.bullet", tint: MacSection.ramOptimiser.tint) {
            Text("Select apps to quit. Only regular, user-facing applications are listed — never background system processes.")
                .font(.caption2).foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(candidates.prefix(15)) { candidate in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { selectedPIDs.contains(candidate.id) },
                            set: { isOn in
                                if isOn { selectedPIDs.insert(candidate.id) } else { selectedPIDs.remove(candidate.id) }
                            }
                        )) {
                            Text(candidate.app.localizedName ?? "Unknown")
                        }
                        Spacer()
                        Text(ByteFormat.memoryString(candidate.residentBytes)).font(.subheadline).bold()
                        Button("Quit…") { pendingConfirmation = candidate }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                    if candidate.id != candidates.prefix(15).last?.id { Divider() }
                }
            }

            Button {
                confirmBatch = true
            } label: {
                if isOptimising {
                    HStack { ProgressView().controlSize(.small); Text("Optimising…") }
                } else {
                    Label("Optimise (Quit Selected)", systemImage: "wand.and.stars")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedPIDs.isEmpty || isOptimising)
        }
    }

    private func beforeAfterCard(before: MemorySnapshot, after: MemorySnapshot) -> some View {
        MacCard(title: "Result", systemImage: "arrow.left.arrow.right", tint: MacSection.ramOptimiser.tint) {
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("BEFORE").font(.caption).bold().foregroundStyle(.secondary)
                    Text("Pressure: \(before.pressure.rawValue)").font(.subheadline)
                    Text("Used: \(ByteFormat.memoryString(before.stats.used))").font(.subheadline)
                    Text("Swap: \(before.swap.map { ByteFormat.memoryString($0.used) } ?? "Unavailable")").font(.subheadline)
                }
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("AFTER").font(.caption).bold().foregroundStyle(.secondary)
                    Text("Pressure: \(after.pressure.rawValue)").font(.subheadline)
                    Text("Used: \(ByteFormat.memoryString(after.stats.used))").font(.subheadline)
                    Text("Swap: \(after.swap.map { ByteFormat.memoryString($0.used) } ?? "Unavailable")").font(.subheadline)
                }
            }
            let delta = Int64(before.stats.used) - Int64(after.stats.used)
            Text(delta > 0 ? "Freed approximately \(ByteFormat.memoryString(delta))." : "No measurable change — the quit apps may not have been holding much resident memory, or macOS reclaimed it into cache rather than showing as \"free\".")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func currentSnapshot() -> MemorySnapshot? {
        readStatsStatic()
    }

    private func analyze() {
        isAnalyzing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let processes = MacProcessMonitor.snapshot()
            let snapshot = readStatsStatic()
            let candidatesResult = MacMemoryOptimizer.quitCandidates(processes: processes)
            let findingsResult = snapshot.map { MacMemoryOptimizer.analyze(processes: processes, memory: $0.stats, swap: $0.swap) } ?? []

            DispatchQueue.main.async {
                before = snapshot
                findings = findingsResult
                candidates = candidatesResult
                isAnalyzing = false
            }
        }
    }

    private func readStatsStatic() -> MemorySnapshot? {
        let monitor = MacMemoryMonitor()
        monitor.refresh()
        guard let stats = monitor.stats else { return nil }
        return MemorySnapshot(stats: stats, swap: monitor.swap, pressure: monitor.pressure)
    }

    private func performOptimise() {
        isOptimising = true
        let toQuit = candidates.filter { selectedPIDs.contains($0.id) }
        for candidate in toQuit {
            _ = MacMemoryOptimizer.quit(candidate)
        }
        selectedPIDs.removeAll()

        // Give quitting apps a few seconds to actually release memory
        // before re-measuring, so the "after" figure reflects reality.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            after = readStatsStatic()
            isOptimising = false
        }
    }
}
