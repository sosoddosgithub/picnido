import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import ImageIO
import AppKit

/// Final class wrapper so CGImage can live in an NSCache.
final class CachedImage {
    let image: CGImage
    let key: String
    init(_ image: CGImage, key: String) { self.image = image; self.key = key }
}

/// Loads source images, applies the non-destructive edit stack, and caches results.
final class ImageEngine {

    static let shared = ImageEngine()

    let context: CIContext
    private let renderCache = NSCache<NSString, CachedImage>()
    private let sourceCache = NSCache<NSString, CachedImage>()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private init() {
        context = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB) as Any,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
            .cacheIntermediates: false,
            .highQualityDownsample: true
        ])
        renderCache.countLimit = 40
        renderCache.totalCostLimit = 384 * 1024 * 1024
        sourceCache.countLimit = 8
    }

    // MARK: - Source

    /// Full resolution source, EXIF-rotated so downstream coordinates are upright.
    func sourceImage(for url: URL) -> CGImage? {
        let key = "src:" + url.path
        if let hit = sourceCache.object(forKey: key as NSString) { return hit.image }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        var upright = cg
        let orientation = exifOrientation(src)
        if orientation != 1 {
            let ci = CIImage(cgImage: cg).oriented(forExifOrientation: Int32(orientation))
            if let baked = context.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: colorSpace) {
                upright = baked
            }
        }
        sourceCache.setObject(CachedImage(upright, key: key), forKey: key as NSString)
        return upright
    }

    private func exifOrientation(_ src: CGImageSource) -> Int {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return 1 }
        return (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    }

    // MARK: - Thumbnails
    //
    // Thumbnails no longer live in an `NSCache` in this class. They live in `ThumbnailCache`,
    // which keeps a bounded memory layer in front of a persistent, sharded JPEG store under
    // `~/Library/Caches/Picnido/thumbs`. Everything below is the thin adapter that maps a
    // point size to a device pixel size and threads the edit stack through.

    /// Device pixels for a point size, snapped to the cache's bucket ladder.
    static func pixelSize(forDisplaySize size: CGFloat) -> Int {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return ThumbBuckets.snap(Int((size * scale).rounded(.up)))
    }

    /// Memory-only peek. Safe to call from a view body — never touches the disk.
    func cachedThumbnail(for photo: PhotoItem, displaySize: CGFloat) -> CGImage? {
        ThumbnailCache.shared.cached(photo: photo, pixels: Self.pixelSize(forDisplaySize: displaySize))
    }

    /// Blocking lookup through the whole cache, decoding on a miss. For scripted verification and
    /// for the few places that genuinely need the pixels immediately.
    func thumbnailNow(for photo: PhotoItem, displaySize: CGFloat) -> CGImage? {
        ThumbnailCache.shared.imageNow(photo: photo,
                                       pixels: Self.pixelSize(forDisplaySize: displaySize),
                                       transform: editTransform(for: photo))
    }

    /// The one call the grid and the filmstrip make.
    func thumbnail(for photo: PhotoItem, displaySize: CGFloat,
                   priority: ThumbnailCache.Priority = .visible,
                   completion: @escaping (CGImage?) -> Void) {
        ThumbnailCache.shared.request(photo: photo,
                                      pixels: Self.pixelSize(forDisplaySize: displaySize),
                                      priority: priority,
                                      transform: editTransform(for: photo),
                                      completion: completion)
    }

    /// Warms a set of photos off the critical path.
    func prefetch(photos: [PhotoItem], displaySize: CGFloat) {
        ThumbnailCache.shared.prefetch(photos: photos,
                                       pixels: Self.pixelSize(forDisplaySize: displaySize)) { [weak self] photo in
            self?.editTransform(for: photo)
        }
    }

    /// Prepares the grid thumbnail for every photo in `photos`, in the background.
    ///
    /// Used once after a folder is imported. The prefetcher only covers a window around the
    /// viewport, so without this the rest of a 500-photo folder stays cold until the user scrolls
    /// it — which is what "the cache cannot keep up" actually was.
    @discardableResult
    func buildThumbnails(for photos: [PhotoItem], displaySize: CGFloat,
                         progress: @escaping (Int, Int) -> Void,
                         finished: @escaping (Int) -> Void) -> Int {
        ThumbnailCache.shared.buildCache(photos: photos,
                                         pixels: Self.pixelSize(forDisplaySize: displaySize),
                                         transform: { [weak self] photo in
                                             self?.editTransform(for: photo)
                                         },
                                         progress: progress,
                                         finished: finished)
    }

    /// Applies the edit stack to an already-decoded bitmap. Returned as a closure so the work
    /// happens on the cache's worker queue rather than on the caller's.
    func editTransform(for photo: PhotoItem) -> ((CGImage) -> CGImage?)? {
        guard photo.hasEdits else { return nil }
        let steps = photo.stack
        let ctx = context
        let cs = colorSpace
        return { [weak self] cg in
            guard let self else { return cg }
            let input = CIImage(cgImage: cg)
            guard let out = self.apply(steps: steps, to: input, quality: .preview) else { return cg }
            return ctx.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: cs) ?? cg
        }
    }

    /// The sharpest bitmap the cache can give us that is at least `pixels` on the long side,
    /// decoded lazily on a background queue.
    func viewerImage(for photo: PhotoItem, pixels: Int,
                     completion: @escaping (CGImage?) -> Void) {
        ThumbnailCache.shared.request(photo: photo, pixels: pixels,
                                      priority: .visible,
                                      transform: editTransform(for: photo),
                                      completion: completion)
    }

    // MARK: - Viewer tiles

    /// Renders a normalised sub-rectangle of the photo — one screenful plus a margin.
    ///
    /// This is the answer to "zooming in makes it slow". The viewer used to ask for the *whole*
    /// photo at ever larger sizes (3200, then 6144 pixels), which for a 24-megapixel frame means a
    /// full decode plus a JPEG round trip before any extra detail appears — measured at over seven
    /// seconds. But at that magnification only a window-full of the picture is ever visible, so
    /// rasterising the entire frame is almost all waste.
    ///
    /// Cropping first and rasterising second fixes both halves of the problem: the work is
    /// proportional to the screen rather than to the file, and because a `CIImage` built from a
    /// URL is a lazy graph, `createCGImage` only decodes the region it is asked for.
    ///
    /// - Parameter rect: the region to keep, in unit coordinates with the origin at the
    ///   **top left** (the same convention as the viewer's layout maths).
    func viewerTile(for photo: PhotoItem, unitRect rect: CGRect, maxPixels: Int) -> CGImage? {
        guard let base = CIImage(contentsOf: photo.url,
                                 options: [.applyOrientationProperty: true]) else {
            // Formats CoreImage will not open lazily (some RAW variants) fall back to the packed
            // decode path; correctness first.
            return ThumbnailCache.shared.imageNow(photo: photo, pixels: maxPixels,
                                                  transform: editTransform(for: photo))
        }

        var ci = base
        if let out = apply(steps: photo.stack, to: ci, quality: .preview) { ci = out }
        let extent = ci.extent
        guard extent.width > 1, extent.height > 1 else { return nil }

        let unit = CGRect(x: min(max(rect.minX, 0), 1),
                          y: min(max(rect.minY, 0), 1),
                          width: min(max(rect.width, 0.0005), 1),
                          height: min(max(rect.height, 0.0005), 1))

        // CIImage's origin is bottom-left, the layout's is top-left.
        let crop = CGRect(x: extent.minX + unit.minX * extent.width,
                          y: extent.minY + (1 - unit.maxY) * extent.height,
                          width: unit.width * extent.width,
                          height: unit.height * extent.height)
        var tile = ci.cropped(to: crop)

        // Never render more pixels than the region actually has — upscaling here would be pure
        // waste, the GPU does that for free when the layer is drawn.
        let longest = max(crop.width, crop.height)
        let native = max(1, Int(longest.rounded()))
        let target = min(max(16, maxPixels), native)
        if native > target {
            let scale = CGFloat(target) / longest
            tile = tile.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        tile = tile.transformed(by: CGAffineTransform(translationX: -tile.extent.origin.x,
                                                      y: -tile.extent.origin.y))
        return context.createCGImage(tile, from: tile.extent, format: .RGBA8, colorSpace: colorSpace)
    }

    /// Whether a sharper version than `pixels` is worth asking for.
    static func nextDetailBucket(after pixels: Int) -> Int? {
        ThumbBuckets.next(after: pixels)
    }

    func invalidate(url: URL) {
        sourceCache.removeObject(forKey: ("src:" + url.path) as NSString)
        renderCache.removeAllObjects()
    }

    // MARK: - Frosted backdrop

    private let frostCache = NSCache<NSString, CachedImage>()

    /// A small, pre-blurred, pre-saturated wash of the photo for the viewer backdrop.
    ///
    /// Rendered once and cached. Doing this live in SwiftUI (`.blur(radius: 65)`) forced a
    /// full-frame blur pass on every zoom step, which is what made the old viewer stutter —
    /// the backdrop is static, so it should be computed exactly once.
    func frostedBackdrop(for photo: PhotoItem) -> CGImage? {
        let key = "frost:\(photo.url.path):\(photo.stack.count)" as NSString
        if let hit = frostCache.object(forKey: key) { return hit.image }

        guard let src = thumbnailNow(for: photo, displaySize: 420) else { return nil }
        let input = CIImage(cgImage: src)
        let small = input.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        let blurred = small
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 18)
            .cropped(to: small.extent)
        let graded = blurred.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 1.55,
            kCIInputBrightnessKey: -0.05,
        ])

        guard let cg = context.createCGImage(graded, from: graded.extent,
                                             format: .RGBA8, colorSpace: colorSpace) else { return nil }
        frostCache.setObject(CachedImage(cg, key: key as String), forKey: key)
        return cg
    }

    // MARK: - Render

    enum Quality { case preview, full }

    /// Renders the photo with its whole edit stack applied.
    func render(photo: PhotoItem, maxDimension: CGFloat, quality: Quality = .preview) -> CGImage? {
        let key = "render:\(photo.url.path):\(photo.stack.hashValue):\(Int(maxDimension)):\(quality == .full ? 1 : 0)"
        if quality == .preview, let hit = renderCache.object(forKey: key as NSString) { return hit.image }

        // Fast path: nothing to apply, so the decimating decode in the thumbnail cache is both
        // correct and an order of magnitude cheaper than `sourceImage` + CoreImage. This used to
        // be the single biggest cost of opening the viewer — a 24-megapixel decode and a full
        // CoreImage round trip just to show an unedited photo.
        if photo.stack.isEmpty {
            guard let cg = ThumbnailCache.shared.imageNow(photo: photo,
                                                          pixels: Int(maxDimension),
                                                          transform: nil) else { return nil }
            if quality == .preview {
                renderCache.setObject(CachedImage(cg, key: key), forKey: key as NSString)
            }
            return cg
        }

        guard var cg = sourceImage(for: photo.url) else { return nil }
        var ci = CIImage(cgImage: cg)

        if let out = apply(steps: photo.stack, to: ci, quality: quality) {
            ci = out
        }

        // Downscale for preview after the pipeline (filters like grain look right at full size first)
        let extent = ci.extent
        if quality == .preview, extent.width > maxDimension || extent.height > maxDimension {
            let scale = min(maxDimension / extent.width, maxDimension / extent.height)
            ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x, y: -ci.extent.origin.y))
        }

        guard let rendered = context.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: colorSpace) else {
            return nil
        }
        cg = rendered
        if quality == .preview {
            renderCache.setObject(CachedImage(cg, key: key), forKey: key as NSString)
        }
        return cg
    }

    /// Applies the full stack to a CIImage.
    func apply(steps: [EditStep], to input: CIImage, quality: Quality) -> CIImage? {
        var image = input
        for step in steps where step.enabled {
            image = apply(op: step.op, to: image, quality: quality)
        }
        return image
    }

    private func apply(op: EditOp, to image: CIImage, quality: Quality) -> CIImage {
        switch op {
        case .rotate(let quarters):
            return Filters.rotate(image, quarterTurns: quarters)
        case .flipHorizontal:
            return image.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: image.extent.width, y: 0))
        case .flipVertical:
            return image.transformed(by: CGAffineTransform(scaleX: 1, y: -1))
                .transformed(by: CGAffineTransform(translationX: 0, y: image.extent.height))
        case .straighten(let degrees):
            return Filters.straighten(image, degrees: degrees)
        case .crop(let rect, _):
            return Filters.crop(image, normalizedRect: rect)
        case .effect(let id, let params):
            return Filters.apply(id: id, params: params, to: image, context: context)
        case .tuning(let t):
            return Filters.tuning(image, params: t, context: context)
        case .redeye(let points, let radius):
            return Filters.redeye(image, points: points, radius: radius, context: context)
        case .retouch(let points, let radius):
            return Filters.retouch(image, points: points, radius: radius, context: context)
        case .whitePoint(let point, let strength):
            return Filters.neutralPicker(image, at: point, strength: strength, context: context)
        case .text(let overlay):
            return Filters.drawText(overlay, on: image)
        }
    }

    /// Renders an arbitrary stack, used for live previews in the editor.
    func render(stack: [EditStep], url: URL, maxDimension: CGFloat) -> CGImage? {
        guard let cg = sourceImage(for: url) else { return nil }
        var ci = CIImage(cgImage: cg)
        if let out = apply(steps: stack, to: ci, quality: .preview) { ci = out }
        let extent = ci.extent
        if extent.width > maxDimension || extent.height > maxDimension {
            let scale = min(maxDimension / extent.width, maxDimension / extent.height)
            ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x, y: -ci.extent.origin.y))
        }
        return context.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: colorSpace)
    }

    // MARK: - Export helpers

    func exportCGImage(photo: PhotoItem, maxDimension: CGFloat?) -> CGImage? {
        guard let ci = fullImage(photo) else { return nil }
        var out = ci
        if let maxDimension, maxDimension > 0, out.extent.width > maxDimension || out.extent.height > maxDimension {
            let scale = min(maxDimension / out.extent.width, maxDimension / out.extent.height)
            out = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            out = out.transformed(by: CGAffineTransform(translationX: -out.extent.origin.x, y: -out.extent.origin.y))
        }
        return context.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: colorSpace)
    }

    func fullImage(_ photo: PhotoItem) -> CIImage? {
        guard let cg = sourceImage(for: photo.url) else { return nil }
        return apply(steps: photo.stack, to: CIImage(cgImage: cg), quality: .full)
    }

    func makeContext() -> CIContext { context }
}
