import Foundation
import ImageIO
import CoreGraphics

// embedpreview.swift — separate "what the file carries" from "what the app did with it".
//
// A JPEG can carry more than one image: an EXIF thumbnail, a secondary reduced-size JPEG, and
// the real frame. `CGImageSourceGetCount` says how many, and index 0 is not always the real one.
// Prints, per file: image count, the native size of each image, and a content fingerprint, so
// "every tile shows the same picture" can be traced to the files rather than to the renderer.
//
//   embedpreview <file>…

func fingerprint(_ img: CGImage) -> String {
    let n = 8
    var buf = [UInt8](repeating: 0, count: n * n * 4)
    guard let ctx = CGContext(data: &buf, width: n, height: n, bitsPerComponent: 8,
                              bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "?" }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n))
    var h: UInt64 = 1469598103934665603
    for b in buf { h = (h ^ UInt64(b)) &* 1099511628211 }
    return String(h, radix: 16)
}

/// What `ThumbnailCache.embeddedPreview` would return: the file's own preview, never a decode.
func embedded(_ src: CGImageSource) -> CGImage? {
    CGImageSourceCreateThumbnailAtIndex(src, 0, [
        kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
        kCGImageSourceCreateThumbnailFromImageAlways: false,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 8192,
    ] as CFDictionary)
}

for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        print("\(url.lastPathComponent)\tUNREADABLE"); continue
    }
    let count = CGImageSourceGetCount(src)
    var parts: [String] = []
    for i in 0..<count {
        if let img = CGImageSourceCreateImageAtIndex(src, i, nil) {
            parts.append("img[\(i)]=\(img.width)x\(img.height):\(fingerprint(img))")
        } else {
            parts.append("img[\(i)]=nil")
        }
    }
    var prevProps = "—"
    if let thumb = embedded(src) {
        prevProps = "\(thumb.width)x\(thumb.height):\(fingerprint(thumb))"
    }
    // The same call the app makes for a filmstrip tile (192 px).
    var fast = "nil"
    if let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
        kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
        kCGImageSourceCreateThumbnailFromImageAlways: false,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 8192,
    ] as CFDictionary) {
        fast = "\(thumb.width)x\(thumb.height):\(fingerprint(thumb))"
    }
    print("\(url.lastPathComponent)\tcount=\(count)\tpreview=\(prevProps)\t\(parts.joined(separator: " "))")
    _ = fast
}
