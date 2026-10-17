import SwiftUI
import AppKit

// MARK: - Export

struct ExportSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var isRunning = false
    @State private var progressText = StatusNote()
    @State private var doneText = StatusNote()

    private var targets: [PhotoItem] { app.exportTargets }

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "square.and.arrow.up").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Export").font(.headline)
                    Text(targets.isEmpty
                     ? localizedString("Nothing selected")
                     : localizedFormat(targets.count == 1 ? "%lld photo will be exported"
                                                         : "%lld photos will be exported",
                                       targets.count))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Location").frame(width: 110, alignment: .leading)
                    Text(app.exportFolder.path)
                        .font(.system(size: 11))
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.prompt = "Choose"
                        if panel.runModal() == .OK, let u = panel.url { app.exportFolder = u }
                    }
                }

                HStack {
                    Text("Name prefix").frame(width: 110, alignment: .leading)
                    TextField("optional", text: $app.exportNamePrefix)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("Image size").frame(width: 110, alignment: .leading)
                    Toggle("Original size", isOn: $app.exportOriginalSize)
                    Slider(value: $app.exportMaxDimension, in: 480...6000, step: 20)
                        .disabled(app.exportOriginalSize)
                    Text(app.exportOriginalSize
                     ? localizedString("original")
                     : localizedFormat("%lld px", Int(app.exportMaxDimension)))
                        .font(.caption).frame(width: 74, alignment: .trailing)
                }

                HStack {
                    Text("Format").frame(width: 110, alignment: .leading)
                    Picker("", selection: $app.exportFormat) {
                        ForEach(ExportFormat.allCases) { Text(localizedString($0.rawValue)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    Spacer()
                }

                HStack {
                    Text("Quality").frame(width: 110, alignment: .leading)
                    Slider(value: $app.exportJPEGQuality, in: 0.4...1.0)
                        .disabled(app.exportFormat == .png)
                    Text("\(Int(app.exportJPEGQuality * 100))%")
                        .font(.caption).frame(width: 74, alignment: .trailing)
                }

                HStack {
                    Toggle("Watermark", isOn: $app.exportWatermark)
                    TextField("text", text: $app.exportWatermarkText)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!app.exportWatermark)
                }
                .frame(maxWidth: 420, alignment: .leading)
            }

            Divider()

            if !progressText.isEmpty {
                Text(progressText.text(app.language)).font(.caption).foregroundStyle(.secondary)
            }
            if !doneText.isEmpty {
                Text(doneText.text(app.language)).font(.caption).foregroundStyle(.green)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(localizedString(isRunning ? "Exporting…" : "Export")) { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(targets.isEmpty || isRunning)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private func run() {
        guard !targets.isEmpty else { return }
        isRunning = true
        var opts = ExportOptions(folder: app.exportFolder)
        opts.namePrefix = app.exportNamePrefix
        opts.maxDimension = app.exportOriginalSize ? nil : CGFloat(app.exportMaxDimension)
        opts.quality = app.exportJPEGQuality
        opts.format = app.exportFormat
        opts.watermark = app.exportWatermark ? app.exportWatermarkText : nil

        let photos = targets
        let folder = app.exportFolder
        DispatchQueue.global(qos: .userInitiated).async {
            var count = 0
            for (i, p) in photos.enumerated() {
                DispatchQueue.main.async { progressText = StatusNote("Exporting %lld of %lld…", [i + 1, photos.count]) }
                if (try? Exporter.export(photo: p, options: opts)) != nil { count += 1 }
            }
            DispatchQueue.main.async {
                isRunning = false
                progressText = StatusNote()
                doneText = StatusNote("Exported %lld file\(count == 1 ? "" : "s") to %@", [count, folder.lastPathComponent])
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
        }
    }
}

// MARK: - Backup

struct BackupSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var destination: URL = FileManager.default.homeDirectoryForCurrentUser
    @State private var includeOriginals = true
    @State private var status = StatusNote()
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "externaldrive.badge.timemachine").font(.title2)
                Text("Back Up Library").font(.headline)
                Spacer()
            }
            Divider()
            HStack {
                Text("Destination").frame(width: 110, alignment: .leading)
                Text(destination.path).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.prompt = "Choose"
                    if panel.runModal() == .OK, let u = panel.url { destination = u }
                }
            }
            Toggle("Include an Originals sub-folder with untouched copies", isOn: $includeOriginals)
            Text("\(app.store.photos.count) photos · \(ByteCountFormatter.string(fromByteCount: app.store.photos.reduce(0) { $0 + $1.fileSize }, countStyle: .file))")
                .font(.caption).foregroundStyle(.secondary)
            if !status.isEmpty { Text(status.text(app.language)).font(.caption).foregroundStyle(.green) }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(localizedString(running ? "Backing up…" : "Back Up")) { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func run() {
        running = true
        let photos = app.store.photos
        let dest = destination
        let withOriginals = includeOriginals
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            var copied = 0
            for p in photos {
                let rel = p.url.path.replacingOccurrences(of: fm.homeDirectoryForCurrentUser.path, with: "")
                let target = dest.appendingPathComponent("Picnido Backup").appendingPathComponent(rel)
                try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fm.fileExists(atPath: target.path) {
                    try? fm.copyItem(at: p.url, to: target)
                    copied += 1
                }
                _ = withOriginals
            }
            DispatchQueue.main.async {
                running = false
                status = StatusNote("Backed up %lld new file\(copied == 1 ? "" : "s")", [copied])
            }
        }
    }
}

// MARK: - New album

struct NewAlbumSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 14) {
            Text("New Album").font(.headline)
            TextField("Album name", text: $app.newAlbumName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            Text("Photos currently in the tray (\(app.store.tray.count)) will be added.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    let name = app.newAlbumName.trimmingCharacters(in: .whitespaces)
                    app.store.createAlbum(named: name.isEmpty ? "Untitled Album" : name,
                                          with: app.store.tray)
                    app.newAlbumName = ""
                    app.store.clearTray()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Print

struct PrintSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var style: PrintStyle = .contactSheet
    @State private var columns = 2
    @State private var rows = 3
    @State private var showCaption = true

    enum PrintStyle: String, CaseIterable, Identifiable {
        case fullPage = "One photo per page"
        case contactSheet = "Contact sheet"
        case fourBySix = "4×6 prints"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "printer").font(.title2)
                Text("Print").font(.headline)
                Spacer()
            }
            Divider()
            Picker("Layout", selection: $style) {
                ForEach(PrintStyle.allCases) { Text(localizedString($0.rawValue)).tag($0) }
            }
            if style == .contactSheet {
                HStack {
                    Text("Columns"); Stepper("\(columns)", value: $columns, in: 1...6)
                    Text("Rows"); Stepper("\(rows)", value: $rows, in: 1...8)
                }
            }
            Toggle("Print captions", isOn: $showCaption)
            Text("\(app.exportTargets.count) photos")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Print…") {
                    PrintRenderer.print(photos: app.exportTargets, style: style,
                                        columns: columns, rows: rows, captions: showCaption)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(app.exportTargets.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

enum PrintRenderer {

    static func print(photos: [PhotoItem], style: PrintSheet.PrintStyle,
                      columns: Int, rows: Int, captions: Bool) {
        guard !photos.isEmpty else { return }
        let info = NSPrintInfo.shared
        info.topMargin = 36; info.bottomMargin = 36
        info.leftMargin = 36; info.rightMargin = 36
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.orientation = .landscape

        let view = PrintLayoutView(photos: photos, style: style, columns: columns,
                                   rows: rows, captions: captions, pageSize: info.paperSize)
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = true
        op.run()
    }
}

final class PrintLayoutView: NSView {
    let photos: [PhotoItem]
    let style: PrintSheet.PrintStyle
    let columns: Int
    let rows: Int
    let captions: Bool
    let pageSize: NSSize
    private var images: [CGImage?] = []

    init(photos: [PhotoItem], style: PrintSheet.PrintStyle, columns: Int, rows: Int,
         captions: Bool, pageSize: NSSize) {
        self.photos = photos
        self.style = style
        self.columns = max(columns, 1)
        self.rows = max(rows, 1)
        self.captions = captions
        self.pageSize = pageSize
        super.init(frame: NSRect(origin: .zero, size: pageSize))
        images = photos.map { ImageEngine.shared.exportCGImage(photo: $0, maxDimension: 2000) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()

        let contentW = pageSize.width - 72
        let contentH = pageSize.height - 72

        switch style {
        case .fullPage:
            for (i, img) in images.enumerated() {
                if i > 0 { NSGraphicsContext.current?.cgContext.beginPDFPage(nil) }
                drawImage(img, in: NSRect(x: 36, y: 36, width: contentW, height: contentH))
            }
        case .contactSheet, .fourBySix:
            let perPage = columns * rows
            let cellW = contentW / CGFloat(columns)
            let cellH = contentH / CGFloat(rows)
            for (i, img) in images.enumerated() {
                let page = i / perPage
                let idxOnPage = i % perPage
                if idxOnPage == 0 && page > 0 {
                    NSGraphicsContext.current?.cgContext.beginPDFPage(nil)
                    NSColor.white.setFill()
                    bounds.fill()
                }
                let col = idxOnPage % columns
                let row = idxOnPage / columns
                let padding: CGFloat = 10
                let captionH: CGFloat = captions ? 16 : 0
                let cell = NSRect(x: 36 + CGFloat(col) * cellW + padding,
                                  y: 36 + CGFloat(row) * cellH + padding,
                                  width: cellW - padding * 2,
                                  height: cellH - padding * 2 - captionH)
                drawImage(img, in: cell)
                if captions {
                    let p = photos[i]
                    let text = p.caption.isEmpty ? p.fileName : p.caption
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 9),
                        .foregroundColor: NSColor.darkGray
                    ]
                    (text as NSString).draw(in: NSRect(x: cell.minX, y: cell.maxY + 3,
                                                       width: cell.width, height: 12),
                                            withAttributes: attrs)
                }
            }
        }
    }

    private func drawImage(_ cg: CGImage?, in rect: NSRect) {
        guard let cg else { return }
        let src = NSSize(width: cg.width, height: cg.height)
        let scale = min(rect.width / src.width, rect.height / src.height)
        let w = src.width * scale, h = src.height * scale
        let target = NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        NSGraphicsContext.current?.cgContext.draw(cg, in: target)
    }
}

// MARK: - Email

enum EmailComposer {
    static func compose(photos: [PhotoItem], app: AppState) {
        guard !photos.isEmpty else { return }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("PicnidoMail")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        var urls: [URL] = []
        var opts = ExportOptions(folder: tmp)
        opts.maxDimension = 1200
        opts.quality = 0.8
        opts.watermark = nil
        for p in photos.prefix(12) {
            if let u = try? Exporter.export(photo: p, options: opts) { urls.append(u) }
        }
        guard !urls.isEmpty else { return }
        if let service = NSSharingService(named: .composeEmail) {
            service.perform(withItems: urls)
        } else {
            NSWorkspace.shared.open(urls[0])
        }
    }
}
