import SwiftUI
import AppKit
import CoreImage

// MARK: - Background blur / vibrancy helper

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}

/// The signature "frosted glass" backdrop.
///
/// Only the tinted wash of the current photo lives here. The actual behind-window blur is
/// installed on the window itself by `configureViewerWindow`, because an AppKit subview —
/// and `NSVisualEffectView` is one — always draws above the hosting view's SwiftUI content.
/// A `VisualEffectView` placed in this stack would therefore have covered the filmstrip and
/// the buttons rather than sitting behind the photo. The wash is a cached bitmap rather than
/// a live SwiftUI `.blur()`, which is what used to make zooming stutter.
///
/// NOTE: the wash goes in an `.overlay`, never in the `ZStack` directly. An
/// `.aspectRatio(contentMode: .fill)` image reports the *scaled-to-fill* size as its layout
/// size, so as a sibling it silently inflated the whole viewer: a 1400×950 photo in a
/// 2048×1152 window made the root stack 2048×1389.7, which pushed the filmstrip below the
/// bottom edge of the screen. An overlay contributes no layout at all, so the root stack is
/// always exactly the window.
struct FrostedBackdrop: View {
    let photo: PhotoItem?

    @State private var wash: CGImage?

    var body: some View {
        Color.clear
            .overlay {
                if let wash {
                    Image(decorative: wash, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .opacity(Self.washOpacity)
                } else {
                    Color.black.opacity(0.22)
                }
            }
            .overlay(Color.black.opacity(0.14))
            .clipped()
            .ignoresSafeArea()
            .task(id: photo?.id) { await load() }
    }

    /// Photo-wash strength. PICNIDO_WASH_ALPHA=0 strips it back to bare system glass, which is
    /// how the behind-window blur gets verified in isolation.
    private static var washOpacity: Double {
        if let raw = ProcessInfo.processInfo.environment["PICNIDO_WASH_ALPHA"],
           let value = Double(raw) { return min(max(value, 0), 1) }
        return 0.46
    }

    private func load() async {
        guard let photo else { wash = nil; return }
        let p = photo
        let img = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            ImageEngine.shared.frostedBackdrop(for: p)
        }.value
        wash = img
    }
}

// MARK: - Zoom commands

/// Keyboard zoom commands travel from the viewer (which owns the key handlers, because they are
/// shared with the rest of the app's shortcuts) down to the stage (which owns the zoom maths).
///
/// The sequence number matters: two presses of "+" are two distinct values, so an `onChange`
/// observer fires both times instead of collapsing them into one.
struct ZoomRequest: Equatable {
    enum Kind { case zoomIn, zoomOut, reset, toggle }
    let seq: Int
    let kind: Kind
}

/// Append-only zoom trace. PICNIDO_ZOOM_LOG=<path> turns it on.
func picnidoZoomLog(_ message: String) {
    guard let path = ProcessInfo.processInfo.environment["PICNIDO_ZOOM_LOG"] else { return }
    let line = "\(message)\n"
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8) ?? Data())
        try? h.close()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// MARK: - Photo Viewer

struct ViewerWindow: View {
    @Environment(AppState.self) private var app

    /// The strip at the top of the display that the menu bar is composited over.
    ///
    /// `ViewerHost` builds the panel at `screen.frame`, which **includes** that strip: the window
    /// reaches the physical top edge and the menu bar is drawn on top of it. Whatever the viewer
    /// puts in those first ~25 points is not merely close to the menu bar, it is underneath it —
    /// and that is what happened to the Close button. The tool bar's top padding was a flat 14
    /// points, so the row sat at y=14…41 with the menu bar covering 0…25: the button was half
    /// eaten, and the row read as clipped rather than as overlapped.
    ///
    /// Passed in rather than looked up here: the value belongs to the display the panel was
    /// placed on, and when this view first evaluates the window is still mid-construction
    /// (`ViewerHost.shared.nsWindow` is nil until after `contentView` is assigned).
    var menuBand: CGFloat = ViewerWindow.fallbackMenuBand

    /// For the never-opened scene declaration in `PicnidoApp`, which has no display to ask.
    /// `NSStatusBar.system.thickness` reports the same number on every display of a given Mac
    /// and does not change when the menu bar is set to auto-hide — which is the property that
    /// makes it the right fallback for a reserve that has to hold in *both* states.
    static var fallbackMenuBand: CGFloat { NSStatusBar.system.thickness }

    @State private var chromeVisible = true
    @State private var hideWorkItem: DispatchWorkItem?

    /// Forwarded to the stage. Holding the zoom state here would re-evaluate *this* body on every
    /// frame of a drag, which — with a filmstrip of hundreds of cells mounted below — was the
    /// other half of why dragging a zoomed photo stuttered.
    @State private var zoomRequest: ZoomRequest?
    @State private var zoomSeq = 0

    /// Glass the picture must keep above *and* below it. Not the whole interaction band — just the
    /// strip itself, so the picture does not butt up against the thumbnails.
    private static let clearance: CGFloat = FilmstripView.height

    // MARK: Tool bar metrics
    //
    // The picture is laid out against these numbers before the tool bar has ever been measured,
    // so they have to be stated rather than read. `work/verify_viewer_band.sh` checks the claim
    // from the outside: the air it measures above the picture is the distance to this height, and
    // the picture's own top edge comes from an independent pixel scan of a snapshot. If the button
    // style below changes, `buttonHeight` changes with it and the check fails loudly.
    /// 12pt label + 6pt padding top and bottom inside the capsule.
    private static let buttonHeight: CGFloat = 27
    /// Room under the row for the scrim to fade out, and for the right-hand end of the row to
    /// clear the window edge on a narrow display.
    private static let bottomPad: CGFloat = 26
    /// Air between the menu bar and the row.
    private static let topAir: CGFloat = 10

    private var chromeTopPad: CGFloat { menuBand + Self.topAir }

    /// The band the tool bar occupies, menu bar included, measured from the window's top edge.
    /// Handed to the stage so the picture is centred in what is left rather than in the window.
    private var chromeHeight: CGFloat { chromeTopPad + Self.buttonHeight + Self.bottomPad }

    /// What the arrow keys and the filmstrip page through. Not `store.visiblePhotos` directly:
    /// a picture opened from the Finder was never added to the library, so the session list has
    /// to be able to stand in — see `AppState.viewerPhotos`.
    private var list: [PhotoItem] { app.viewerPhotos }

    /// True while showing pictures handed over by the Finder. Nothing on screen has a row in
    /// the library, so the controls that write to it have to go away rather than silently
    /// do nothing.
    private var isSession: Bool { app.isViewerSession }

    private var index: Int {
        guard let id = app.viewerID else { return 0 }
        return list.firstIndex { $0.id == id } ?? 0
    }

    private var photo: PhotoItem? { app.viewedPhoto }

    var body: some View {
        ZStack {
            FrostedBackdrop(photo: photo)

            ViewerStage(photo: photo,
                        sourceSize: ViewerStage.displaySize(for: photo),
                        topBand: chromeHeight,
                        clearance: Self.clearance,
                        // The zoom read-out rides the tool bar's row. It used to sit at a flat 18
                        // points when the chrome was hidden, which put it under the menu bar too.
                        chromeInset: chromeTopPad + 6,
                        zoomRequest: zoomRequest,
                        onToggleChrome: { toggleChrome() },
                        onClose: { close() })

            if chromeVisible {
                VStack {
                    topChrome
                    Spacer()
                    bottomChrome
                }
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        // Moving the mouse anywhere over the viewer brings the chrome back. Without this the
        // only way to un-hide it was a click on the photo, because the hover trigger used to
        // live on `topChrome` itself — a view that no longer exists once it is hidden.
        .onContinuousHover { phase in
            if case .active = phase, !chromeVisible { showChrome() }
        }
        .background(WindowAccessor { w in configureViewerWindow(w) })
        .focusable()
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.upArrow) { step(-1); return .handled }
        .onKeyPress(.downArrow) { step(1); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(.space) { app.startSlideshow(); return .handled }
        .onKeyPress(keys: [.init("+"), .init("=")]) { _ in sendZoom(.zoomIn); return .handled }
        .onKeyPress(keys: [.init("-")]) { _ in sendZoom(.zoomOut); return .handled }
        .onKeyPress(keys: [.init("0")]) { _ in sendZoom(.reset); return .handled }
        .onKeyPress(keys: [.init("i")]) { _ in app.infoPaneVisible.toggle(); return .handled }
        .onAppear {
            chromeVisible = true               // every open starts with the filmstrip up
            scheduleHide()
            // `menuBand` and the bar's own paddings are reported together so the one thing that
            // cannot be measured from a snapshot — whether the row clears the menu bar — has a
            // number attached to it. Asserted by `work/verify_viewer_band.sh`.
            PicnidoAppDelegate.report("""
            viewer onAppear chromeVisible=\(chromeVisible) photos=\(list.count) \
            stripHeight=\(FilmstripView.height) menuBand=\(menuBand) \
            chromeTopPad=\(chromeTopPad) chromeHeight=\(chromeHeight)
            """)
        }
        .onDisappear {
            NSApp.presentationOptions = []
        }
    }

    private func sendZoom(_ kind: ZoomRequest.Kind) {
        zoomSeq += 1
        zoomRequest = ZoomRequest(seq: zoomSeq, kind: kind)
    }

    // MARK: - Window

    /// Finishing touches on the panel `ViewerHost` built.
    ///
    /// The frame, the borderless style mask, the level and the behind-window glass are all
    /// settled before this view ever exists — see `ViewerHost`. This only re-asserts the
    /// menu-bar/Dock auto-hide (which has to land after the window is on screen) and keeps
    /// the window key so the keyboard shortcuts reach SwiftUI.
    private func configureViewerWindow(_ w: NSWindow) {
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        // A translucent window has nothing to show through if the desktop is hidden behind
        // a full-screen Space, so the viewer deliberately covers the screen instead of
        // using `toggleFullScreen`. Auto-hiding both chrome strips makes it reach the edges.
        NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
        ViewerHost.shared.refit()
        w.makeKeyAndOrderFront(nil)
    }

    // MARK: - Chrome

    private var topChrome: some View {
        HStack(spacing: 10) {
            // "Back to Library" is a lie when the picture came from the Finder: there is no
            // library entry behind it to go back to, so the button closes instead.
            Button { close() } label: {
                Label(localizedString(isSession ? "Close" : "Back to Library"),
                      systemImage: isSession ? "xmark" : "chevron.left")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(GlassButtonStyle())

            if let photo {
                Text(photo.caption.isEmpty ? photo.fileName : photo.caption)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Text("\(index + 1) / \(list.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer()

            if let photo {
                // Everything here writes to the library. In a session the picture has no row to
                // write to, so the buttons are absent rather than present-and-inert.
                if !isSession {
                    Button { app.store.toggleStar(photo.id) } label: {
                        Image(systemName: photo.starred ? "star.fill" : "star")
                            .foregroundStyle(photo.starred ? .yellow : .white)
                    }
                    .buttonStyle(GlassButtonStyle())
                    .help("Star (⌘⇧8)")

                    Button { app.store.push(photo.id, .rotate(quarterTurns: -1)) } label: {
                        Image(systemName: "rotate.left")
                    }
                    .buttonStyle(GlassButtonStyle())

                    Button { app.store.push(photo.id, .rotate(quarterTurns: 1)) } label: {
                        Image(systemName: "rotate.right")
                    }
                    .buttonStyle(GlassButtonStyle())

                    Button { app.startEditing(photo.id); close() } label: {
                        Label("Edit", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(GlassButtonStyle())

                    Button { app.startSlideshow() } label: {
                        Label("Slideshow", systemImage: "play.fill")
                    }
                    .buttonStyle(GlassButtonStyle())
                }

                Menu {
                    if isSession {
                        // Both of these act on the file itself, which is all a session has.
                        Button("Open in External Editor") { app.openInExternalEditor(photo.url) }
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([photo.url]) }
                    } else {
                        Button("Export…") { app.showExport = true }
                        Button("Export as HTML Gallery…") { app.showGalleryExport = true }
                        Button("Print…") { app.showPrint = true }
                        Button("Email…") { EmailComposer.compose(photos: [photo], app: app) }
                        Divider()
                        Button("Collage…") { app.showCollage = true }
                        Button("Movie…") { app.showMovie = true }
                        Divider()
                        Button("Open in External Editor") { app.openInExternalEditor(photo.url) }
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([photo.url]) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 34)
                .buttonStyle(GlassButtonStyle())
            }
        }
        .padding(.horizontal, 18)
        // Clears the menu bar, which is composited over this window's top `menuBand` points.
        .padding(.top, chromeTopPad)
        .padding(.bottom, Self.bottomPad)
        .background(
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
        )
        .background(Color.green.opacity(Self.chromeDebugTint))
        .onContinuousHover { phase in
            if case .active = phase { showChrome() }
        }
    }

    /// Bottom band. The original pins a full-width filmstrip to the bottom edge and floats
    /// its control bar directly on top of it (`#controlbar (buttons) appear on top of
    /// filmstrip`), so the status line rides above the strip rather than replacing it.
    private var bottomChrome: some View {
        VStack(spacing: 0) {
            if let photo {
                HStack(spacing: 12) {
                    Text("\(photo.pixelWidth) × \(photo.pixelHeight)")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                    // "the glass" is the frosted backdrop around the photo, not a magnifier:
                    // tapping anywhere the photo is not dismisses the viewer. The old wording
                    // was the original app's own i18n key, and every non-English translator
                    // read "glass" as "magnifying glass" (zh 放大镜 / ja ルーペ / ko 돋보기),
                    // pointing users at an icon that has never existed in this app.
                    Text("Click outside the photo to close · scroll to zoom · drag to pan")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(.bottom, 8)
            }

            FilmstripView(photos: list, currentID: app.viewerID) { id in
                app.viewerID = id
            }
            .frame(height: FilmstripView.height)
        }
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
        )
        // PICNIDO_CHROME_DEBUG paints the band a flat colour. If a saturated block shows up in
        // a snapshot the band is being composited and any remaining problem is styling; if it
        // does not, the band never reaches the screen at all.
        .background(Color.red.opacity(Self.chromeDebugTint))
    }

    private static var chromeDebugTint: Double {
        ProcessInfo.processInfo.environment["PICNIDO_CHROME_DEBUG"] != nil ? 1 : 0
    }

    // MARK: Behaviour

    private func step(_ delta: Int) {
        let l = list
        guard !l.isEmpty else { return }
        let next = (index + delta + l.count) % l.count
        app.viewerID = l[next].id
    }

    private func close() {
        ViewerHost.shared.close()
        app.viewerID = nil
        // Drop the handed-over set, so a later open from the grid cannot end up paging through
        // the pictures the Finder handed us.
        app.endViewerSession()
    }

    // MARK: Auto-hiding chrome

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
        PicnidoAppDelegate.report("toggleChrome -> \(chromeVisible)")
        if chromeVisible { scheduleHide() }
    }

    private func showChrome() {
        if !chromeVisible {
            withAnimation(.easeInOut(duration: 0.15)) { chromeVisible = true }
            PicnidoAppDelegate.report("showChrome -> true")
        }
        scheduleHide()
    }

    private func scheduleHide() {
        // PICNIDO_CHROME_PIN keeps the chrome (and therefore the filmstrip) up so a scripted
        // snapshot can catch it; without it the chrome auto-hides like the original. Read through
        // `DevHook` for the same reason `PICNIDO_SNAPSHOT` is: the run that most needs pinning is
        // the one LaunchServices started (a real double-click), and that one cannot be given an
        // environment variable.
        if DevHook.isSet("PICNIDO_CHROME_PIN") {
            PicnidoAppDelegate.report("chrome pinned by PICNIDO_CHROME_PIN")
            return
        }
        hideWorkItem?.cancel()
        let item = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.35)) { chromeVisible = false }
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: item)
    }
}

// MARK: - Stage

/// Everything that moves: the picture, the gestures, the zoom read-out.
///
/// This is a separate view on purpose. Zoom and pan used to live on `ViewerWindow` itself, so
/// every frame of a drag re-evaluated the viewer's whole body — including a filmstrip holding one
/// cell per photo in the library. With five hundred photos in the folder that is a thousand views
/// (each cell draws itself twice, once for the tile and once for its reflection) re-diffed sixty
/// times a second, and that, not the GPU, is what made panning "卡到很夸张".
///
/// It also owns the loading strategy: a cheap bitmap first, a sharper one once the user stops
/// moving, and a sharper one again whenever the zoom level outgrows what is on screen.
struct ViewerStage: View {

    let photo: PhotoItem?
    /// True pixel size of the original, orientation applied. Available immediately from the
    /// catalogue, so the geometry — and therefore the hit testing — is correct from the first
    /// frame instead of waiting for a decode to finish.
    let sourceSize: CGSize
    /// Height of the tool bar band at the top of the window, menu bar included.
    let topBand: CGFloat
    let clearance: CGFloat
    let chromeInset: CGFloat
    let zoomRequest: ZoomRequest?
    let onToggleChrome: () -> Void
    let onClose: () -> Void

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    /// The sharp layer on screen, what part of the photo it covers, and how sharp it is.
    @State private var bitmap: CGImage?
    @State private var tileRect: CGRect = ViewerStage.fullRect
    @State private var tileSharpness: CGFloat = 0
    /// The whole picture, at whatever resolution was last produced for it, kept underneath the
    /// sharp layer.
    ///
    /// Once the photo is larger than the window the sharp layer is only a *crop* — the visible
    /// region plus a margin. That is what makes panning cheap, but it means the moment a drag
    /// outruns the margin there would be nothing to draw at the trailing edge and the picture
    /// would tear open onto bare glass. A cheap full-picture plate underneath fixes that: the
    /// drag always slides *something* real, and the sharp crop lands on top of it a tenth of a
    /// second later. It is the same trick a map uses with its low-zoom tiles.
    @State private var base: CGImage?
    @State private var viewport: CGSize = .zero

    @State private var readout: Int?
    @State private var readoutToken = 0
    @State private var detailTask: Task<Void, Never>?
    /// Separate from `detailTask`: the plate is a fallback that must survive the sharp layer
    /// being cancelled and re-requested on every wheel notch.
    @State private var plateTask: Task<Void, Never>?
    /// Counts tiles that actually made it onto the canvas. The pan benchmark reports the delta,
    /// because "the drag was smooth" is meaningless if no new tile was ever needed — and, more
    /// importantly, a drag that re-renders on every step is a drag that will not be smooth.
    @State private var tilesRendered = 0
    /// At most one tile render in flight, one target waiting. See `updateTile`.
    @State private var stillRendering = false
    @State private var queuedWant: DesiredTile?

    @State private var lastTapTime: Date = .distantPast
    @State private var lastTapPoint: CGPoint = .zero

    /// When this photo started loading, for the `PICNIDO_VIEWER_TIMING` report.
    @State private var openStamp = Date()

    /// Set while the photo on screen is an animation being fed by the hub.
    ///
    /// The viewer subscribes at `.focused`, which means it does not compete with the grid for the
    /// frame budget: the picture the user asked to see at full size is not something to ration.
    @State private var animation: AnimationHub.Token?

    /// Spinner -> picture, and picture -> sharp picture, in milliseconds.
    private static var timingEnabled: Bool {
        ProcessInfo.processInfo.environment["PICNIDO_VIEWER_TIMING"] != nil
    }

    static let fullRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Margin rendered around the visible area so a drag does not immediately need a new tile.
    private static let overscan: CGFloat = 0.30
    /// Ceiling for a whole-picture bitmap. Beyond the window's own device size there is nothing
    /// to show, and a 6144-pixel request on a 24-megapixel frame measured over seven seconds.
    private static let maxPackedPixels = 4096
    /// How much of the picture must be on screen before one cached whole-picture render beats
    /// re-cropping the visible part on every pan step.
    private static let wholePictureCoverage: CGFloat = 0.5

    private static let minZoom: CGFloat = 0.2
    /// Hard ceiling on the *actual* pixel ratio, in multiples of the original. The old view
    /// allowed eight times the fit size, which on a 24-megapixel frame is roughly 700% of the
    /// original — past the point where any more magnification shows anything but interpolation.
    private static let maxActualRatio: CGFloat = 8

    // MARK: Geometry

    /// The photo's true pixel size, upright. EXIF orientations 5–8 are the quarter turns, so the
    /// stored width and height are the other way round from what the user sees.
    ///
    /// An animation answers from its container instead, because that is the only size that
    /// describes what is about to be drawn: a frame is composited into the file's canvas, and
    /// every frame is that size no matter what any individual frame's own header says. Getting
    /// this wrong would not be a cosmetic error — the whole zoom and hit-testing geometry is
    /// derived from it.
    static func displaySize(for photo: PhotoItem?) -> CGSize {
        guard let photo else { return .zero }
        if let info = AnimationProbe.info(for: photo.url), info.isAnimated {
            return info.canvas
        }
        guard photo.pixelWidth > 0, photo.pixelHeight > 0 else { return .zero }
        var w = CGFloat(photo.pixelWidth)
        var h = CGFloat(photo.pixelHeight)
        if photo.exifOrientation >= 5 { swap(&w, &h) }
        return CGSize(width: w, height: h)
    }

    private var baseSize: CGSize {
        ViewerGeometry.baseSize(image: sourceSize, viewport: viewport,
                               topBand: topBand, clearance: clearance)
    }

    private var maxZoom: CGFloat {
        guard sourceSize.width > 0, viewport.width > 1 else { return 8 }
        let base = baseSize
        guard base.width > 0 else { return 8 }
        let fitRatio = base.width / sourceSize.width       // displayed point per source pixel at zoom 1
        return max(1, Self.maxActualRatio / fitRatio)
    }

    /// **The zoom percentage the user actually asked about.**
    ///
    /// It is the ratio of displayed pixels to *original* pixels — so 100% means one image pixel
    /// per one device pixel, which is what "actual size" means everywhere else. The old read-out
    /// printed the zoom factor relative to the *fit* size; a 6000-pixel-wide photo shrunk to fit a
    /// 2560-point window therefore read "100%" while showing 30% of the pixels, and only said
    /// "330%" once it really was one-to-one. That is exactly the 300–400% the report described.
    private var percent: Int {
        guard sourceSize.width > 0, viewport.width > 1 else { return Int((zoom * 100).rounded()) }
        let base = baseSize
        guard base.width > 0 else { return 0 }
        return Int(((base.width * zoom) / sourceSize.width * 100).rounded())
    }

    private var backingScale: CGFloat { NSScreen.main?.backingScaleFactor ?? 2 }

    /// Device pixels per source pixel the screen is currently showing. 1.0 means every pixel of
    /// the original has at least one of its own on screen; above that there is nothing more to
    /// resolve.
    private var requiredSharpness: CGFloat {
        guard sourceSize.width > 0 else { return 0 }
        let base = baseSize
        return min(1, base.width * zoom * backingScale / sourceSize.width)
    }

    private func photoRect(viewport size: CGSize) -> CGRect {
        guard sourceSize.width > 0 else { return .zero }
        return ViewerGeometry.photoRect(image: sourceSize, viewport: size,
                                        topBand: topBand, clearance: clearance,
                                        zoom: zoom, pan: pan)
    }

    /// What the screen actually needs right now.
    ///
    /// Either the whole picture (when it fits), or — once it is bigger than the window — just the
    /// visible region plus a margin. The second case is the one that used to cost seconds.
    private struct DesiredTile {
        /// What to render: the area that must be on screen, plus a margin.
        let rect: CGRect
        /// What must be on screen, in the same unit coordinates. Coverage is judged against
        /// this rather than against `rect`, because the margin only earns its keep if it is
        /// allowed to be slack — see `currentTileSuffices`.
        let visible: CGRect
        let pixels: Int
        let packed: Bool
        let sharpness: CGFloat
    }

    private func desiredTile() -> DesiredTile? {
        guard sourceSize.width > 0, viewport.width > 1, viewport.height > 1 else { return nil }
        let full = photoRect(viewport: viewport)
        guard full.width > 4, full.height > 4 else { return nil }

        let visible = full.intersection(CGRect(origin: .zero, size: viewport))
        guard !visible.isNull, visible.width > 8, visible.height > 8 else { return nil }

        let nativeLongest = max(sourceSize.width, sourceSize.height)
        let padded = visible.insetBy(dx: -visible.width * Self.overscan,
                                     dy: -visible.height * Self.overscan)
        let region = padded.intersection(full)

        func unitized(_ rect: CGRect) -> CGRect {
            CGRect(x: (rect.minX - full.minX) / full.width,
                   y: (rect.minY - full.minY) / full.height,
                   width: rect.width / full.width,
                   height: rect.height / full.height)
        }
        let regionUnit = unitized(region)
        let visibleUnit = unitized(visible)

        // Most of the picture is on screen. Take it in one piece, even though it no longer
        // *fits*: a single whole-picture render is produced once and then survives every pan
        // step untouched, whereas a crop has to be re-rendered whenever the view moves. The
        // request is also served by the thumbnail path, which downsamples during decode,
        // instead of the crop path's decode-at-1:1-then-scale.
        //
        // `regionShare` catches the awkward middle: at roughly 200% the padded region has grown
        // to cover the whole file, so a "crop" would be a full-resolution twenty-four-megapixel
        // render of the entire picture — more expensive than the downsampling path, and not
        // cacheable. Once the crop is the whole picture, it is no longer a crop.
        let coverage = (visible.width * visible.height) / max(1, full.width * full.height)
        let regionShare = regionUnit.width * regionUnit.height
        if coverage >= Self.wholePictureCoverage || regionShare >= 0.9 {
            let wanted = Int((max(full.width, full.height) * backingScale).rounded(.up))
            // Never ask the decoder to invent pixels the file does not have: for a 2000-pixel
            // original on a Retina screen the old formula requested a 4096-pixel decode, which
            // is four times the pixels and none of the detail.
            let ceiling = max(512, min(Self.maxPackedPixels, Int(nativeLongest.rounded(.up))))
            let pixels = ThumbBuckets.snap(min(max(512, wanted), ceiling))
            return DesiredTile(rect: Self.fullRect, visible: Self.fullRect, pixels: pixels,
                               packed: true,
                               sharpness: min(1, CGFloat(pixels) / max(1, nativeLongest)))
        }

        let regionNative = max(regionUnit.width * sourceSize.width,
                               regionUnit.height * sourceSize.height)
        let wantedPixels = Int((max(region.width, region.height) * backingScale).rounded(.up))
        let pixels = max(256, min(wantedPixels, Int(regionNative.rounded(.up))))
        return DesiredTile(rect: regionUnit, visible: visibleUnit, pixels: pixels, packed: false,
                           sharpness: min(1, CGFloat(pixels) / max(1, regionNative)))
    }

    /// True when the bitmap already on screen covers what the user needs to see and is at least
    /// as sharp as anything we could produce for it.
    ///
    /// Coverage is measured against `want.visible`, not against `want.rect`. The margin in
    /// `rect` is the *slack* that lets a drag continue without another render, and comparing
    /// target against target throws it away: the new target is always the same size as the old
    /// one, so the smallest movement would invalidate it. That is not hypothetical — with the
    /// comparison the wrong way round a two-second drag re-decoded fifty-two times; with it the
    /// right way round the same drag re-decodes once or twice.
    ///
    /// Likewise the sharpness comparison is against `want.sharpness` rather than the screen's
    /// requirement: the want is already capped by the source and by the whole-picture ceiling,
    /// so demanding the unattainable "1.0 or better" would leave a capped render permanently
    /// judged insufficient and re-render it for ever.
    private func currentTileSuffices(_ want: DesiredTile) -> Bool {
        guard bitmap != nil else { return false }
        let covered = tileRect.contains(want.visible.insetBy(dx: -0.004, dy: -0.004))
        return covered && tileSharpness >= want.sharpness * 0.92
    }

    // MARK: Body

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                // Two layers, bottom first. The plate always spans the whole picture; the sharp
                // layer is drawn only when it covers less than that, so at or below the resting
                // size there is still exactly one image on screen and the layout is unchanged.
                if tileRect != Self.fullRect, let base {
                    ZoomCanvasView(image: base, sourceSize: sourceSize,
                                   tileRect: Self.fullRect,
                                   zoom: zoom, pan: pan,
                                   topBand: topBand, clearance: clearance)
                        .allowsHitTesting(false)
                }
                ZoomCanvasView(image: bitmap, sourceSize: sourceSize, tileRect: tileRect,
                               zoom: zoom, pan: pan,
                               topBand: topBand, clearance: clearance)
                    .allowsHitTesting(false)

                if bitmap == nil && base == nil {
                    ProgressView().controlSize(.large)
                }

                interactionSurface(size: size)

                if let readout {
                    zoomBadge(readout)
                }
            }
            .frame(width: size.width, height: size.height)
            .onAppear { viewport = size; reportGeometry(size) }
            .onChange(of: size) { _, newValue in
                viewport = newValue
                reportGeometry(newValue)
                updateTile()
            }
        }
        .task(id: photo?.id) { await loadPhoto() }
        .onChange(of: photo?.id) { _, _ in resetZoom() }
        .onChange(of: zoom) { _, _ in updateTile() }
        // No debounce while dragging: a timer that restarts on every mouse move never fires.
        .onChange(of: pan) { _, _ in updateTile(debounce: false) }
        .onChange(of: zoomRequest) { _, newValue in
            guard let newValue else { return }
            apply(newValue.kind)
        }
        .onAppear {
            installScrollMonitor()
            if ProcessInfo.processInfo.environment["PICNIDO_ZOOM_TEST"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { runZoomSelfTest() }
            }
            // PICNIDO_DRAG_TEST=1 — checks the one invariant a drag has to satisfy: the point
            // that was under the cursor when the button went down stays under the cursor.
            if ProcessInfo.processInfo.environment["PICNIDO_DRAG_TEST"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 7.5) { runDragSelfTest() }
            }
            // PICNIDO_ZOOM_AT=<percent> — sit at a given *true-pixel* zoom, so a screenshot can be
            // taken of the read-out at a number that means something (100% = one image pixel per
            // device pixel). The percentage the read-out shows is what is asked for here.
            if let raw = ProcessInfo.processInfo.environment["PICNIDO_ZOOM_AT"], let want = Double(raw) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    let base = baseSize
                    guard sourceSize.width > 0, base.width > 0 else { return }
                    let target = min(max(CGFloat(want) / 100 * sourceSize.width / base.width,
                                         Self.minZoom), maxZoom)
                    zoom = target
                    committedZoom = target
                    pan = .zero
                    flashReadout()
                    updateTile(force: true, debounce: false)
                }
            }
            if ProcessInfo.processInfo.environment["PICNIDO_PAN_BENCH"] != nil {
                // Kept short so the measurement finishes before anything else on the machine
                // disturbs it — and so the window is still definitely on screen.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { runPanBenchmark() }
            }
        }
        .onDisappear {
            removeScrollMonitor()
            detailTask?.cancel()
            animation?.cancel()
            animation = nil
        }
    }

    // MARK: - Interaction surface

    /// One transparent sheet that owns every mouse gesture. The photo canvas below refuses
    /// hit-testing entirely, so taps land here and we decide — by geometry — whether the
    /// pointer is on the picture or on the frosted glass around it.
    private func interactionSurface(size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        // The pan is accumulated *from where the drag started*, not taken as the
                        // gesture's own translation.
                        //
                        // `value.translation` is measured from the mouse-down point, not from the
                        // picture's current position. Assigning it straight to `pan` therefore
                        // threw away whatever the picture had already been panned to: the moment
                        // the mouse moved, the photo snapped back to centred (the jump the user
                        // reported), and from then on it tracked the cursor while the point that
                        // was actually grabbed sat somewhere else — off by exactly the discarded
                        // pan. Zooming in with the wheel anchors on the cursor and leaves a
                        // non-zero pan, so the offset showed up every time, on every picture.
                        if panAtDragStart == nil { panAtDragStart = pan }
                        pan = panned(from: panAtDragStart ?? .zero,
                                     by: value.translation, viewport: size)
                    }
                    .onEnded { _ in
                        pan = clampPan(pan, viewport: size)
                        panAtDragStart = nil
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        zoom = min(max(committedZoom * value, Self.minZoom), maxZoom)
                        flashReadout()
                    }
                    .onEnded { _ in
                        committedZoom = zoom
                        updateTile()
                    }
            )
            .onTapGesture(coordinateSpace: .local) { location in
                handleTap(at: location, in: size)
            }
    }

    @State private var committedZoom: CGFloat = 1
    /// The pan as it stood when the current drag began. See `interactionSurface`.
    @State private var panAtDragStart: CGSize?

    /// One tap handler for everything, so no gesture has to wait for another.
    ///
    /// The previous version registered both `.onTapGesture(count: 2)` and a plain tap, and
    /// SwiftUI cannot tell a single click from the first half of a double click until the
    /// double-click window expires — so dismissing the viewer by clicking the frosted glass
    /// felt like it had a built-in pause. Double clicks are recognised by hand here instead,
    /// which lets the two actions stay different without either one waiting.
    private func handleTap(at point: CGPoint, in size: CGSize) {
        // Anywhere on the frosted glass dismisses, immediately. No double-click to wait for
        // out here, so there is nothing to disambiguate.
        guard photoRect(viewport: size).contains(point) else {
            lastTapTime = .distantPast
            onClose()
            return
        }

        let now = Date()
        let quick = now.timeIntervalSince(lastTapTime) < 0.32
        let near = hypot(point.x - lastTapPoint.x, point.y - lastTapPoint.y) < 14
        if quick && near {
            lastTapTime = .distantPast
            toggleZoom()
            return
        }
        lastTapTime = now
        lastTapPoint = point
        onToggleChrome()
    }

    // MARK: - Loading

    /// Progressive load.
    ///
    /// Step one is a 1024-pixel bitmap out of the shared cache — which, for anything the grid has
    /// already touched, is a file read rather than a decode — so the picture appears at once
    /// instead of leaving a spinner over black. Step two is the tile the screen actually needs.
    private func loadPhoto() async {
        detailTask?.cancel()
        plateTask?.cancel()
        plateTask = nil
        // The previous file must stop feeding this stage. Without this, stepping through a
        // folder of animations leaves one decoder per photo visited running into a view that is
        // showing something else, and the frames of the old file land on the new one.
        animation?.cancel()
        animation = nil
        guard let photo else {
            bitmap = nil; base = nil; tileRect = Self.fullRect; tileSharpness = 0
            stillRendering = false; queuedWant = nil
            return
        }
        let pid = photo.id
        bitmap = nil
        base = nil
        tileRect = Self.fullRect
        tileSharpness = 0
        stillRendering = false
        queuedWant = nil
        openStamp = Date()

        let p = photo
        let quick: CGImage? = await withCheckedContinuation { continuation in
            ImageEngine.shared.thumbnail(for: p, displaySize: 1024, priority: .visible) { img in
                continuation.resume(returning: img)
            }
        }
        guard self.photo?.id == pid else { return }
        if let quick {
            bitmap = quick
            base = quick
            tileRect = Self.fullRect
            tileSharpness = min(1, CGFloat(max(quick.width, quick.height))
                                   / max(1, max(sourceSize.width, sourceSize.height)))
            if Self.timingEnabled {
                PicnidoAppDelegate.report(String(format: "[viewer] first paint %.0f ms (%dpx placeholder)",
                                                Date().timeIntervalSince(openStamp) * 1000, quick.width))
            }
        }

        // An animation is played, not tiled.
        //
        // The tile machinery exists to avoid rasterising twenty-four megapixels when a windowful
        // will do. An animation has the opposite shape: its frames arrive already composited at
        // the canvas size, it costs nothing extra to draw one whole, and every re-render of a
        // crop would be a frame's worth of latency spent on a picture that is about to change
        // anyway. So the stage hands the whole surface to the hub and keeps its zoom and pan.
        if let token = AnimationHub.shared.subscribe(photo, priority: .focused, onFrame: { frame in
            bitmap = frame
            base = frame
            tileRect = Self.fullRect
            tileSharpness = 1
        }) {
            animation = token
            if Self.timingEnabled {
                PicnidoAppDelegate.report("[viewer] \(p.fileName) is animated -> playback path")
            }
            return
        }

        updateTile(force: true)
    }

    /// Renders the tile the screen needs — usually the visible region with a margin — and swaps
    /// it in.
    ///
    /// **Zoom debounces, panning does not.** A wheel or pinch gesture produces a stream of zoom
    /// values of which only the last is worth rendering, so that path waits 90 ms for the
    /// movement to stop. A *drag* must not: the old code restarted the same 90 ms timer on every
    /// pan change, which meant that as long as the user kept moving, the timer never expired and
    /// the sharper tile never arrived at all — a long drag stayed on the low-resolution plate
    /// from start to finish, magnified. That is the case the log showed: the crop landed at
    /// 4608 ms, just after a drag that ran from 2500 ms to 4420 ms.
    ///
    /// Panning therefore renders at once, and simply keeps at most one render in flight — a
    /// newer target replaces an older queued one rather than queueing behind it, because by the
    /// time the older one came out it would already be stale.
    private func updateTile(force: Bool = false, debounce: Bool = true) {
        guard let photo, let want = desiredTile() else { return }
        if !force, currentTileSuffices(want) { return }

        if stillRendering {
            queuedWant = want
            return
        }

        stillRendering = true
        let pid = photo.id
        let p = photo
        detailTask = Task { @MainActor in
            if debounce {
                try? await Task.sleep(nanoseconds: 90_000_000)
                guard !Task.isCancelled else { stillRendering = false; return }
            }

            let started = Date()
            let wantRect = want.rect
            let wantPixels = want.pixels
            let packed = want.packed
            let result: CGImage? = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let img: CGImage?
                    if packed {
                        // The whole picture, straight out of the memory cache when it is warm.
                        img = ThumbnailCache.shared.imageNow(photo: p, pixels: wantPixels,
                                                             transform: ImageEngine.shared.editTransform(for: p))
                    } else {
                        img = ImageEngine.shared.viewerTile(for: p, unitRect: wantRect,
                                                            maxPixels: wantPixels)
                    }
                    continuation.resume(returning: img)
                }
            }
            stillRendering = false
            guard self.photo?.id == pid else { return }
            if let result {
                bitmap = result
                tileRect = wantRect
                tileSharpness = want.sharpness
                tilesRendered += 1
                // A whole-picture render is also the best plate we have, so it replaces the
                // placeholder one. A crop never does — it covers a fraction of the picture and
                // would leave the rest of the plate blank exactly when it is needed.
                if packed { base = result }
                if Self.timingEnabled {
                    PicnidoAppDelegate.report(String(format: "[viewer] tile %@ %dx%d in %.0f ms (%.0f ms after open)",
                                                    packed ? "whole" : "crop",
                                                    result.width, result.height,
                                                    Date().timeIntervalSince(started) * 1000,
                                                    Date().timeIntervalSince(openStamp) * 1000))
                }
            }

            // Something was wanted while we were busy. Drain it now instead of dropping it —
            // the drag has moved on since, so the request has to be re-derived anyway.
            if queuedWant != nil {
                queuedWant = nil
                updateTile(force: false, debounce: false)
            }
        }

        // Cropped and nothing underneath: go and get a plate. This only happens when the 1024
        // placeholder failed to decode, and it is cheap — that size is on disk for anything the
        // grid has already drawn.
        if !want.packed, base == nil, plateTask == nil {
            let p2 = photo
            plateTask = Task { @MainActor in
                let img: CGImage? = await withCheckedContinuation { continuation in
                    ThumbnailCache.shared.request(photo: p2, pixels: 1024, priority: .visible) { img in
                        continuation.resume(returning: img)
                    }
                }
                plateTask = nil
                guard self.photo?.id == p2.id, let img, base == nil else { return }
                base = img
            }
        }
    }

    // MARK: - Pan benchmark

    /// CPU time this process has burned since it started.
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// `PICNIDO_PAN_BENCH=<frames>` — drives a real drag through the run loop and reports how many
    /// frames actually got rendered.
    ///
    /// The old complaint was that dragging a zoomed photo "卡到很夸张". Measuring that by feel is
    /// useless, so: zoom in first (so the drag has something to move), then schedule one pan step
    /// per run-loop turn at a 125 Hz cadence, and count the frames the canvas produced. A healthy
    /// result is close to the requested cadence with a mean lateness well under one 60 Hz frame
    /// (16.7 ms). Lateness is measured as `actual - scheduled`, so a saturated main thread shows
    /// up immediately.
    private func runPanBenchmark() {
        let env = ProcessInfo.processInfo.environment
        guard let frames = Int(env["PICNIDO_PAN_BENCH"] ?? ""), frames > 0 else { return }

        // Bring the viewer forward first. macOS suspends the display updates of a window that is
        // not being composited, and a suspended window renders *zero* frames no matter how fast
        // the code is — which reads exactly like a performance catastrophe in the report. Making
        // that state visible in the output is the only way to tell the two apart.
        NSApp.activate(ignoringOtherApps: true)
        ViewerHost.shared.nsWindow?.makeKeyAndOrderFront(nil)

        // Zoom in — a drag is only meaningful once the picture is bigger than the window.
        let fit = sourceSize.width / max(1, baseSize.width)
        zoom = min(max(2.5, fit * 1.6), maxZoom)
        committedZoom = zoom
        pan = .zero

        let interval = 0.008          // 125 Hz, deliberately faster than any real display
        let start = Date()
        var late: [Double] = []
        late.reserveCapacity(frames)
        _ = FrameCounter.shared.take()
        let tilesAtStart = tilesRendered
        let cpuAtStart = Self.cpuSeconds()

        for i in 0..<frames {
            let scheduled = interval * Double(i)
            DispatchQueue.main.asyncAfter(deadline: .now() + scheduled) { [self] in
                let actual = Date().timeIntervalSince(start)
                late.append(max(0, actual - scheduled) * 1000)
                let f = Double(i) / Double(max(1, frames - 1))
                pan = CGSize(width: -420 + 840 * f, height: -260 + 520 * f)
                flashReadout()
                if i == frames - 1 {
                    let elapsed = Date().timeIntervalSince(start)
                    let rendered = FrameCounter.shared.take()
                    let mean = late.reduce(0, +) / Double(late.count)
                    let worst = late.max() ?? 0
                    let sorted = late.sorted()
                    let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
                    let window = ViewerHost.shared.nsWindow
                    let occluded = window.map { ($0.occlusionState.rawValue & NSWindow.OcclusionState.visible.rawValue) == 0 } ?? true
                    // CPU time is the one number here that load cannot flatter or ruin: frame
                    // counts and lateness both measure how much of the machine this run got, and
                    // on a busy desk that is mostly noise. Work done is not.
                    let cpuMs = (Self.cpuSeconds() - cpuAtStart) * 1000
                    PicnidoAppDelegate.report(String(format: """
                    --- pan benchmark ---
                    requested   %d pan steps at %.1f ms (%.0f Hz)
                    elapsed     %.2f s
                    rendered    %d frames  -> %.1f fps
                    lateness    mean %.2f ms  p95 %.2f ms  max %.2f ms
                    re-decodes  %d tiles rendered during the drag
                    cpu         %.0f ms total  ->  %.3f ms per pan step  (%.0f%% of one core)
                    zoom        %.1f%%  tileSharpness %.2f  source %dx%d
                    env         appActive=%@ windowVisible=%@ occluded=%@
                    --- end benchmark ---
                    """, frames, interval * 1000, 1 / interval, elapsed, rendered,
                         Double(rendered) / elapsed, mean, p95, worst,
                         tilesRendered - tilesAtStart,
                         cpuMs, cpuMs / Double(frames),
                         cpuMs / (elapsed * 1000) * 100,
                         Double(percent), Double(tileSharpness),
                         Int(sourceSize.width), Int(sourceSize.height),
                         NSApp.isActive ? "yes" : "NO",
                         (window?.isVisible ?? false) ? "yes" : "NO",
                         occluded ? "YES" : "no"))
                }
            }
        }
    }

    /// Debug hook (PICNIDO_GEOM_REPORT). Prints the numbers that decide where the photo and
    /// the filmstrip band actually land — used to tell a layout bug from a compositing one.
    ///
    /// `airTop` / `airBottom` are the pair that matters, and they are not `topGap` / `bottomGap`.
    /// The gaps measure to the *window* edges; the air measures to the *chrome*. Two equal gaps
    /// with a 114-point strip and a 67-point bar means 47 points of glass above the picture and
    /// none below — which is what this report was printing while the picture visibly sat on the
    /// filmstrip. The air is what `work/verify_viewer_band.sh` asserts on.
    private func reportGeometry(_ size: CGSize) {
        guard ProcessInfo.processInfo.environment["PICNIDO_GEOM_REPORT"] != nil else { return }
        let base = ViewerGeometry.baseSize(image: sourceSize, viewport: size,
                                           topBand: topBand, clearance: clearance)
        let rect = ViewerGeometry.photoRect(image: sourceSize, viewport: size,
                                            topBand: topBand, clearance: clearance,
                                            zoom: zoom, pan: pan)
        let topGap = rect.minY
        let bottomGap = size.height - rect.maxY
        let airTop = rect.minY - topBand
        let airBottom = (size.height - clearance) - rect.maxY
        PicnidoAppDelegate.report("""
        --- viewer geometry ---
        viewport=\(size)
        source=\(Int(sourceSize.width))x\(Int(sourceSize.height)) tileRect=\(tileRect) tileSharpness=\(String(format: "%.3f", tileSharpness)) required=\(String(format: "%.3f", requiredSharpness))
        base=\(base) fillRatio=\(ViewerGeometry.fillRatio) boundBy=\(base.width >= size.width * ViewerGeometry.fillRatio - 0.5 ? "width" : "height")
        zoom=\(String(format: "%.3f", zoom)) percent=\(percent)% pan=\(pan)
        photoRect=\(rect)
        topGap=\(String(format: "%.1f", topGap)) bottomGap=\(String(format: "%.1f", bottomGap)) symmetric=\(abs(topGap - bottomGap) < 1)
        topBand=\(String(format: "%.1f", topBand)) airTop=\(String(format: "%.1f", airTop)) airBottom=\(String(format: "%.1f", airBottom)) airSymmetric=\(abs(airTop - airBottom) < 1) breath=\(ViewerGeometry.breath)
        filmstripZone=\(FilmstripView.interactionZone) clearance=\(clearance) stripHeight=\(FilmstripView.height)
        """)
    }

    // MARK: - Zoom read-out

    /// Just the number, top-left — no pill, no material, no border.
    private func zoomBadge(_ value: Int) -> some View {
        VStack {
            HStack(alignment: .top) {
                Text("\(value)%")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 5, y: 1)
                Spacer()
            }
            .padding(.leading, 22)
            .padding(.top, chromeInset)
            Spacer()
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    /// Shows the current percentage and arms a fade-out. Each call invalidates the previous
    /// timer so a long scroll keeps the read-out up and the *last* stop is what hides it.
    private func flashReadout() {
        readoutToken += 1
        let token = readoutToken
        readout = percent
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            guard token == readoutToken else { return }
            withAnimation(.easeOut(duration: 0.32)) { readout = nil }
        }
    }

    // MARK: - Mouse wheel / two-finger scroll zoom

    private func installScrollMonitor() {
        // The monitor itself belongs to `ViewerHost` (see the note on `scrollHandler`);
        // the view only lends it the gesture maths, and gets to take that back on close.
        ViewerHost.shared.scrollHandler = { event in
            handleScrollWheel(event)
            return true
        }
    }

    private func removeScrollMonitor() {
        ViewerHost.shared.scrollHandler = nil
    }

    /// Wheel zooms about the pointer, the same feel as the original viewer.
    private func handleScrollWheel(_ event: NSEvent) {
        guard sourceSize.width > 0, viewport.width > 1 else { return }
        let dy = event.scrollingDeltaY
        guard abs(dy) > 0.0001 else { return }

        // A trackpad reports fine-grained deltas; a notched wheel reports coarse ones.
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.006 : 0.055
        let factor = CGFloat(exp(Double(dy * sensitivity)))

        // Window coordinates are bottom-left; all our geometry is top-left.
        var point: CGPoint?
        if let content = event.window?.contentView {
            let p = content.convert(event.locationInWindow, from: nil)
            point = CGPoint(x: p.x, y: content.bounds.height - p.y)
        }
        applyZoom(factor, viewport: viewport, at: point)
    }

    /// factor > 1 zooms in. `point` is in top-left view coordinates; nil zooms about centre.
    private func applyZoom(_ factor: CGFloat, viewport size: CGSize, at point: CGPoint?) {
        let old = zoom
        let new = min(max(old * factor, Self.minZoom), maxZoom)
        guard abs(new - old) > 0.0001 else { return }

        var px: CGFloat = 0, py: CGFloat = 0
        if let point {
            px = point.x - size.width / 2
            py = point.y - size.height / 2
        }

        // Keep whatever sits under the cursor pinned in place while scaling.
        let ratio = new / old
        let anchored = CGSize(width: px - (px - pan.width) * ratio,
                              height: py - (py - pan.height) * ratio)

        zoom = new
        committedZoom = new
        pan = clampPan(anchored, viewport: size)
        flashReadout()
        picnidoZoomLog("factor=\(String(format: "%.4f", factor)) zoom=\(String(format: "%.1f", zoom)) percent=\(percent)% pan=(\(Int(pan.width)),\(Int(pan.height)))")
    }

    private var pct: String { "\(percent)%" }

    /// Debug hook (PICNIDO_ZOOM_TEST): drives the wheel maths and reports to PICNIDO_ZOOM_LOG.
    private func runZoomSelfTest() {
        let vp = viewport
        guard vp.width > 1 else { picnidoZoomLog("selftest: no viewport"); return }
        picnidoZoomLog("--- selftest begin viewport=\(Int(vp.width))x\(Int(vp.height)) source=\(Int(sourceSize.width))x\(Int(sourceSize.height)) tileRect=\(tileRect) tileSharpness=\(String(format: "%.3f", tileSharpness)) required=\(String(format: "%.3f", requiredSharpness)) ---")

        let anchor = CGPoint(x: vp.width * 0.7, y: vp.height * 0.35)
        let wheelUp = CGFloat(exp(3 * 0.055))
        let wheelDown = CGFloat(exp(-3 * 0.055))

        picnidoZoomLog("step1 base            zoom=\(pct) pan=(\(Int(pan.width)),\(Int(pan.height)))")
        applyZoom(wheelUp, viewport: vp, at: anchor)
        picnidoZoomLog("step2 wheel up x1     zoom=\(pct) pan=(\(Int(pan.width)),\(Int(pan.height)))")
        applyZoom(wheelUp, viewport: vp, at: anchor)
        picnidoZoomLog("step3 wheel up x2     zoom=\(pct) pan=(\(Int(pan.width)),\(Int(pan.height)))")
        applyZoom(wheelDown, viewport: vp, at: anchor)
        applyZoom(wheelDown, viewport: vp, at: anchor)
        picnidoZoomLog("step4 wheel down x2   zoom=\(pct) pan=(\(Int(pan.width)),\(Int(pan.height)))")
        applyZoom(0.98, viewport: vp, at: anchor)
        for _ in 0..<12 { applyZoom(0.5, viewport: vp, at: anchor) }
        picnidoZoomLog("step5 zoom out to min zoom=\(pct) pan=(\(Int(pan.width)),\(Int(pan.height)))")
        for _ in 0..<40 { applyZoom(1.5, viewport: vp, at: anchor) }
        picnidoZoomLog("step6 zoom in to max  zoom=\(pct) pan=(\(Int(pan.width)),\(Int(pan.height))) maxZoom=\(String(format: "%.2f", maxZoom))")
        resetZoom()
        let rect = photoRect(viewport: vp)
        picnidoZoomLog("resting photo rect = \(Int(rect.width))x\(Int(rect.height)) at (\(Int(rect.minX)),\(Int(rect.minY))) viewport=\(Int(vp.width))x\(Int(vp.height)) ratio=\(String(format: "%.3f", rect.height / vp.height))")
        picnidoZoomLog("--- selftest maths end ---")

        // The one thing that must hold for the percentage to mean anything: at 100% the photo's
        // displayed width equals its pixel width.
        let target = sourceSize.width / max(0.0001, baseSize.width)
        zoom = target; committedZoom = target
        let at100 = photoRect(viewport: vp)
        picnidoZoomLog("at 100% -> readout=\(pct) displayedWidth=\(String(format: "%.1f", at100.width)) sourceWidth=\(Int(sourceSize.width))")
        zoom = 1; committedZoom = 1; pan = .zero
    }

    /// Stops the picture being flung off screen, and keeps it centred while it fits.
    private func clampPan(_ p: CGSize, viewport size: CGSize) -> CGSize {
        guard sourceSize.width > 0, size.width > 1, size.height > 1 else { return .zero }
        let base = ViewerGeometry.baseSize(image: sourceSize, viewport: size,
                                           topBand: topBand, clearance: clearance)
        let limitX = max(0, (base.width * zoom - size.width) / 2)
        let limitY = max(0, (base.height * zoom - size.height) / 2)
        return CGSize(width: min(max(p.width, -limitX), limitX),
                      height: min(max(p.height, -limitY), limitY))
    }

    /// Where a drag lands, given the pan it started from. The gesture and the self-test both go
    /// through here, so the test cannot pass while the gesture does something else.
    private func panned(from origin: CGSize, by translation: CGSize, viewport size: CGSize) -> CGSize {
        clampPan(CGSize(width: origin.width + translation.width,
                        height: origin.height + translation.height), viewport: size)
    }

    /// The screen position of a point in the photo, given as a fraction of the picture
    /// (0…1, top-left origin).
    private func screenPoint(of unit: CGPoint, pan p: CGSize, in size: CGSize) -> CGPoint {
        let r = ViewerGeometry.photoRect(image: sourceSize, viewport: size,
                                         topBand: topBand, clearance: clearance,
                                         zoom: zoom, pan: p)
        return CGPoint(x: r.minX + unit.x * r.width, y: r.minY + unit.y * r.height)
    }

    /// The inverse: which part of the picture sits under a given screen point.
    private func unitPoint(of screen: CGPoint, pan p: CGSize, in size: CGSize) -> CGPoint {
        let r = ViewerGeometry.photoRect(image: sourceSize, viewport: size,
                                         topBand: topBand, clearance: clearance,
                                         zoom: zoom, pan: p)
        guard r.width > 0.01, r.height > 0.01 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: (screen.x - r.minX) / r.width, y: (screen.y - r.minY) / r.height)
    }

    /// Debug hook (PICNIDO_DRAG_TEST=1).
    ///
    /// "The picture does not follow the mouse — the point that moves is down and to the left of
    /// the point I grabbed" is a claim about a single invariant, and the invariant can be checked
    /// without a mouse:
    ///
    ///     whatever was under the grab point must be under the cursor after the drag
    ///
    /// It reproduces the user's situation first — wheel-zoom to 300% anchored off-centre, which
    /// is what leaves a non-zero pan behind — and then drives the drag through the same
    /// `panned(from:by:)` the gesture uses.
    private func runDragSelfTest() {
        let vp = viewport
        guard vp.width > 1, sourceSize.width > 0, baseSize.width > 0 else {
            picnidoZoomLog("dragselftest: no viewport"); return
        }
        picnidoZoomLog("--- drag selftest viewport=\(Int(vp.width))x\(Int(vp.height)) source=\(Int(sourceSize.width))x\(Int(sourceSize.height)) ---")

        // Wheel-zoom to 300% of the original, anchored off centre.
        zoom = 1; committedZoom = 1; pan = .zero
        let wanted = CGFloat(3.0) * sourceSize.width / max(1, baseSize.width)
        let steps = 14
        let step = pow(min(wanted, maxZoom), 1 / CGFloat(steps))
        let anchor = CGPoint(x: vp.width * 0.68, y: vp.height * 0.62)
        for _ in 0..<steps { applyZoom(step, viewport: vp, at: anchor) }
        picnidoZoomLog("after wheel-zoom   zoom=\(pct) pan=(\(Int(pan.width)),\(Int(pan.height)))  (non-zero pan is what the bug tripped over)")

        let startPan = pan
        let grab = CGPoint(x: vp.width * 0.58, y: vp.height * 0.54)
        let translation = CGSize(width: 137, height: -86)
        let move = CGPoint(x: grab.x + translation.width, y: grab.y + translation.height)

        let grabbed = unitPoint(of: grab, pan: startPan, in: vp)
        let landed = panned(from: startPan, by: translation, viewport: vp)
        let where_ = screenPoint(of: grabbed, pan: landed, in: vp)
        let error = hypot(where_.x - move.x, where_.y - move.y)

        picnidoZoomLog(String(format: "grabbed unit=(%.3f,%.3f) at (%.0f,%.0f)", grabbed.x, grabbed.y, grab.x, grab.y))
        picnidoZoomLog(String(format: "drag by (%.0f,%.0f) -> pan=(%.0f,%.0f)", translation.width, translation.height, landed.width, landed.height))
        picnidoZoomLog(String(format: "grabbed point landed at (%.1f,%.1f), cursor at (%.1f,%.1f)  error=%.2f pt  %@",
                             where_.x, where_.y, move.x, move.y, error,
                             error < 0.5 ? "OK" : "FAIL"))

        // The same drag without the fix, for contrast: `pan = translation`, which is what the
        // gesture used to do.
        let old = clampPan(translation, viewport: vp)
        let oldWhere = screenPoint(of: grabbed, pan: old, in: vp)
        picnidoZoomLog(String(format: "old behaviour would have landed it at (%.1f,%.1f)  error=%.1f pt",
                             oldWhere.x, oldWhere.y, hypot(oldWhere.x - move.x, oldWhere.y - move.y)))

        zoom = 1; committedZoom = 1; pan = .zero
        picnidoZoomLog("--- drag selftest end ---")
    }

    // MARK: Commands

    private func apply(_ kind: ZoomRequest.Kind) {
        switch kind {
        case .zoomIn: zoomIn()
        case .zoomOut: zoomOut()
        case .reset: resetZoom()
        case .toggle: toggleZoom()
        }
    }

    private func zoomIn() {
        zoom = min(zoom * 1.5, maxZoom)
        committedZoom = zoom
        flashReadout()
    }

    private func zoomOut() {
        zoom = max(zoom / 1.5, Self.minZoom)
        committedZoom = zoom
        pan = clampPan(pan, viewport: viewport)
        flashReadout()
    }

    private func resetZoom() {
        zoom = 1
        committedZoom = 1
        pan = .zero
    }

    private func toggleZoom() {
        if zoom > 1.05 {
            resetZoom()
        } else {
            // Double-click goes to 100% of the original — the same gesture the original viewer
            // maps to "actual size". On a small photo that is a magnification, on a huge one it
            // is still a magnification, and it always means the same thing.
            let target = sourceSize.width > 0 && baseSize.width > 0
                ? min(sourceSize.width / baseSize.width, maxZoom)
                : 2.5
            zoom = target
            committedZoom = target
            pan = clampPan(pan, viewport: viewport)
        }
        flashReadout()
    }
}

struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
