import Foundation
import AppKit
import CoreGraphics
import ImageIO

/// Writes a static HTML gallery from a template folder.
/// It reads templates from the app bundle and honours the `define` / `include` / `loop` /
/// `targetloop` / `copy` commands and the `<%variable%>` / `<%if name%>…<%endif%>`
/// substitution syntax that the gallery templates in this bundle are written in.
enum GalleryWriter {

    struct Template: Identifiable, Hashable {
        var id: String            // folder name
        var name: String          // friendly name
        var outputName: String    // file written by `define exportFileName`

        static let all: [Template] = [
            Template(id: "img_plain", name: "Plain — thumbnails only", outputName: "index.html")
        ]
    }

    // MARK: - Locating the templates

    static var root: URL? {
        if let u = Bundle.main.resourceURL?.appendingPathComponent("templates"),
           FileManager.default.fileExists(atPath: u.path) { return u }
        // development fallback next to the source tree
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/templates")
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        return nil
    }

    static func templates() -> [Template] {
        guard let root else { return [] }
        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return Template.all.filter { t in
            t.id == "img_plain" ? true : onDisk.contains(t.id)
        }
    }

    // MARK: - Export

    struct Settings {
        var folder: URL
        var template: String = "img_plain"
        var albumName: String = "My Album"
        var albumCaption: String = ""
        var imageWidth: Int = 800
        var thumbnailSize: Int = 128
        var showCaptions: Bool = true
    }

    static func export(photos: [PhotoItem], settings: Settings,
                       progress: @escaping (Int, Int) -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: settings.folder, withIntermediateDirectories: true)
        let imagesDir = settings.folder.appendingPathComponent("images", isDirectory: true)
        let thumbsDir = settings.folder.appendingPathComponent("thumbs", isDirectory: true)
        try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: thumbsDir, withIntermediateDirectories: true)

        // 1. write the images and build the variable table per item
        var items: [[String: String]] = []
        for (i, photo) in photos.enumerated() {
            progress(i, photos.count)
            let base = String(format: "%03d_%@", i + 1,
                              slug(photo.url.deletingPathExtension().lastPathComponent))
            let largeURL = imagesDir.appendingPathComponent(base + ".jpg")
            let thumbURL = thumbsDir.appendingPathComponent(base + ".jpg")

            if let cg = ImageEngine.shared.exportCGImage(photo: photo, maxDimension: CGFloat(settings.imageWidth)),
               let data = jpeg(cg, quality: 0.85) {
                try? data.write(to: largeURL)
            }
            if let cg = ImageEngine.shared.exportCGImage(photo: photo, maxDimension: CGFloat(settings.thumbnailSize)),
               let data = jpeg(cg, quality: 0.82) {
                try? data.write(to: thumbURL)
            }
            var vars: [String: String] = [:]
            vars["itemLargeImage"] = "images/" + largeURL.lastPathComponent
            vars["itemThumbnailImage"] = "thumbs/" + thumbURL.lastPathComponent
            vars["itemThumbnailWidth"] = "\(settings.thumbnailSize)"
            vars["itemThumbnailHeight"] = "\(settings.thumbnailSize)"
            vars["itemCaption"] = settings.showCaptions ? (photo.caption.isEmpty ? photo.fileName : photo.caption) : ""
            vars["itemName"] = photo.fileName
            vars["itemWidth"] = "\(settings.imageWidth)"
            vars["itemHeight"] = "\(settings.imageWidth)"
            vars["itemWidth"] = "\(photo.pixelWidth)"
            vars["itemHeight"] = "\(photo.pixelHeight)"
            vars["isImage"] = "1"
            vars["isMovie"] = ""
            items.append(vars)
        }
        progress(photos.count, photos.count)

        let globals: [String: String] = [
            "albumName": settings.albumName,
            "albumCaption": settings.albumCaption,
            "albumItemCount": "\(photos.count)",
            "exportDescription": settings.albumName,
            "exportFileName": "index.html"
        ]

        if settings.template == "img_plain" {
            try writePlainGallery(photos: photos, items: items, settings: settings, globals: globals)
            return
        }

        guard let root else {
            try writePlainGallery(photos: photos, items: items, settings: settings, globals: globals)
            return
        }
        let templateDir = root.appendingPathComponent(settings.template)
        guard fm.fileExists(atPath: templateDir.appendingPathComponent("index.tpl").path) else {
            try writePlainGallery(photos: photos, items: items, settings: settings, globals: globals)
            return
        }

        let outFile = settings.folder.appendingPathComponent("index.html").path
        var output = ""

        var targetIndex = 0
        var targetPages: [String] = []

        let indexText = (try? String(contentsOf: templateDir.appendingPathComponent("index.tpl"), encoding: .utf8)) ?? ""
        var defines = globals

        for rawLine in indexText.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ").map(String.init)
            guard let cmd = parts.first else { continue }

            switch cmd {
            case "define":
                if parts.count >= 3 { defines[parts[1]] = parts[2...].joined(separator: " ") }
            case "exportFileName":
                if parts.count >= 2 { defines["exportFileName"] = parts[1] }
            case "include":
                if parts.count >= 2 {
                    output += substitute(read(templateDir, parts[1]), vars: defines.merging(globals) { a, _ in a })
                }
            case "loop":
                if parts.count >= 2 {
                    let fragment = read(templateDir, parts[1])
                    for item in items {
                        output += substitute(fragment, vars: item.merging(defines) { a, _ in a })
                    }
                }
            case "targetloop":
                if parts.count >= 3 {
                    let pageTemplate = read(templateDir, parts[1])
                    let includeFragment = read(templateDir, parts[2])
                    for (i, item) in items.enumerated() {
                        var vars = item.merging(defines) { a, _ in a }
                        vars["isFirstTarget"] = i == 0 ? "" : "1"
                        vars["isLastTarget"] = i == items.count - 1 ? "" : "1"
                        vars["isPrevTarget"] = i > 0 ? "1" : ""
                        vars["isNextTarget"] = i < items.count - 1 ? "1" : ""
                        vars["firstTarget"] = "target1.html"
                        vars["lastTarget"] = "target\(items.count).html"
                        vars["prevTarget"] = "target\(i).html"
                        vars["nextTarget"] = "target\(i + 2).html"
                        vars["referrer"] = defines["exportFileName"] ?? "index.html"
                        let page = substitute(pageTemplate, vars: vars)
                        let pageURL = settings.folder.appendingPathComponent("target\(i + 1).html")
                        try? page.write(to: pageURL, atomically: true, encoding: .utf8)
                        var incVars = item.merging(defines) { a, _ in a }
                        incVars["targetPath"] = "target\(i + 1).html"
                        output += substitute(includeFragment, vars: incVars)
                    }
                    targetIndex = items.count
                    _ = targetIndex
                }
            case "copy":
                if parts.count >= 2 {
                    let src = templateDir.appendingPathComponent(parts[1])
                    let dstName = parts.count >= 3 ? parts[2] : parts[1]
                    let dst = settings.folder.appendingPathComponent(dstName)
                    try? copyItem(src, to: dst)
                }
            default:
                output += substitute(rawLine, vars: defines.merging(globals) { a, _ in a }) + "\n"
            }
        }

        try output.write(to: URL(fileURLWithPath: outFile), atomically: true, encoding: .utf8)
        _ = targetPages
    }

    // MARK: - Fallback plain gallery (also used for "Plain")

    private static func writePlainGallery(photos: [PhotoItem], items: [[String: String]],
                                          settings: Settings, globals: [String: String]) throws {
        var html = """
        <html><head><meta charset="utf-8"><title>\(settings.albumName)</title>
        <style>
        body{font-family:-apple-system,Helvetica,Arial,sans-serif;background:#fff;color:#111;margin:40px}
        .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:16px}
        figure{margin:0}img{width:100%;height:auto;border-radius:4px;box-shadow:0 1px 4px rgba(0,0,0,.2)}
        figcaption{font-size:11px;color:#666;margin-top:6px}
        h1{font-size:20px}
        </style></head><body>
        <h1>\(settings.albumName)</h1><p>\(settings.albumCaption)</p>
        <div class="grid">
        """
        for item in items {
            html += """
            <figure><a href="\(item["itemLargeImage"] ?? "")"><img src="\(item["itemThumbnailImage"] ?? "")" alt=""></a>
            <figcaption>\(item["itemCaption"] ?? "")</figcaption></figure>
            """
        }
        html += "</div></body></html>"
        try html.write(to: settings.folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    }

    // MARK: - Engine bits

    private static func read(_ dir: URL, _ name: String) -> String {
        (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    private static func substitute(_ text: String, vars: [String: String]) -> String {
        var result = text
        // <%if name%> … <%endif%>  and  <%if !name%> … <%endif%>
        let pattern = "<%if\\s+(!?)([A-Za-z0-9_]+)%>(.*?)<%endif%>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
            var guardCount = 0
            while guardCount < 50 {
                let range = NSRange(result.startIndex..., in: result)
                guard let match = regex.firstMatch(in: result, options: [], range: range) else { break }
                let negate = (result[Range(match.range(at: 1), in: result)!]) == "!"
                let name = String(result[Range(match.range(at: 2), in: result)!])
                let body = String(result[Range(match.range(at: 3), in: result)!])
                let value = vars[name] ?? ""
                let truthy = !value.isEmpty && value != "0"
                let keep = negate ? !truthy : truthy
                result = (result as NSString).replacingCharacters(in: match.range, with: keep ? body : "")
                guardCount += 1
            }
        }
        // <%name%>
        let varPattern = "<%([A-Za-z0-9_]+)%>"
        if let regex = try? NSRegularExpression(pattern: varPattern) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                let name = String(result[Range(match.range(at: 1), in: result)!])
                result = (result as NSString).replacingCharacters(in: match.range, with: vars[name] ?? "")
            }
        }
        return result
    }

    private static func slug(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .replacingOccurrences(of: "__+", with: "_", options: .regularExpression)
    }

    private static func jpeg(_ cg: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func copyItem(_ src: URL, to dst: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else { return }
        if isDir.boolValue {
            try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
            for child in (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? [] {
                try? copyItem(child, to: dst.appendingPathComponent(child.lastPathComponent))
            }
        } else {
            if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
        }
    }
}
