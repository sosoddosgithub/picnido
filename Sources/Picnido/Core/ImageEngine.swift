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
    /// Bytes of backing store, so `NSCache` can enforce a `totalCostLimit`.
    ///
    /// This is not decoration. `setObject(_:forKey:)` defaults the cost to zero, and an entry
    /// with zero cost is invisible to `totalCostLimit`: the cache then only ever evicts at its
    /// count limit, which for viewer-sized bitmaps is hundreds of megabytes per entry. Passing
    /// the real cost is what makes the byte budget mean anything.
    let cost: Int

    init(_ image: CGImage, key: String) {
        self.image = image
        self.key = key
        self.cost = image.bytesPerRow * image.height
    }
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
        // Budgets are in bytes, and they only bind because every insertion passes a cost. The
        // count limits stay as a second wall: forty 24-megapixel previews is already 1.5 GB, so a
        // count limit alone cannot be the thing that keeps this process inside a laptop's memory.
        renderCache.countLimit = 40
        renderCache.totalCostLimit = 256 * 1024 * 1024
        sourceCache.countLimit = 8
        sourceCache.totalCostLimit = 512 * 1024 * 1024
        frostCache.countLimit = 64
        frostCache.totalCostLimit = 32 * 1024 * 1024
        // One plane of a 101-megapixel file is 388 MB, so the byte budget is what stops the cache
        // from being a memory leak with a count limit in front of it. A full plane plus the
        // half-size one the viewer prefetches plus the eighth-size plate is 491 MB — already more
        // than a 32 GB machine wants to hand to one photo.
        planeCache.countLimit = 4
        planeCache.totalCostLimit = 640 * 1024 * 1024
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
        let boxed = CachedImage(upright, key: key)
        sourceCache.setObject(boxed, forKey: key as NSString, cost: boxed.cost)
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
    //
    // Everything below rests on one rule: **a file is decoded once per photo, not once per
    // screenful**, and nothing that returns a bitmap is allowed to defer the work.
    //
    // The previous version opened a fresh `CIImage(contentsOf:)` for *every* crop and asked
    // `CIContext.createCGImage` for the pixels. Both halves of that were wrong, and together they
    // are exactly the "zooming in freezes the app, the beachball spins for seconds" report:
    //
    //  1. `createCGImage` is lazy. It returns in about a millisecond and leaves the actual
    //     rasterisation to whoever first *draws* the bitmap. In a SwiftUI view that is the main
    //     thread inside a display pass. Measured on a 101-megapixel JPEG: the call returned in
    //     1 ms and the draw that followed blocked for 775 ms.
    //  2. Each crop decoded the whole file again, because the lazy graph was thrown away when the
    //     function returned. Measured: 1271 ms for one crop, 2266 ms for the next one.
    //
    // So the pipeline is now: decode once into a plain, fully materialised RGBA8 bitmap ("the
    // plane"), keep it in a cost-bounded cache, and serve each crop as a `cropping(to:)` of that
    // bitmap plus an explicit draw into a buffer this class owns. A 6656x4160 crop then costs
    // about 15 ms instead of two seconds, and every millisecond of it runs on the caller's
    // background queue.

    /// Fully materialised RGBA8 copies of the original, keyed by decimation factor.
    private let planeCache = NSCache<NSString, CachedImage>()

    /// Rasterises `image` into a bitmap this process owns.
    ///
    /// This is the anti-laziness step. `CGImage` is allowed to be a promise — ImageIO hands back
    /// images whose pixels are still a JPEG stream, and CoreImage hands back images whose pixels
    /// are a graph. Drawing one into a `CGContext` is what turns the promise into bytes, and doing
    /// it here means it happens on whichever queue called us instead of inside a display pass.
    static func flatten(_ image: CGImage,
                        to size: CGSize? = nil,
                        interpolation: CGInterpolationQuality = .none) -> CGImage? {
        let w = Int((size?.width ?? CGFloat(image.width)).rounded())
        let h = Int((size?.height ?? CGFloat(image.height)).rounded())
        guard w > 0, h > 0 else { return nil }
        // BGRA with no alpha channel: the layout CoreAnimation samples without a conversion pass,
        // and the one every crop below is drawn into, so a 1:1 crop is a plain copy.
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)
                                      ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = interpolation
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// A coarser request is allowed to reuse a finer plane that is already cached.
    ///
    /// Without this, stepping between the viewer's whole-picture buckets (2048, then 3072) builds
    /// a second plane from the same file — half a second of decoding for pixels that are already
    /// in memory one level up.
    private func cachedPlane(for photo: PhotoItem, atLeast factor: Int) -> CGImage? {
        for candidate in [1, 2, 4, 8] where candidate <= factor {
            let key = "plane:\(photo.url.path):\(candidate)" as NSString
            if let hit = planeCache.object(forKey: key) { return hit.image }
        }
        return nil
    }

    /// Builds a plane, and never builds the same one twice at once.
    ///
    /// Two requests for the same photo race here by design: the viewer prefetches the half-size
    /// plane while the first crop asks for the full one, and both arrive on different queues. A
    /// fifty-line lock is cheaper than decoding a hundred-megapixel file twice — and the duplicate
    /// is not harmless, because the second one lands in the cache *after* the first and costs the
    /// full half-second of ignored work.
    private let planeGate = NSCondition()
    private var planeInFlight = Set<String>()

    private func buildPlane(key: String, produce: () -> CGImage?) -> CGImage? {
        planeGate.lock()
        while planeInFlight.contains(key) {
            planeGate.wait()
        }
        if let hit = planeCache.object(forKey: key as NSString) {
            planeGate.unlock()
            return hit.image
        }
        planeInFlight.insert(key)
        planeGate.unlock()

        let built = produce()

        planeGate.lock()
        planeInFlight.remove(key)
        planeGate.broadcast()
        planeGate.unlock()
        return built
    }

    /// The whole photo as a flat bitmap, decimated by `factor` (1 = native pixels).
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` is doing the decode even at factor 1: it decimates
    /// during the JPEG decode and bakes the EXIF orientation in, which is why every crop below can
    /// assume upright pixels and why no second pass is needed for a rotated photo.
    func plane(for photo: PhotoItem, factor: Int) -> CGImage? {
        let decimation = max(1, factor)
        let key = "plane:\(photo.url.path):\(decimation)" as NSString
        if let hit = planeCache.object(forKey: key) { return hit.image }
        if let finer = cachedPlane(for: photo, atLeast: decimation) { return finer }

        let nativeLongest = max(photo.pixelWidth, photo.pixelHeight)
        guard nativeLongest > 0 else { return nil }
        let started = Date()
        let built = buildPlane(key: key as String) { [self] in
            guard let src = CGImageSourceCreateWithURL(photo.url as CFURL,
                                                       [kCGImageSourceShouldCache: false] as CFDictionary)
            else { return nil }
            let request = max(16, nativeLongest / decimation)
            guard let decimated = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: request,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary) else { return nil }
            guard let flat = Self.flatten(decimated) else { return nil }
            let boxed = CachedImage(flat, key: key as String)
            planeCache.setObject(boxed, forKey: key, cost: boxed.cost)
            if ProcessInfo.processInfo.environment["PICNIDO_VIEWER_TIMING"] != nil {
                PicnidoAppDelegate.report(String(format: "[engine] plane %dx %dx%d in %.0f ms (%d MB)",
                                                 decimation, flat.width, flat.height,
                                                 Date().timeIntervalSince(started) * 1000,
                                                 boxed.cost / (1024 * 1024)))
            }
            return flat
        }
        // A plane built by a *finer* request while this one waited is just as good.
        return built ?? cachedPlane(for: photo, atLeast: decimation) ?? planeCache.object(forKey: key)?.image
    }

    /// The fastest bitmap that still looks like the picture.
    ///
    /// One eighth of the original, because that is the only decimation ImageIO has a fast path
    /// for: on a hundred-megapixel JPEG, 1/8 takes 93 ms while 1/4 takes 477 ms and 1/1 takes
    /// 579 ms. The viewer paints this first so the click is answered in a tenth of a second rather
    /// than after a half-second decode, then replaces it with the real tile.
    func quickPlate(for photo: PhotoItem) -> CGImage? {
        plane(for: photo, factor: 8)
    }

    /// How far the plane may be decimated before the screen would notice.
    ///
    /// The screen needs `maxPixels` device pixels across this region; the plane must still have at
    /// least that many, so the largest tolerable factor is `regionNative / maxPixels`. Using it
    /// keeps a 101-megapixel file at 97 MB instead of 388 MB whenever the window cannot resolve the
    /// difference — which is most of the time, because a 2048-point-wide window never shows more
    /// than 4096 device pixels of a 8736-pixel-wide photo at once.
    static func decimationFactor(regionNative: CGFloat, maxPixels: Int) -> Int {
        guard regionNative > 1, maxPixels > 0 else { return 1 }
        let tolerance = regionNative / CGFloat(maxPixels)
        for candidate in [8, 4, 2] where CGFloat(candidate) <= tolerance { return candidate }
        return 1
    }

    /// How soft a tile may be before a coarse request refuses to answer.
    ///
    /// Half resolution is the useful boundary: the compositor magnifies it for free while the
    /// hand is moving, and the viewer replaces it within a fifth of a second of the gesture
    /// ending. Everything coarser than the 0.45 line used to be rejected on the grounds that a
    /// soft tile is a downgrade — but the thing it would be downgrading *from* is the plate,
    /// which carries the whole picture at a tenth of that resolution, and a correctly positioned
    /// crop at 45% is worth a great deal more than a full-picture bitmap at 10%. Measured on a
    /// hundred-megapixel file at 400%: rejecting it left the drag with zero new tiles, accepting
    /// it gives a fresh 1092-pixel crop per step for about 15 ms.
    private static let coarseFloor: CGFloat = 0.45

    /// Ceiling on a coarse tile's long side, in pixels.
    ///
    /// The handoff, not the crop, is what costs: a correctly-sized 4368x2856 tile for a wide
    /// window is twelve megapixels, and handing a fresh twelve-megapixel bitmap to CoreAnimation
    /// mid-drag measured 87 ms against 3 ms for the crop itself. Capping the coarse tile here
    /// keeps the pixels the screen can actually resolve in a moving window — it is magnified by
    /// the layer transform either way — and bounds the upload to a third of that.
    private static let coarseCeiling = 2048

    /// The finest plane already in memory for this photo — never builds one.
    private func finestCachedPlane(for photo: PhotoItem) -> CGImage? {
        for candidate in [1, 2, 4, 8] {
            let key = "plane:\(photo.url.path):\(candidate)" as NSString
            if let hit = planeCache.object(forKey: key) { return hit.image }
        }
        return nil
    }

    /// Crops a unit rectangle out of a plane and shrinks it to at most `maxPixels`.
    ///
    /// One implementation for both viewer paths, so a coarse tile and a sharp one are the same
    /// piece of the picture at two resolutions rather than two different geometries.
    private func tile(from plane: CGImage, unit: CGRect, maxPixels: Int) -> CGImage? {
        let pw = CGFloat(plane.width), ph = CGFloat(plane.height)
        let bounds = CGRect(x: 0, y: 0, width: pw, height: ph)
        // CIImage and CGImage both put the origin at the bottom left; the layout puts it at the
        // top left.
        let crop = CGRect(x: unit.minX * pw,
                          y: (1 - unit.maxY) * ph,
                          width: unit.width * pw,
                          height: unit.height * ph).integral.intersection(bounds)
        guard crop.width >= 1, crop.height >= 1, let piece = plane.cropping(to: crop) else {
            return nil
        }

        // Only ever shrink. Asking the rasteriser for more pixels than the region has would be
        // pure waste — a layer transform magnifies the smaller bitmap for free.
        var target = CGSize(width: CGFloat(piece.width), height: CGFloat(piece.height))
        let longest = max(target.width, target.height)
        if longest > CGFloat(maxPixels) {
            let scale = CGFloat(maxPixels) / longest
            target = CGSize(width: max(1, (target.width * scale).rounded()),
                            height: max(1, (target.height * scale).rounded()))
        }
        let quality: CGInterpolationQuality =
            target.width < CGFloat(piece.width) - 1 ? .medium : .none
        return Self.flatten(piece, to: target, interpolation: quality)
    }

    /// Renders a normalised sub-rectangle of the photo — one screenful plus a margin.
    ///
    /// - Parameter rect: the region to keep, in unit coordinates with the origin at the
    ///   **top left** (the same convention as the viewer's layout maths).
    /// - Parameter coarse: answer only from pixels already in memory. A full-resolution plane of
    ///   a hundred-megapixel file is 388 MB, and it is the *allocation* — not the decode — that
    ///   stops the main thread: zero-filling that many pages while a gesture is running shows up
    ///   as a one-second hole with no frame in it. A coarse request therefore never decodes, and
    ///   says so by returning nil rather than by handing back something too soft to be useful.
    func viewerTile(for photo: PhotoItem, unitRect rect: CGRect, maxPixels: Int,
                    coarse: Bool = false) -> CGImage? {
        let unit = CGRect(x: min(max(rect.minX, 0), 1),
                          y: min(max(rect.minY, 0), 1),
                          width: min(max(rect.width, 0.0005), 1),
                          height: min(max(rect.height, 0.0005), 1))

        // An edited photo still has to go through CoreImage, and there is no plane that could
        // carry filters along with it. That path keeps its old shape but is forced through
        // `flatten` before it leaves, so it cannot smuggle a lazy graph out to the main thread
        // either. It is also never coarse: a filtered render is a CoreImage graph, and the cached
        // plane it would need does not exist.
        if photo.hasEdits { return editedTile(for: photo, unitRect: unit, maxPixels: maxPixels) }

        var w = CGFloat(photo.pixelWidth), h = CGFloat(photo.pixelHeight)
        guard w > 1, h > 1 else {
            // No catalogue dimensions: the geometry is unusable anyway, but the packed path can
            // still answer from the thumbnail cache. Cheap insurance against a format whose
            // header this build cannot read.
            return ThumbnailCache.shared.imageNow(photo: photo, pixels: maxPixels,
                                                  transform: editTransform(for: photo))
        }
        if photo.exifOrientation >= 5 { swap(&w, &h) }

        let plane: CGImage?
        if coarse {
            guard let cached = finestCachedPlane(for: photo) else { return nil }
            let cover = max(unit.width * CGFloat(cached.width), unit.height * CGFloat(cached.height))
            guard cover >= CGFloat(maxPixels) * Self.coarseFloor else { return nil }
            plane = cached
        } else {
            let regionNative = max(unit.width * w, unit.height * h)
            let factor = Self.decimationFactor(regionNative: regionNative, maxPixels: maxPixels)
            guard let built = self.plane(for: photo, factor: factor) else { return nil }
            plane = built
        }
        guard let plane else { return nil }
        let budget = coarse ? min(maxPixels, Self.coarseCeiling) : maxPixels
        return tile(from: plane, unit: unit, maxPixels: budget)
    }

    /// The whole photo, no more than `maxPixels` on the long side — served from the plane.
    ///
    /// The viewer used to ask the thumbnail cache for this. That works, but each *bucket* is a
    /// separate ImageIO decode of the whole file — measured at 500–580 ms per bucket on a
    /// 101-megapixel JPEG — and stepping zoom up and down walks across buckets, so the same photo
    /// was being decoded again and again. Going through the plane means at most two decodes per
    /// photo no matter how the zoom wanders, and the result is also the bitmap every crop uses.
    func wholeImage(for photo: PhotoItem, maxPixels: Int, coarse: Bool = false) -> CGImage? {
        guard !photo.hasEdits else {
            return ThumbnailCache.shared.imageNow(photo: photo, pixels: maxPixels,
                                                  transform: editTransform(for: photo))
        }
        let nativeLongest = max(photo.pixelWidth, photo.pixelHeight)
        guard nativeLongest > 1 else {
            return ThumbnailCache.shared.imageNow(photo: photo, pixels: maxPixels,
                                                  transform: editTransform(for: photo))
        }
        let plane: CGImage?
        if coarse {
            plane = finestCachedPlane(for: photo)
        } else {
            let factor = Self.decimationFactor(regionNative: CGFloat(nativeLongest),
                                               maxPixels: maxPixels)
            plane = self.plane(for: photo, factor: factor)
        }
        guard let plane else { return nil }
        let maxPixels = coarse ? min(maxPixels, Self.coarseCeiling) : maxPixels
        let longest = max(plane.width, plane.height)
        guard longest > maxPixels else { return plane }
        let scale = CGFloat(maxPixels) / CGFloat(longest)
        let size = CGSize(width: (CGFloat(plane.width) * scale).rounded(),
                          height: (CGFloat(plane.height) * scale).rounded())
        return Self.flatten(plane, to: size, interpolation: .medium)
    }

    /// The edited-photo branch of `viewerTile`, unchanged in what it computes — see the note above
    /// for why it is forced through `flatten`.
    private func editedTile(for photo: PhotoItem, unitRect unit: CGRect,
                            maxPixels: Int) -> CGImage? {
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

        let crop = CGRect(x: extent.minX + unit.minX * extent.width,
                          y: extent.minY + (1 - unit.maxY) * extent.height,
                          width: unit.width * extent.width,
                          height: unit.height * extent.height)
        var tile = ci.cropped(to: crop)

        let longest = max(crop.width, crop.height)
        let native = max(1, Int(longest.rounded()))
        let target = min(max(16, maxPixels), native)
        if native > target {
            let scale = CGFloat(target) / longest
            tile = tile.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        tile = tile.transformed(by: CGAffineTransform(translationX: -tile.extent.origin.x,
                                                      y: -tile.extent.origin.y))
        guard let rendered = context.createCGImage(tile, from: tile.extent,
                                                   format: .RGBA8, colorSpace: colorSpace) else {
            return nil
        }
        return Self.flatten(rendered) ?? rendered
    }

    /// Whether a sharper version than `pixels` is worth asking for.
    static func nextDetailBucket(after pixels: Int) -> Int? {
        ThumbBuckets.next(after: pixels)
    }

    func invalidate(url: URL) {
        sourceCache.removeObject(forKey: ("src:" + url.path) as NSString)
        renderCache.removeAllObjects()
        for factor in [1, 2, 4, 8] {
            planeCache.removeObject(forKey: "plane:\(url.path):\(factor)" as NSString)
        }
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
        let boxed = CachedImage(cg, key: key as String)
        frostCache.setObject(boxed, forKey: key, cost: boxed.cost)
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
                let boxed = CachedImage(cg, key: key)
                renderCache.setObject(boxed, forKey: key as NSString, cost: boxed.cost)
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
            let boxed = CachedImage(cg, key: key)
            renderCache.setObject(boxed, forKey: key as NSString, cost: boxed.cost)
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
