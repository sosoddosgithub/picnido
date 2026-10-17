import Foundation
import ImageIO
import CoreGraphics
import AppKit

// The decisive measurement.
//
// Requesting frame *i* costs O(i) — measured, and not explained by disk or caching. That alone
// would make animation impossible, *if* every request re-walked the file from the start.
//
// What matters instead is the cost of walking the frames **once, in order**, because that is what
// a player does. If the whole sequence comes out at roughly (frames x per-frame decode), ImageIO
// keeps decoder state between consecutive requests and animation is affordable; if it comes out at
// the O(N^2) the scattered measurements imply, it is not — and no amount of buffering fixes it.

let args = Array(CommandLine.arguments.dropFirst())
guard let path = args.first else { exit(2) }
let url = URL(fileURLWithPath: path)
let maxPixels = args.count > 1 ? Int(args[1]) ?? 1024 : 1024
func now() -> Double { Date().timeIntervalSince1970 }

guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { exit(1) }
let count = CGImageSourceGetCount(src)
let bytes = (try? Data(contentsOf: url, options: [.mappedIfSafe]).count) ?? 0
print("file        : \(url.lastPathComponent)  \(bytes / 1024 / 1024) MB  \(count) frames")

let opts: [CFString: Any] = [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceCreateThumbnailWithTransform: true,
    kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    kCGImageSourceShouldCacheImmediately: true,
]

// --- Sequential walk, the way a player would do it. ---
var checkpoints: [Int] = [0, 1, 5, 10, 25, 50, 100, 150, 179].filter { $0 < count }
var marks: [Int: Double] = [:]
var memory = 0
let t0 = now()
for i in 0..<count {
    guard let img = CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary) else { continue }
    memory += img.width * img.height * 4
    if checkpoints.contains(i) { marks[i] = now() - t0 }
}
let total = now() - t0
print(String(format: "sequential walk of all %d frames: %.2f s  (%.1f ms/frame)", count, total, total / Double(count) * 1000))
var prev = 0.0
for i in checkpoints {
    if let m = marks[i] {
        print(String(format: "  cumulative to frame %3d: %7.2f s   (+%.2f s)", i, m, m - prev))
        prev = m
    }
}
print(String(format: "  decoded pixels would occupy %.0f MB if all kept", Double(memory) / 1024 / 1024))

// --- Is the O(i) cost per request, or does it only look that way when access is scattered? ---
print("\nsame frames again, now strictly in order:")
var marks2: [Int] = []
var t1 = now()
for i in [0, 5, 10, 25, 50] where i < count {
    _ = CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary)
    marks2.append(i)
    print(String(format: "  to frame %3d: %.2f s", i, now() - t1))
}

// --- What AppKit does with it, for comparison. ---
var t2 = now()
let ns = NSImage(contentsOf: url)
print(String(format: "\nNSImage(contentsOf:) : %.2f s  -> %d reps", now() - t2, ns?.representations.count ?? 0))
