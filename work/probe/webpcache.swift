import Foundation
import ImageIO
import CoreGraphics

// The one experiment that decides the architecture.
//
// Measurements so far are consistent with two very different worlds:
//   (a) frame i costs O(i) *every time* — no decoder state is kept, so playing means re-decoding
//       the whole prefix per frame. Unplayable, and no amount of buffering helps.
//   (b) frame i costs O(i) cold, but a sequential walk keeps state, so playing once is O(N).
// The earlier numbers pointed at (a) but a second pass looked 14x faster, so they disagree.
//
// This asks directly: repeat the same request, walk consecutively, and re-walk.

let args = Array(CommandLine.arguments.dropFirst())
guard let path = args.first else { exit(2) }
let url = URL(fileURLWithPath: path)
func now() -> Double { Date().timeIntervalSince1970 }

for cacheFlag in [false, true] {
    let opts: [CFString: Any] = [kCGImageSourceShouldCache: cacheFlag]
    guard let src = CGImageSourceCreateWithURL(url as CFURL, opts as CFDictionary) else { exit(1) }
    let count = CGImageSourceGetCount(src)
    let pick = [10, 50, 100, min(170, count - 1)]
    let decodeOpts: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]

    print("### kCGImageSourceShouldCache = \(cacheFlag)   (file has \(count) frames) ###")
    func time(_ i: Int) -> Double {
        let t = now()
        _ = CGImageSourceCreateImageAtIndex(src, i, decodeOpts as CFDictionary)
        return (now() - t) * 1000
    }
    var line = "  single request, cold   :"
    for i in pick { line += String(format: "  f%d=%.0fms", i, time(i)) }
    print(line)
    line = "  same request, again    :"
    for i in pick { line += String(format: "  f%d=%.0fms", i, time(i)) }
    print(line)
    // Consecutive: does requesting i and then i+1 cost less than requesting i twice?
    let a = time(pick[1]); let b = time(pick[1] + 1); let c = time(pick[1] + 1)
    print(String(format: "  f%d=%.0f  f%d=%.0f  f%d again=%.0f", pick[1], a, pick[1] + 1, b, pick[1] + 1, c))
    // A full walk, twice.
    for pass in 1...2 {
        let t = now()
        for i in 0..<count { _ = CGImageSourceCreateImageAtIndex(src, i, decodeOpts as CFDictionary) }
        print(String(format: "  full walk, pass %d      : %.2f s  (%.1f ms/frame)", pass, now() - t, (now() - t) / Double(count) * 1000))
    }
    print("")
}
