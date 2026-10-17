import Foundation
import ImageIO
import CoreGraphics
import AppKit

// `CGAnimateImageAtURLWithBlock` is the only ImageIO entry point meant for *playing* an animation
// rather than fetching a frame. Everything else (`CreateImageAtIndex`) re-walks the file from
// frame 0 on every call, which measured as O(N^2) — 88 seconds to walk a 180-frame file once.
//
// This probe answers the four questions a player implementation turns on:
//   1. Does it deliver frames at the file's own rate (30 fps), or as fast as it can decode?
//   2. Does a full loop cost seconds or minutes?
//   3. What does it do with `kCGImageAnimationLoopCount`?
//   4. Can it be stopped, and does stopping actually stop the callbacks?
// Plus: does it honour a maximum size, so a 720x976 file does not have to be played at full
// resolution?

let args = Array(CommandLine.arguments.dropFirst())
guard let path = args.first else { exit(2) }
let url = URL(fileURLWithPath: path)
let stopAfter = args.count > 1 ? Int(args[1]) ?? 60 : 60
func now() -> Double { Date().timeIntervalSince1970 }

guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { exit(1) }
print("file: \(url.lastPathComponent)   frames=\(CGImageSourceGetCount(src))")

let propNames: [(CFString, String)] = [
    (kCGImagePropertyWebPDelayTime, "WebPDelayTime"),
    (kCGImagePropertyWebPUnclampedDelayTime, "WebPUnclamped"),
    (kCGImagePropertyWebPLoopCount, "WebPLoopCount"),
]
if let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
   let d = p[kCGImagePropertyWebPDictionary] as? [CFString: Any] {
    for (k, label) in propNames {
        print("  \(label): \(d[k].map { "\($0)" } ?? "—")")
    }
}

print("\n--- CGAnimateImageAtURLWithBlock, no options ---")
var stamps: [Double] = []
var indices: [Int] = []
var sizes: Set<String> = []
var fingerprints: [String] = []
let t0 = now()
var done = false
var callbackThread = ""
let srcFrameCount = CGImageSourceGetCount(src)
var loops = 0

CGAnimateImageAtURLWithBlock(url as CFURL, nil) { index, image, stop in
    if stamps.isEmpty {
        callbackThread = Thread.isMainThread ? "main" : "other"
        print("  first callback: index=\(index)")
    }
    stamps.append(now() - t0)
    indices.append(index)
    sizes.insert("\(image.width)x\(image.height)")
    var bytes = [UInt8](repeating: 0, count: 64)
    if let ctx = CGContext(data: &bytes, width: 4, height: 4, bitsPerComponent: 8,
                           bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 4, height: 4))
        var h: UInt64 = 1469598103934665603
        for b in bytes { h = (h ^ UInt64(b)) &* 1099511628211 }
        fingerprints.append(String(h % 0xFFFFFF, radix: 16))
    }
    if index >= srcFrameCount { loops += 1 }
    if stamps.count >= stopAfter {
        done = true
        stop.pointee = true          // the documented way to end the animation
    }
}

// Let it run, then stop. The animation is driven from a run loop, so pumping it is the whole
// difference between "0 frames" and a playing animation — a busy-wait blocks every callback.
let deadline = now() + 30
while !done && now() < deadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
}

let afterStop = stamps.count
let settleUntil = now() + 0.7
while now() < settleUntil {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
}

print(String(format: "  frames delivered : %d   first callback on %@ thread", stamps.count, callbackThread))
if stamps.count > 1 {
    let span = stamps.last! - stamps.first!
    print(String(format: "  span             : %.2f s  -> %.1f fps over %d intervals",
                 span, Double(stamps.count - 1) / span, stamps.count - 1))
    let deltas = zip(stamps.dropFirst(), stamps).map(-)
    print(String(format: "  frame interval   : min %.1f ms  median %.1f ms  max %.1f ms",
                 deltas.min()! * 1000, deltas.sorted()[deltas.count / 2] * 1000, deltas.max()! * 1000))
}
print("  indices seen     : \(indices.prefix(8).map(String.init).joined(separator: ",")) … last=\(indices.last ?? -1)  (source has \(srcFrameCount), \(loops) wrap(s))")
print("  sizes            : \(sizes.sorted().joined(separator: ", "))")
print("  distinct frames  : \(Set(fingerprints).count) of \(fingerprints.count)")
print(String(format: "  stopped at       : %d frames  (+%d in the 0.7 s after the stop call)",
             afterStop, stamps.count - afterStop))
