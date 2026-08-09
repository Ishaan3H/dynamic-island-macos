import AppKit
import SwiftUI

/// Downsampled image cache.
///
/// The previous implementation called `NSImage(contentsOf:)` inside `body`. That
/// is a synchronous disk read *and* a full-size decode on the main thread, re-run
/// on every invalidation — with 20 staged screenshots it was the single largest
/// source of dropped frames.
///
/// Two fixes: decode off the main thread, and decode to the size actually drawn
/// (`CGImageSourceCreateThumbnailAtIndex` decodes straight to the target
/// dimension instead of loading a 4K image to paint 26 points of it).
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 256
        c.totalCostLimit = 24 * 1024 * 1024   // ~24 MB of decoded pixels
        return c
    }()

    private let queue = DispatchQueue(
        label: "com.qwerty.dynamicisland.thumbnails",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private let lock = NSLock()
    private var inFlight = Set<String>()

    private func key(_ url: URL, _ pixels: Int) -> String { "\(url.path)@\(pixels)" }

    /// Cache-only lookup. Safe to call from `body` — never touches the disk.
    func cached(url: URL, pixels: Int) -> NSImage? {
        cache.object(forKey: key(url, pixels) as NSString)
    }

    /// Decodes off-thread, then delivers on main. Coalesces duplicate requests.
    func load(url: URL, pixels: Int, completion: @escaping (NSImage?) -> Void) {
        let k = key(url, pixels)

        if let hit = cache.object(forKey: k as NSString) {
            completion(hit)
            return
        }

        lock.lock()
        let alreadyLoading = inFlight.contains(k)
        if !alreadyLoading { inFlight.insert(k) }
        lock.unlock()
        guard !alreadyLoading else { return }

        queue.async { [weak self] in
            let image = Self.downsample(url: url, pixels: pixels)

            if let image {
                let cost = pixels * pixels * 4
                self?.cache.setObject(image, forKey: k as NSString, cost: cost)
            }
            self?.lock.lock()
            self?.inFlight.remove(k)
            self?.lock.unlock()

            DispatchQueue.main.async { completion(image) }
        }
    }

    private static func downsample(url: URL, pixels: Int) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,   // decode here, not at draw time
            kCGImageSourceThumbnailMaxPixelSize: pixels
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: pixels, height: pixels))
    }
}

/// Drop-in thumbnail view. Holds its own `@State`, so a decode completing
/// invalidates one row rather than the island.
struct CachedThumbnail<Placeholder: View>: View {
    let url: URL?
    let side: CGFloat
    let cornerRadius: CGFloat
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: NSImage?
    @Environment(\.displayScale) private var displayScale

    private var pixels: Int { Int(side * max(displayScale, 2)) }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder()
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: url) { await resolve() }
    }

    @MainActor
    private func resolve() async {
        guard let url else {
            image = nil
            return
        }
        if let hit = ThumbnailCache.shared.cached(url: url, pixels: pixels) {
            image = hit
            return
        }
        image = await withCheckedContinuation { continuation in
            ThumbnailCache.shared.load(url: url, pixels: pixels) { continuation.resume(returning: $0) }
        }
    }
}
