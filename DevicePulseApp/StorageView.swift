//
//  StorageView.swift
//  DevicePulse
//

import SwiftUI
import Photos
import UIKit

struct StorageView: View {
    @StateObject private var photos = PhotoLibraryMonitor()

    @State private var storageStats: StorageStats?
    @State private var documentsSize: Int64 = 0
    @State private var librarySize: Int64 = 0
    @State private var cacheSize: Int64 = 0
    @State private var tempSize: Int64 = 0
    @State private var isClearing = false
    @State private var lastClearedMessage: String?

    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    storageCard
                    photosCard
                    appStorageCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Storage")
            .onAppear(perform: refresh)
            .onReceive(refreshTimer) { _ in refresh() }
        }
    }

    private func refresh() {
        storageStats = StorageReader.read() // statfs — cheap, fine on main
        // The four AppCacheManager calls each recursively enumerate a
        // directory in the app's own container. Individually small, but
        // this refresh re-runs every 5 seconds on a Timer while this tab
        // is open — doing that inline blocked the main thread on a
        // recurring basis. Moved off main, same pattern as the Mac app.
        DispatchQueue.global(qos: .userInitiated).async {
            let documents = AppCacheManager.documentsDirectorySize()
            let library = AppCacheManager.libraryDirectorySizeExcludingCaches()
            let cache = AppCacheManager.cachesDirectorySize()
            let temp = AppCacheManager.tempDirectorySize()
            DispatchQueue.main.async {
                documentsSize = documents
                librarySize = library
                cacheSize = cache
                tempSize = temp
            }
        }
    }

    private var storageCard: some View {
        StatCard(title: "Storage", systemImage: "internaldrive") {
            if let stats = storageStats {
                VStack(alignment: .leading, spacing: 10) {
                    UsageBar(
                        usedLabel: "Used \(ByteFormat.string(stats.used))",
                        totalLabel: "of \(ByteFormat.string(stats.total))",
                        fraction: stats.usedFraction,
                        tint: .blue
                    )
                    Text("\(ByteFormat.string(stats.free)) available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Storage info unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var photosCard: some View {
        StatCard(title: "Photos & Videos", systemImage: "photo.on.rectangle") {
            VStack(alignment: .leading, spacing: 10) {
                switch photos.accessState {
                case .notDetermined:
                    Text("Grant access to estimate how much storage your Photos library is using.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        photos.requestAccessAndCalculate()
                    } label: {
                        Label("Estimate Photos Storage", systemImage: "photo.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)

                case .denied:
                    Text("Photo library access is denied. Enable it in Settings to see an estimate here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Open Settings", systemImage: "gear")
                    }
                    .buttonStyle(.bordered)

                case .authorized(let limited):
                    if photos.isCalculating {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Scanning library…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let summary = photos.summary {
                        photosSummary(summary, limited: limited)
                    } else {
                        Button {
                            photos.calculate()
                        } label: {
                            Label("Estimate Photos Storage", systemImage: "photo.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func photosSummary(_ summary: PhotoLibrarySummary, limited: Bool) -> some View {
        HStack(spacing: 16) {
            MiniStat(label: "Photos", value: "\(summary.photoCount)")
            MiniStat(label: "Videos", value: "\(summary.videoCount)")
            MiniStat(label: "Screenshots", value: "\(summary.screenshotCount)")
            MiniStat(label: "Screen Recordings", value: "\(summary.screenRecordingCount)")
        }
        UsageBar(
            usedLabel: "Photos \(ByteFormat.string(summary.totalPhotoBytes))",
            totalLabel: "Videos \(ByteFormat.string(summary.totalVideoBytes))",
            fraction: summary.totalBytes == 0 ? 0 : Double(summary.totalPhotoBytes) / Double(summary.totalBytes),
            tint: .pink
        )
        Text("Estimated total: \(ByteFormat.string(summary.totalBytes))")
            .font(.subheadline).bold()

        if limited {
            Text("Limited library access — this only covers the photos you've selected to share with this app.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        Text("ESTIMATE, not exact — this will not match Settings ▸ iPhone Storage. iOS may only keep a small local proxy for iCloud-optimized photos/videos unless \"Download Originals\" is on, and Settings' figure also includes system data this app can't see.")
            .font(.caption2)
            .foregroundStyle(.secondary)

        if !summary.largestAssets.isEmpty {
            Divider()
            Text("Largest items").font(.caption).bold()
            ForEach(summary.largestAssets.prefix(5)) { asset in
                HStack {
                    Image(systemName: asset.isVideo ? "video" : "photo")
                        .foregroundStyle(.secondary)
                    Text(asset.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? "Unknown date")
                        .font(.caption2)
                    Spacer()
                    Text(ByteFormat.string(asset.bytes)).font(.caption2).bold()
                }
            }
        }

        if !summary.recentlyAdded.isEmpty {
            Divider()
            Text("Recently added").font(.caption).bold()
            ForEach(summary.recentlyAdded.prefix(5)) { asset in
                HStack {
                    Image(systemName: asset.isVideo ? "video" : "photo")
                        .foregroundStyle(.secondary)
                    Text(asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown date")
                        .font(.caption2)
                    Spacer()
                }
            }
        }

        Button {
            photos.calculate()
        } label: {
            Label("Recalculate", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
    }

    private var appStorageCard: some View {
        StatCard(title: "This App's Storage", systemImage: "trash") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    MiniStat(label: "Documents", value: ByteFormat.string(documentsSize))
                    MiniStat(label: "Library", value: ByteFormat.string(librarySize))
                }
                HStack {
                    MiniStat(label: "Cache", value: ByteFormat.string(cacheSize))
                    MiniStat(label: "Temp Files", value: ByteFormat.string(tempSize))
                }
                Text("Total: \(ByteFormat.string(documentsSize + librarySize + cacheSize + tempSize))")
                    .font(.caption).bold()

                Text("Sandboxing means an app can only see and clear its OWN folders — not Safari's, not other apps', not system caches. This button only clears DevicePulse's own Cache and Temp files (Documents/Library are left alone since this app doesn't currently store anything meaningful there).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button {
                    clearOwnCache()
                } label: {
                    if isClearing {
                        ProgressView()
                    } else {
                        Label("Clear This App's Cache", systemImage: "trash")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isClearing || (cacheSize == 0 && tempSize == 0))

                if let message = lastClearedMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private func clearOwnCache() {
        isClearing = true
        lastClearedMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let cacheOK = AppCacheManager.clearCachesDirectory()
            let tempOK = AppCacheManager.clearTempDirectory()
            DispatchQueue.main.async {
                cacheSize = AppCacheManager.cachesDirectorySize()
                tempSize = AppCacheManager.tempDirectorySize()
                isClearing = false
                lastClearedMessage = (cacheOK && tempOK) ? "Cleared." : "Cleared what it could — some files were in use."
            }
        }
    }
}

#Preview {
    StorageView()
}
