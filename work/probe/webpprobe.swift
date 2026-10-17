import Foundation
import ImageIO
import CoreGraphics
import AppKit

// What does this machine's ImageIO actually give us for an animated WebP?
//
// Two questions decide the whole design:
//   1. Does `CGImageSourceGetCount` report more than one frame? (Can we decode frames at all?)
//   2. Where do the per-frame delays live — in the WebP-specific dictionary, or nowhere?
//
// If (1) is yes, animation is a SwiftUI problem. If it is no, it is a decoder problem, and the
// answer is very different (we would have to drive libwebp ourselves).

func hex(_ b: UInt8) -> String { String(format: "%02x", b) }

let paths = Array(CommandLine.arguments.dropFirst())
guard !paths.isEmpty else {
    FileHandle.standardError.write("usage: webpprobe <file>...\n".data(using: .utf8)!)
    exit(2)
}

for path in paths {
    let url = URL(fileURLWithPath: path)
    print("=== \(url.lastPathComponent) ===")

    // --- Container facts, read straight from the bytes. Trust nothing above this. ---
    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
        print("  unreadable"); continue
    }
    let bytes = [UInt8](data.prefix(64))
    print("  RIFF magic      : \(String(bytes: bytes[0..<4], encoding: .ascii) ?? "?") / " +
          "\(String(bytes: bytes[8..<12], encoding: .ascii) ?? "?")")
    // Walk the RIFF chunk list: VP8X/ANIM/ANMF are the animation markers.
    var offset = 12
    var chunks: [(String, Int)] = []
    while offset + 8 <= data.count {
        let id = String(bytes: [UInt8](data[offset..<offset+4]), encoding: .ascii) ?? "????"
        let size = data.withUnsafeBytes { raw -> Int in
            Int(raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
        }
        chunks.append((id, size))
        if id == "ANMF" { break }               // first frame is enough to prove animation
        offset += 8 + size + (size % 2)
        if chunks.count > 12 { break }
    }
    print("  chunks          : \(chunks.map { "\($0.0)(\($0.1))" }.joined(separator: " "))")
    let animated = chunks.contains { $0.0 == "ANIM" || $0.0 == "ANMF" }
    print("  has ANIM/ANMF   : \(animated ? "YES — animated" : "no — still image")")

    // --- Now what ImageIO makes of it. ---
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        print("  ImageIO         : cannot open"); continue
    }
    let sourceType = (CGImageSourceGetType(src) as String?) ?? "?"
    let count = CGImageSourceGetCount(src)
    print("  ImageIO type    : \(sourceType)")
    print("  frame count     : \(count)")

    if let props = CGImageSourceCopyProperties(src, nil) as? [CFString: Any] {
        let keys = props.keys.map { $0 as String }.sorted()
        print("  file properties : \(keys.joined(separator: ", "))")
    }

    let frames = min(count, 6)
    for i in 0..<frames {
        var line = "  frame \(i)"
        if let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] {
            let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            line += String(format: "  %dx%d", w, h)
            // GIF-style delay key. WebP may or may not populate it.
            let gif = p[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let gifDelay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
            // WebP-specific dictionary.
            let webp = p[kCGImagePropertyWebPDictionary] as? [CFString: Any]
            let webpDelay = (webp?[kCGImagePropertyWebPUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? (webp?[kCGImagePropertyWebPDelayTime] as? NSNumber)?.doubleValue
            line += "  gifDelay=\(gifDelay.map { String(format: "%.3f", $0) } ?? "—")"
            line += "  webpDelay=\(webpDelay.map { String(format: "%.3f", $0) } ?? "—")"
            if webp != nil { line += "  webpDictKeys=\(webp!.keys.map { $0 as String }.sorted().joined(separator: ","))" }
            if let loop = (p[kCGImagePropertyWebPDictionary] as? [CFString: Any])?[kCGImagePropertyWebPLoopCount] as? NSNumber {
                line += "  loop=\(loop.intValue)"
            }
        }
        if let cg = CGImageSourceCreateImageAtIndex(src, i, nil) {
            line += "  decoded=\(cg.width)x\(cg.height)"
        } else {
            line += "  decoded=NIL"
        }
        print(line)
    }
    if count > frames { print("  … \(count - frames) more frames") }

    // --- Can NSImage animate it on its own? That would make the view trivial. ---
    if let ns = NSImage(contentsOf: url) {
        let reps = ns.representations
        let animatedRep = reps.contains { ($0 as? NSBitmapImageRep)?.value(forProperty: .frameCount) != nil }
        print("  NSImage         : \(Int(ns.size.width))x\(Int(ns.size.height)) pt, " +
              "\(reps.count) rep(s), animatedRep=\(animatedRep ? "yes" : "no")")
        for r in reps {
            let fc = (r as? NSBitmapImageRep)?.value(forProperty: .frameCount) as? Int
            print("     rep \(type(of: r))  frames=\(fc.map(String.init) ?? "—")")
        }
    } else {
        print("  NSImage         : nil")
    }
    print("")
}
