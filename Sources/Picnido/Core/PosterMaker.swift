import Foundation
import CoreGraphics
import AppKit
import CoreText

/// The "Poster" output: a printable page (or PDF) with a title and a grid of photos.
enum PosterMaker {

    struct Settings {
        var photos: [PhotoItem] = []
        var title: String = ""
        var pageWidthInches: Double = 17
        var pageHeightInches: Double = 11
        var columns: Int = 2
        var rows: Int = 3
        var showCaptions: Bool = true
        var margin: CGFloat = 36
    }

    static func pageSize(_ s: Settings) -> CGSize {
        CGSize(width: s.pageWidthInches * 72, height: s.pageHeightInches * 72)
    }

    static func exportPDF(settings: Settings, to url: URL) throws {
        var mediaBox = CGRect(origin: .zero, size: pageSize(settings))
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw ExportError.cannotCreate(url.lastPathComponent)
        }
        let images = settings.photos.compactMap {
            ImageEngine.shared.exportCGImage(photo: $0, maxDimension: 2200)
        }
        let perPage = max(settings.columns * settings.rows, 1)
        let pageCount = max(Int(ceil(Double(images.count) / Double(perPage))), 1)

        for page in 0..<pageCount {
            ctx.beginPDFPage(nil)
            draw(page: page, images: images, ctx: ctx, settings: settings)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    static func renderPreview(settings: Settings, maxDimension: CGFloat = 1100) -> CGImage? {
        let size = pageSize(settings)
        let scale = maxDimension / max(size.width, size.height)
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let images = settings.photos.compactMap {
            ImageEngine.shared.exportCGImage(photo: $0, maxDimension: 1200)
        }
        draw(page: 0, images: images, ctx: ctx, settings: settings)
        return ctx.makeImage()
    }

    static func print(settings: Settings) {
        let size = pageSize(settings)
        let info = NSPrintInfo.shared
        info.paperSize = size
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        info.orientation = size.width >= size.height ? .landscape : .portrait
        let view = PosterPrintView(settings: settings, pageSize: size)
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = true
        op.run()
    }

    // MARK: - Drawing

    static func drawPage(page: Int, images: [CGImage], ctx: CGContext, settings: Settings) {
        draw(page: page, images: images, ctx: ctx, settings: settings)
    }

    private static func draw(page: Int, images: [CGImage], ctx: CGContext, settings: Settings) {
        let size = pageSize(settings)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))

        var cursorY = size.height - settings.margin
        if !settings.title.isEmpty {
            let titleSize = max(size.height * 0.045, 14)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: titleSize),
                .foregroundColor: NSColor.black
            ]
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            let string = NSAttributedString(string: settings.title, attributes: attrs)
            let s = string.size()
            string.draw(at: CGPoint(x: (size.width - s.width) / 2, y: cursorY - s.height))
            NSGraphicsContext.restoreGraphicsState()
            cursorY -= s.height + 10
        }

        let cols = max(settings.columns, 1)
        let rows = max(settings.rows, 1)
        let available = CGRect(x: settings.margin, y: settings.margin,
                               width: size.width - settings.margin * 2,
                               height: cursorY - settings.margin)
        let gap: CGFloat = 12
        let cellW = (available.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let cellH = (available.height - gap * CGFloat(rows - 1)) / CGFloat(rows)

        let perPage = cols * rows
        let start = page * perPage
        for slot in 0..<perPage {
            let idx = start + slot
            guard idx < images.count else { break }
            let col = slot % cols
            let row = slot / cols
            let cell = CGRect(x: available.minX + CGFloat(col) * (cellW + gap),
                              y: available.maxY - CGFloat(row + 1) * cellH - CGFloat(row) * gap,
                              width: cellW, height: cellH)
            let img = images[idx]
            let captionH: CGFloat = settings.showCaptions ? 16 : 0
            let scale = min(cell.width / CGFloat(img.width), (cell.height - captionH) / CGFloat(img.height))
            let w = CGFloat(img.width) * scale
            let h = CGFloat(img.height) * scale
            let target = CGRect(x: cell.midX - w / 2, y: cell.maxY - h, width: w, height: h)
            ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 6,
                          color: NSColor.black.withAlphaComponent(0.28).cgColor)
            ctx.draw(img, in: target)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)

            if settings.showCaptions, idx < settings.photos.count {
                let p = settings.photos[idx]
                let text = p.caption.isEmpty ? p.fileName : p.caption
                let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = ns
                let style = NSMutableParagraphStyle(); style.alignment = .center
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9),
                    .foregroundColor: NSColor.darkGray,
                    .paragraphStyle: style
                ]
                (text as NSString).draw(in: CGRect(x: cell.minX, y: target.minY - captionH,
                                                   width: cell.width, height: captionH - 2),
                                        withAttributes: attrs)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }
}

final class PosterPrintView: NSView {
    let settings: PosterMaker.Settings
    private let images: [CGImage]

    init(settings: PosterMaker.Settings, pageSize: NSSize) {
        self.settings = settings
        self.images = settings.photos.compactMap {
            ImageEngine.shared.exportCGImage(photo: $0, maxDimension: 2200)
        }
        super.init(frame: NSRect(origin: .zero, size: pageSize))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        PosterMaker.drawPage(page: 0, images: images, ctx: ctx, settings: settings)
    }
}
