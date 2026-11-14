// The Photos side: find the iPhone's screen recordings and copy one out as a movie file. Read-only.
import AVFoundation
import Foundation
import Photos

enum Library {
    /// Asks for Photos access the first time (macOS shows its own prompt), then reports whether we have it.
    static func authorize() -> Bool {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            let done = DispatchSemaphore(value: 0)
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { result in status = result; done.signal() }
            if done.wait(timeout: .now() + 280) == .timedOut { return false }
        }
        return status == .authorized || status == .limited
    }

    /// The video file's original name, e.g. `ScreenRecording_11-14-2026 10-02-11_1.mp4`.
    static func filename(of asset: PHAsset) -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        return (resources.first { $0.type == .video } ?? resources.first)?.originalFilename ?? ""
    }

    /// iOS names its screen recordings `ScreenRecording_…` (and `RPReplay_Final…` before iOS 18). Camera videos
    /// are `IMG_…`. Photos also sets an undocumented subtype bit (1 << 19) on them; either tell is enough.
    static func isScreenRecording(_ asset: PHAsset, filename: String) -> Bool {
        let name = filename.lowercased()
        return asset.mediaSubtypes.rawValue & (1 << 19) != 0 || name.hasPrefix("screenrecording") || name.hasPrefix("rpreplay") || name.hasPrefix("screen recording")
    }

    static func videos(since: Date) -> [PHAsset] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d AND creationDate > %@", PHAssetMediaType.video.rawValue, since as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        var found: [PHAsset] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in found.append(asset) }
        return found
    }

    static func asset(id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    /// Copies the recording out as `recording.mp4` in `directory`, fetching it from iCloud if this Mac only has
    /// a preview. Throws while the original is not available yet; the next pass tries again.
    static func export(_ asset: PHAsset, to directory: URL) async throws -> URL {
        let resources = PHAssetResource.assetResources(for: asset)
        // A trimmed recording has a full-size version; otherwise the original.
        guard let resource = resources.first(where: { $0.type == .fullSizeVideo }) ?? resources.first(where: { $0.type == .video }) else {
            throw NSError(domain: "AgentDispatch", code: 1, userInfo: [NSLocalizedDescriptionKey: "The asset has no video file"])
        }
        let raw = directory.appendingPathComponent("original-" + resource.originalFilename)
        try? FileManager.default.removeItem(at: raw)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: raw, options: options)

        // Clipshot serves the file under this name, so it has to be an MP4.
        let movie = directory.appendingPathComponent("recording.mp4")
        try? FileManager.default.removeItem(at: movie)
        if raw.pathExtension.lowercased() == "mp4" {
            try FileManager.default.moveItem(at: raw, to: movie)
        } else {
            try await rewrap(raw, as: movie)
            try? FileManager.default.removeItem(at: raw)
        }
        return movie
    }

    /// Puts a .mov's tracks in an .mp4 without re-encoding; re-encodes only if that is refused.
    static func rewrap(_ source: URL, as movie: URL) async throws {
        let asset = AVURLAsset(url: source)
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality] {
            guard let export = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            try? FileManager.default.removeItem(at: movie)
            do {
                try await export.export(to: movie, as: .mp4)
                return
            } catch {
                if preset == AVAssetExportPresetHighestQuality { throw error }
            }
        }
        throw NSError(domain: "AgentDispatch", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not convert the recording to MP4"])
    }
}
