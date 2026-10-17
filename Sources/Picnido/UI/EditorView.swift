import SwiftUI
import AppKit

struct EditorView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                EditorCanvas()
                Divider()
                EditorStatusBar()
            }
            Divider()
            EditPanel()
                .frame(width: 302)
        }
    }
}

// MARK: - Status bar under the canvas

struct EditorStatusBar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 12) {
            if let photo = app.editingPhoto {
                Text(photo.fileName).font(.caption)
                Text(photo.dimensionsText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let id = app.editingID, let photo = app.store.photo(id) {
                Text("\(photo.stack.count) edit\(photo.stack.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Revert to Original") {
                    app.store.clearEdits(id)
                    app.liveTuning = TuningParams()
                    app.liveEffectID = nil
                    app.activeTool = .none
                }
                .controlSize(.small)
                .disabled(photo.stack.isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Canvas

struct EditorCanvas: View {
    @Environment(AppState.self) private var app

    @State private var rendered: CGImage?
    @State private var original: CGImage?
    @State private var rendering = false
    @State private var dragStart: CGRect?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(nsColor: .underPageBackgroundColor)

                if let photo = app.editingPhoto {
                    let fitted = fittedRect(imageSize: CGSize(width: photo.pixelWidth, height: photo.pixelHeight),
                                            in: geo.size, inset: 28)

                    ZStack {
                        if let img = rendered {
                            Image(decorative: img, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: fitted.width, height: fitted.height)
                        } else {
                            ProgressView()
                        }

                        if app.compareOriginal, let img = original {
                            Image(decorative: img, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: fitted.width / 2, height: fitted.height)
                                .clipped()
                                .frame(width: fitted.width, height: fitted.height, alignment: .leading)
                        }
                    }
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 3)
                    .overlay(alignment: .center) {
                        if case .crop = app.activeTool {
                            CropOverlay(fitted: fitted)
                        }
                    }
                    .overlay(alignment: .center) {
                        if app.activeTool == .straighten {
                            StraightenOverlay(fitted: fitted)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 1, coordinateSpace: .local) { location in
                        handleClick(location: location, fitted: fitted)
                    }
                    .frame(width: fitted.width, height: fitted.height)
                    .position(x: fitted.midX, y: fitted.midY)

                    if rendering {
                        VStack {
                            HStack {
                                Spacer()
                                ProgressView().controlSize(.small).padding(8)
                            }
                            Spacer()
                        }
                    }
                } else {
                    ContentUnavailableView("No photo selected", systemImage: "photo")
                }
            }
        }
        .task(id: renderKey) { await render() }
    }

    private var renderKey: String {
        guard let photo = app.editingPhoto else { return "none" }
        return "\(photo.id)|\(app.store.photo(photo.id)?.stack.count ?? 0)|\(app.liveEffectID ?? "")|\(app.liveEffectParams)|\(app.liveTuning)|\(app.liveStraighten)|\(app.activeTool)"
    }

    private func fittedRect(imageSize: CGSize, in container: CGSize, inset: CGFloat) -> CGRect {
        let availW = max(container.width - inset * 2, 80)
        let availH = max(container.height - inset * 2, 80)
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(x: inset, y: inset, width: availW, height: availH)
        }
        let scale = min(availW / imageSize.width, availH / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    private func render() async {
        guard let photo = app.editingPhoto else { rendered = nil; return }
        rendering = true
        let stack = app.displayStack(for: photo)
        let url = photo.url
        let img = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            ImageEngine.shared.render(stack: stack, url: url, maxDimension: 2400)
        }.value
        rendered = img
        if original == nil || original?.width != img?.width {
            let o = await Task.detached(priority: .utility) { () -> CGImage? in
                ImageEngine.shared.render(stack: [], url: url, maxDimension: 2400)
            }.value
            original = o
        }
        rendering = false
    }

    private func handleClick(location: CGPoint, fitted: CGRect) {
        guard fitted.contains(location) else { return }
        let nx = (location.x - fitted.minX) / fitted.width
        let ny = (location.y - fitted.minY) / fitted.height
        guard let id = app.editingID else { return }

        switch app.activeTool {
        case .redeye:
            app.store.push(id, .redeye(points: [CGPoint(x: nx, y: ny)], radius: app.toolRadius))
        case .retouch:
            app.store.push(id, .retouch(points: [CGPoint(x: nx, y: ny)], radius: app.toolRadius))
        case .whitePoint:
            app.store.push(id, .whitePoint(point: CGPoint(x: nx, y: ny), strength: 0.85))
            app.activeTool = .none
        case .text:
            app.liveText.x = nx
            app.liveText.y = ny
            app.store.push(id, .text(app.liveText))
            app.activeTool = .none
        case .pickFocal(let fid):
            app.liveEffectID = fid
            app.activeTool = .none
        default:
            break
        }
    }
}

// MARK: - Crop overlay

struct CropOverlay: View {
    @Environment(AppState.self) private var app
    let fitted: CGRect

    @State private var dragOrigin: CGRect?
    @State private var activeHandle: Int?

    private func rect() -> CGRect {
        CGRect(x: fitted.minX + app.liveCropRect.minX * fitted.width,
               y: fitted.minY + app.liveCropRect.minY * fitted.height,
               width: app.liveCropRect.width * fitted.width,
               height: app.liveCropRect.height * fitted.height)
    }

    var body: some View {
        let r = rect()
        ZStack {
            // dim outside
            Path { p in
                p.addRect(fitted)
                p.addRect(r)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))

            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)

            // rule-of-thirds guides
            ForEach(1..<3) { i in
                Rectangle().fill(Color.white.opacity(0.35)).frame(width: 1, height: r.height)
                    .position(x: r.minX + r.width * CGFloat(i) / 3, y: r.midY)
                Rectangle().fill(Color.white.opacity(0.35)).frame(width: r.width, height: 1)
                    .position(x: r.midX, y: r.minY + r.height * CGFloat(i) / 3)
            }

            ForEach(0..<4) { i in
                CornerHandle()
                    .position(handlePosition(i, in: r))
                    .gesture(handleDrag(i, in: r))
            }

            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .gesture(moveDrag(in: r))
        }
        .frame(width: fitted.width, height: fitted.height)
    }

    private func handlePosition(_ i: Int, in r: CGRect) -> CGPoint {
        switch i {
        case 0: return CGPoint(x: r.minX, y: r.minY)
        case 1: return CGPoint(x: r.maxX, y: r.minY)
        case 2: return CGPoint(x: r.minX, y: r.maxY)
        default: return CGPoint(x: r.maxX, y: r.maxY)
        }
    }

    private func normalize(_ r: CGRect) -> CGRect {
        var x = (r.minX - fitted.minX) / fitted.width
        var y = (r.minY - fitted.minY) / fitted.height
        var w = r.width / fitted.width
        var h = r.height / fitted.height
        x = min(max(x, 0), 1); y = min(max(y, 0), 1)
        w = min(max(w, 0.04), 1 - x); h = min(max(h, 0.04), 1 - y)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func handleDrag(_ i: Int, in r: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { v in
                var nr = r
                switch i {
                case 0: nr = CGRect(x: r.minX + v.translation.width, y: r.minY + v.translation.height,
                                    width: r.width - v.translation.width, height: r.height - v.translation.height)
                case 1: nr = CGRect(x: r.minX, y: r.minY + v.translation.height,
                                    width: r.width + v.translation.width, height: r.height - v.translation.height)
                case 2: nr = CGRect(x: r.minX + v.translation.width, y: r.minY,
                                    width: r.width - v.translation.width, height: r.height + v.translation.height)
                default: nr = CGRect(x: r.minX, y: r.minY,
                                     width: r.width + v.translation.width, height: r.height + v.translation.height)
                }
                nr = clamp(nr)
                app.liveCropRect = normalize(nr)
            }
    }

    private func moveDrag(in r: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { v in
                var nr = r
                nr.origin.x += v.translation.width
                nr.origin.y += v.translation.height
                nr = clamp(nr)
                app.liveCropRect = normalize(nr)
            }
    }

    private func clamp(_ r: CGRect) -> CGRect {
        var rect = r
        rect.size.width = max(rect.size.width, 24)
        rect.size.height = max(rect.size.height, 24)
        rect.origin.x = min(max(rect.minX, fitted.minX), fitted.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, fitted.minY), fitted.maxY - rect.height)

        if let aspect = app.currentAspect.value {
            var w = rect.width, h = rect.height
            if w / h > aspect { w = h * aspect } else { h = w / aspect }
            rect.size = CGSize(width: w, height: h)
            rect.origin.x = min(max(rect.minX, fitted.minX), fitted.maxX - w)
            rect.origin.y = min(max(rect.minY, fitted.minY), fitted.maxY - h)
        }
        return rect
    }
}

struct CornerHandle: View {
    var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 11, height: 11)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.4)))
            .shadow(radius: 1)
    }
}

struct StraightenOverlay: View {
    let fitted: CGRect
    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
            ForEach(0..<9) { i in
                Rectangle().fill(Color.white.opacity(0.28)).frame(width: 1)
                    .position(x: fitted.minX + fitted.width * CGFloat(i) / 8, y: fitted.midY)
                    .frame(height: fitted.height)
            }
            ForEach(0..<9) { i in
                Rectangle().fill(Color.white.opacity(0.28)).frame(height: 1)
                    .position(x: fitted.midX, y: fitted.minY + fitted.height * CGFloat(i) / 8)
                    .frame(width: fitted.width)
            }
        }
        .frame(width: fitted.width, height: fitted.height)
        .allowsHitTesting(false)
    }
}
