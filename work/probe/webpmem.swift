import Foundation
import ImageIO
import CoreGraphics

// Re-decode, or re-read?
//
// The GIF control proves ImageIO *can* walk frames in O(1) each (180 frames in 0.80 s). The WebP
// decoder takes 88 s for the same shape of file. Two explanations remain, and they have opposite
// fixes:
//
//   - It re-decodes frames 0…i for every request → nothing to do from outside ImageIO; the only
//     way to play is to pay the quadratic cost once and hold the frames.
//   - It re-reads the file to reach chunk i → putting the bytes in memory first makes it linear,
//     and animation becomes easy.
//
// The same file, same request pattern, three sources: URL, mapped bytes, resident bytes.

let args = Array(CommandLine.arguments.dropFirst())
guard let path = args.first else { exit(2) }
let url = URL(fileURLWithPath: path)
let limit = args.count > 1 ? Int(args[1]) ?? 60 : 60
func now() -> Double { Date().timeIntervalSince1970 }

let decodeOpts: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]

func walk(_ label: String, _ make: () -> CGImageSource?) {
    guard let src = make() else { print("  \(label): could not open"); return }
    let count = min(CGImageSourceGetCount(src), limit)
    let t = now()
    var marks: [String] = []
    for i in 0..<count {
        let t0 = now()
        _ = CGImageSourceCreateImageAtIndex(src, i, decodeOpts as CFDictionary)
        if [0, 10, 30, 59].contains(i) { marks.append(String(format: "f%d=%.0fms", i, (now() - t0) * 1000)) }
    }
    let total = now() - t
    print(String(format: "  %-22@ %6.2f s for %3d frames  (%.1f ms/frame)   %@",
                 label as NSString, total, count, total / Double(count) * 1000,
                 marks.joined(separator: " ") as NSString))
}

print("file: \(url.lastPathComponent)")
print("\ncold, one traversal each:")
walk("from URL") { CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) }

let tRead = now()
let resident = try? Data(contentsOf: url)
print(String(format: "  (read whole file into memory: %.2f s, %.1f MB)", now() - tRead,
             Double(resident?.count ?? 0) / 1024 / 1024))

walk("from Data (resident)") {
    resident.flatMap { CGImageSourceCreateWithData($0 as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) }
}
walk("from Data (mapped)") { CGImageSourceCreateWithData((try? Data(contentsOf: url, options: [.mappedIfSafe])) as CFData? ?? Data() as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) }

print("\nagain, to separate first-touch cost from steady state:")
walk("from URL, 2nd") { CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) }
walk("from Data (resident) 2nd") {
    resident.flatMap { CGImageSourceCreateWithData($0 as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) }
}
