import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import AppKit

/// Every effect in the catalogue, implemented on Core Image.
/// Slider indices follow the order the catalogue declares them in (slider id 0, 1, 2 …).
enum Filters {

    // MARK: - Tiny helpers

    @discardableResult
    static func make(_ name: String, _ params: [String: Any] = [:]) -> CIImage? {
        guard let f = CIFilter(name: name) else { return nil }
        for (k, v) in params { f.setValue(v, forKey: k) }
        return f.outputImage
    }

    static func clamp(_ image: CIImage, to extent: CGRect) -> CIImage {
        image.cropped(to: extent)
    }

    static func radialMask(center: CGPoint, r0: CGFloat, r1: CGFloat, extent: CGRect,
                           inner: CIColor = CIColor(red: 1, green: 1, blue: 1, alpha: 1),
                           outer: CIColor = CIColor(red: 0, green: 0, blue: 0, alpha: 1)) -> CIImage {
        let g = make("CIRadialGradient", [
            "inputCenter": CIVector(x: center.x, y: center.y),
            "inputRadius0": r0,
            "inputRadius1": max(r1, r0 + 1),
            "inputColor0": inner,
            "inputColor1": outer
        ]) ?? CIImage(color: inner)
        return g.cropped(to: extent)
    }

    static func linearMask(extent: CGRect, angle: Double) -> CIImage {
        let cx = extent.midX, cy = extent.midY
        let r = max(extent.width, extent.height)
        let dx = CGFloat(cos(angle)) * r, dy = CGFloat(sin(angle)) * r
        return make("CILinearGradient", [
            "inputPoint0": CIVector(x: cx - dx, y: cy - dy),
            "inputPoint1": CIVector(x: cx + dx, y: cy + dy),
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        ])?.cropped(to: extent) ?? CIImage(color: .white).cropped(to: extent)
    }

    static func blend(_ top: CIImage, over bottom: CIImage, mask: CIImage) -> CIImage {
        make("CIBlendWithMask", [
            kCIInputImageKey: top,
            kCIInputBackgroundImageKey: bottom,
            kCIInputMaskImageKey: mask
        ]) ?? top
    }

    static func toneCurve(_ image: CIImage, _ pts: [CGPoint]) -> CIImage {
        var p = pts
        while p.count < 5 { p.append(p.last ?? CGPoint(x: 1, y: 1)) }
        let keys = ["inputPoint0", "inputPoint1", "inputPoint2", "inputPoint3", "inputPoint4"]
        var params: [String: Any] = [kCIInputImageKey: image]
        for (i, k) in keys.enumerated() {
            params[k] = CIVector(x: p[i].x, y: p[i].y)
        }
        return make("CIToneCurve", params) ?? image
    }

    static func colorMatrix(_ image: CIImage, r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1,
                            bias: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)) -> CIImage {
        make("CIColorMatrix", [
            kCIInputImageKey: image,
            "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: bias.0, y: bias.1, z: bias.2, w: 0)
        ]) ?? image
    }

    static func monochrome(_ image: CIImage) -> CIImage {
        make("CIColorControls", [kCIInputImageKey: image, kCIInputSaturationKey: 0]) ?? image
    }

    static func tinted(_ image: CIImage, color: CIColor, intensity: CGFloat) -> CIImage {
        let mono = monochrome(image)
        let colored = make("CIColorMonochrome", [
            kCIInputImageKey: mono,
            "inputColor": color,
            "inputIntensity": intensity
        ]) ?? mono
        return colored
    }

    // MARK: - Geometry

    static func rotate(_ image: CIImage, quarterTurns: Int) -> CIImage {
        let t = ((quarterTurns % 4) + 4) % 4
        switch t {
        case 1: return image.oriented(.right)
        case 2: return image.oriented(.down)
        case 3: return image.oriented(.left)
        default: return image
        }
    }

    /// Rotates and crops away the empty corners, exactly like the original app's Straighten tool.
    static func straighten(_ image: CIImage, degrees: Double) -> CIImage {
        guard abs(degrees) > 0.001 else { return image }
        let radians = degrees * .pi / 180
        let e = image.extent
        let rotated = image.transformed(by: CGAffineTransform(rotationAngle: CGFloat(radians)))
        let target = largestInscribedRect(in: e.size, angle: CGFloat(abs(radians)))
        // centre the crop on the rotated image
        let re = rotated.extent
        let cropRect = CGRect(x: re.midX - target.width / 2, y: re.midY - target.height / 2,
                              width: target.width, height: target.height)
        return rotated.cropped(to: cropRect)
    }

    private static func largestInscribedRect(in size: CGSize, angle: CGFloat) -> CGSize {
        let s = sin(angle), c = cos(angle)
        if abs(size.height) <= abs(size.width) {
            if size.height <= 2 * s * c * size.width || abs(s - c) < 1e-8 {
                let x = 0.5 * size.height
                return CGSize(width: x / s, height: x / c)
            }
            let cos2 = c * c - s * s
            return CGSize(width: (size.width * c - size.height * s) / cos2,
                          height: (size.height * c - size.width * s) / cos2)
        } else {
            if size.width <= 2 * s * c * size.height || abs(s - c) < 1e-8 {
                let x = 0.5 * size.width
                return CGSize(width: x / s, height: x / c)
            }
            let cos2 = c * c - s * s
            return CGSize(width: (size.width * c - size.height * s) / cos2,
                          height: (size.height * c - size.width * s) / cos2)
        }
    }

    /// `rect` is normalised with the origin at the TOP-left (UI convention).
    static func crop(_ image: CIImage, normalizedRect rect: CGRect) -> CIImage {
        let e = image.extent
        let x = e.origin.x + rect.minX * e.width
        let y = e.origin.y + (1 - rect.maxY) * e.height
        let w = rect.width * e.width
        let h = rect.height * e.height
        guard w > 1, h > 1 else { return image }
        return image.cropped(to: CGRect(x: x, y: y, width: w, height: h))
    }

    // MARK: - Histogram / auto helpers

    static func histogram(_ image: CIImage, context: CIContext) -> [Float] {
        let e = image.extent
        guard let raw = make("CIAreaHistogram", [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: e),
            "inputCount": 256,
            "inputScale": 1
        ]) else { return [] }
        let out = raw.cropped(to: CGRect(x: 0, y: 0, width: 256, height: 1))
        var buf = [Float](repeating: 0, count: 256 * 4)
        buf.withUnsafeMutableBytes { rawBuf in
            context.render(out, toBitmap: rawBuf.baseAddress!, rowBytes: 256 * 4 * MemoryLayout<Float>.size,
                           bounds: CGRect(x: 0, y: 0, width: 256, height: 1),
                           format: .RGBAf, colorSpace: nil)
        }
        var bins = [Float](repeating: 0, count: 256)
        for i in 0..<256 { bins[i] = (buf[i * 4] + buf[i * 4 + 1] + buf[i * 4 + 2]) / 3 }
        return bins
    }

    static func averageColor(_ image: CIImage, context: CIContext) -> (CGFloat, CGFloat, CGFloat) {
        guard let out = make("CIAreaAverage", [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: image.extent)
        ]) else { return (0.5, 0.5, 0.5) }
        var px = [UInt8](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { raw in
            context.render(out, toBitmap: raw.baseAddress!, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        return (CGFloat(px[0]) / 255, CGFloat(px[1]) / 255, CGFloat(px[2]) / 255)
    }

    static func autoLevels(_ image: CIImage, context: CIContext, clip: Float = 0.004) -> CIImage {
        let bins = histogram(image, context: context)
        guard bins.count == 256 else { return image }
        let total = bins.reduce(0, +)
        guard total > 0 else { return image }
        var acc: Float = 0
        var lo = 0, hi = 255
        for i in 0..<256 { acc += bins[i]; if acc / total >= clip { lo = i; break } }
        acc = 0
        for i in stride(from: 255, through: 0, by: -1) { acc += bins[i]; if acc / total >= clip { hi = i; break } }
        guard hi > lo + 2 else { return image }
        let loF = CGFloat(lo) / 255, hiF = CGFloat(hi) / 255
        let p = (0..<5).map { i -> CGPoint in
            let x = CGFloat(i) / 4
            let y = min(max((x - loF) / max(hiF - loF, 0.001), 0), 1)
            return CGPoint(x: x, y: y)
        }
        var out = toneCurve(image, p)
        out = make("CIColorControls", [kCIInputImageKey: out, kCIInputSaturationKey: 1.06]) ?? out
        return out
    }

    static func autoColor(_ image: CIImage, context: CIContext) -> CIImage {
        let (r, g, b) = averageColor(image, context: context)
        let mean = (r + g + b) / 3
        guard r > 0.02, g > 0.02, b > 0.02 else { return image }
        // Gray-world: equalise the channel means, but only partially (like the original).
        let strength: CGFloat = 0.85
        let scaleR = 1 + (mean / r - 1) * strength
        let scaleG = 1 + (mean / g - 1) * strength
        let scaleB = 1 + (mean / b - 1) * strength
        return colorMatrix(image, r: scaleR, g: scaleG, b: scaleB)
    }

    static func enhance(_ image: CIImage) -> CIImage {
        var out = image
        for f in image.autoAdjustmentFilters() {
            f.setValue(out, forKey: kCIInputImageKey)
            if let o = f.outputImage { out = o }
        }
        out = make("CIColorControls", [kCIInputImageKey: out, kCIInputSaturationKey: 1.12,
                                       kCIInputContrastKey: 1.03]) ?? out
        return out.cropped(to: image.extent)
    }

    // MARK: - Tuning panel

    static func tuning(_ image: CIImage, params: TuningParams, context: CIContext) -> CIImage {
        guard !params.isIdentity else { return image }
        var out = image

        // Shadows / highlights / fill light as one tone curve (this is exactly how the
        // original's "Lighting Fixes" sliders behaved).
        let f = CGFloat(params.fillLight) * 0.30
        let s = CGFloat(params.shadows) * 0.20
        let h = CGFloat(params.highlights) * 0.20
        let p0 = CGPoint(x: 0, y: min(max(0.0 + f * 0.9 + s * 0.5, 0), 0.45))
        let p1 = CGPoint(x: 0.25, y: min(max(0.25 + f * 0.55 + s * 0.30, 0), 0.6))
        let p2 = CGPoint(x: 0.5, y: min(max(0.5 + f * 0.1, 0), 0.75))
        let p3 = CGPoint(x: 0.75, y: min(max(0.75 + h * 0.25, 0.55), 1))
        let p4 = CGPoint(x: 1, y: min(max(1.0 + h * 0.0, 0.8), 1))
        out = toneCurve(out, [p0, p1, p2, p3, p4])

        if params.temperature != 0 {
            let t = CGFloat(params.temperature)
            out = make("CITemperatureAndTint", [
                kCIInputImageKey: out,
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 - t * 3200, y: 0)
            ]) ?? out
        }
        if params.saturation != 0 {
            out = make("CIColorControls", [
                kCIInputImageKey: out,
                kCIInputSaturationKey: 1 + CGFloat(params.saturation) * 0.9,
                kCIInputBrightnessKey: 0,
                kCIInputContrastKey: 1
            ]) ?? out
        }
        return out.cropped(to: image.extent)
    }

    // MARK: - Tools

    static func redeye(_ image: CIImage, points: [CGPoint], radius: Double, context: CIContext) -> CIImage {
        var out = image
        for p in points { out = redeye(out, point: p, radius: radius, context: context) }
        return out
    }

    private static func redeye(_ image: CIImage, point: CGPoint, radius: Double, context: CIContext) -> CIImage {
        let e = image.extent
        // UI normalised (top-left origin) -> CI extent
        let cx = e.origin.x + point.x * e.width
        let cy = e.origin.y + (1 - point.y) * e.height
        let r = max(CGFloat(radius) * e.width, 4)
        let roi = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2).intersection(e)
        guard roi.width > 2, roi.height > 2 else { return image }

        let w = Int(roi.width), h = Int(roi.height)
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { raw in
            context.render(image, toBitmap: raw.baseAddress!, rowBytes: w * 4, bounds: roi,
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        for i in stride(from: 0, to: buf.count, by: 4) {
            let rr = Double(buf[i]), gg = Double(buf[i + 1]), bb = Double(buf[i + 2])
            let redness = rr - max(gg, bb)
            if redness > 22 {
                // Neutralise while preserving the underlying luminance.
                let lum = 0.3 * rr + 0.59 * gg + 0.11 * bb
                let target = min(lum * 0.85, 200)
                let mix = min(redness / 90.0, 1.0)
                buf[i]     = UInt8(max(0, min(255, rr + (target - rr) * mix)))
                buf[i + 1] = UInt8(max(0, min(255, gg + (target - gg) * mix)))
                buf[i + 2] = UInt8(max(0, min(255, bb + (target - bb) * mix)))
            }
        }
        guard let provider = CGDataProvider(data: Data(buf) as CFData),
              let patch = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else { return image }
        var patchCI = CIImage(cgImage: patch)
        patchCI = patchCI.transformed(by: CGAffineTransform(translationX: roi.origin.x, y: roi.origin.y))
        let mask = radialMask(center: CGPoint(x: cx, y: cy), r0: r * 0.55, r1: r, extent: e)
        return blend(patchCI, over: image, mask: mask).cropped(to: e)
    }

    static func retouch(_ image: CIImage, points: [CGPoint], radius: Double, context: CIContext) -> CIImage {
        var out = image
        for p in points { out = retouch(out, point: p, radius: radius, context: context) }
        return out
    }

    private static func retouch(_ image: CIImage, point: CGPoint, radius: Double, context: CIContext) -> CIImage {
        let e = image.extent
        let cx = e.origin.x + point.x * e.width
        let cy = e.origin.y + (1 - point.y) * e.height
        let r = max(CGFloat(radius) * e.width, 3)
        let roi = CGRect(x: cx - r * 1.6, y: cy - r * 1.6, width: r * 3.2, height: r * 3.2).intersection(e)
        guard roi.width > 3, roi.height > 3 else { return image }
        let region = image.cropped(to: roi)
        // Blurred reconstruction of the area: heals dust, blemishes and small scratches.
        let healed = make("CIGaussianBlur", [kCIInputImageKey: region,
                                             kCIInputRadiusKey: r * 0.6])?.cropped(to: roi) ?? region
        let mask = radialMask(center: CGPoint(x: cx, y: cy), r0: r * 0.5, r1: r * 1.15, extent: e)
        return blend(healed, over: image, mask: mask).cropped(to: e)
    }

    /// the original app's "Neutral Color Picker": click something that should be grey.
    static func neutralPicker(_ image: CIImage, at point: CGPoint, strength: Double, context: CIContext) -> CIImage {
        let e = image.extent
        let x = e.origin.x + point.x * e.width
        let y = e.origin.y + (1 - point.y) * e.height
        let rect = CGRect(x: x - 3, y: y - 3, width: 6, height: 6).intersection(e)
        guard rect.width > 1 else { return image }
        guard let avg = make("CIAreaAverage", [kCIInputImageKey: image.cropped(to: rect),
                                               kCIInputExtentKey: CIVector(cgRect: rect)]) else { return image }
        var px = [UInt8](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { raw in
            context.render(avg, toBitmap: raw.baseAddress!, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        let r = max(CGFloat(px[0]) / 255, 0.02)
        let g = max(CGFloat(px[1]) / 255, 0.02)
        let b = max(CGFloat(px[2]) / 255, 0.02)
        let m = (r + g + b) / 3
        let s = CGFloat(max(0, min(1, strength)))
        let sr = 1 + (m / r - 1) * s
        let sg = 1 + (m / g - 1) * s
        let sb = 1 + (m / b - 1) * s
        return colorMatrix(image, r: sr, g: sg, b: sb).cropped(to: e)
    }

    // MARK: - Text

    static func drawText(_ t: TextOverlay, on image: CIImage) -> CIImage {
        let e = image.extent
        guard !t.string.isEmpty, e.width > 2 else { return image }
        let w = Int(e.width), h = Int(e.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        let size = max(CGFloat(t.fontSizeRatio) * CGFloat(h), 8)
        let nsFont = NSFont(name: t.fontName, size: size) ?? NSFont.boldSystemFont(ofSize: size)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: nsFont,
            .foregroundColor: NSColor(srgbRed: CGFloat(t.red), green: CGFloat(t.green),
                                      blue: CGFloat(t.blue), alpha: CGFloat(t.alpha))
        ]
        let attributed = NSAttributedString(string: t.string, attributes: attrs)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        let textSize = attributed.size()
        ctx.translateBy(x: CGFloat(t.x) * CGFloat(w), y: CGFloat(1 - t.y) * CGFloat(h))
        ctx.rotate(by: CGFloat(-t.rotationDegrees * .pi / 180))
        attributed.draw(at: CGPoint(x: -textSize.width / 2, y: -textSize.height / 2))
        NSGraphicsContext.restoreGraphicsState()
        guard let overlayCG = ctx.makeImage() else { return image }
        let overlay = CIImage(cgImage: overlayCG)
        return blend(overlay, over: image, mask: CIImage(color: .white).cropped(to: e)).cropped(to: e)
    }

    // MARK: - Default slider values per filter (the catalogue's own presets)

    static func defaultParams(for id: String) -> [Double] {
        switch id {
        case "unsmooth", "unsmooth2": return [50]
        case "unsharp", "unsharp2": return [50]
        case "radblur": return [0.45, 0.5]
        case "radsat": return [0.5, 0.4]
        case "linblur": return [0.35]
        case "tint", "PicnikTint": return [0.5]
        case "dir_tint": return [0.4, 0.4]
        case "radtint": return [0.4]
        case "glow", "glow2": return [0.5, 0.5]
        case "sat": return [0.5]
        case "colortemp": return [0.5, 0.5]
        case "shadow": return [0.5, 0.35, 0.35]
        case "blur": return [0.25]
        case "contrast": return [0.5]
        case "gamma": return [0.5]
        case "backlight": return [0.4]
        case "focalpixelate", "PicnikFocalPixelate": return [0.12, 0.45, 0.5, 0.5]
        case "dir_sat", "dir_brite", "dir_sharp": return [0.3, 0.3]
        case "grain2", "PicnikGrain": return [0.3]
        case "Pixelate": return [0.15]
        case "QuantizePalette": return [0.4]
        case "Soften": return [0.3]
        case "TwoTone": return [0.5]
        case "Vignette": return [0.5]
        case "debug": return [0.15]
        default: return []
        }
    }

    // MARK: - The effect switchboard

    static func apply(id: String, params: [Double], to image: CIImage, context: CIContext) -> CIImage {
        let e = image.extent
        func p(_ i: Int, _ fallback: Double = 0.5) -> CGFloat {
            CGFloat(i < params.count ? params[i] : fallback)
        }

        switch id {

        // ---------- one-click fixes ----------
        case "enhance":
            return enhance(image)

        case "autolight", "autocontrast":
            return autoLevels(image, context: context)

        case "autocolor":
            return autoColor(image, context: context)

        case "autobacklight", "backlight":
            let amt = id == "backlight" ? 0.15 + p(0) * 0.6 : 0.55
            return toneCurve(image, [
                CGPoint(x: 0, y: 0.02 + amt * 0.30),
                CGPoint(x: 0.25, y: 0.25 + amt * 0.22),
                CGPoint(x: 0.5, y: 0.52 + amt * 0.06),
                CGPoint(x: 0.75, y: 0.76),
                CGPoint(x: 1, y: 1)
            ]).cropped(to: e)

        case "autobacklightFill":
            return image

        case "bw":
            let mono = monochrome(image)
            return make("CIColorControls", [kCIInputImageKey: mono, kCIInputContrastKey: 1.12])?.cropped(to: e) ?? mono

        case "sepia":
            return make("CISepiaTone", [kCIInputImageKey: image, kCIInputIntensityKey: 0.85])?.cropped(to: e) ?? image

        case "warm":
            let warm = make("CITemperatureAndTint", [
                kCIInputImageKey: image,
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 4800, y: 0)
            ]) ?? image
            return make("CIColorControls", [kCIInputImageKey: warm, kCIInputSaturationKey: 1.08])?.cropped(to: e) ?? warm

        case "grain", "grain2", "PicnikGrain":
            let amt: CGFloat = id == "grain" ? 0.10 : 0.05 + p(0) * 0.16
            guard let noise = make("CIRandomGenerator")?.cropped(to: e) else { return image }
            let mono = monochrome(noise)
            let faded = make("CIColorMatrix", [
                kCIInputImageKey: mono,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: amt),
                "inputBiasVector": CIVector(x: 0.5, y: 0.5, z: 0.5, w: 0)
            ]) ?? mono
            return make("CIOverlayBlendMode", [kCIInputImageKey: faded,
                                               kCIInputBackgroundImageKey: image])?.cropped(to: e) ?? image

        // ---------- sharpening ----------
        case "unsharp", "unsharp2":
            let amount = 0.4 + p(0) * 1.6
            return make("CIUnsharpMask", [kCIInputImageKey: image,
                                          kCIInputRadiusKey: 2.2,
                                          kCIInputIntensityKey: amount])?.cropped(to: e) ?? image

        // ---------- colour / tone effects ----------
        case "tint", "PicnikTint":
            let amount = 0.15 + p(0) * 0.6
            let target = CIColor(red: 0.42, green: 0.26, blue: 0.62)
            let mono = monochrome(image)
            let colored = make("CIColorMonochrome", [kCIInputImageKey: mono, "inputColor": target,
                                                     "inputIntensity": 1.0]) ?? mono
            return make("CIDissolveTransition", [kCIInputImageKey: image, "inputTargetImage": colored,
                                                 "inputTime": amount])?.cropped(to: e) ?? colored

        case "sat":
            return make("CIColorControls", [kCIInputImageKey: image,
                                            kCIInputSaturationKey: 0.2 + p(0) * 2.2])?.cropped(to: e) ?? image

        case "colortemp":
            let t = (p(0) - 0.5) * 2
            return make("CITemperatureAndTint", [
                kCIInputImageKey: image,
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 - t * 3200, y: 0)
            ])?.cropped(to: e) ?? image

        case "shadow":
            let radius = p(0) * 30
            let shadow = p(1)
            let highlight = 1.0 - p(2) * 0.7
            return make("CIHighlightShadowAdjust", [
                kCIInputImageKey: image,
                "inputRadius": radius,
                "inputShadowAmount": shadow,
                "inputHighlightAmount": max(0.3, min(1.0, highlight))
            ])?.cropped(to: e) ?? image

        case "contrast":
            return make("CIColorControls", [kCIInputImageKey: image,
                                            kCIInputContrastKey: 0.4 + p(0) * 2.0])?.cropped(to: e) ?? image

        case "gamma":
            return make("CIGammaAdjust", [kCIInputImageKey: image,
                                          "inputPower": 0.35 + p(0) * 2.4])?.cropped(to: e) ?? image

        case "blur":
            return make("CIGaussianBlur", [kCIInputImageKey: image,
                                           kCIInputRadiusKey: 1 + p(0) * 24])?.cropped(to: e) ?? image

        case "linblur":
            return make("CIMotionBlur", [kCIInputImageKey: image,
                                         kCIInputRadiusKey: 2 + p(0) * 40,
                                         kCIInputAngleKey: 0.0])?.cropped(to: e) ?? image

        case "ansel", "anselBW":
            // "Filtered B&W" — a red filter plus a hard contrast curve.
            let filtered = colorMatrix(image, r: 1.6, g: 1.0, b: 0.85)
            let mono = monochrome(filtered)
            return toneCurve(mono, [CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.16),
                                    CGPoint(x: 0.5, y: 0.52), CGPoint(x: 0.75, y: 0.85),
                                    CGPoint(x: 1, y: 1)]).cropped(to: e)

        case "Matte":
            return toneCurve(image, [CGPoint(x: 0, y: 0.07), CGPoint(x: 0.25, y: 0.29),
                                     CGPoint(x: 0.5, y: 0.53), CGPoint(x: 0.75, y: 0.78),
                                     CGPoint(x: 1, y: 0.96)]).cropped(to: e)

        case "Invert":
            return make("CIColorInvert", [kCIInputImageKey: image])?.cropped(to: e) ?? image

        case "Boost":
            var out = make("CIColorControls", [kCIInputImageKey: image, kCIInputSaturationKey: 1.28,
                                               kCIInputContrastKey: 1.10]) ?? image
            out = make("CIUnsharpMask", [kCIInputImageKey: out, kCIInputRadiusKey: 3,
                                         kCIInputIntensityKey: 0.7]) ?? out
            return out.cropped(to: e)

        case "LocalContrast":
            return make("CIUnsharpMask", [kCIInputImageKey: image, kCIInputRadiusKey: 22,
                                          kCIInputIntensityKey: 1.4])?.cropped(to: e) ?? image

        case "HDR":
            var out = make("CIUnsharpMask", [kCIInputImageKey: image, kCIInputRadiusKey: 30,
                                             kCIInputIntensityKey: 1.9]) ?? image
            out = make("CIColorControls", [kCIInputImageKey: out, kCIInputSaturationKey: 1.35,
                                           kCIInputContrastKey: 1.12]) ?? out
            return out.cropped(to: e)

        case "Soften":
            let radius = 1 + p(0) * 8
            guard let blurred = make("CIGaussianBlur", [kCIInputImageKey: image,
                                                        kCIInputRadiusKey: radius])?.cropped(to: e) else { return image }
            return make("CIDissolveTransition", [kCIInputImageKey: image, "inputTargetImage": blurred,
                                                 "inputTime": 0.55])?.cropped(to: e) ?? blurred

        // ---------- glow / blur family ----------
        case "glow", "glow2":
            let intensity = 0.3 + p(0) * 0.9
            let radius = 4 + p(1) * 22
            guard let bloom = make("CIBloom", [kCIInputImageKey: image, kCIInputRadiusKey: radius,
                                               kCIInputIntensityKey: intensity])?.cropped(to: e) else { return image }
            return make("CILightenBlendMode", [kCIInputImageKey: bloom,
                                               kCIInputBackgroundImageKey: image])?.cropped(to: e) ?? bloom

        case "radblur":
            let size = 0.15 + p(0) * 0.5
            guard let blurred = make("CIGaussianBlur", [kCIInputImageKey: image,
                                                        kCIInputRadiusKey: 4 + p(0) * 16])?.cropped(to: e) else { return image }
            let mask = radialMask(center: CGPoint(x: e.midX, y: e.midY),
                                  r0: e.width * 0.08, r1: e.width * size, extent: e,
                                  inner: CIColor(red: 0, green: 0, blue: 0, alpha: 1),
                                  outer: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
            return blend(blurred, over: image, mask: mask).cropped(to: e)

        case "radsat":
            let mono = monochrome(image)
            let sharp = make("CIUnsharpMask", [kCIInputImageKey: mono, kCIInputRadiusKey: 2,
                                               kCIInputIntensityKey: 0.5 + p(1) * 1.0])?.cropped(to: e) ?? mono
            let mask = radialMask(center: CGPoint(x: e.midX, y: e.midY),
                                  r0: e.width * 0.05, r1: e.width * (0.2 + p(0) * 0.5), extent: e,
                                  inner: CIColor(red: 0, green: 0, blue: 0, alpha: 1),
                                  outer: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
            return blend(sharp, over: image, mask: mask).cropped(to: e)

        case "radtint":
            let tinted = tinted(image, color: CIColor(red: 0.95, green: 0.75, blue: 0.45),
                                intensity: 0.85)
            let mask = radialMask(center: CGPoint(x: e.midX, y: e.midY),
                                  r0: e.width * 0.05, r1: e.width * (0.25 + p(0) * 0.6), extent: e,
                                  inner: CIColor(red: 0, green: 0, blue: 0, alpha: 1),
                                  outer: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
            return blend(tinted, over: image, mask: mask).cropped(to: e)

        case "dir_tint":
            let tinted = tinted(image, color: CIColor(red: 0.98, green: 0.78, blue: 0.5),
                                intensity: 0.6 + p(1) * 0.4)
            let mask = linearMask(extent: e, angle: 0).transformed(by: CGAffineTransform(translationX: 0, y: 0))
            let feathered = make("CIGaussianBlur", [kCIInputImageKey: mask,
                                                    kCIInputRadiusKey: 4 + p(0) * e.width * 0.15])?.cropped(to: e) ?? mask
            return blend(tinted, over: image, mask: feathered).cropped(to: e)

        case "dir_sat":
            let desat = make("CIColorControls", [kCIInputImageKey: image,
                                                 kCIInputSaturationKey: 0.0])?.cropped(to: e) ?? image
            let mask = linearMask(extent: e, angle: Double(p(1) * .pi))
            return blend(desat, over: image, mask: mask).cropped(to: e)

        case "dir_brite":
            let bright = make("CIExposureAdjust", [kCIInputImageKey: image,
                                                   kCIInputEVKey: 0.8])?.cropped(to: e) ?? image
            let mask = linearMask(extent: e, angle: Double(p(1) * .pi))
            return blend(bright, over: image, mask: mask).cropped(to: e)

        case "dir_sharp":
            let sharp = make("CIUnsharpMask", [kCIInputImageKey: image, kCIInputRadiusKey: 2.5,
                                               kCIInputIntensityKey: 1.6])?.cropped(to: e) ?? image
            let mask = linearMask(extent: e, angle: Double(p(1) * .pi))
            return blend(sharp, over: image, mask: mask).cropped(to: e)

        // ---------- focal (puck) effects ----------
        case "focalpixelate", "PicnikFocalPixelate":
            let scale = 4 + p(0) * 40
            let focal = 0.15 + p(1) * 0.45
            guard let pix = make("CIPixellate", [kCIInputImageKey: image,
                                                 kCIInputScaleKey: scale,
                                                 kCIInputCenterKey: CIVector(x: e.midX, y: e.midY)])?.cropped(to: e) else { return image }
            let mask = radialMask(center: CGPoint(x: e.midX, y: e.midY),
                                  r0: e.width * focal * 0.5, r1: e.width * focal, extent: e,
                                  inner: CIColor(red: 0, green: 0, blue: 0, alpha: 1),
                                  outer: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
            return blend(pix, over: image, mask: mask).cropped(to: e)

        case "Pixelate":
            let scale = 6 + p(0) * 90
            return make("CIPixellate", [kCIInputImageKey: image, kCIInputScaleKey: scale,
                                        kCIInputCenterKey: CIVector(x: e.midX, y: e.midY)])?.cropped(to: e) ?? image

        case "FocalZoom":
            // Zoom + blur the centre, keep the outside: the classic "focal zoom" look.
            let zoomed = image.transformed(by: CGAffineTransform(scaleX: 1.5, y: 1.5))
            let centered = zoomed.transformed(by: CGAffineTransform(translationX: (e.width - zoomed.extent.width) / 2,
                                                                    y: (e.height - zoomed.extent.height) / 2))
            let blurred = make("CIGaussianBlur", [kCIInputImageKey: centered,
                                                  kCIInputRadiusKey: 6])?.cropped(to: e) ?? centered
            let mask = radialMask(center: CGPoint(x: e.midX, y: e.midY),
                                  r0: e.width * 0.15, r1: e.width * 0.45, extent: e,
                                  inner: CIColor(red: 0, green: 0, blue: 0, alpha: 1),
                                  outer: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
            return blend(blurred, over: image, mask: mask).cropped(to: e)

        case "Vignette":
            return make("CIVignette", [kCIInputImageKey: image,
                                       kCIInputIntensityKey: 0.3 + p(0) * 1.5,
                                       kCIInputRadiusKey: 1.4])?.cropped(to: e) ?? image

        // ---------- frames ----------
        case "MuseumMatte", "Border", "DropShadow", "RoundedEdges", "Polaroid":
            return FrameMaker.apply(id: id, params: params, to: image, context: context)

        case "Cinemascope":
            return FrameMaker.cinemascope(image)

        // ---------- looks ----------
        case "Lomo":
            var out = make("CIColorControls", [kCIInputImageKey: image, kCIInputSaturationKey: 1.5,
                                               kCIInputContrastKey: 1.22]) ?? image
            out = colorMatrix(out, r: 1.04, g: 1.0, b: 0.94)
            out = make("CIVignette", [kCIInputImageKey: out, kCIInputIntensityKey: 1.6,
                                      kCIInputRadiusKey: 1.6])?.cropped(to: e) ?? out
            return out.cropped(to: e)

        case "Holga":
            var out = make("CIColorControls", [kCIInputImageKey: image, kCIInputSaturationKey: 1.35,
                                               kCIInputContrastKey: 1.1]) ?? image
            out = colorMatrix(out, r: 1.06, g: 1.02, b: 0.94, bias: (0.03, 0.02, 0.01))
            out = make("CIVignette", [kCIInputImageKey: out, kCIInputIntensityKey: 2.0,
                                      kCIInputRadiusKey: 1.2])?.cropped(to: e) ?? out
            return out.cropped(to: e)

        case "Orton":
            guard let bloom = make("CIBloom", [kCIInputImageKey: image, kCIInputRadiusKey: 14,
                                               kCIInputIntensityKey: 1.1])?.cropped(to: e) else { return image }
            var out = make("CIColorControls", [kCIInputImageKey: bloom, kCIInputSaturationKey: 1.35,
                                               kCIInputContrastKey: 1.1]) ?? bloom
            out = make("CIUnsharpMask", [kCIInputImageKey: out, kCIInputRadiusKey: 3,
                                         kCIInputIntensityKey: 0.6]) ?? out
            return out.cropped(to: e)

        case "Sixties":
            var out = toneCurve(image, [CGPoint(x: 0, y: 0.10), CGPoint(x: 0.25, y: 0.32),
                                        CGPoint(x: 0.5, y: 0.55), CGPoint(x: 0.75, y: 0.78),
                                        CGPoint(x: 1, y: 0.94)])
            out = colorMatrix(out, r: 1.10, g: 1.02, b: 0.82)
            return make("CIColorControls", [kCIInputImageKey: out,
                                            kCIInputSaturationKey: 0.82])?.cropped(to: e) ?? out

        case "CrossProcess":
            var out = toneCurve(image, [CGPoint(x: 0, y: 0.0), CGPoint(x: 0.25, y: 0.20),
                                        CGPoint(x: 0.5, y: 0.52), CGPoint(x: 0.75, y: 0.82),
                                        CGPoint(x: 1, y: 1.0)])
            out = colorMatrix(out, r: 1.12, g: 1.02, b: 0.95, bias: (0.0, 0.02, 0.06))
            return make("CIColorControls", [kCIInputImageKey: out,
                                            kCIInputSaturationKey: 1.25])?.cropped(to: e) ?? out

        case "HeatMap":
            return make("CIThermal", [kCIInputImageKey: image])?.cropped(to: e) ?? image

        case "Comicize":
            return make("CIComicEffect", [kCIInputImageKey: image])?.cropped(to: e) ?? image

        case "PencilSketch":
            let edges = make("CIEdgeWork", [kCIInputImageKey: image, kCIInputRadiusKey: 2.4])?.cropped(to: e) ?? image
            let paper = monochrome(edges)
            return make("CIColorInvert", [kCIInputImageKey: paper])?.cropped(to: e) ?? paper

        case "Neon":
            guard let edges = make("CIEdgeWork", [kCIInputImageKey: image,
                                                  kCIInputRadiusKey: 3.0])?.cropped(to: e) else { return image }
            let monoInverted = make("CIColorInvert", [kCIInputImageKey: monochrome(edges)])?.cropped(to: e) ?? edges
            let hot = monochrome(make("CIColorInvert", [kCIInputImageKey: monoInverted]) ?? monoInverted)
            let colored = tinted(hot, color: CIColor(red: 0.2, green: 0.9, blue: 1.0), intensity: 1.0)
            return make("CILightenBlendMode", [kCIInputImageKey: colored,
                                               kCIInputBackgroundImageKey: image])?.cropped(to: e) ?? colored

        case "NightVision":
            var out = monochrome(image)
            out = tinted(out, color: CIColor(red: 0.25, green: 1.0, blue: 0.35), intensity: 1.0)
            out = make("CIColorControls", [kCIInputImageKey: out, kCIInputContrastKey: 1.25]) ?? out
            if let bloom = make("CIBloom", [kCIInputImageKey: out, kCIInputRadiusKey: 10,
                                            kCIInputIntensityKey: 0.7])?.cropped(to: e) { out = bloom }
            out = make("CIVignette", [kCIInputImageKey: out, kCIInputIntensityKey: 1.6,
                                      kCIInputRadiusKey: 1.3])?.cropped(to: e) ?? out
            return out

        case "IR":
            // Infrared film: swap the red and blue channels, then glow.
            let swapped = make("CIColorMatrix", [
                kCIInputImageKey: image,
                "inputRVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])?.cropped(to: e) ?? image
            var out = make("CIColorControls", [kCIInputImageKey: swapped, kCIInputSaturationKey: 0.45,
                                               kCIInputContrastKey: 1.2]) ?? swapped
            if let bloom = make("CIBloom", [kCIInputImageKey: out, kCIInputRadiusKey: 12,
                                            kCIInputIntensityKey: 0.9])?.cropped(to: e) { out = bloom }
            return out.cropped(to: e)

        case "QuantizePalette":
            let levels = 2 + p(0) * 10
            return make("CIColorPosterize", [kCIInputImageKey: image,
                                             "inputLevels": levels])?.cropped(to: e) ?? image

        case "TwoTone":
            let mono = monochrome(image)
            let duotone = make("CIFalseColor", [
                kCIInputImageKey: mono,
                "inputColor0": CIColor(red: 0.08, green: 0.05, blue: 0.22),
                "inputColor1": CIColor(red: 0.98, green: 0.85, blue: 0.55)
            ])?.cropped(to: e) ?? mono
            return make("CIDissolveTransition", [kCIInputImageKey: image, "inputTargetImage": duotone,
                                                 "inputTime": 0.4 + p(0) * 0.6])?.cropped(to: e) ?? duotone

        case "ReanimatedEyeColor":
            // "Ghoul Eye" — heavily desaturated with a sickly green-grey cast.
            var out = make("CIColorControls", [kCIInputImageKey: image, kCIInputSaturationKey: 0.25,
                                               kCIInputContrastKey: 1.2]) ?? image
            out = colorMatrix(out, r: 0.92, g: 1.06, b: 0.88, bias: (0.0, 0.04, 0.0))
            return out.cropped(to: e)

        case "debug":
            return make("CIPixellate", [kCIInputImageKey: image,
                                        kCIInputScaleKey: max(4, p(0) * 200)])?.cropped(to: e) ?? image

        default:
            return image
        }
    }
}
