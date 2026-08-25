//
//  MacUninstallerView.swift
//  DevicePulseMac
//

import SwiftUI
import AppKit

struct MacUninstallerView: View {
    @State private var apps: [InstalledApp] = []
    @State private var isScanning = false
    @State private var searchText = ""
    @State private var pendingApp: InstalledApp?
    @State private var pendingLeftovers: [MacAppUninstaller.LeftoverMatch] = []
    @State private var selectedLeftovers: Set<String> = []
    @State private var removalLog: [(name: String, detail: String, date: Date)] = []
    @State private var sizedCount = 0
    @State private var totalToSize = 0
    @StateObject private var undoToast = UndoToastState()

    private var filteredApps: [InstalledApp] {
        guard !searchText.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Uninstaller").font(.largeTitle).bold()
                Text("Lists apps in /Applications and ~/Applications. Uninstalling moves the app — and, if you choose, its related files — to the Trash. Nothing is permanently deleted; restore from the Trash if needed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("Search apps", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    Spacer()
                    Button {
                        scan()
                    } label: {
                        if isScanning {
                            HStack { ProgressView().controlSize(.small); Text("Scanning…") }
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isScanning)
                }

                if totalToSize > 0 && sizedCount < totalToSize {
                    ProgressView(value: Double(sizedCount), total: Double(totalToSize)) {
                        Text("Sizing \(sizedCount) of \(totalToSize) apps…").font(.caption).foregroundStyle(.secondary)
                    }
                }

                MacCard(title: "Applications (\(filteredApps.count))", systemImage: "square.grid.2x2", tint: MacSection.uninstaller.tint) {
                    VStack(spacing: 0) {
                        ForEach(filteredApps) { app in
                            row(for: app)
                            if app.id != filteredApps.last?.id { Divider() }
                        }
                    }
                }

                if !removalLog.isEmpty {
                    MacCard(title: "Recent Removals", systemImage: "checkmark.circle", tint: MacSection.uninstaller.tint) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(removalLog.enumerated()), id: \.offset) { _, entry in
                                Text("\(entry.name): \(entry.detail) — \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .onAppear(perform: scan)
        .undoToast(undoToast)
        .sheet(item: $pendingApp) { app in
            uninstallSheet(for: app)
        }
    }

    private func row(for app: InstalledApp) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name).font(.subheadline).bold()
                    if app.isProtected {
                        Text("System").font(.caption2).bold()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                }
                Text(app.version.map { "Version \($0)" } ?? app.path)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if let size = app.sizeBytes {
                Text(ByteFormat.string(size)).font(.subheadline).bold()
            } else {
                ProgressView().controlSize(.small)
            }
            Button("Uninstall…") {
                beginUninstall(app)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(app.isProtected)
            .help(app.isProtected ? "Apple system app — not offered for uninstall here" : "")
        }
        .padding(.vertical, 6)
    }

    private func uninstallSheet(for app: InstalledApp) -> some View {
        let exact = pendingLeftovers.filter { $0.confidence == .exact }
        let possible = pendingLeftovers.filter { $0.confidence == .possible }

        return VStack(alignment: .leading, spacing: 14) {
            Text("Uninstall \(app.name)?").font(.title2).bold()
            Text("This moves the app bundle to the Trash:")
                .font(.callout).foregroundStyle(.secondary)
            Text(app.path).font(.caption).foregroundStyle(.secondary)

            if pendingLeftovers.isEmpty {
                Text("No related files found in common locations.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !exact.isEmpty {
                            Text("Matched by bundle ID or exact app name — pre-selected:")
                                .font(.caption).bold()
                            leftoverList(exact)
                        }
                        if !possible.isEmpty {
                            Text("Possible matches only — the app name appears in these, but review before including:")
                                .font(.caption).bold()
                                .foregroundStyle(.orange)
                            leftoverList(possible)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }

            HStack {
                Spacer()
                Button("Cancel") { pendingApp = nil }
                Button("Move App to Trash Only") { performUninstall(app) }
                    .buttonStyle(.bordered)
                if !pendingLeftovers.isEmpty {
                    Button("Move App + Selected (\(selectedLeftovers.count)) to Trash") { performUninstall(app) }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedLeftovers.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func leftoverList(_ items: [MacAppUninstaller.LeftoverMatch]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                HStack(spacing: 6) {
                    Button {
                        if selectedLeftovers.contains(item.id) {
                            selectedLeftovers.remove(item.id)
                        } else {
                            selectedLeftovers.insert(item.id)
                        }
                    } label: {
                        Image(systemName: selectedLeftovers.contains(item.id) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(selectedLeftovers.contains(item.id) ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    Text(item.url.path).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func beginUninstall(_ app: InstalledApp) {
        pendingLeftovers = []
        selectedLeftovers = []
        pendingApp = app
        DispatchQueue.global(qos: .userInitiated).async {
            let found = MacAppUninstaller.leftovers(for: app)
            DispatchQueue.main.async {
                if pendingApp?.id == app.id {
                    pendingLeftovers = found
                    selectedLeftovers = Set(found.filter { $0.confidence == .exact }.map(\.id))
                }
            }
        }
    }

    private func performUninstall(_ app: InstalledApp) {
        let leftovers = pendingLeftovers.filter { selectedLeftovers.contains($0.id) }.map(\.url)
        pendingApp = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let appRecord = MacAppUninstaller.trash(URL(fileURLWithPath: app.path))
            let leftoverRecords = leftovers.compactMap { MacAppUninstaller.trash($0) }

            DispatchQueue.main.async {
                let allRecords = ([appRecord].compactMap { $0 }) + leftoverRecords
                let detail = appRecord != nil
                    ? (leftoverRecords.count > 0 ? "Moved app + \(leftoverRecords.count) related item(s) to Trash" : "Moved app to Trash")
                    : "Failed to move app to Trash"
                removalLog.insert((app.name, detail, Date()), at: 0)
                apps.removeAll { $0.id == app.id }
                undoToast.show(records: allRecords, message: "Uninstalled \(app.name)") {
                    apps.append(app)
                    apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                }
            }
        }
    }

    private func scan() {
        isScanning = true
        sizedCount = 0
        totalToSize = 0
        DispatchQueue.global(qos: .userInitiated).async {
            let found = MacAppUninstaller.scan()
            DispatchQueue.main.async {
                apps = found
                isScanning = false
                totalToSize = found.count
            }
            for app in found {
                let sized = MacAppUninstaller.size(of: app)
                DispatchQueue.main.async {
                    if let index = apps.firstIndex(where: { $0.id == sized.id }) {
                        apps[index] = sized
                    }
                    sizedCount += 1
                }
            }
        }
    }
}
