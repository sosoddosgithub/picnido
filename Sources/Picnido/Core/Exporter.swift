import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

struct ExportOptions {
    var folder: URL
    var namePrefix: String = ""
    var maxDimension: CGFloat? = nil      // nil == original size
    var quality: Double = 0.9
    var format: ExportFormat = .jpeg
    var watermark: String? = nil
    var keepMetadata: Bool = true
}

enum Exporter {

    // MARK: - Single file

    @discardableResult
    static func export(photo: PhotoItem, options: ExportOptions) throws -> URL {
        guard var cg = ImageEngine.shared.exportCGImage(photo: photo, maxDimension: options.maxDimension) else {
            throw ExportError.renderFailed(photo.fileName)
        }
        if let wm = options.watermark, !wm.isEmpty {
            cg = drawWatermark(wm, on: cg) ?? cg
        }
        // "Original" is resolved per photo, which is the only scope in which it means anything.
        // It lands on the source's own format when this machine can encode it (JPEG, PNG, TIFF
        // among the ones a photo is likely to be) and on JPEG otherwise — where "otherwise"
        // includes every RAW, so the extension we write matches the bytes we write.
        var opts = options
        if opts.format == .original {
            opts.format = ExportFormat.matching(photo.url.pathExtension)
        }
        let dest = uniqueURL(folder: opts.folder,
                             prefix: opts.namePrefix,
                             base: photo.url.deletingPathExtension().lastPathComponent,
                             ext: opts.format.fileExtension)
        try write(cg, to: dest, options: opts)
        return dest
    }

    static func write(_ cg: CGImage, to url: URL, options: ExportOptions) throws {
        try write(cg, to: url, quality: options.quality, type: utType(options.format))
    }

    /// The one place pixels reach the disk. `type` is resolved by the caller rather than read off
    /// `ExportOptions.format`, because saving in place has to respect the *original's* format.
    static func write(_ cg: CGImage, to url: URL, quality: Double, type: UTType) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ExportError.cannotCreate(url.lastPathComponent)
        }
        var props: [CFString: Any] = [:]
        // Only the lossy encoders read this key. Handing it to PNG or TIFF is ignored at best and
        // there is no reason to leave a quality setting in the file's metadata for a format that
        // does not have one.
        if isLossy(type) { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ExportError.writeFailed(url.lastPathComponent)
        }
    }

    private static func isLossy(_ type: UTType) -> Bool {
        [UTType.jpeg, UTType.heic, Self.jpeg2000].contains { type.conforms(to: $0) }
    }

    /// `UTType.jpeg2000` does not exist; the identifier is `public.jpeg-2000`.
    private static let jpeg2000 = UTType("public.jpeg-2000") ?? .image

    /// Formats ImageIO on *this* machine can encode, cached because the query is not free and
    /// `saveInPlace` asks once per file.
    ///
    /// Worth knowing the shape of the answer: `CGImageSourceCopyTypeIdentifiers()` reports 61
    /// readable types and `CGImageDestinationCopyTypeIdentifiers()` reports 21 writable ones. Of
    /// the formats this app imports, every one can be read and only nine can be written — JPEG,
    /// PNG, GIF, BMP, TIFF, HEIC, PSD, TGA, JPEG 2000. RAW, WebP, AVIF, JPEG XL and plain
    /// `heif` are read-only.
    private static let writableIdentifiers: Set<String> =
        Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])

    /// The type to write back into a file with this extension, or nil when this machine cannot
    /// encode that format at all.
    static func writableType(forExtension ext: String) -> UTType? {
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext),
              writableIdentifiers.contains(type.identifier) else { return nil }
        return type
    }

    private static func utType(_ f: ExportFormat) -> UTType {
        switch f {
        case .jpeg, .original: return .jpeg
        case .png: return .png
        case .tiff: return .tiff
        }
    }

    // MARK: - Batch

    static func exportAll(_ photos: [PhotoItem], options: ExportOptions,
                          progress: @escaping (Int, Int) -> Void) -> [URL] {
        var written: [URL] = []
        for (i, p) in photos.enumerated() {
            progress(i, photos.count)
            if let url = try? export(photo: p, options: options) { written.append(url) }
        }
        progress(photos.count, photos.count)
        return written
    }

    // MARK: - Save in place (the original app's "Save" / "Save a Copy")

    /// Writes the edited result back over the original file, keeping a backup copy in an
    /// `Originals` sub-folder — the same contract the original application used.
    ///
    /// **Not** every imported format can be saved over itself, and the failure is not loud: the
    /// old version chose `.png` or `.jpeg` from the extension and then wrote those bytes to the
    /// original path regardless. Editing a `.dng` and saving produced a JPEG called
    /// `IMG_1234.dng` — a file whose extension lies about its contents and which no longer
    /// decodes at all, the RAW being gone. Twenty-eight formats are readable and nine are
    /// writable, so this is the common case, not the edge case.
    ///
    /// A photo in a read-only format is therefore saved *beside* itself as `-edited.jpg` and the
    /// original is left untouched. The returned URL says which of the two happened.
    @discardableResult
    static func saveInPlace(photo: PhotoItem, backupOriginals: Bool, quality: Double = 0.95) throws -> URL {
        guard let cg = ImageEngine.shared.exportCGImage(photo: photo, maxDimension: nil) else {
            throw ExportError.renderFailed(photo.fileName)
        }
        let folder = photo.folder
        let base = photo.url.deletingPathExtension().lastPathComponent

        guard let type = writableType(forExtension: photo.url.pathExtension) else {
            let copy = uniqueURL(folder: folder, prefix: "", base: base + "-edited", ext: "jpg")
            try write(cg, to: copy, quality: quality, type: .jpeg)
            return copy
        }

        if backupOriginals {
            let originals = folder.appendingPathComponent("Originals", isDirectory: true)
            try? FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
            let backup = originals.appendingPathComponent(photo.fileName)
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.copyItem(at: photo.url, to: backup)
            }
        }
        try write(cg, to: photo.url, quality: quality, type: type)
        ImageEngine.shared.invalidate(url: photo.url)
        return photo.url
    }

    /// "Save a Copy" — always writes a new file next to the original.
    @discardableResult
    static func saveCopy(photo: PhotoItem, quality: Double = 0.95) throws -> URL {
        guard let cg = ImageEngine.shared.exportCGImage(photo: photo, maxDimension: nil) else {
            throw ExportError.renderFailed(photo.fileName)
        }
        let dest = uniqueURL(folder: photo.folder, prefix: "",
                             base: photo.url.deletingPathExtension().lastPathComponent + "-edited",
                             ext: "jpg")
        var opts = ExportOptions(folder: photo.folder)
        opts.quality = quality
        opts.format = .jpeg
        try write(cg, to: dest, options: opts)
        return dest
    }

    // MARK: - Helpers

    static func uniqueURL(folder: URL, prefix: String, base: String, ext: String) -> URL {
        let safePrefix = prefix.isEmpty ? "" : prefix + "_"
        var candidate = folder.appendingPathComponent("\(safePrefix)\(base).\(ext)")
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(safePrefix)\(base)_\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    static func drawWatermark(_ text: String, on cg: CGImage) -> CGImage? {
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let size = max(CGFloat(h) * 0.028, 12)
        let font = NSFont.boldSystemFont(ofSize: size)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = size * 0.25
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            .shadow: shadow
        ]
        let string = NSAttributedString(string: text, attributes: attrs)
        let s = string.size()
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        string.draw(at: CGPoint(x: CGFloat(w) - s.width - size, y: size))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}

enum ExportError: LocalizedError {
    case renderFailed(String)
    case cannotCreate(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .renderFailed(let n): return "Could not render \(n)"
        case .cannotCreate(let n): return "Could not create output for \(n)"
        case .writeFailed(let n): return "Could not write \(n)"
        }
    }
}

extension AppState {
    /// Photos the export / share commands should act on: the tray if non-empty, else the selection.
    var exportTargets: [PhotoItem] {
        if !store.tray.isEmpty { return store.trayPhotos }
        let sel = store.selection
        if !sel.isEmpty { return store.visiblePhotos.filter { sel.contains($0.id) } }
        return []
    }
}
