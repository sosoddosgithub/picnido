import Foundation
import CoreImage
import CoreGraphics
import AppKit

/// The framing effects (Museum Matte, Border, Drop Shadow, Rounded Edges, Polaroid,
/// Cinemascope) all work by rasterising and compositing onto a larger canvas.
enum FrameMaker {

    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    static func apply(id: String, params: [Double], to image: CIImage, context: CIContext) -> CIImage {
        switch id {
        case "MuseumMatte":  return matte(image, context: context)
        case "Border":       return border(image, context: context)
        case "DropShadow":   return dropShadow(image, context: context)
        case "RoundedEdges": return rounded(image, context: context)
        case "Polaroid":     return polaroid(image, context: context)
        default:             return image
        }
    }

    // MARK: - Canvas helper

    private static func raster(_ image: CIImage, context: CIContext) -> CGImage? {
        context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space)
    }

    private static func canvasOutput(_ cg: CGImage) -> CIImage {
        CIImage(cgImage: cg)
    }

    // MARK: - Museum matte

    static func matte(_ image: CIImage, context: CIContext) -> CIImage {
        guard let src = raster(image, context: context) else { return image }
        let w = src.width, h = src.height
        let pad = Int(Double(max(w, h)) * 0.085)
        let line = max(2, pad / 14)
        let cw = w + pad * 2, ch = h + pad * 2
        guard let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.setFillColor(CGColor(red: 0.94, green: 0.93, blue: 0.91, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: pad / 3, y: pad / 3, width: cw - pad * 2 / 3, height: ch - pad * 2 / 3))
        ctx.draw(src, in: CGRect(x: pad, y: pad, width: w, height: h))
        ctx.setStrokeColor(CGColor(red: 0.72, green: 0.70, blue: 0.66, alpha: 1))
        ctx.setLineWidth(CGFloat(line))
        ctx.stroke(CGRect(x: pad, y: pad, width: w, height: h))
        guard let out = ctx.makeImage() else { return image }
        return canvasOutput(out)
    }

    // MARK: - Simple white border

    static func border(_ image: CIImage, context: CIContext) -> CIImage {
        guard let src = raster(image, context: context) else { return image }
        let w = src.width, h = src.height
        let pad = Int(Double(max(w, h)) * 0.035)
        let cw = w + pad * 2, ch = h + pad * 2
        guard let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
        ctx.draw(src, in: CGRect(x: pad, y: pad, width: w, height: h))
        ctx.setStrokeColor(CGColor(red: 0.86, green: 0.86, blue: 0.86, alpha: 1))
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: pad, y: pad, width: w, height: h))
        guard let out = ctx.makeImage() else { return image }
        return canvasOutput(out)
    }

    // MARK: - Drop shadow

    static func dropShadow(_ image: CIImage, context: CIContext) -> CIImage {
        guard let src = raster(image, context: context) else { return image }
        let w = src.width, h = src.height
        let pad = Int(Double(max(w, h)) * 0.06)
        let cw = w + pad * 2, ch = h + pad * 2
        guard let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
        ctx.setShadow(offset: CGSize(width: 0, height: -CGFloat(pad) * 0.22),
                      blur: CGFloat(pad) * 0.55,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
        ctx.draw(src, in: CGRect(x: pad, y: pad, width: w, height: h))
        guard let out = ctx.makeImage() else { return image }
        return canvasOutput(out)
    }

    // MARK: - Rounded edges

    static func rounded(_ image: CIImage, context: CIContext) -> CIImage {
        guard let src = raster(image, context: context) else { return image }
        let w = src.width, h = src.height
        let pad = Int(Double(max(w, h)) * 0.02)
        let cw = w + pad * 2, ch = h + pad * 2
        guard let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
        let radius = CGFloat(min(w, h)) * 0.06
        let path = CGPath(roundedRect: CGRect(x: pad, y: pad, width: w, height: h),
                          cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(src, in: CGRect(x: pad, y: pad, width: w, height: h))
        guard let out = ctx.makeImage() else { return image }
        return canvasOutput(out)
    }

    // MARK: - Polaroid

    static func polaroid(_ image: CIImage, context: CIContext) -> CIImage {
        // The look first: creamy highlights, warm cast, slightly crushed blacks.
        var look = Filters.toneCurve(image, [CGPoint(x: 0, y: 0.06), CGPoint(x: 0.25, y: 0.28),
                                             CGPoint(x: 0.5, y: 0.54), CGPoint(x: 0.75, y: 0.80),
                                             CGPoint(x: 1, y: 0.97)])
        look = Filters.colorMatrix(look, r: 1.05, g: 1.01, b: 0.96)
        look = Filters.make("CIColorControls", [kCIInputImageKey: look,
                                                kCIInputSaturationKey: 0.9]) ?? look

        guard let src = raster(look, context: context) else { return image }
        let w = src.width, h = src.height
        let pad = Int(Double(max(w, h)) * 0.055)
        let bottom = Int(Double(h) * 0.20)
        let cw = w + pad * 2, ch = h + pad + bottom
        guard let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.setFillColor(CGColor(red: 1, green: 0.995, blue: 0.98, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
        ctx.draw(src, in: CGRect(x: pad, y: bottom, width: w, height: h))
        guard let out = ctx.makeImage() else { return image }
        return canvasOutput(out)
    }

    // MARK: - Cinemascope

    static func cinemascope(_ image: CIImage) -> CIImage {
        let e = image.extent
        let target: CGFloat = 2.39
        var out = image
        let aspect = e.width / max(e.height, 1)
        if aspect > target {
            let newH = e.width / target
            let crop = CGRect(x: e.origin.x, y: e.midY - newH / 2, width: e.width, height: newH)
            out = image.cropped(to: crop)
        } else if aspect < target {
            let newH = e.width / target
            let extra = newH - e.height
            let black = CIImage(color: CIColor(red: 0.01, green: 0.01, blue: 0.015, alpha: 1))
            let top = black.cropped(to: CGRect(x: e.origin.x, y: e.maxY, width: e.width, height: extra / 2))
            let bottom = black.cropped(to: CGRect(x: e.origin.x, y: e.origin.y - extra / 2, width: e.width, height: extra / 2))
            out = out.composited(over: bottom).composited(over: top)
        }
        let cool = Filters.make("CIColorControls", [kCIInputImageKey: out,
                                                    kCIInputSaturationKey: 0.92]) ?? out
        return Filters.colorMatrix(cool, r: 0.98, g: 0.99, b: 1.04)
    }
}
