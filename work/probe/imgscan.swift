import Foundation
import CoreGraphics
import ImageIO

// imgscan <png> col <x>        — colour runs down one column
// imgscan <png> row <y>        — colour runs across one row
//
// Printed as value ranges in points (the image is assumed to be a 2x screenshot), because the
// question this answers is always "how tall is that band", and eyeballing a screenshot gets the
// boundary wrong by tens of points.

func load(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func pixels(_ img: CGImage) -> (buf: [UInt8], w: Int, h: Int, stride: Int) {
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpaceCreateDeviceRGB()
    buf.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return (buf, w, h, w * 4)
}

let args = CommandLine.arguments
guard args.count >= 4, let img = load(args[1]) else {
    FileHandle.standardError.write(Data("usage: imgscan <png> col|row <n> [scale]\n".utf8))
    exit(1)
}
let (buf, w, h, stride) = pixels(img)
let axis = args[2]
let n = Int(args[3]) ?? 0
// Pixels per point. A screenshot of a retina window is 2x; the app's own snapshot is 1x.
let scale = args.count >= 5 ? (Double(args[4]) ?? 2.0) : 2.0
let count = axis == "col" ? h : w

func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    let o = y * stride + x * 4
    return (Int(buf[o]), Int(buf[o + 1]), Int(buf[o + 2]))
}

var start = 0
var prev = axis == "col" ? rgb(n, 0) : rgb(0, n)
for i in 1...count {
    let cur = i < count ? (axis == "col" ? rgb(n, i) : rgb(i, n)) : (-1, -1, -1)
    if cur != prev {
        let a = Double(start) / scale, b = Double(i) / scale
        print(String(format: "%7.1f – %7.1f pt  (%5d – %5d px)  rgb(%3d,%3d,%3d)",
                     a, b, start, i, prev.0, prev.1, prev.2))
        start = i
        prev = cur
    }
}
