//
//  PhotoLibraryMonitor.swift
//  DevicePulse
//
//  Estimates how much on-device storage the Photos library is using, via
//  the PUBLIC PhotoKit framework. This requires the user to grant photo
//  library access — nothing is read without that permission.
//
//  HONESTY NOTE: This is an ESTIMATE, not an exact figure, and will not
//  match Settings ▸ General ▸ iPhone Storage exactly. iOS only keeps a
//  small local proxy for iCloud-optimized photos/videos unless "Download
//  Originals to this iPhone" is on, and Settings' number also folds in
//  system-managed data this app has no access to. There is no way to
//  distinguish "optimized" from "fully local" from PhotoKit alone.
//

import Photos
import Combine

enum PhotoAccessState: Equatable {
    case notDetermined
    case denied
    case authorized(limited: Bool)
}

struct PhotoLibrarySummary {
    var photoCount = 0
    var videoCount = 0
    var screenshotCount = 0
    var screenRecordingCount = 0
    var totalPhotoBytes: Int64 = 0
    var totalVideoBytes: Int64 = 0
    var largestAssets: [LargeAsset] = []
    var recentlyAdded: [RecentAsset] = []

    var totalBytes: Int64 { totalPhotoBytes + totalVideoBytes }
}

struct LargeAsset: Identifiable {
    let id: String
    let bytes: Int64
    let isVideo: Bool
    let creationDate: Date?
}

struct RecentAsset: Identifiable {
    let id: String
    let isVideo: Bool
    let creationDate: Date?
}

final class PhotoLibraryMonitor: ObservableObject {
    @Published var accessState: PhotoAccessState = .notDetermined
    @Published var isCalculating = false
    @Published var summary: PhotoLibrarySummary?

    init() {
        refreshAccessState()
    }

    func refreshAccessState() {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized:
            accessState = .authorized(limited: false)
        case .limited:
            accessState = .authorized(limited: true)
        case .notDetermined:
            accessState = .notDetermined
        case .denied, .restricted:
            accessState = .denied
        @unknown default:
            accessState = .denied
        }
    }

    func requestAccessAndCalculate() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshAccessState()
                if case .authorized = self?.accessState ?? .denied {
                    self?.calculate()
                }
            }
        }
    }

    func calculate() {
        guard case .authorized = accessState else { return }
        isCalculating = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fetchResult = PHAsset.fetchAssets(with: nil)
            var result = PhotoLibrarySummary()
            var large: [LargeAsset] = []

            fetchResult.enumerateObjects { asset, _, _ in
                let resources = PHAssetResource.assetResources(for: asset)
                var assetBytes: Int64 = 0
                for resource in resources {
                    if let size = resource.value(forKey: "fileSize") as? Int64 {
                        assetBytes += size
                    }
                }

                let isVideo = asset.mediaType == .video
                if isVideo {
                    result.videoCount += 1
                    result.totalVideoBytes += assetBytes
                } else {
                    result.photoCount += 1
                    result.totalPhotoBytes += assetBytes
                }

                if asset.mediaSubtypes.contains(.photoScreenshot) {
                    result.screenshotCount += 1
                }
                if #available(iOS 15.0, *), asset.mediaSubtypes.contains(.videoScreenRecording) {
                    result.screenRecordingCount += 1
                }

                if assetBytes > 0 {
                    large.append(LargeAsset(id: asset.localIdentifier, bytes: assetBytes, isVideo: isVideo, creationDate: asset.creationDate))
                }
            }

            large.sort { $0.bytes > $1.bytes }
            result.largestAssets = Array(large.prefix(10))

            let recentOptions = PHFetchOptions()
            recentOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            recentOptions.fetchLimit = 10
            let recentFetch = PHAsset.fetchAssets(with: recentOptions)
            var recent: [RecentAsset] = []
            recentFetch.enumerateObjects { asset, _, _ in
                recent.append(RecentAsset(id: asset.localIdentifier, isVideo: asset.mediaType == .video, creationDate: asset.creationDate))
            }
            result.recentlyAdded = recent

            DispatchQueue.main.async {
                self?.summary = result
                self?.isCalculating = false
            }
        }
    }
}
