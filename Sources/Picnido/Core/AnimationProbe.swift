import Foundation
import CoreGraphics
import ImageIO

/// What an animated file is, short of decoding it.
///
/// Everything here comes from the container: the RIFF chunk index for WebP, the GIF dictionary
/// for GIF. That matters because the alternative — asking a decoder — means loading a file that
/// can be twenty megabytes into memory just to find out whether it moves, and the library grid
/// asks that question about every photo on screen.
struct AnimationInfo {
    let frameCount: Int
    /// The size every frame composites into. For WebP this is the canvas; for GIF, which has no
    /// canvas, the size of the first frame.
    let canvas: CGSize
    /// As declared: 0 means loop forever.
    let loopCount: Int
    /// Seconds per frame, in order. Never empty, never contains a zero.
    let durations: [Double]

    var totalDuration: Double { durations.reduce(0, +) }
    var isAnimated: Bool { frameCount > 1 }

    /// How long frame `index` should stay on screen, wrapping.
    func duration(at index: Int) -> Double {
        guard !durations.isEmpty else { return 0.1 }
        return durations[index % durations.count]
    }
}

/// Reads animation metadata out of a file's header without decoding it.
///
/// Results are cached by path plus modification time, so a grid cell may ask on every redraw
/// without touching the disk again.
enum AnimationProbe {

    private static let cache = NSCache<NSString, Box>()

    private final class Box {
        let info: AnimationInfo?
        init(_ info: AnimationInfo?) { self.info = info }
    }

    /// The animation in `url`, or nil if it is not an animated image this app can play.
    ///
    /// Returning nil is the common case and is not an error: it is the answer for every still
    /// image, for a one-frame WebP, and for a format nobody claims to animate.
    static func info(for url: URL) -> AnimationInfo? {
        let key = cacheKey(url) as NSString
        if let hit = cache.object(forKey: key) { return hit.info }

        let info = parse(url)
        cache.setObject(Box(info), forKey: key)
        return info
    }

    /// Whether this file should be offered to the animation hub at all.
    ///
    /// Cheap, and deliberately so — the extension check keeps the header reader off the hot path
    /// for the several thousand JPEGs a library can hold.
    static func mayAnimate(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "webp", "gif": return true
        default: return false
        }
    }

    private static func cacheKey(_ url: URL) -> String {
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
            .flatMap { $0.contentModificationDate }?.timeIntervalSince1970 ?? 0
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey])).flatMap { $0.fileSize } ?? 0
        return "\(url.path)|\(Int(stamp))|\(size)"
    }

    private static func parse(_ url: URL) -> AnimationInfo? {
        switch url.pathExtension.lowercased() {
        case "webp": return webp(url)
        case "gif": return gif(url)
        default: return nil
        }
    }

    // MARK: - WebP

    /// Walks the RIFF chunk index.
    ///
    /// The chunks that matter are all near the front except `ANMF`, one per frame, which is what
    /// makes this worth doing with seeks rather than by reading the file: the frame records are
    /// spread through the whole animation with an 18 MB payload between the first and the last,
    /// but each record is only sixteen bytes and skipping the payload is a seek.
    private static func webp(_ url: URL) -> AnimationInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var cursor = 0
        func read(_ count: Int) -> Data? {
            guard count > 0, let d = try? handle.read(upToCount: count), d.count == count else { return nil }
            cursor += count
            return d
        }
        func skip(_ count: Int) -> Bool {
            guard count >= 0 else { return false }
            guard count > 0 else { return true }
            guard (try? handle.seek(toOffset: UInt64(cursor + count))) != nil else { return false }
            cursor += count
            return true
        }

        guard let riff = read(4), riff == Data("RIFF".utf8) else { return nil }
        guard read(4) != nil else { return nil }                       // file size, not needed
        guard let form = read(4), form == Data("WEBP".utf8) else { return nil }

        var flags: UInt8 = 0
        var canvas = CGSize.zero
        var loopCount = 0
        var durations: [Double] = []

        while true {
            guard let fourccData = read(4) else { break }
            guard let sizeData = read(4) else { break }
            let fourcc = String(decoding: fourccData, as: UTF8.self)
            let size = Int(u32(sizeData, 0))

            // A chunk header that claims more bytes than any real file has means the walk has
            // run off the end of something malformed. Stop rather than trusting it.
            if size < 0 || size > 1 << 30 { break }

            if fourcc == "VP8X" {
                guard let payload = read(min(size, 10)), payload.count >= 10 else { break }
                flags = payload[0]
                guard flags & 0x02 != 0 else { return nil }             // no animation flag
                canvas = CGSize(width: Double(u24(payload, 4) + 1),
                                height: Double(u24(payload, 7) + 1))
                guard skip(size - payload.count) else { break }
            } else if fourcc == "ANIM" {
                guard let payload = read(min(size, 6)), payload.count >= 6 else { break }
                loopCount = Int(u16(payload, 4))
                guard skip(size - payload.count) else { break }
            } else if fourcc == "ANMF" {
                guard let payload = read(min(size, 16)), payload.count >= 16 else { break }
                let ms = u24(payload, 12)
                // Zero-duration frames exist and are not a bug in the file; they mean "as fast as
                // possible". A floor keeps a pathological file from spinning the player at the
                // refresh rate, and 20 ms is the floor browsers settled on for the same reason.
                durations.append(max(Double(ms) / 1000.0, 0.02))
                guard skip(size - payload.count) else { break }
            } else {
                guard skip(size) else { break }
            }

            // RIFF pads every chunk to an even length.
            if size % 2 == 1 { guard skip(1) else { break } }
        }

        guard !durations.isEmpty, canvas.width > 0, canvas.height > 0 else { return nil }
        return AnimationInfo(frameCount: durations.count, canvas: canvas,
                             loopCount: loopCount, durations: durations)
    }

    private static func u16(_ d: Data, _ o: Int) -> Int {
        guard o + 1 < d.count else { return 0 }
        return Int(d[o]) | Int(d[o + 1]) << 8
    }

    private static func u24(_ d: Data, _ o: Int) -> Int {
        guard o + 2 < d.count else { return 0 }
        return Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16
    }

    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        guard o + 3 < d.count else { return 0 }
        return UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
    }

    // MARK: - GIF

    /// GIF goes through ImageIO rather than a hand-rolled reader: the frame delays are scattered
    /// across per-frame Graphic Control Extensions and the loop count lives in a Netscape
    /// extension that ImageIO already knows how to find. Reading them here would be a parser for
    /// no benefit — unlike WebP, ImageIO's GIF decoder is genuinely fast (measured: 4.5 ms a
    /// frame, constant, against 490 ms for the same frame count as WebP).
    private static func gif(_ url: URL) -> AnimationInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }

        guard let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let width = (first[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (first[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        guard width > 0, height > 0 else { return nil }

        var durations: [Double] = []
        durations.reserveCapacity(count)
        var loopCount = 0

        for index in 0..<count {
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            // The unclamped value is what the file actually says; the clamped one is ImageIO's
            // opinion of what a viewer should do about it. Prefer the file, floor it afterwards.
            let raw = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
                ?? 0
            durations.append(min(max(raw, 0.02), 10.0))

            if index == 0, let loop = gif?[kCGImagePropertyGIFLoopCount] as? NSNumber {
                loopCount = loop.intValue
            }
        }

        return AnimationInfo(frameCount: count,
                             canvas: CGSize(width: width, height: height),
                             loopCount: loopCount,
                             durations: durations)
    }
}
