//
//  MacBigFilesView.swift
//  DevicePulseMac
//

import SwiftUI
import AppKit

private enum SizeThreshold: Int64, CaseIterable, Identifiable {
    case mb50 = 52_428_800
    case mb100 = 104_857_600
    case mb500 = 524_288_000
    case gb1 = 1_073_741_824

    var id: Int64 { rawValue }
    var label: String {
        switch self {
        case .mb50: return "50 MB+"
        case .mb100: return "100 MB+"
        case .mb500: return "500 MB+"
        case .gb1: return "1 GB+"
        }
    }
}

struct MacBigFilesView: View {
    @State private var rootURL: URL = FileManager.default.homeDirectoryForCurrentUser
    @State private var threshold: SizeThreshold = .mb100
    @State private var results: [BigFileEntry] = []
    @State private var isScanning = false
    @State private var hasScanned = false
    @State private var pendingTrash: BigFileEntry?
    @State private var scannedCount = 0
    @StateObject private var undoToast = UndoToastState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Big Files Finder").font(.largeTitle).bold()
                Text("Scans a folder you choose for individually large files — videos, disk images, archives, VM images. Skips inside app bundles.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                MacCard(title: "Scan Location", systemImage: "folder", tint: MacSection.bigFiles.tint) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(rootURL.path)
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Choose Folder…") { chooseFolder() }
                                .buttonStyle(.bordered)
                        }
                        Picker("Minimum size", selection: $threshold) {
                            ForEach(SizeThreshold.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 360)

                        HStack(spacing: 10) {
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

                            if isScanning && scannedCount > 0 {
                                Text("\(scannedCount) files scanned…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if hasScanned {
                    MacCard(title: "Results (\(results.count))", systemImage: "doc.text.magnifyingglass", tint: MacSection.bigFiles.tint) {
                        if results.isEmpty {
                            Text("Nothing found at or above \(threshold.label) in this folder.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(results) { entry in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.name).font(.subheadline).bold()
                                            Text(entry.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        }
                                        Spacer()
                                        Text(ByteFormat.string(entry.sizeBytes)).font(.subheadline).bold()
                                        Button("Reveal") {
                                            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        Button("Trash") {
                                            pendingTrash = entry
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                    .padding(.vertical, 5)
                                    if entry.id != results.last?.id { Divider() }
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .undoToast(undoToast)
        .alert(
            pendingTrash.map { "Move \($0.name) to Trash?" } ?? "",
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } })
        ) {
            Button("Cancel", role: .cancel) { pendingTrash = nil }
            Button("Move to Trash", role: .destructive) {
                if let entry = pendingTrash, let record = MacBigFilesScanner.trash(entry) {
                    results.removeAll { $0.id == entry.id }
                    undoToast.show(records: [record], message: "Moved \(entry.name) to Trash") {
                        results.append(entry)
                        results.sort { $0.sizeBytes > $1.sizeBytes }
                    }
                }
                pendingTrash = nil
            }
        } message: {
            if let entry = pendingTrash {
                Text("This moves \(entry.path) to the Trash. You can restore it from there afterward.")
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = rootURL
        panel.message = "Choose a folder to scan for large files"
        if panel.runModal() == .OK, let url = panel.url {
            rootURL = url
            hasScanned = false
            results = []
        }
    }

    private func scan() {
        isScanning = true
        scannedCount = 0
        let root = rootURL
        let minSize = threshold.rawValue
        DispatchQueue.global(qos: .utility).async {
            let found = MacBigFilesScanner.scan(root: root, minSizeBytes: minSize) { count in
                DispatchQueue.main.async { scannedCount = count }
            }
            DispatchQueue.main.async {
                results = found
                isScanning = false
                hasScanned = true
            }
        }
    }
}
