//
//  MacCrashReportsView.swift
//  DevicePulseMac
//

import SwiftUI
import AppKit

struct MacCrashReportsView: View {
    @State private var reports: [CrashReport] = []
    @State private var truncated = false
    @State private var isLoading = true
    @State private var selectedCategory: CrashReportCategory?
    @State private var openReport: CrashReport?
    @State private var pendingDelete: CrashReport?

    private var filtered: [CrashReport] {
        guard let selectedCategory else { return reports }
        return reports.filter { $0.category == selectedCategory }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Crash Reports").font(.largeTitle).bold()

                MacCard(title: "About", systemImage: "info.circle", tint: MacSection.crashReports.tint) {
                    Text("These are the crash, kernel-panic, hang and CPU/energy reports macOS writes on its own to ~/Library/Logs/DiagnosticReports and /Library/Logs/DiagnosticReports. A report existing doesn't mean something is wrong now — apps occasionally crash and macOS logs resource spikes routinely. Repeated reports for the same app or a kernel panic are the ones worth looking at.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Scanning diagnostic reports…").font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                } else if reports.isEmpty {
                    MacCard(title: "No Reports", systemImage: "checkmark.seal", tint: MacSection.crashReports.tint) {
                        Text("No crash, panic or diagnostic reports were found. If you expected some from the system-wide folder, Device Pulse may need Full Disk Access (System Settings ▸ Privacy & Security ▸ Full Disk Access).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    summaryCard
                    reportListCard
                }
            }
            .padding(24)
        }
        .onAppear(perform: load)
        .sheet(item: $openReport) { report in
            CrashReportDetailSheet(report: report)
        }
        .alert(
            pendingDelete.map { "Move “\($0.fileName)” to Trash?" } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Move to Trash", role: .destructive) {
                if let report = pendingDelete { delete(report) }
                pendingDelete = nil
            }
        } message: {
            Text("The report is moved to the Trash, not deleted outright — you can put it back until you empty the Trash. Reports in the system-wide folder may not move without Full Disk Access.")
        }
    }

    private var summaryCard: some View {
        MacCard(title: "Summary", systemImage: "chart.bar", tint: MacSection.crashReports.tint) {
            let counts = MacCrashReportMonitor.counts(for: reports)
            HStack(spacing: 8) {
                categoryChip(title: "All", count: reports.count, category: nil)
                ForEach(counts, id: \.0) { entry in
                    categoryChip(title: entry.0.rawValue, count: entry.1, category: entry.0)
                }
            }
            if truncated {
                Text("Showing the \(reports.count) most recent reports — older ones are omitted.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func categoryChip(title: String, count: Int, category: CrashReportCategory?) -> some View {
        let isSelected = selectedCategory == category
        return Button {
            selectedCategory = category
        } label: {
            HStack(spacing: 5) {
                if let category { Image(systemName: category.symbol).font(.caption2) }
                Text(title).font(.caption)
                Text("\(count)").font(.caption).bold()
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.2)))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(isSelected ? MacSection.crashReports.tint.opacity(0.25) : Color.secondary.opacity(0.1)))
            .overlay(Capsule().stroke(isSelected ? MacSection.crashReports.tint : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var reportListCard: some View {
        MacCard(title: selectedCategory?.rawValue ?? "All Reports", systemImage: "list.bullet.rectangle", tint: MacSection.crashReports.tint) {
            LazyVStack(spacing: 0) {
                ForEach(filtered) { report in
                    reportRow(report)
                    if report.id != filtered.last?.id { Divider() }
                }
            }
        }
    }

    @ViewBuilder
    private func reportRow(_ report: CrashReport) -> some View {
        HStack(spacing: 10) {
            Image(systemName: report.category.symbol)
                .foregroundStyle(report.category == .kernelPanic || report.category == .appCrash ? .red : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(report.processName).font(.subheadline)
                HStack(spacing: 6) {
                    Text(report.date, format: .relative(presentation: .named))
                    if report.isSystemLocation { Text("· system") }
                    if report.isRetired { Text("· archived") }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open") { openReport = report }
                .buttonStyle(.bordered).controlSize(.small)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: report.path)])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.bordered).controlSize(.small)
            .help("Reveal in Finder")
            Button(role: .destructive) {
                pendingDelete = report
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered).controlSize(.small)
            .help("Move to Trash")
        }
        .padding(.vertical, 5)
    }

    private func load() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = MacCrashReportMonitor.scan()
            DispatchQueue.main.async {
                reports = result.reports
                truncated = result.truncated
                isLoading = false
            }
        }
    }

    private func delete(_ report: CrashReport) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = MacCrashReportMonitor.moveToTrash(report)
            DispatchQueue.main.async {
                if ok {
                    reports.removeAll { $0.id == report.id }
                } else {
                    load() // don't claim success; re-scan to reflect reality
                }
            }
        }
    }
}

private struct CrashReportDetailSheet: View {
    let report: CrashReport
    @Environment(\.dismiss) private var dismiss

    @State private var text: String?
    @State private var permissionDenied = false
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.processName).font(.headline)
                    Text(report.fileName).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: report.path)])
                }
                .buttonStyle(.bordered)
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
            Divider()

            if isLoading {
                ProgressView().controlSize(.small).padding(24).frame(maxWidth: .infinity)
            } else if permissionDenied {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Can't read this report", systemImage: "lock")
                        .font(.headline)
                    Text("It's in the system-wide DiagnosticReports folder, which needs Full Disk Access to read. Grant it in System Settings ▸ Privacy & Security ▸ Full Disk Access, or open the file directly in Console.app.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open Privacy Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(text ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(width: 720, height: 560)
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = MacCrashReportMonitor.contents(of: report)
                DispatchQueue.main.async {
                    text = result.text
                    permissionDenied = result.permissionDenied
                    isLoading = false
                }
            }
        }
    }
}
