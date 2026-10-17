import Foundation
import CoreGraphics
import ImageIO
import CWebP

/// One animated file, decoded a frame at a time.
///
/// The interface is deliberately forward-only, because that is the truth about the fast path:
/// libwebp's animation decoder recomputes a frame from the beginning of the file every time it is
/// asked for one, so "give me frame 40" costs forty decodes. Measured on an 18 MB / 180-frame
/// animation, walking it in order costs 5.3 ms a frame and is flat; asking for frame 150 alone
/// costs 850 ms. Everything above this class is therefore written to play in sequence, and
/// `rewind` exists only for the loop.
///
/// GIF does not have that constraint — ImageIO's GIF decoder is random-access and flat — but it
/// is hidden behind the same interface so callers do not have to know which format they hold.
final class AnimatedImage: @unchecked Sendable {

    struct Frame {
        let image: CGImage
        /// Position in the animation, for callers that need to know where the loop is.
        let index: Int
    }

    let info: AnimationInfo
    let url: URL

    private let lock = NSLock()
    private let source: FrameSource
    private var index = 0
    private var failed = false

    init?(url: URL, info: AnimationInfo) {
        guard let source = AnimatedImage.makeSource(url: url, info: info) else { return nil }
        self.url = url
        self.info = info
        self.source = source
    }

    private static func makeSource(url: URL, info: AnimationInfo) -> FrameSource? {
        switch url.pathExtension.lowercased() {
        case "webp":
            if let s = WebPFrameSource(url: url) { return s }
            // A WebP the vendored decoder refuses (a newer bitstream, a corrupt chunk) still has
            // a perfectly good still image in it, and ImageIO can read that much. Falling back
            // keeps the photo on screen instead of showing nothing.
            return GIFFrameSource(url: url)
        default:
            return GIFFrameSource(url: url)
        }
    }

    /// The next frame in sequence, wrapping to the start at the end of the animation.
    ///
    /// Returns nil only when the file has become undecodable; every other failure mode — end of
    /// animation, a corrupt frame — is handled by rewinding or by stepping over it.
    func advance() -> Frame? {
        lock.lock()
        defer { lock.unlock() }
        guard !failed else { return nil }

        if let image = source.next() {
            let at = index
            index = (index + 1) % max(1, info.frameCount)
            return Frame(image: image, index: at)
        }
        failed = true
        return nil
    }

    func rewind() {
        lock.lock()
        defer { lock.unlock() }
        source.reset()
        index = 0
        failed = false
    }

    /// Bytes one decoded frame occupies, for the hub's memory budget.
    var frameBytes: Int {
        Int(info.canvas.width) * Int(info.canvas.height) * 4
    }
}

// MARK: - Frame sources

private protocol FrameSource: AnyObject {
    /// Next frame, or nil if the source cannot produce one.
    ///
    /// Implementations that can loop should loop rather than returning nil, so that nil keeps
    /// meaning exactly one thing.
    func next() -> CGImage?
    func reset()
}

/// libwebp's animation decoder, wrapped.
///
/// This is the whole reason the vendored library exists. The system's own WebP decoding goes
/// through ImageIO, whose `CGImageSourceCreateImageAtIndex` costs O(frame index) — 88 seconds to
/// walk a 180-frame animation, against 0.99 seconds here. Playing at 30 frames a second is not
/// possible on the system path at any price.
private final class WebPFrameSource: FrameSource {

    private let decoder: OpaquePointer
    private var buffer: [UInt8]
    private let width: Int
    private let height: Int

    init?(url: URL) {
        guard let decoder = url.path.withCString({ pcw_open($0) }) else { return nil }
        let w = Int(pcw_width(decoder))
        let h = Int(pcw_height(decoder))
        guard w > 0, h > 0, Int(pcw_frame_count(decoder)) > 0 else {
            pcw_close(decoder)
            return nil
        }
        self.decoder = decoder
        self.width = w
        self.height = h
        self.buffer = [UInt8](repeating: 0, count: w * h * 4)
    }

    deinit { pcw_close(decoder) }

    func next() -> CGImage? {
        // Two attempts at most: the first may run off the end, the second is the wrapped frame.
        for _ in 0..<2 {
            var timestamp: Int32 = 0
            let rc = buffer.withUnsafeMutableBufferPointer { p -> Int32 in
                pcw_next(decoder, p.baseAddress, p.count, &timestamp)
            }
            if rc == 0 { return makeImage() }
            if rc == 1 { pcw_reset(decoder); continue }
            return nil
        }
        return nil
    }

    func reset() { pcw_reset(decoder) }

    /// Copies the RGBA frame into a `CGImage`.
    ///
    /// The copy is unavoidable: libwebp hands back a pointer into its own canvas that the next
    /// decode overwrites, and the frame has to stay on screen until then. Six megabytes of
    /// memcpy is about half a millisecond, against the five the decode itself costs.
    ///
    /// `CGImageAlphaInfo.last` — straight, not premultiplied — because that is what libwebp
    /// emits. Tagging straight data as premultiplied is the classic way to give a transparent
    /// animation a bright halo around every edge.
    private func makeImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(buffer) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// ImageIO, for GIF.
///
/// GIF could in principle be handed to libwebp too — no, it could not, and this is worth stating
/// because the numbers invite the mistake: the same 180-frame walk that costs libwebp a second
/// costs ImageIO's *GIF* decoder 0.8 seconds. It is only ImageIO's **WebP** decoder that is
/// pathological. So GIF stays on the system path, where it needs no third-party code at all.
private final class GIFFrameSource: FrameSource {

    private let source: CGImageSource
    private let count: Int
    private var index = 0

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        self.source = source
        self.count = count
    }

    func next() -> CGImage? {
        if index >= count { index = 0 }
        // `kCGImageSourceShouldCache: false` keeps ImageIO from filling its cache with every
        // frame of an animation the moment it appears in a grid.
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateImageAtIndex(source, index, options as CFDictionary)
        else { return nil }
        index += 1
        return image
    }

    func reset() { index = 0 }
}
