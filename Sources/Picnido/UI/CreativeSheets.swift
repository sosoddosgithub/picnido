import SwiftUI
import AppKit
import AVFoundation

// MARK: - Collage

struct CollageSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var preview: CGImage?
    @State private var working = false
    @State private var message = StatusNote()
    @State private var aspectChoice: AspectChoice = .square

    enum AspectChoice: String, CaseIterable, Identifiable {
        case square = "Square (1:1)"
        case standard = "Standard (4:3)"
        case wide = "Widescreen (16:9)"
        case photo = "Photo (3:2)"
        case tall = "Tall (2:3)"
        var id: String { rawValue }
        var value: Double {
            switch self {
            case .square: return 1.0
            case .standard: return 4.0 / 3.0
            case .wide: return 16.0 / 9.0
            case .photo: return 3.0 / 2.0
            case .tall: return 2.0 / 3.0
            }
        }
    }

    private var sourcePhotos: [PhotoItem] {
        let targets = app.exportTargets
        return targets.isEmpty ? Array(app.store.visiblePhotos.prefix(12)) : targets
    }

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "square.grid.3x3.square").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Collage").font(.headline)
                    Text("\(sourcePhotos.count) photos")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Layout", selection: $app.collageLayout) {
                        ForEach(CollageLayout.allCases) { Text(localizedString($0.rawValue)).tag($0) }
                    }
                    Picker("Shape", selection: $aspectChoice) {
                        ForEach(AspectChoice.allCases) { Text(localizedString($0.rawValue)).tag($0) }
                    }
                    Picker("Background", selection: $app.collageBackground) {
                        ForEach(CollageBackground.allCases) { Text(localizedString($0.rawValue)).tag($0) }
                    }
                    HStack {
                        Text("Spacing").font(.caption)
                        Slider(value: $app.collageSpacing, in: 0...40)
                        Text("\(Int(app.collageSpacing))").font(.caption).frame(width: 24)
                    }
                    HStack {
                        Text("Border").font(.caption)
                        Slider(value: $app.collageBorderWidth, in: 0...24)
                        Text("\(Int(app.collageBorderWidth))").font(.caption).frame(width: 24)
                    }
                    Toggle("Drop shadows", isOn: $app.collageShadows)
                    Button("Refresh preview") { render() }
                        .controlSize(.small)
                }
                .frame(width: 280)

                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black.opacity(0.08))
                    if let preview {
                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(8)
                    } else if working {
                        ProgressView()
                    } else {
                        Text("Preview").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 420, height: 320)
            }

            if !message.isEmpty {
                Text(message.text(app.language)).font(.caption).foregroundStyle(.green)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create…") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sourcePhotos.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 760)
        .onAppear { render() }
    }

    private func settings() -> CollageMaker.Settings {
        var s = CollageMaker.Settings()
        s.layout = app.collageLayout
        s.aspect = aspectChoice.value
        s.spacing = CGFloat(app.collageSpacing)
        s.background = app.collageBackground
        s.shadows = app.collageShadows
        s.borderWidth = CGFloat(app.collageBorderWidth)
        s.captions = app.collageLayout == .contactSheet
        return s
    }

    private func render() {
        working = true
        let photos = sourcePhotos
        let s = settings()
        DispatchQueue.global(qos: .userInitiated).async {
            let img = CollageMaker.render(photos: photos, settings: s)
            DispatchQueue.main.async { preview = img; working = false }
        }
    }

    private func create() {
        let photos = sourcePhotos
        let s = settings()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Collage.jpg"
        panel.prompt = "Save"
        if panel.runModal() == .OK, let url = panel.url {
            DispatchQueue.global(qos: .userInitiated).async {
                guard let img = CollageMaker.render(photos: photos, settings: s) else { return }
                var opts = ExportOptions(folder: url.deletingLastPathComponent())
                opts.quality = 0.92
                try? Exporter.write(img, to: url, options: opts)
                DispatchQueue.main.async { message = StatusNote("Saved %@", [url.lastPathComponent]) }
            }
        }
    }
}

// MARK: - Movie

struct MovieSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var progress: Double = 0
    @State private var running = false
    @State private var message = StatusNote()

    private var sourcePhotos: [PhotoItem] {
        let t = app.exportTargets
        return t.isEmpty ? Array(app.store.visiblePhotos.prefix(24)) : t
    }

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "film").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Movie").font(.headline)
                    Text("\(sourcePhotos.count) photos")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Title").frame(width: 110, alignment: .leading)
                    TextField("Movie title", text: $app.movieTitle).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Seconds / photo").frame(width: 110, alignment: .leading)
                    HStack {
                        Slider(value: $app.movieDuration, in: 0.5...12)
                        Text(String(format: "%.1f", app.movieDuration)).font(.caption).frame(width: 34)
                    }
                }
                GridRow {
                    Text("Transition").frame(width: 110, alignment: .leading)
                    Picker("", selection: $app.movieTransition) {
                        ForEach(TransitionKind.allCases) { Text(localizedString($0.rawValue)).tag($0) }
                    }.labelsHidden().frame(width: 180)
                }
                GridRow {
                    Text("Resolution").frame(width: 110, alignment: .leading)
                    Picker("", selection: $app.movieResolution) {
                        ForEach(MovieResolution.allCases) { Text(localizedString($0.rawValue)).tag($0) }
                    }.labelsHidden().frame(width: 180)
                }
                GridRow {
                    Text("Ken Burns").frame(width: 110, alignment: .leading)
                    Toggle("Pan and zoom each photo", isOn: $app.movieKenBurns)
                }
                GridRow {
                    Text("Music").frame(width: 110, alignment: .leading)
                    HStack {
                        Text(localizedString(app.movieMusic?.lastPathComponent ?? "None"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Button("Choose…") { chooseMusic() }.controlSize(.small)
                        if app.movieMusic != nil {
                            Button("Clear") { app.movieMusic = nil }.controlSize(.small)
                        }
                    }
                }
            }

            if running {
                ProgressView(value: progress)
                Text("\(Int(progress * 100))% — encoding")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !message.isEmpty {
                Text(message.text(app.language)).font(.caption).foregroundStyle(.green)
            }

            Divider()
            HStack {
                Text("Estimated length: \(estimatedLength)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button(localizedString(running ? "Creating…" : "Create…")) { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running || sourcePhotos.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 610)
    }

    private var estimatedLength: String {
        let seconds = Double(sourcePhotos.count) * app.movieDuration
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private func chooseMusic() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mp3, .mpeg4Audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { app.movieMusic = panel.url }
    }

    private func create() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(app.movieTitle.isEmpty ? "Picnido Movie" : app.movieTitle).mp4"
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var s = MovieMaker.Settings()
        s.photos = sourcePhotos
        s.secondsPerPhoto = app.movieDuration
        s.transition = app.movieTransition
        s.resolution = app.movieResolution
        s.kenBurns = app.movieKenBurns
        s.music = app.movieMusic
        s.title = app.movieTitle
        running = true
        message = StatusNote()
        MovieMaker.make(settings: s, output: url, progress: { p in
            DispatchQueue.main.async { progress = p }
        }, completion: { result in
            DispatchQueue.main.async {
                running = false
                switch result {
                case .success(let u):
                    message = StatusNote("Wrote %@", [u.lastPathComponent])
                    NSWorkspace.shared.activateFileViewerSelecting([u])
                case .failure(let e):
                    message = StatusNote("Failed: %@", [e.localizedDescription])
                }
            }
        })
    }
}

// MARK: - Poster

struct PosterSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var preview: CGImage?
    @State private var message = StatusNote()

    private var sourcePhotos: [PhotoItem] {
        let t = app.exportTargets
        return t.isEmpty ? Array(app.store.visiblePhotos.prefix(12)) : t
    }

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "doc.richtext").font(.title2)
                Text("Poster").font(.headline)
                Spacer()
            }
            Divider()
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Poster title", text: $app.posterTitle).textFieldStyle(.roundedBorder)
                    HStack {
                        Text("Page").font(.caption)
                        TextField("W", value: $app.posterPageWidth, format: .number)
                            .frame(width: 50).textFieldStyle(.roundedBorder)
                        Text("×").foregroundStyle(.secondary)
                        TextField("H", value: $app.posterPageHeight, format: .number)
                            .frame(width: 50).textFieldStyle(.roundedBorder)
                        Text("inches").font(.caption).foregroundStyle(.secondary)
                    }
                    Stepper("Columns: \(app.posterColumns)", value: $app.posterColumns, in: 1...8)
                    Stepper("Rows: \(app.posterRows)", value: $app.posterRows, in: 1...8)
                    Button("Refresh preview") { render() }.controlSize(.small)
                }
                .frame(width: 260)

                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.08))
                    if let preview {
                        Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit).padding(8)
                    }
                }
                .frame(width: 430, height: 300)
            }
            if !message.isEmpty { Text(message.text(app.language)).font(.caption).foregroundStyle(.green) }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Export PDF…") { exportPDF() }
                Button("Print…") { PosterMaker.print(settings: settings()) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sourcePhotos.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 760)
        .onAppear { render() }
    }

    private func settings() -> PosterMaker.Settings {
        var s = PosterMaker.Settings()
        s.photos = sourcePhotos
        s.title = app.posterTitle
        s.pageWidthInches = app.posterPageWidth
        s.pageHeightInches = app.posterPageHeight
        s.columns = app.posterColumns
        s.rows = app.posterRows
        return s
    }

    private func render() {
        let s = settings()
        DispatchQueue.global(qos: .userInitiated).async {
            let img = PosterMaker.renderPreview(settings: s)
            DispatchQueue.main.async { preview = img }
        }
    }

    private func exportPDF() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(app.posterTitle.isEmpty ? "Poster" : app.posterTitle).pdf"
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PosterMaker.exportPDF(settings: settings(), to: url)
            message = StatusNote("Wrote %@", [url.lastPathComponent])
        } catch {
            message = StatusNote("Failed: %@", [error.localizedDescription])
        }
    }
}

// MARK: - HTML gallery

struct GalleryExportSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var template = "img_plain"
    @State private var albumName = "My Album"
    @State private var albumCaption = ""
    @State private var imageWidth: Double = 800
    @State private var thumbSize: Double = 128
    @State private var folder: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Sites/PicnidoGallery")
    @State private var running = false
    @State private var message = StatusNote()

    private let templates = GalleryWriter.templates()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "globe").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Export as HTML Gallery").font(.headline)
                    Text("\(app.exportTargets.count) photos · uses the original template engine")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()

            Picker("Template", selection: $template) {
                ForEach(templates) { Text(localizedString($0.name)).tag($0.id) }
            }
            .pickerStyle(.radioGroup)

            HStack {
                Text("Album name").frame(width: 100, alignment: .leading)
                TextField("", text: $albumName).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Caption").frame(width: 100, alignment: .leading)
                TextField("optional", text: $albumCaption).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Image width").frame(width: 100, alignment: .leading)
                Slider(value: $imageWidth, in: 320...2400, step: 20)
                Text("\(Int(imageWidth)) px").font(.caption).frame(width: 70, alignment: .trailing)
            }
            HStack {
                Text("Thumbnails").frame(width: 100, alignment: .leading)
                Slider(value: $thumbSize, in: 64...320, step: 8)
                Text("\(Int(thumbSize)) px").font(.caption).frame(width: 70, alignment: .trailing)
            }
            HStack {
                Text("Destination").frame(width: 100, alignment: .leading)
                Text(folder.path).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.prompt = "Choose"
                    if panel.runModal() == .OK, let u = panel.url { folder = u }
                }
            }

            if !message.isEmpty { Text(message.text(app.language)).font(.caption).foregroundStyle(.green) }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(localizedString(running ? "Exporting…" : "Export")) { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running || app.exportTargets.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 640)
    }

    private func run() {
        var s = GalleryWriter.Settings(folder: folder)
        s.template = template
        s.albumName = albumName
        s.albumCaption = albumCaption
        s.imageWidth = Int(imageWidth)
        s.thumbnailSize = Int(thumbSize)
        let photos = app.exportTargets
        running = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try GalleryWriter.export(photos: photos, settings: s) { _, _ in }
                DispatchQueue.main.async {
                    running = false
                    message = StatusNote("Wrote %@", [folder.appendingPathComponent("index.html").path])
                    NSWorkspace.shared.open(folder.appendingPathComponent("index.html"))
                }
            } catch {
                DispatchQueue.main.async {
                    running = false
                    message = StatusNote("Failed: %@", [error.localizedDescription])
                }
            }
        }
    }
}
