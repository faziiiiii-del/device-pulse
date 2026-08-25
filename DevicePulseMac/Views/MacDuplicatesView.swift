//
//  MacDuplicatesView.swift
//  DevicePulseMac
//
//  Scan → Review → Clean, same shape as Smart Care and Maintenance:
//  nothing is trashed until you've seen exactly which copies would go.
//  Each group's oldest file is treated as "the original" and pre-kept
//  (unchecked) — everything else is pre-selected for Trash, but every
//  checkbox is yours to change before anything moves.
//

import SwiftUI
import AppKit

struct MacDuplicatesView: View {
    @State private var rootURL: URL = FileManager.default.homeDirectoryForCurrentUser
    @State private var minSizeIndex = 1
    @State private var groups: [DuplicateGroup] = []
    @State private var selected: Set<String> = [] // DuplicateFileEntry.id (path)
    @State private var isScanning = false
    @State private var hasScanned = false
    @State private var scannedCount = 0
    @State private var pendingTrash = false
    @StateObject private var undoToast = UndoToastState()

    private let sizeOptions: [(label: String, bytes: Int64)] = [
        ("100 KB+", 100_000), ("1 MB+", 1_000_000), ("10 MB+", 10_000_000), ("100 MB+", 100_000_000),
    ]

    private var reclaimableBytes: Int64 {
        groups.reduce(0) { total, group in
            total + group.files.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.sizeBytes }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Duplicate Finder").font(.largeTitle).bold()
                Text("Finds files that are byte-identical, not just similarly named or sized — size is checked first (free), then content is hashed (SHA-256) to confirm an actual match. Skips inside app bundles. Nothing is moved until you review and choose.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                MacCard(title: "Scan Location", systemImage: "folder", tint: MacSection.duplicates.tint) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(rootURL.path).font(.subheadline).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Choose Folder…") { chooseFolder() }.buttonStyle(.bordered)
                        }
                        Picker("Minimum file size", selection: $minSizeIndex) {
                            ForEach(sizeOptions.indices, id: \.self) { index in
                                Text(sizeOptions[index].label).tag(index)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 420)
                        Text("Files smaller than this are skipped — tiny same-sized files (icons, empty markers) are rarely worth reclaiming and would slow scanning down.")
                            .font(.caption2).foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Button {
                                scan()
                            } label: {
                                if isScanning {
                                    HStack { ProgressView().controlSize(.small); Text("Scanning…") }
                                } else {
                                    Label("Scan", systemImage: "doc.on.doc")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isScanning)

                            if isScanning && scannedCount > 0 {
                                Text("\(scannedCount) items examined…").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if hasScanned {
                    resultsCard
                }
            }
            .padding(24)
        }
        .undoToast(undoToast)
        .alert(
            "Move \(selected.count) file(s) to Trash?",
            isPresented: $pendingTrash
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { performTrash() }
        } message: {
            Text("This moves the selected duplicate copies to the Trash — reversible from there. At least one copy of each file is always kept.")
        }
    }

    private var resultsCard: some View {
        MacCard(title: "Duplicates (\(groups.count) group\(groups.count == 1 ? "" : "s"))", systemImage: "doc.on.doc.fill", tint: MacSection.duplicates.tint) {
            if groups.isEmpty {
                Text("No exact duplicates found at or above \(sizeOptions[minSizeIndex].label) in this folder.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(ByteFormat.string(reclaimableBytes)) reclaimable from the selected copies below.")
                        .font(.subheadline).bold()
                    Text("Each group's oldest copy is kept by default — the app never assumes which duplicate you actually want, only that keeping the earliest one is the safest default.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(groups) { group in
                        groupRow(group)
                        if group.id != groups.last?.id { Divider() }
                    }
                }
                Button {
                    pendingTrash = true
                } label: {
                    Label("Move \(selected.count) Selected to Trash (\(ByteFormat.string(reclaimableBytes)))", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
                .padding(.top, 4)
            }
        }
    }

    private func groupRow(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(group.files.count) copies").font(.subheadline).bold()
                Text("·").foregroundStyle(.secondary)
                Text(ByteFormat.string(group.sizeBytes) + " each").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(ByteFormat.string(group.reclaimableBytes)) reclaimable").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(group.files.enumerated()), id: \.element.id) { index, entry in
                HStack {
                    if index == 0 {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.secondary)
                            .help("Kept by default — the oldest copy in this group.")
                    } else {
                        Button {
                            toggle(entry)
                        } label: {
                            Image(systemName: selected.contains(entry.id) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(selected.contains(entry.id) ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Text(entry.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if let modified = entry.modifiedDate {
                        Text(modified.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                        .buttonStyle(.bordered).controlSize(.mini)
                }
            }
        }
    }

    private func toggle(_ entry: DuplicateFileEntry) {
        if selected.contains(entry.id) { selected.remove(entry.id) } else { selected.insert(entry.id) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = rootURL
        panel.message = "Choose a folder to scan for duplicates"
        if panel.runModal() == .OK, let url = panel.url {
            rootURL = url
            hasScanned = false
            groups = []
            selected = []
        }
    }

    private func scan() {
        isScanning = true
        scannedCount = 0
        let root = rootURL
        let minSize = sizeOptions[minSizeIndex].bytes
        DispatchQueue.global(qos: .utility).async {
            let found = MacDuplicateScanner.scan(root: root, minSizeBytes: minSize) { count in
                DispatchQueue.main.async { scannedCount = count }
            }
            DispatchQueue.main.async {
                groups = found
                // Pre-select every copy except each group's first (oldest/kept) entry.
                selected = Set(found.flatMap { $0.files.dropFirst().map(\.id) })
                isScanning = false
                hasScanned = true
            }
        }
    }

    private func performTrash() {
        let toTrash = groups.flatMap { $0.files.filter { selected.contains($0.id) } }
        var records: [TrashRecord] = []
        for entry in toTrash {
            if let record = MacTrashUndo.trash(entry.url) { records.append(record) }
        }
        let trashedIDs = Set(toTrash.map(\.id))
        groups = groups.compactMap { group in
            var updated = group
            updated.files.removeAll { trashedIDs.contains($0.id) }
            return updated.files.count > 1 ? updated : nil
        }
        selected.subtract(trashedIDs)
        if !records.isEmpty {
            undoToast.show(records: records, message: "Moved \(records.count) duplicate(s) to Trash") {
                hasScanned = false
            }
        }
    }
}
