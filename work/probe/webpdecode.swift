import Foundation
import ImageIO
import CoreGraphics

// Can we decode frame *i* at a chosen size, and what does it cost?
//
// The animation only becomes cheap if both answers are good. `CGImageSourceCreateThumbnailAtIndex`
// is the one call that downsamples during decode rather than after, so it is the interesting one —
// but it is documented for still images, and its behaviour on `ANMF` frames has to be measured
// rather than assumed. The alternative is a full 720x976 (or 4000x4000) decode per frame, which
// decides whether animation is possible at all.

let args = Array(CommandLine.arguments.dropFirst())
guard let path = args.first else { exit(2) }
let maxPixels = args.count > 1 ? Int(args[1]) ?? 1024 : 1024
let url = URL(fileURLWithPath: path)

func now() -> Double { Date().timeIntervalSince1970 }

// --- Cost of opening the source, which decides whether we can afford one per frame. ---
var t0 = now()
var opened = 0
for _ in 0..<5 {
    if CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) != nil { opened += 1 }
}
print(String(format: "open source         : %.2f ms  (%d/5 ok)", (now() - t0) / 5 * 1000, opened))

guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
    print("cannot open"); exit(1)
}
let count = CGImageSourceGetCount(src)
print("frame count         : \(count)")

// --- Full decode of one frame, no downsampling. ---
t0 = now()
var full: CGImage?
for _ in 0..<3 { full = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) }
let fullMs = (now() - t0) / 3 * 1000
print(String(format: "full decode f0      : %.1f ms  -> %@", fullMs,
             full.map { "\($0.width)x\($0.height)" } ?? "nil"))

// --- Downsampling decode, the call the animator would actually make. ---
let thumbOpts: [CFString: Any] = [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceCreateThumbnailWithTransform: true,
    kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    kCGImageSourceShouldCacheImmediately: true,
]
t0 = now()
var first: CGImage?
for _ in 0..<3 { first = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) }
let firstMs = (now() - t0) / 3 * 1000
print(String(format: "thumb decode f0     : %.1f ms  -> %@  (asked max %d)", firstMs,
             first.map { "\($0.width)x\($0.height)" } ?? "nil", maxPixels))

// --- Does the thumbnail call honour indices other than 0, or silently repeat frame 0? ---
// This is the failure that would be invisible in a screenshot of an animated image.
print("\nper-frame thumbnail decode (warm source):")
var total = 0.0
var sizes: Set<String> = []
for i in 0..<min(count, 12) {
    let t = now()
    let img = CGImageSourceCreateThumbnailAtIndex(src, i, thumbOpts as CFDictionary)
    let ms = (now() - t) * 1000
    total += ms
    var fp = "nil"
    if let img {
        sizes.insert("\(img.width)x\(img.height)")
        // Content fingerprint, so "same object shape" cannot hide "same picture".
        var bytes = [UInt8](repeating: 0, count: 8 * 8 * 4)
        if let ctx = CGContext(data: &bytes, width: 8, height: 8, bitsPerComponent: 8,
                               bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            var h: UInt64 = 1469598103934665603
            for b in bytes { h = (h ^ UInt64(b)) &* 1099511628211 }
            fp = String(h % 0xFFFFFF, radix: 16)
        }
    }
    print(String(format: "  frame %2d  %6.1f ms  %-12@  fp=%@", i, ms,
                 (img.map { "\($0.width)x\($0.height)" } ?? "nil") as NSString, fp as NSString))
}
print(String(format: "  → %.1f ms/frame, distinct sizes: %@", total / Double(min(count, 12)),
             sizes.sorted().joined(separator: ", ")))

// --- Is the linear growth I/O or decoding? Re-run the same loop; page cache should absorb it
// --- if the cost was reading the file to reach chunk i.
print("\nsecond pass over the same frames (page cache warm):")
var t2 = 0.0
for i in 0..<min(count, 12) {
    let t = now()
    _ = CGImageSourceCreateThumbnailAtIndex(src, i, thumbOpts as CFDictionary)
    t2 += (now() - t) * 1000
}
print(String(format: "  → %.1f ms/frame average on pass 2", t2 / Double(min(count, 12))))

print("\nsecond pass, last frame first (worst case seek):")
for i in [11, 10, 9, 0, 1, 5] where i < count {
    let t = now()
    _ = CGImageSourceCreateThumbnailAtIndex(src, i, thumbOpts as CFDictionary)
    print(String(format: "  frame %2d  %6.1f ms", i, (now() - t) * 1000))
}

// --- And the same for the full decode path, to compare. ---
print("\nper-frame FULL decode (warm source):")
t0 = now()
var fps: Set<String> = []
for i in 0..<min(count, 12) {
    guard let img = CGImageSourceCreateImageAtIndex(src, i, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { continue }
    var bytes = [UInt8](repeating: 0, count: 64)
    if let ctx = CGContext(data: &bytes, width: 4, height: 4, bitsPerComponent: 8,
                           bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 4, height: 4))
        var h: UInt64 = 1469598103934665603
        for b in bytes { h = (h ^ UInt64(b)) &* 1099511628211 }
        fps.insert(String(h % 0xFFFF, radix: 16))
    }
}
print(String(format: "  → %.1f ms/frame, %d distinct fingerprints in 12 frames", (now() - t0) / 12 * 1000, fps.count))
