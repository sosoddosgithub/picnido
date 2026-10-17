import Foundation
import CoreGraphics
import AppKit

enum CollageMaker {

    struct Settings {
        var layout: CollageLayout = .grid
        var aspect: Double = 1.0          // width / height
        var spacing: CGFloat = 8
        var background: CollageBackground = .white
        var shadows: Bool = true
        var borderWidth: CGFloat = 6
        var maxDimension: CGFloat = 2600
        var captions: Bool = false
    }

    static func render(photos: [PhotoItem], settings: Settings) -> CGImage? {
        guard !photos.isEmpty else { return nil }
        let images = photos.compactMap { ImageEngine.shared.exportCGImage(photo: $0, maxDimension: 1400) }
        guard !images.isEmpty else { return nil }

        let aspect = max(settings.aspect, 0.25)
        var h = settings.maxDimension
        var w = h * CGFloat(aspect)
        if w > settings.maxDimension * 1.6 { w = settings.maxDimension * 1.6; h = w / CGFloat(aspect) }
        let size = CGSize(width: w.rounded(), height: h.rounded())

        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                 bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        // background
        ctx.setFillColor(settings.background.color.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        if settings.background == .checkerboard {
            let cell: CGFloat = 24
            ctx.setFillColor(NSColor.white.cgColor)
            var row = 0
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = (row % 2 == 0) ? 0 : cell
                while x < size.width {
                    ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
                    x += cell * 2
                }
                y += cell
                row += 1
            }
        }

        switch settings.layout {
        case .grid:            drawGrid(ctx, images: images, photos: photos, settings: settings, size: size)
        case .contactSheet:    drawGrid(ctx, images: images, photos: photos, settings: settings, size: size)
        case .picturePile:     drawPile(ctx, images: images, settings: settings, size: size)
        case .mosaic:          drawMosaic(ctx, images: images, settings: settings, size: size)
        case .frame:           drawFrame(ctx, images: images, settings: settings, size: size)
        case .multipleExposure: drawExposure(ctx, images: images, settings: settings, size: size)
        }
        return ctx.makeImage()
    }

    // MARK: - Grid / contact sheet

    private static func drawGrid(_ ctx: CGContext, images: [CGImage], photos: [PhotoItem],
                                 settings: Settings, size: CGSize) {
        let n = images.count
        let aspect = size.width / size.height
        var cols = Int(ceil(sqrt(Double(n) * Double(aspect))))
        cols = max(1, min(cols, n))
        let rows = Int(ceil(Double(n) / Double(cols)))
        let gap = settings.spacing
        let cellW = (size.width - gap * CGFloat(cols + 1)) / CGFloat(cols)
        let cellH = (size.height - gap * CGFloat(rows + 1)) / CGFloat(rows)

        for (i, img) in images.enumerated() {
            let col = i % cols
            let row = i / cols
            let captionH: CGFloat = settings.captions ? cellH * 0.10 : 0
            let cell = CGRect(x: gap + CGFloat(col) * (cellW + gap),
                              y: gap + CGFloat(row) * (cellH + gap),
                              width: cellW, height: cellH - captionH)
            drawFitted(ctx, img, in: cell, shadow: settings.shadows, border: settings.borderWidth)
            if settings.captions, i < photos.count {
                let text = photos[i].caption.isEmpty ? photos[i].fileName : photos[i].caption
                drawCaption(ctx, text, in: CGRect(x: cell.minX, y: cell.minY - captionH,
                                                  width: cell.width, height: captionH))
            }
        }
    }

    // MARK: - Picture pile

    private static func drawPile(_ ctx: CGContext, images: [CGImage], settings: Settings, size: CGSize) {
        let n = images.count
        var seed: UInt64 = 0x9E3779B97F4A7C15 &+ UInt64(n)
        func rand() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double((seed >> 33) % 10_000) / 10_000.0
        }
        let baseScale = min(0.62, 0.95 / sqrt(Double(n)))
        for (i, img) in images.enumerated() {
            let s = baseScale * (0.85 + rand() * 0.3)
            let w = size.width * CGFloat(s)
            let h = w * CGFloat(img.height) / CGFloat(img.width)
            let cx = size.width / 2 + CGFloat((rand() - 0.5) * 0.28) * size.width
            let cy = size.height / 2 + CGFloat((rand() - 0.5) * 0.28) * size.height
            let angle = CGFloat((rand() - 0.5) * 0.55)
            ctx.saveGState()
            ctx.translateBy(x: cx, y: cy)
            ctx.rotate(by: angle)
            let border = settings.borderWidth
            let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
            if settings.shadows {
                ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22,
                              color: NSColor.black.withAlphaComponent(0.55).cgColor)
            }
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(rect.insetBy(dx: -border, dy: -border))
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.draw(img, in: rect)
            ctx.restoreGState()
            _ = i
        }
    }

    // MARK: - Mosaic

    private static func drawMosaic(_ ctx: CGContext, images: [CGImage], settings: Settings, size: CGSize) {
        let gap = settings.spacing
        let cols = 3, rows = 3
        let cellW = (size.width - gap * CGFloat(cols + 1)) / CGFloat(cols)
        let cellH = (size.height - gap * CGFloat(rows + 1)) / CGFloat(rows)

        let hero = CGRect(x: gap, y: gap, width: cellW * 2 + gap, height: cellH * 2 + gap)
        if let first = images.first {
            drawFitted(ctx, first, in: hero, shadow: settings.shadows, border: settings.borderWidth)
        }
        var slots: [CGRect] = []
        slots.append(CGRect(x: gap + (cellW + gap) * 2, y: gap, width: cellW, height: cellH))
        slots.append(CGRect(x: gap + (cellW + gap) * 2, y: gap + cellH + gap, width: cellW, height: cellH))
        for c in 0..<cols {
            slots.append(CGRect(x: gap + (cellW + gap) * CGFloat(c), y: gap + (cellH + gap) * 2,
                                width: cellW, height: cellH))
            slots.append(CGRect(x: gap + (cellW + gap) * CGFloat(c), y: gap + (cellH + gap), width: cellW, height: cellH))
        }
        for (i, img) in images.dropFirst().enumerated() {
            let slot = slots[i % slots.count]
            drawFitted(ctx, img, in: slot.insetBy(dx: 2, dy: 2), shadow: settings.shadows,
                       border: settings.borderWidth / 2)
        }
    }

    // MARK: - Frame

    private static func drawFrame(_ ctx: CGContext, images: [CGImage], settings: Settings, size: CGSize) {
        let centre = CGRect(x: size.width * 0.16, y: size.height * 0.18,
                            width: size.width * 0.68, height: size.height * 0.64)
        if let first = images.first {
            drawFitted(ctx, first, in: centre, shadow: true, border: settings.borderWidth * 1.5)
        }
        let others = Array(images.dropFirst().prefix(8))
        guard !others.isEmpty else { return }
        let perSide = Int(ceil(Double(others.count) / 2.0))
        for (i, img) in others.enumerated() {
            let leftSide = i < perSide
            let idx = leftSide ? i : i - perSide
            let count = leftSide ? perSide : others.count - perSide
            let slotW = size.width * 0.11
            let slotH = size.height * 0.11
            let t = (CGFloat(idx) + 0.5) / CGFloat(max(count, 1))
            let y = size.height * (1.0 - t) - slotH / 2
            let x = leftSide ? size.width * 0.015 : size.width * 0.875
            drawFitted(ctx, img, in: CGRect(x: x, y: y, width: slotW, height: slotH),
                       shadow: settings.shadows, border: settings.borderWidth / 2)
        }
    }

    // MARK: - Multiple exposure

    private static func drawExposure(_ ctx: CGContext, images: [CGImage], settings: Settings, size: CGSize) {
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setBlendMode(.screen)
        for img in images.prefix(12) {
            let scale = max(size.width / CGFloat(img.width), size.height / CGFloat(img.height))
            let w = CGFloat(img.width) * scale
            let h = CGFloat(img.height) * scale
            ctx.setAlpha(0.62)
            ctx.draw(img, in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
        }
        ctx.setAlpha(1)
        ctx.setBlendMode(.normal)
    }

    // MARK: - Drawing helpers

    private static func drawFitted(_ ctx: CGContext, _ img: CGImage, in rect: CGRect,
                                   shadow: Bool, border: CGFloat) {
        let scale = min(rect.width / CGFloat(img.width), rect.height / CGFloat(img.height))
        let w = CGFloat(img.width) * scale
        let h = CGFloat(img.height) * scale
        let target = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        if border > 0 {
            if shadow {
                ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 12,
                              color: NSColor.black.withAlphaComponent(0.45).cgColor)
            }
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(target.insetBy(dx: -border, dy: -border))
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
        } else if shadow {
            ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 10,
                          color: NSColor.black.withAlphaComponent(0.4).cgColor)
            ctx.draw(img, in: target)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            return
        }
        ctx.draw(img, in: target)
    }

    private static func drawCaption(_ ctx: CGContext, _ text: String, in rect: CGRect) {
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(rect.height * 0.55, 8)),
            .foregroundColor: NSColor.black,
            .paragraphStyle: style
        ]
        (text as NSString).draw(in: rect, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }
}
