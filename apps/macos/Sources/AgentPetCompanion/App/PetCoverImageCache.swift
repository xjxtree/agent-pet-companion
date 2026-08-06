import AppKit
import Foundation

/// Decodes a pet cover image at most once per on-disk version.
///
/// Cover images are read from computed properties inside SwiftUI view bodies,
/// including the always-visible sidebar entry, so every store publish used to
/// re-read and re-decode the same PNG from disk. The cache key carries the
/// file's modification date and size, so replacing a pet asset still produces a
/// fresh decode on the next read instead of serving a stale image.
final class PetCoverImageCache: @unchecked Sendable {
    static let shared = PetCoverImageCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 64
    }

    func image(atPath path: String) -> NSImage? {
        let key = Self.versionedKey(forPath: path)
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    func image(at url: URL) -> NSImage? {
        image(atPath: url.path)
    }

    /// A `stat` per lookup is orders of magnitude cheaper than a PNG decode and
    /// keeps a replaced asset from being served from the cache.
    private static func versionedKey(forPath path: String) -> NSString {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = (attributes?[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return "\(path)|\(modified)|\(size)" as NSString
    }
}
