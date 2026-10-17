// Renders the app icon and produces AppIcon.icns
import AppKit
import CoreGraphics
import Foundation

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./Resources"
let sizes = [16, 32, 64, 128, 256, 512, 1024]

func drawIcon(size: CGFloat) -> CGImage? {
    let s = Int(size)
    guard let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setShouldAntialias(true)

    let inset = size * 0.045
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.225
    let rounded = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // body
    ctx.saveGState()
    ctx.addPath(rounded)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let colors = [
        CGColor(colorSpace: space, components: [0.09, 0.10, 0.13, 1])!,
        CGColor(colorSpace: space, components: [0.20, 0.22, 0.27, 1])!
    ] as CFArray
    if let grad = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY),
                               end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    }
    ctx.restoreGState()

    // aperture blades
    let centre = CGPoint(x: rect.midX, y: rect.midY)
    let outer = rect.width * 0.40
    let inner = rect.width * 0.155
    let palette: [CGColor] = [
        CGColor(colorSpace: space, components: [0.98, 0.20, 0.24, 0.95])!,
        CGColor(colorSpace: space, components: [0.99, 0.60, 0.11, 0.95])!,
        CGColor(colorSpace: space, components: [0.99, 0.84, 0.16, 0.95])!,
        CGColor(colorSpace: space, components: [0.30, 0.78, 0.36, 0.95])!,
        CGColor(colorSpace: space, components: [0.17, 0.62, 0.94, 0.95])!,
        CGColor(colorSpace: space, components: [0.55, 0.35, 0.88, 0.95])!
    ]
    let blades = palette.count
    for i in 0..<blades {
        let a0 = (CGFloat(i) / CGFloat(blades)) * 2 * .pi
        let a1 = a0 + (2 * .pi / CGFloat(blades)) * 1.12
        let p = CGMutablePath()
        p.move(to: CGPoint(x: centre.x + cos(a0) * outer, y: centre.y + sin(a0) * outer))
        p.addArc(center: centre, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
        let mid = a1
        p.addLine(to: CGPoint(x: centre.x + cos(mid) * inner, y: centre.y + sin(mid) * inner))
        p.addArc(center: centre, radius: inner, startAngle: mid, endAngle: a0, clockwise: true)
        p.closeSubpath()
        ctx.addPath(p)
        ctx.setFillColor(palette[i])
        ctx.fillPath()
    }

    // pupil
    ctx.setFillColor(CGColor(colorSpace: space, components: [0.06, 0.07, 0.09, 1])!)
    ctx.fillEllipse(in: CGRect(x: centre.x - inner * 0.92, y: centre.y - inner * 0.92,
                               width: inner * 1.84, height: inner * 1.84))
    ctx.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 0.85])!)
    ctx.fillEllipse(in: CGRect(x: centre.x + inner * 0.10, y: centre.y + inner * 0.30,
                               width: inner * 0.42, height: inner * 0.42))

    // outer stroke
    ctx.addPath(rounded)
    ctx.setStrokeColor(CGColor(colorSpace: space, components: [1, 1, 1, 0.14])!)
    ctx.setLineWidth(max(size * 0.006, 1))
    ctx.strokePath()

    return ctx.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "icon", code: 1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "icon", code: 2) }
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: outDir).deletingLastPathComponent().appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for s in sizes {
    guard let img = drawIcon(size: CGFloat(s)) else { continue }
    let name: String
    switch s {
    case 16: name = "icon_16x16.png"
    case 32: name = "icon_16x16@2x.png"
    case 64: name = "icon_32x32@2x.png"
    case 128: name = "icon_128x128.png"
    case 256: name = "icon_128x128@2x.png"
    case 512: name = "icon_256x256@2x.png"
    default: name = "icon_512x512@2x.png"
    }
    try write(img, to: iconset.appendingPathComponent(name))
    // also provide the plain 1x names Apple wants
    if s == 32 { try write(img, to: iconset.appendingPathComponent("icon_32x32.png")) }
    if s == 256 { try write(img, to: iconset.appendingPathComponent("icon_256x256.png")) }
    if s == 512 { try write(img, to: iconset.appendingPathComponent("icon_512x512.png")) }
}

// preview png for the docs
if let big = drawIcon(size: 512) {
    try write(big, to: URL(fileURLWithPath: outDir).appendingPathComponent("icon-preview.png"))
}
print("iconset written to \(iconset.path)")
