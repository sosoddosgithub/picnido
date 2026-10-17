import SwiftUI
import Observation
import AppKit
import UniformTypeIdentifiers

enum Screen { case library, edit }

/// What the grid prints under each thumbnail — the original's View ▸ Thumbnail Caption submenu.
///
/// `automatic` is the behaviour the grid used to hard-code (caption when there is one, file name
/// otherwise), kept as the default so nobody's grid changes until they ask it to.
enum CaptionMode: String, CaseIterable, Identifiable {
    case automatic = "Automatic"
    case fileName = "File Name"
    case caption = "Caption"
    case tags = "Tags"
    case resolution = "Resolution"
    case dateTaken = "Date Taken"

    var id: String { rawValue }
    static let defaultsKey = "thumbnailCaptionMode"

    static var stored: CaptionMode {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let mode = CaptionMode(rawValue: raw) else { return .automatic }
        return mode
    }

    func text(for photo: PhotoItem) -> String {
        switch self {
        case .automatic:
            return photo.caption.isEmpty ? photo.fileName : photo.caption
        case .fileName:
            return photo.fileName
        case .caption:
            return photo.caption
        case .tags:
            return photo.tags.joined(separator: ", ")
        case .resolution:
            return photo.pixelWidth > 0 ? photo.dimensionsText : ""
        case .dateTaken:
            return photo.created == .distantPast
                ? "" : photo.created.formatted(date: .abbreviated, time: .omitted)
        }
    }
}

/// The languages the interface is translated into.
///
/// The raw values are the `.lproj` directory names, so one string serves the picker, the stored
/// preference, the resource directory and the `Locale` handed to SwiftUI — four things that would
/// otherwise be four lists to keep in step.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case japanese = "ja"
    case korean = "ko"

    var id: String { rawValue }

    /// The language's own name for itself, which is what the picker shows. An English menu that
    /// offers "Japanese" to somebody who reads Japanese asks them to recognise a word in the
    /// language they are trying to leave; writing each name natively is what every system on this
    /// machine does, and this is the one list where that is not a stylistic preference.
    var name: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    static let defaultsKey = "interfaceLanguage"

    /// The language whose table should serve `identifier`, matched on the prefix.
    ///
    /// Prefix matching because the identifiers a machine reports are more specific than the
    /// tables here: `zh-Hans-CN`, `zh-Hant-TW` and a bare `zh` are all Chinese, and none of them
    /// is the string `zh-Hans`. Anything unrecognised returns nil and the caller moves on to the
    /// next candidate, which is what keeps an unknown language from silently selecting English
    /// for a user who has a perfectly good second choice in their list.
    ///
    /// NOTE: Traditional Chinese currently lands on the Simplified table. That is the deliberate
    /// half of a trade — a machine set to `zh-Hant` reads Simplified more easily than it reads
    /// English — and it is recorded in TODO.md as the thing to fix by adding a `zh-Hant` table.
    static func matching(_ identifier: String) -> AppLanguage? {
        let lower = identifier.lowercased()
        if lower.hasPrefix("zh") { return .simplifiedChinese }
        if lower.hasPrefix("ja") { return .japanese }
        if lower.hasPrefix("ko") { return .korean }
        if lower.hasPrefix("en") { return .english }
        return nil
    }

    /// The language to start in: the stored one, else whatever the machine asks for.
    ///
    /// There is deliberately no "Follow the system" row in the picker. An application that has
    /// been English-only for nine versions would otherwise change language on the next launch for
    /// every user whose machine is not English, and that is a larger surprise than any
    /// translation is worth. The machine's preference decides what the *first* launch looks like;
    /// after that the answer is stored and belongs to the user.
    static var initial: AppLanguage {
        if let hook = DevHook.string("PICNIDO_LANG"), let forced = matching(hook) { return forced }
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let stored = AppLanguage(rawValue: raw) {
            return stored
        }
        for identifier in Locale.preferredLanguages {
            if let language = matching(identifier) { return language }
        }
        return .english
    }
}

/// `UserDefaults` keys for the display preferences that outlive a launch.
///
/// Collected here rather than written inline at the two call sites each one has (a read in the
/// property's initial value, a write in its `didSet`), because the failure mode of a typo is
/// silent: the preference would be written under one name and read back under another, and the
/// symptom would be "the switch forgets itself", which points nowhere near the typo.
private enum GridPreference {
    static let masonry = "libraryMasonryLayout"
    static let folderHeaders = "libraryFolderHeaders"
}

/// Which interactive tool currently owns the mouse in the editor.
enum ActiveTool: Equatable {
    case none
    case crop(CropAspect)
    case straighten
    case redeye
    case retouch
    case text
    case whitePoint
    case pickFocal(String)      // filter id waiting for a puck click
}

@Observable
final class AppState {

    /// Single shared instance. The AppKit delegate needs a way back to the app state
    /// (it handles drag-and-drop / "open with" events), and a singleton is the only
    /// shape that survives SwiftUI re-creating the `App` struct.
    static let shared = AppState()

    let store = LibraryStore()

    // Navigation
    var screen: Screen = .library
    var editingID: String?
    var viewerID: String?
    /// Whether the library's information pane is showing. Derived from the selection plus this
    /// flag, so it decides how much of the window the grid — and with it the toolbar row above it
    /// — gets: the pane costs 268 of the 1060-point minimum, and that row is where the width
    /// budget is tightest.
    ///
    /// `PICNIDO_INFO_PANE=0` (or `1`) pins it for a scripted run, because a layout check has to be
    /// able to state which of the two widths it measured. Without the pin a run that passes
    /// `PICNIDO_ROOTS` selects the first photo and the pane comes up on its own, which quietly
    /// turns a "row fits" measurement into a "row is over-subscribed" one.
    var infoPaneVisible: Bool = DevHook.string("PICNIDO_INFO_PANE").map { $0 != "0" } ?? true
    var statusText = StatusNote()

    // Editor
    var editTab: EditTab = .basicFixes
    var activeTool: ActiveTool = .none
    var toolRadius: Double = 0.02
    var selectedFilterID: String?
    var filterParams: [String: [Double]] = [:]
    var textOverlay = TextOverlay()
    var compareOriginal = false
    var showHistogram = true

    // Live (uncommitted) preview state used by the editor canvas
    var liveTuning = TuningParams()
    var liveEffectID: String?
    var liveEffectParams: [Double] = []
    var liveStraighten: Double = 0
    var liveCropRect: CGRect = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
    var liveText = TextOverlay()

    // Library chrome
    /// What the grid prints under each thumbnail. Persisted — a display preference that resets
    /// on every launch is not a preference.
    var captionMode: CaptionMode = CaptionMode.stored {
        didSet { UserDefaults.standard.set(captionMode.rawValue, forKey: CaptionMode.defaultsKey) }
    }

    /// The interface language, persisted. Applied as a `Locale` in the environment rather than by
    /// writing `AppleLanguages`, which makes the change take effect on the next frame instead of
    /// on the next launch — see the root view in `PicnidoApp`, and `AppLanguage` above.
    var language: AppLanguage = AppLanguage.initial {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.defaultsKey) }
    }

    /// Lay the grid out as a masonry — same width per column, each picture its own height — rather
    /// than as the uniform squares it has drawn since the first version.
    ///
    /// Off by default. The grid is the shape people already recognise, and a switch that turned
    /// itself on at upgrade would be rearranging a page of somebody's library without being asked.
    var masonryLayout: Bool = UserDefaults.standard.bool(forKey: GridPreference.masonry) {
        didSet { UserDefaults.standard.set(masonryLayout, forKey: GridPreference.masonry) }
    }

    /// Insert a folder heading above each folder's run of pictures, so the grid says where its
    /// contents came from. Off by default for the same reason as `masonryLayout`: the headings
    /// change the shape of the list, and the list is the user's, not ours.
    ///
    /// Independent of `masonryLayout` — the headings are a property of the *sequence*, not of the
    /// layout, so all four combinations are meaningful and all four are supported.
    var showFolderHeaders: Bool = UserDefaults.standard.bool(forKey: GridPreference.folderHeaders) {
        didSet { UserDefaults.standard.set(showFolderHeaders, forKey: GridPreference.folderHeaders) }
    }

    /// "Copy All Effects" clipboard, plus the photo it came from so the menu can say so.
    var copiedEffects: [EditStep]?
    var copiedEffectsFrom: String?

    // Organise sheets
    var showRename = false
    var showAdjustDate = false
    var showShortcuts = false
    var showDuplicates = false

    /// SwiftUI offers the Settings scene only as an environment action (`openSettings`), and
    /// macOS 14 removed the `showSettingsWindow:` application selector that used to work. A view
    /// captures the action into here so non-view code — the launch-argument hooks — can open it.
    var openSettingsAction: (() -> Void)?

    /// Bumped by the ⌘F menu item. The search field lives inside a view the menu cannot reach,
    /// and a menu command that does nothing visible is worse than no menu command.
    var focusSearchRequest = 0

    /// The stack the canvas should render: the committed history plus whatever is being previewed.
    func displayStack(for photo: PhotoItem) -> [EditStep] {
        guard photo.id == editingID else { return photo.stack }
        var stack = photo.stack
        if activeTool == .straighten, abs(liveStraighten) > 0.01 {
            stack.append(EditStep(op: .straighten(degrees: liveStraighten)))
        }
        if case .crop = activeTool {
            // preview the crop immediately, the crop handles are drawn on top
            stack.append(EditStep(op: .crop(rect: liveCropRect, aspect: currentAspect.rawValue)))
        }
        if let fid = liveEffectID {
            stack.append(EditStep(op: .effect(id: fid, params: liveEffectParams)))
        }
        if !liveTuning.isIdentity {
            stack.append(EditStep(op: .tuning(liveTuning)))
        }
        return stack
    }

    var currentAspect: CropAspect = .original

    enum EditTab: String, CaseIterable, Identifiable {
        case basicFixes = "Basic Fixes"
        case tuning = "Tuning"
        case effects = "Effects"
        case effects2 = "Effects 2"
        case adjustments = "Adjustments"

        var id: String { rawValue }

        /// What fits in a 302-point panel. `rawValue` stays the full name for menus and
        /// documentation; five full-length segments do not fit and SwiftUI answers by
        /// truncating all five.
        var tabLabel: String {
            switch self {
            case .basicFixes: return "Fixes"
            case .tuning: return "Tuning"
            case .effects: return "Effects"
            case .effects2: return "Effects 2"
            case .adjustments: return "Adjust"
            }
        }

        /// Five tabs: Basic Fixes, the fine-tuning sliders, and *three* pages of Effects (the
        /// catalogue has 56 `effect` filters, far too many for one page). The split is drawn
        /// from what each filter is rather than from taste: page one is the effects with no
        /// parameters, page two is the ones that are really a look, and Adjustments is the
        /// sliders. See `FilterSpec.swift`.
        var help: String {
            switch self {
            case .basicFixes: return "Crop, straighten, red-eye, retouch, text, and the one-click fixes"
            case .tuning: return "Fill light, highlights, shadows, colour temperature, saturation"
            case .effects: return "Effects with no settings — one click and done"
            case .effects2: return "Frames, edges and the decorative effects"
            case .adjustments: return "Effects with sliders (sharpen, glow, blur, colour temperature…)"
            }
        }
    }

    // Pending dialogs
    var showExport = false
    var showCollage = false
    var showMovie = false
    var showPoster = false
    var showGalleryExport = false
    var showSlideshow = false
    // No `showSettings` here. One existed and was set by the Tools ▸ Preferences… item, but no
    // view ever read it — the menu item did nothing at all. Settings are opened through SwiftUI's
    // `SettingsLink` now, which talks to the `Settings` scene directly.
    var showBackup = false
    var showPrint = false
    var showScanFolders = false
    var showNewAlbum = false
    var newAlbumName = ""
    var batchApplyFilterID: String?

    // Slideshow / movie settings
    var slideshowInterval: Double = 3.0
    var slideshowTransition: TransitionKind = .fade
    var slideshowMusic: URL?
    var slideshowLoop = true
    var slideshowKenBurns = true

    // Export settings
    var exportFolder: URL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser
    var exportNamePrefix = ""
    var exportMaxDimension: Double = 1600
    var exportOriginalSize = true
    var exportJPEGQuality: Double = 0.9
    var exportFormat: ExportFormat = .jpeg
    var exportWatermark = false
    var exportWatermarkText = "© Picnido"
    var exportKeepEXIF = true

    var movieDuration: Double = 3.0
    var movieTransition: TransitionKind = .crossFade
    var movieMusic: URL?
    var movieTitle = "Picnido Movie"
    var movieKenBurns = true
    var movieResolution: MovieResolution = .hd1080

    // Collage
    var collageLayout: CollageLayout = .grid
    var collageAspect: Double = 1.0
    var collageSpacing: Double = 8
    var collageBackground: CollageBackground = .white
    var collageShadows = true
    var collageBorderWidth: Double = 6

    var posterPageWidth: Double = 17
    var posterPageHeight: Double = 11
    var posterColumns: Int = 2
    var posterRows: Int = 3
    var posterTitle = ""

    // Misc
    var lastImportFolder: URL?
    var showingInspectorFor: String?

    init() {
        store.load()
        // The editor and the viewer key on a path; a rename has to carry them along. Registered
        // here rather than inside the store because the store has no business knowing about
        // navigation state.
        store.pathRemapObservers.append { [weak self] old, new in
            guard let self else { return }
            if self.editingID == old { self.editingID = new }
            if self.viewerID == old { self.viewerID = new }
            if self.showingInspectorFor == old { self.showingInspectorFor = new }
        }
    }

    var editingPhoto: PhotoItem? {
        guard let id = editingID else { return nil }
        return store.photo(id)
    }

    var viewedPhoto: PhotoItem? {
        guard let id = viewerID else { return nil }
        // A picture handed over by the Finder is not in the library, so `store.photo` cannot
        // find it — the session list has to be asked first.
        if isViewerSession { return viewerSession.first { $0.id == id } }
        return store.photo(id)
    }

    /// Opens the viewer on a library photo.
    ///
    /// **The only way the viewer opens.** It used to be opened by a `.onChange(of: viewerID)` in
    /// the library window, which meant the grid was the only possible way in: the viewer could
    /// not open while that window was absent, and the whole feature read as a panel *of* the
    /// library rather than a viewer in its own right — which is exactly how a picture
    /// double-clicked in the Finder ended up being handed to the library instead.
    @MainActor
    func openInViewer(_ id: String) {
        viewerSession.removeAll()
        // This open started inside the app, so the library window — not the pointer — says which
        // display it belongs on. Clearing first keeps an origin left over from an outside open
        // from carrying a grid double-click off to another screen.
        ViewerHost.shared.dropOpenOrigin()
        viewerID = id
        ViewerHost.shared.show(app: self)
        scheduleAutoCloseIfRequested()
    }

    /// Verification hook: close the viewer by itself after N seconds, down the same path the ✕
    /// button takes. Synthetic key events need an Accessibility grant this machine does not give,
    /// so without it the "a viewer-only run quits when the viewer closes" behaviour — and, just as
    /// importantly, the fact that a viewer opened from the library does *not* quit — could only
    /// ever be tried by hand.
    ///
    /// Shared by both ways in, so either can be exercised, and read through `DevHook` so a run
    /// started by `open` — the only kind that reproduces a double-click — can be given the value
    /// at all. That matters here more than anywhere: a viewer-only launch is exactly the run that
    /// cannot be started with an environment variable.
    @MainActor
    private func scheduleAutoCloseIfRequested() {
        guard let seconds = DevHook.double("PICNIDO_VIEWER_AUTOCLOSE"), seconds > 0 else { return }
        // Re-armed on every open rather than once per process. The old one-shot flag meant a run
        // that opened three pictures only ever auto-closed the first, which made the one thing the
        // hook exists for — opening a picture, closing it, opening the next — untestable. Cancelling
        // the pending item first keeps a stale one from firing into a newer session.
        autoCloseWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.viewerID != nil else { return }
            PicnidoAppDelegate.report("[launch] PICNIDO_VIEWER_AUTOCLOSE firing (pictureMode=\(self.isPictureMode))")
            ViewerHost.shared.close()
            self.viewerID = nil
            self.endViewerSession()
        }
        autoCloseWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// The pending auto-close, so the next open replaces it instead of racing it.
    private var autoCloseWork: DispatchWorkItem?

    func startEditing(_ id: String) {
        editingID = id
        screen = .edit
    }

    func returnToLibrary() {
        screen = .library
        activeTool = .none
        selectedFilterID = nil
    }

    // MARK: Filter parameters

    func params(for id: String) -> [Double] {
        if let p = filterParams[id], !p.isEmpty { return p }
        return Filters.defaultParams(for: id)
    }

    func binding(for id: String, index: Int) -> Binding<Double> {
        Binding(
            get: { [weak self] in
                guard let self else { return 0.5 }
                let p = self.params(for: id)
                return index < p.count ? p[index] : 0.5
            },
            set: { [weak self] newValue in
                guard let self else { return }
                var p = self.params(for: id)
                while p.count <= index { p.append(0.5) }
                p[index] = newValue
                self.filterParams[id] = p
            }
        )
    }

    func resetParams(for id: String) {
        filterParams[id] = Filters.defaultParams(for: id)
    }

    /// Applies the currently selected effect, with its live slider values, to the edited photo.
    func commitSelectedFilter() {
        guard let id = editingID, let fid = selectedFilterID else { return }
        store.push(id, .effect(id: fid, params: params(for: fid)))
        selectedFilterID = nil
        activeTool = .none
    }

    func applyFilter(_ id: String) {
        guard let editingID else { return }
        if FilterCatalog.spec(id)?.hasSliders == true {
            selectedFilterID = id
        } else {
            store.push(editingID, .effect(id: id, params: Filters.defaultParams(for: id)))
        }
    }

    func applyFilterToSelection(_ id: String) {
        let ids = store.tray.isEmpty ? Array(store.selection) : store.tray
        for pid in ids {
            store.push(pid, .effect(id: id, params: Filters.defaultParams(for: id)))
        }
        statusText = StatusNote("Applied %@ to %lld photos", [FilterCatalog.spec(id)?.label ?? id, ids.count])
    }

    // MARK: Copy / paste all effects
    //
    // The original's headline batch workflow: get one photo right, then put those effects on
    // the other two hundred. It is the reason `Edit` carries these two commands with shortcuts
    // rather than burying them.

    /// The steps "Copy All Effects" considers: the effects, the tuning and the colour picker.
    ///
    /// Crop, rotate, straighten, red-eye and retouch are deliberately left out. They are tied to
    /// what is where in *this* photograph — pasting one photo's crop onto another is not a
    /// feature, it is a bug with a menu item.
    static func transferableSteps(of photo: PhotoItem) -> [EditStep] {
        photo.stack.filter { step in
            switch step.op {
            case .effect, .tuning, .whitePoint, .text: return true
            default: return false
            }
        }
    }

    func copyAllEffects(from photo: PhotoItem) {
        let steps = Self.transferableSteps(of: photo)
        guard !steps.isEmpty else {
            statusText = StatusNote("%@ has no effects to copy", [photo.fileName])
            return
        }
        copiedEffects = steps
        copiedEffectsFrom = photo.fileName
        statusText = StatusNote("Copied %lld effect\(steps.count == 1 ? "" : "s") from %@", [steps.count, photo.fileName])
    }

    /// Puts the clipboard's effects onto one or many photos, replacing whatever effects they had.
    @discardableResult
    func pasteAllEffects(on ids: [String]) -> Int {
        guard let steps = copiedEffects, !steps.isEmpty else { return 0 }
        for id in ids {
            store.replaceEffects(id, with: steps.map { EditStep(op: $0.op) })
        }
        statusText = StatusNote("Pasted %lld effect\(steps.count == 1 ? "" : "s") onto %lld photo\(ids.count == 1 ? "" : "s")", [steps.count, ids.count])
        return ids.count
    }

    /// The photos a batch command should act on: the tray when there is one, otherwise the
    /// selection. Same rule the existing "apply to selection" command uses.
    var batchTargets: [String] { store.tray.isEmpty ? Array(store.selection) : store.tray }

    /// Hands a file to whatever application the user nominates — the escape hatch for the one
    /// edit this application does not do. The original had this on the right-click menu too.
    func openInExternalEditor(_ url: URL) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Open With"
        panel.message = "Choose the application to open \(url.lastPathComponent) with"
        guard panel.runModal() == .OK, let appURL = panel.url else { return }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) { _, error in
            if let error {
                Task { @MainActor in self.statusText = StatusNote("Could not open in %@: %@", [appURL.lastPathComponent, error.localizedDescription]) }
            } else {
                Task { @MainActor in self.statusText = StatusNote("Opened %@ in %@", [url.lastPathComponent, appURL.lastPathComponent]) }
            }
        }
    }

    func startSlideshow() {
        guard !store.visiblePhotos.isEmpty else { return }
        showSlideshow = true
    }

    /// Single entry point for paths handed to us from outside the app — the Finder's
    /// "Open With", a double-click, a drop on the Dock icon, `PICNIDO_OPEN`.
    ///
    /// Folders are *imported*: they become library roots, which is what managing folders means.
    /// Pictures are not. Opening a document is a request to look at it, not to file it — and the
    /// old code ran `addRoot(url.deletingLastPathComponent())` for every file, so double-clicking
    /// one photo silently enlisted its entire folder and brought the library window forward
    /// showing a folder nobody had asked to manage. Pictures now go to the viewer and the
    /// library is left exactly as it was.
    ///
    /// Several paths at once (a multi-selection "Open With") start one session on the first
    /// picture; the sibling pass then fills in everything sharing its folder.
    ///
    /// `external` marks the paths as having come from outside the app — the Finder's "Open With",
    /// a double-click, a drop on the Dock icon — as opposed to `PICNIDO_OPEN`, which is our own
    /// scripting hook. Only the external route may turn a launch into a viewer-only one; a
    /// scripted run must keep behaving like a scripted run.
    @MainActor
    func importPaths(_ paths: [String], external: Bool = false) {
        var folders: [URL] = []
        var images: [URL] = []
        for path in paths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                folders.append(url)
            } else if LibraryStore.imageExtensions.contains(url.pathExtension.lowercased()) {
                images.append(url)
            } else {
                // Not a picture we can show. Make its folder reachable rather than dropping the
                // request on the floor, which is what "open with" is asking for.
                folders.append(url.deletingLastPathComponent())
            }
        }
        for folder in folders { store.addRoot(folder) }
        if let first = images.first {
            if external {
                noteExternalPicture()
                // Read the pointer now, while it is still on the icon that was double-clicked.
                // `openViewerSession` builds the window after an ImageIO read off the main thread,
                // and by then the cursor has often moved; the display the picture came from is only
                // knowable here.
                ViewerHost.shared.noteOpenOrigin()
            }
            openViewerSession(startingAt: first)
        } else if external, !folders.isEmpty {
            // An outside folder is a request to manage it, so the library is what was asked for.
            // Saying so here keeps a later "close the viewer" from quitting under the user.
            libraryWindowSettled = true
        }
    }

    @MainActor
    func importPath(_ path: String) { importPaths([path]) }

    // MARK: - Viewer sessions (pictures opened from outside the library)

    /// Pictures handed to us by the Finder rather than picked inside the library.
    ///
    /// Non-empty means the viewer is showing a handed-over set, which changes two things: the
    /// list it pages through, and which controls it can honestly offer — nothing here has a row
    /// in the library, so Star, Rotate and Edit would have nowhere to write.
    var viewerSession: [PhotoItem] = []
    var isViewerSession: Bool { !viewerSession.isEmpty }

    /// What the viewer pages through: the handed-over set when there is one, the library
    /// otherwise. The filmstrip and the arrow keys both read this, so they always agree on what
    /// "next" means.
    var viewerPhotos: [PhotoItem] { isViewerSession ? viewerSession : store.visiblePhotos }

    // MARK: - Launch mode: looking at a picture vs. managing folders

    /// True while the app presents itself as a picture viewer rather than as a library: no Dock
    /// icon, no Cmd-Tab entry, one small status item in the menu bar instead.
    ///
    /// Two ways in, which is why this is no longer named after the launch:
    ///
    /// * **A picture handed over from outside during launch** (`noteExternalPicture`) — the case the
    ///   masking below was built for. The library window is a SwiftUI scene, so the framework builds
    ///   it and puts it on screen before any of our code is in a position to object, and there is no
    ///   supported way to stop that; the window is therefore held invisible from the moment it
    ///   exists rather than prevented (`libraryWindowMasked`).
    /// * **The user closing the library window** (`dismissLibraryWindow`) — the window is faded out
    ///   rather than closed, so it can come straight back.
    ///
    /// What it is *not* any more is a reason to quit. Quitting on the way out of the viewer is what
    /// put an icon into the Dock and took it away again for every picture — the flicker being
    /// reported. The app now steps back to the menu bar and stays there until it is asked to leave.
    private(set) var isPictureMode = false

    /// Set once the launch has settled with no picture arriving, meaning the library is what the
    /// user asked for and nothing later should be allowed to reinterpret the launch.
    private var libraryWindowSettled = false

    /// Whether the launch has stopped being reinterpretable.
    ///
    /// Read by the reopen handler, which has to tell "nobody asked for this" (the echo of a window
    /// being hidden during launch) from "the user asked for the library".
    var isLaunchSettled: Bool { libraryWindowSettled }

    /// True from launch until the run is known to be about the library.
    ///
    /// The window is faded out the instant it exists — before it can be drawn — and brought back
    /// as soon as the launch is known not to be a picture launch, which is at
    /// `applicationDidFinishLaunching` for every launch that has no picture in it. Without this
    /// the library window is on screen for as long as it takes the viewer to cover it. The window
    /// itself is unavoidable — SwiftUI builds scenes and orders them on screen with no supported
    /// way to intervene — but it never has to be *seen*.
    private var libraryWindowMasked = true

    /// How long after launch an incoming picture still counts as "this launch was for the
    /// picture".
    ///
    /// The Finder hands the file over during `finishLaunching`, before `applicationDidFinishLaunching`
    /// — measured with a stand-in app that logs every event it is given — so in practice a picture
    /// has already claimed the launch by the time this timer is even armed. It exists for the
    /// launches that are slower than that, and it is deliberately generous.
    private static let launchSettleDelay: TimeInterval = 1.5

    /// Keeps every window but the viewer off screen while a viewer-only run lasts.
    ///
    /// A guard rather than a fix, because the window that reappeared was not the one that had been
    /// hidden. The log, with the picture viewer up, read:
    ///
    ///     window[0] title="Picnido v1.1.2" ... visible=true  alpha=1.0
    ///     window[2] title="Picnido v1.1.2" ... visible=true  alpha=0.0
    ///
    /// Two library windows at once: the hidden one, and a second one SwiftUI had built rather than
    /// restored. Since the windows come from a `WindowGroup` scene, SwiftUI is entitled to make
    /// more of them whenever it likes, and there is no supported way to tell it not to. What can
    /// be relied on is this: while the app is only showing a picture, nothing else may be on
    /// screen. Anything that appears gets taken down as it appears.
    private var viewerOnlyWindowGuard: Timer?

    @MainActor
    private func startWindowGuard() {
        guard viewerOnlyWindowGuard == nil else { return }
        // A sweep, not a notification. The obvious notification does not exist: `UIWindow`'s
        // `didBecomeVisibleNotification` has no AppKit counterpart, and the AppKit ordering
        // notifications are not exposed under the names that suggest themselves — the compiler
        // rejected both `didBecomeVisibleNotification` and `didOrderOnScreenNotification` on
        // `NSWindow`. A quarter-second pass over a handful of windows costs nothing next to the
        // thing it prevents, and unlike a notification it also catches a window that was never
        // announced.
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { AppState.shared.sweepNonViewerWindows() }
        }
        // `.common`, not the default mode: a timer added only to the default mode stops while the
        // user is dragging or scrolling, which is precisely when a window could slip through.
        RunLoop.main.add(timer, forMode: .common)
        viewerOnlyWindowGuard = timer
    }

    @MainActor
    private func stopWindowGuard() {
        viewerOnlyWindowGuard?.invalidate()
        viewerOnlyWindowGuard = nil
    }

    /// Fades out anything on screen that is not the picture viewer.
    ///
    /// See `startWindowGuard` for why this exists at all. It is deliberately blunt: while the app
    /// is only showing a picture, nothing else has any business being visible, and the one window
    /// that is allowed — `ViewerPanel` — is excluded by type rather than by title or size.
    @MainActor
    private func sweepNonViewerWindows() {
        guard isPictureMode else { return }
        for window in NSApp.windows {
            guard !(window is ViewerPanel),
                  window.isVisible, window.alphaValue > 0,
                  window.frame.width > 200        // ignores the small helper windows AppKit keeps
            else { continue }
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            PicnidoAppDelegate.report("[launch] guard hid a window that appeared: number=\(window.windowNumber) class=\(type(of: window))")
        }
    }

    /// Decides whether the library window may be shown, and arms the launch window a picture can
    /// claim. Called once, from `applicationDidFinishLaunching`.
    ///
    /// Two separate questions, answered separately:
    ///
    /// * **May the window be seen?** Answered now, and answered *yes* unless a picture has already
    ///   claimed the launch. The Finder hands its document over during `finishLaunching`, before
    ///   this runs — measured, see `noteExternalPicture` — so by this point a picture launch has
    ///   already identified itself, and every other launch gets its window immediately.
    /// * **May the launch still be reinterpreted?** Answered after `launchSettleDelay`. A picture
    ///   arriving inside that window still turns the run into a viewer-only one.
    @MainActor
    func beginLaunchWindow() {
        if !isPictureMode { unmaskLibraryWindow() }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchSettleDelay) { [weak self] in
            guard let self else { return }
            self.libraryWindowSettled = true
            // Belt and braces. Nothing above should have brought the library window back, but a
            // reopen request during the launch window would have, and it is invisible to take it
            // down again — the viewer covers the screen.
            self.hideLibraryWindowIfPictureMode()
            PicnidoAppDelegate.report("[launch] settled: pictureMode=\(self.isPictureMode) masked=\(self.libraryWindowMasked) libraryWindowVisible=\(LibraryWindow.isVisible)")
        }

        scheduleLibraryCloseIfRequested()
    }

    /// Verification hook: close the library window the way the red button and ⌘W do, after a delay.
    ///
    /// `PICNIDO_VIEWER_AUTOCLOSE` covers the viewer; this covers the library, which is otherwise only
    /// reachable by a real mouse click or key press — neither of which a scripted run can produce
    /// without accessibility permission, and a feature that cannot be exercised from a script is a
    /// feature that only gets tested by hand. `performClose:` is the entry point both the red button
    /// and ⌘W end up in, so a hook here exercises the arrangement rather than a copy of it.
    @MainActor
    private func scheduleLibraryCloseIfRequested() {
        guard !libraryCloseScheduled,
              let seconds = DevHook.double("PICNIDO_LIBRARY_CLOSE"), seconds > 0 else { return }
        libraryCloseScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard self != nil, let window = LibraryWindow.window, window.alphaValue > 0 else { return }
            PicnidoAppDelegate.report("[mode] PICNIDO_LIBRARY_CLOSE firing -> performClose")
            window.performClose(nil)
        }
    }

    /// Keeps the library-close hook from arming itself twice.
    private var libraryCloseScheduled = false

    /// Called from inside a library window the moment that window exists.
    ///
    /// Masking here rather than later is the whole point: `viewDidMoveToWindow` runs while the
    /// window is still being assembled, so the fade is in place before the first frame is drawn
    /// and there is no flash to see. A window that is not the library window is not masked but
    /// closed — see `LibraryWindow.adopt`.
    @MainActor
    func windowRegistered(_ window: NSWindow) {
        LibraryWindow.adopt(window)
        guard window === LibraryWindow.window else { return }
        LibraryCloseButtonHook.shared.install(on: window)
        installLibraryKeyMonitor()
        guard libraryWindowMasked || isPictureMode else { return }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        PicnidoAppDelegate.report("[launch] library window masked at creation: number=\(window.windowNumber)")
    }

    /// ⌘W in the library window means "put it away", not "quit and lose it".
    ///
    /// The red button is covered by `LibraryCloseButtonHook`, but ⌘W never touches the button — it
    /// goes through the File menu straight to `performClose:`. A local monitor sees the key before
    /// the menu is asked for its key equivalent, so this one hook covers both. Scoped to the
    /// library window being the key window, so ⌘W in a sheet — a rename, an export panel — still
    /// means what it says.
    private var libraryKeyMonitor: Any?

    @MainActor
    private func installLibraryKeyMonitor() {
        guard libraryKeyMonitor == nil else { return }
        libraryKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let commandW = event.modifierFlags.contains(.command)
                && !event.modifierFlags.contains(.shift)
                && event.charactersIgnoringModifiers?.lowercased() == "w"
            guard commandW,
                  let library = LibraryWindow.window,
                  NSApp.keyWindow === library
            else { return event }
            AppState.shared.dismissLibraryWindow()
            return nil
        }
    }

    /// Shows the library window, if it is still being held back.
    @MainActor
    private func unmaskLibraryWindow() {
        guard libraryWindowMasked else { return }
        libraryWindowMasked = false
        guard let window = LibraryWindow.window else { return }
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        PicnidoAppDelegate.report("[launch] library window unmasked: number=\(window.windowNumber)")
    }

    /// A picture arrived from outside. Before the launch has settled, that turns this run into a
    /// viewer-only one.
    ///
    /// The Finder's hand-over arrives *during* `finishLaunching`, before
    /// `applicationDidFinishLaunching` — measured with a stand-in app that logs every event it is
    /// given: `open -a Probe.app picture.jpg` produced `open(urls:)` before `didFinishLaunching`,
    /// and `open -a Probe.app` produced no file event at all. So a picture that arrives before the
    /// window has settled is not a later errand, it is the reason this process exists.
    ///
    /// It deliberately does *not* order the library window out here. Doing it at this moment
    /// leaves an instant in which the app has no visible window at all — the library has gone and
    /// the viewer is not on screen yet — and AppKit reads that instant as "the user wants a
    /// window" and sends a reopen request, which puts the library straight back, behind the
    /// viewer. The window is already masked at this point (see `windowRegistered`), and the viewer
    /// takes it down for good once it is up; see `hideLibraryWindowIfPictureMode`.
    @MainActor
    func noteExternalPicture() {
        guard !libraryWindowSettled, !isPictureMode else { return }
        isPictureMode = true
        enterPictureMode()
        PicnidoAppDelegate.report("[launch] picture from outside -> picture mode")
    }

    /// Takes the library window off screen, but only while the app is in picture mode.
    @MainActor
    func hideLibraryWindowIfPictureMode() {
        guard isPictureMode else { return }
        hideLibraryWindow()
    }

    /// Takes the library window off screen for a viewer-only run, without closing it.
    ///
    /// Faded to transparent rather than ordered out, and that choice was forced by measurement
    /// rather than taste. The library window belongs to a SwiftUI `WindowGroup` scene, and SwiftUI
    /// puts a scene's window back on screen whenever it re-evaluates that scene: with `orderOut`
    /// the log read
    ///
    ///     [launch] library window ordered out (viewerOnly=true)
    ///     window[0] title="Picnido v1.1.2" ... visible=true      ← back a second later
    ///
    /// An alpha of zero leaves the window in the state SwiftUI expects — on screen — while making
    /// it invisible, so there is nothing for SwiftUI to correct. Mouse events are dropped as well
    /// so an invisible window can never swallow a click meant for the viewer behind it.
    @MainActor
    func hideLibraryWindow() {
        guard let window = LibraryWindow.window else { return }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        PicnidoAppDelegate.report("[launch] library window hidden: number=\(window.windowNumber) visible=\(window.isVisible) alpha=\(window.alphaValue)")
    }

    // MARK: - The app's two faces: library mode and picture mode

    /// Picture mode: no Dock icon, no Cmd-Tab entry, one small status item in the menu bar.
    ///
    /// The Dock icon appearing when a picture opened and vanishing when it closed is what this
    /// arrangement removes — an accessory app has no Dock icon to flicker. The status item is the
    /// handle that replaces it, and it is also the only way out of the app: see `MenuBarController`.
    @MainActor
    func enterPictureMode() {
        MenuBarController.shared.show()
        NSApp.setActivationPolicy(.accessory)
        // Wanted here and not only during a launch: the library window belongs to a SwiftUI
        // `WindowGroup`, which is entitled to build another one whenever it re-evaluates the scene,
        // and in picture mode nothing but the viewer has any business being on screen.
        startWindowGuard()
        PicnidoAppDelegate.report("[mode] picture mode: policy=\(NSApp.activationPolicy().rawValue) menuBarItem=\(MenuBarController.shared.isShown)")
    }

    /// Library mode: Dock icon, full menu bar, Cmd-Tab entry — what "Picnido is running" looks like
    /// while someone is working in the library. The status item goes away, because the Dock icon is
    /// the handle here and two handles for one app is one too many.
    @MainActor
    func enterLibraryMode() {
        MenuBarController.shared.hide()
        stopWindowGuard()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        PicnidoAppDelegate.report("[mode] library mode: policy=\(NSApp.activationPolicy().rawValue) menuBarItem=\(MenuBarController.shared.isShown)")
    }

    /// The user closed the library window: put it away and step back to the menu bar.
    ///
    /// Reached from the red button (`LibraryCloseButtonHook`) and from ⌘W
    /// (`installLibraryKeyMonitor`). Not a quit, and not a real close — the window is faded out
    /// exactly the way a picture launch hides it, so `showLibraryWindow` can bring it back without
    /// asking SwiftUI for a new one.
    @MainActor
    func dismissLibraryWindow() {
        PicnidoAppDelegate.report("[mode] library window dismissed -> menu bar")
        isPictureMode = true
        libraryWindowSettled = true
        hideLibraryWindow()
        enterPictureMode()
    }

    /// Brings the library window back. This is the status item's left click, and the way out of
    /// picture mode: a user who asks for the library has asked for the library.
    @MainActor
    func showLibraryWindow() {
        // A full-screen viewer cannot be left covering the window that was just asked for. Nothing
        // else closes it on this path — `endViewerSession` belongs to the viewer's own way out — so
        // without this, asking for the library from picture mode changed the mode and looked like
        // it had done nothing at all.
        if ViewerHost.shared.isOpen {
            PicnidoAppDelegate.report("[mode] library asked for while the viewer was up -> closing the viewer")
            ViewerHost.shared.close()
            viewerID = nil
            viewerSession.removeAll()
        }
        isPictureMode = false
        libraryWindowSettled = true
        enterLibraryMode()
        unmaskLibraryWindow()
        guard let window = LibraryWindow.window else { return }
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        window.makeKeyAndOrderFront(nil)
        PicnidoAppDelegate.report("[launch] library window shown on request")
    }

    /// Drops the handed-over set. Called when the viewer closes, so the next open from the grid
    /// does not inherit a stale list.
    @MainActor
    func endViewerSession() {
        viewerSession.removeAll()
        // This used to quit, and quitting here is the flicker: every picture opened and closed put
        // an icon into the Dock and took it away again. The app steps back to the menu bar instead,
        // and only the status item's menu can end it — see `MenuBarController`.
        guard isPictureMode else { return }
        PicnidoAppDelegate.report("[mode] viewer closed -> staying in picture mode")
        enterPictureMode()
    }

    /// Bumped on every open. A slow sibling pass that lands after the user has opened something
    /// else is discarded instead of overwriting the newer list.
    private var viewerSessionToken = 0

    /// Opens the viewer on a picture that is not in the library.
    ///
    /// Two passes on purpose. The clicked file is indexed first so the window is on screen
    /// straight away; its folder is enumerated behind it and the filmstrip fills in. Reading a
    /// folder of two thousand headers before showing anything would make the double-click feel
    /// broken for exactly as long as that takes.
    @MainActor
    func openViewerSession(startingAt url: URL) {
        viewerSessionToken &+= 1
        let token = viewerSessionToken
        PicnidoAppDelegate.report("[open] viewer session <- \(url.lastPathComponent) token=\(token) pictureMode=\(isPictureMode)")

        Task { @MainActor in
            // `indexRow` does an ImageIO header read. Off the main thread, because a
            // double-click on a file on a network volume must not stall the whole app.
            let row = await Task.detached(priority: .userInitiated) {
                LibraryStore.indexRow(for: url)
            }.value
            guard let row else {
                // ImageIO cannot read it. Fall back to importing the folder so the file is at
                // least reachable rather than vanishing.
                PicnidoAppDelegate.report("[open] \(url.lastPathComponent): ImageIO cannot read it")
                store.addRoot(url.deletingLastPathComponent())
                return
            }

            let item = store.makePhoto(from: row)
            viewerSession = [item]
            viewerID = item.id
            ViewerHost.shared.show(app: self)

            let rows = await Task.detached(priority: .utility) {
                LibraryStore.siblingImages(of: url).compactMap { LibraryStore.indexRow(for: $0) }
            }.value
            guard token == viewerSessionToken, rows.count > 1 else { return }
            let items = rows.map { store.makePhoto(from: $0) }
            viewerSession = items
            if let current = viewerID, !items.contains(where: { $0.id == current }) {
                viewerID = items.first?.id
            }
        }

        // Verification hook, shared with the library path: see `scheduleAutoCloseIfRequested`.
        scheduleAutoCloseIfRequested()
    }

    /// Accepts the same style of command line the original viewer did:
    ///   Picnido <folder|image>…  [--view] [--edit] [--slideshow] [--collage] [--movie] [--poster]
    func applyLaunchArguments() async {
        var args = Array(CommandLine.arguments.dropFirst())
        // Also honour an environment override — Paths on the command line get eaten by
        // AppKit's "open these documents" handling before SwiftUI ever sees them.
        if let env = ProcessInfo.processInfo.environment["PICNIDO_OPEN"], !env.isEmpty {
            args.append(env)
        }

        let hooks = ProcessInfo.processInfo.environment

        // --- verification hooks ----------------------------------------------------------
        // PICNIDO_FILETYPES_CHECK=1 — compare the plist's declared UTIs against the ones the
        // catalogue derives. Runs before anything else and needs no reconciliation, so a
        // headless launch is enough to check a freshly built bundle.
        if hooks["PICNIDO_FILETYPES_CHECK"] != nil {
            for line in FileTypeCatalog.auditReport() {
                PicnidoAppDelegate.report("[filetypes] " + line)
            }
        }

        // PICNIDO_SET_DEFAULT=<ext>,<ext> — claim formats for this app and report the handler
        // before and after. Exists because "did the button work" cannot be answered by reading
        // the code: the write is asynchronous and its result lives in the LaunchServices
        // database, not in this process.
        if let spec = hooks["PICNIDO_SET_DEFAULT"], !spec.isEmpty {
            let extensions = spec.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            DefaultViewer.snapshotIfNeeded()
            PicnidoAppDelegate.report("[defaults] self bundle=\(Bundle.main.bundleURL.path) id=\(Bundle.main.bundleIdentifier ?? "nil")")
            for ext in extensions {
                let uti = FileTypeCatalog.utiIdentifier(for: ext) ?? "?"
                let before = DefaultViewer.handlerName(for: ext) ?? "—"
                let outcome = await DefaultViewer.claim(ext)
                // The write is asynchronous and LaunchServices caches; reading straight back
                // reports the old value often enough to be useless as evidence.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let after = DefaultViewer.handlerName(for: ext) ?? "—"
                PicnidoAppDelegate.report("[defaults] \(ext) [\(uti)]: \(before) → \(after)  (\(outcome))")
                PicnidoAppDelegate.report("[defaults]    db default=\(DefaultViewer.defaultHandlerID(forUTI: uti) ?? "nil")")
                PicnidoAppDelegate.report("[defaults]    candidates=\(DefaultViewer.allHandlers(forUTI: uti).joined(separator: ", "))")
            }
        }

        // PICNIDO_DEFAULT_PROBE=<ext>,<ext> — call both write APIs directly and print exactly
        // what each says. `claim` folds three different failures into one word; this separates
        // "the call threw", "the call lied" and "the system ignored it".
        if let spec = hooks["PICNIDO_DEFAULT_PROBE"], !spec.isEmpty {
            let appURL = Bundle.main.bundleURL
            for ext in spec.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !ext.isEmpty {
                guard let type = FileTypeCatalog.uti(for: ext) else {
                    PicnidoAppDelegate.report("[probe] \(ext): no UTI"); continue
                }
                let uti = type.identifier
                var viaAsync = "no error"
                do {
                    try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type)
                } catch {
                    viaAsync = "error: \(error)"
                }
                PicnidoAppDelegate.report("[probe] \(ext) setDefaultApplication → \(viaAsync)")
                let status = DefaultViewer.rawSetDefault(uti)
                PicnidoAppDelegate.report("[probe] \(ext) LSSetDefaultRoleHandler → OSStatus \(status)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                PicnidoAppDelegate.report("[probe] \(ext) db default now = \(DefaultViewer.defaultHandlerID(forUTI: uti) ?? "nil")")
            }
        }

        // PICNIDO_RESTORE_DEFAULTS=1 — hand everything in the snapshot back.
        if hooks["PICNIDO_RESTORE_DEFAULTS"] != nil {
            let n = DefaultViewer.restoreSnapshot()
            PicnidoAppDelegate.report("[defaults] restored \(n) formats")
            for ext in FileTypeCatalog.allExtensions.prefix(4) {
                PicnidoAppDelegate.report("[defaults] \(ext) now: \(DefaultViewer.handlerName(for: ext) ?? "—")")
            }
        }

        // PICNIDO_ROOTS is applied inside `LibraryStore.load()` so the transient roots are in
        // place before the reconcile starts. All that is left to do here is wait for that
        // reconcile and report what it produced.
        if let rootsSpec = hooks["PICNIDO_ROOTS"], !rootsSpec.isEmpty {
            let started = Date()
            var waited = 0.0
            while store.isScanning || store.photos.isEmpty {
                if waited > 90 { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 0.1
            }
            PicnidoAppDelegate.report(String(format: "[roots] transient library: %d photos, %d folders in %.0f ms",
                                            store.photos.count, rootsSpec.split(separator: ":").count,
                                            Date().timeIntervalSince(started) * 1000))
            if let first = store.visiblePhotos.first { store.selection = [first.id] }
        }

        // PICNIDO_DUPLICATES=<folder> — run the duplicate scan over one folder and print the
        // groups. Walks the folder itself rather than reading the library: going through the
        // store means waiting for its reconcile, which makes the answer depend on scan timing
        // rather than on the comparison being tested.
        if let folder = hooks["PICNIDO_DUPLICATES"], !folder.isEmpty, folder != "1" {
            let root = URL(fileURLWithPath: folder)
            let urls = LibraryStore.enumerateImages(under: root)
            var items: [PhotoItem] = []
            for url in urls {
                let v = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
                var item = PhotoItem(url: url)
                item.fileSize = Int64(v?.fileSize ?? 0)
                item.created = v?.creationDate ?? .distantPast
                items.append(item)
            }
            PicnidoAppDelegate.report("[dupes] enumerated \(items.count) files under \(folder)")
            let outcome = await Task.detached(priority: .userInitiated) {
                DuplicateFinder.find(items)
            }.value
            PicnidoAppDelegate.report(String(format: "[dupes] %d photos · %d candidates read (%@) · %.1fs",
                                            outcome.scannedPhotos, outcome.filesRead,
                                            DuplicateFinder.sizeText(outcome.bytesRead), outcome.seconds))
            PicnidoAppDelegate.report(String(format: "[dupes] %d groups · %d extra copies · %@ recoverable",
                                            outcome.groups.count, outcome.duplicateFiles,
                                            DuplicateFinder.sizeText(outcome.wastedTotal)))
            for group in outcome.groups {
                let names = group.photos.map { $0.url.lastPathComponent }.joined(separator: " | ")
                PicnidoAppDelegate.report("[dupes]   \(group.count)× \(DuplicateFinder.sizeText(group.size)): \(names)")
            }
        }

        // PICNIDO_SHOW_DUPLICATES=<seconds> — open the Duplicate Files panel after N seconds, so
        // a snapshot can capture it. Needs to wait: the panel reads the library, which is still
        // filling when the launch arguments run.
        if let raw = hooks["PICNIDO_SHOW_DUPLICATES"] {
            let delay = Double(raw) ?? 6
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                showDuplicates = true
            }
        }

        // PICNIDO_SHEET=<name> — open one of the library's sheets at launch. Almost every one of
        // them is otherwise reachable only by clicking a toolbar or menu item, which a scripted run
        // cannot do, so they were the one surface no language check had ever looked at — and they
        // turned out to be the surface `.sheet` presents in a window that does not inherit the
        // scene's locale (see `InterfaceLanguage`). Names are the same as the flags: export,
        // collage, movie, poster, gallery, backup, print, album, scan, rename, date, shortcuts,
        // duplicates.
        //
        // Delayed for the same reason as the hook above: the panels read the library, which is
        // still filling when the launch arguments run.
        if let name = hooks["PICNIDO_SHEET"] {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                switch name {
                case "export":     showExport = true
                case "collage":    showCollage = true
                case "movie":      showMovie = true
                case "poster":     showPoster = true
                case "gallery":    showGalleryExport = true
                case "backup":     showBackup = true
                case "print":      showPrint = true
                case "album":      showNewAlbum = true
                case "scan":       showScanFolders = true
                case "rename":     showRename = true
                case "date":       showAdjustDate = true
                case "shortcuts":  showShortcuts = true
                case "duplicates": showDuplicates = true
                default:           PicnidoAppDelegate.report("[hooks] PICNIDO_SHEET='\(name)' is not a sheet name")
                }
            }
        }

        // PICNIDO_MENU_DUMP=1 — print the menu bar as text, so it can be checked in each language.
        // It cannot be screenshotted: the menu bar is not the app's window, and grabbing it needs
        // the screen-recording permission this machine does not grant. Menus are also the one
        // surface that is neither a window nor a sheet, so whether they follow the picker at all
        // is a question only a dump can answer.
        if hooks["PICNIDO_MENU_DUMP"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard let main = NSApp.mainMenu else {
                    PicnidoAppDelegate.report("[menu] no main menu")
                    return
                }
                for menu in main.items where !menu.title.isEmpty {
                    PicnidoAppDelegate.report("[menu] \(menu.title)")
                    for item in menu.submenu?.items ?? [] where !item.title.isEmpty {
                        PicnidoAppDelegate.report("[menu]    \(item.title)")
                    }
                }
            }
        }

        // PICNIDO_SETTINGS_TAB=<tab> is read by SettingsView itself, not here.

        // PICNIDO_SHOW_SETTINGS=<seconds> — open the Settings window after N seconds. Delayed
        // because `openSettingsAction` is only captured once the main window has appeared, and
        // it does nothing before that.
        //
        // `@MainActor` on the task is load-bearing: `openSettings` reaches into SwiftUI, and a
        // plain `Task {}` from this non-isolated function runs on a background thread, where
        // that is a hard crash ("calling into SwiftUI on a non-main thread is not supported"),
        // not a warning.
        if let raw = hooks["PICNIDO_SHOW_SETTINGS"] {
            let delay = Double(raw) ?? 3
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                openSettingsAction?()
            }
        }

        // PICNIDO_THUMB_STATS=<seconds> — dump the thumbnail cache counters after N seconds.
        // Accepts a comma-separated list (`0.5,1,2,4,8`) so a cold run can be watched filling
        // rather than only sampled once, which is what "does the cache keep up when I scroll"
        // actually needs: the shape of the curve, not a single end state.
        if let raw = hooks["PICNIDO_THUMB_STATS"] {
            let seconds = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            for seconds in seconds {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    PicnidoAppDelegate.report(String(format: "[t=%.1fs] %@", seconds,
                                                    ThumbnailCache.shared.statsLine()))
                }
            }
        }

        // PICNIDO_TREE_DUMP=1 — print the sidebar's folder tree, so the nesting can be checked
        // as text rather than by reading a screenshot.
        if hooks["PICNIDO_TREE_DUMP"] != nil {
            func walk(_ nodes: [FolderNode], _ depth: Int) -> String {
                var text = ""
                for node in nodes {
                    text += String(repeating: "    ", count: depth)
                        + "\(node.name) (\(node.totalCount)) own=\(node.ownCount)\n"
                    text += walk(node.children, depth + 1)
                }
                return text
            }
            PicnidoAppDelegate.report("--- folder tree ---\n" + walk(store.folderTree, 0) + "--- end tree ---")
        }

        // PICNIDO_GRID_SCROLL=<steps> — scroll the photo grid with real wheel events and report
        // what the thumbnail pipeline did.
        //
        // The complaint was that scrolling outran the cache. The only honest way to test that is
        // to scroll it, so the events go through `scrollWheel(with:)` on whatever view the hit
        // test lands on — the same call AppKit would make — rather than by asking the loader for
        // thumbnails directly, which would measure nothing.
        if let raw = hooks["PICNIDO_GRID_SCROLL"], let steps = Int(raw), steps > 0 {
            let gap = Double(hooks["PICNIDO_GRID_SCROLL_MS"] ?? "24") ?? 24
            let interval = gap / 1000
            let delta = Double(hooks["PICNIDO_GRID_SCROLL_DY"] ?? "-90") ?? -90
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            guard let window = NSApp.windows.first(where: {
                $0.isVisible && !($0 is ViewerPanel) && $0.frame.width > 400
            }), let content = window.contentView else {
                PicnidoAppDelegate.report("gridscroll: no library window")
                return
            }
            if let snap = hooks["PICNIDO_SNAPSHOT"] { PicnidoAppDelegate.snapshotAll(to: snap + "_before") }
            let point = CGPoint(x: content.bounds.width * 0.6, y: content.bounds.height * 0.45)
            let before = ThumbnailCache.shared.statsLine()
            let started = Date()
            var late: [Double] = []

            for i in 0..<steps {
                let scheduled = interval * Double(i)
                DispatchQueue.main.asyncAfter(deadline: .now() + scheduled) {
                    late.append(max(0, Date().timeIntervalSince(started) - scheduled) * 1000)
                    if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                        wheelCount: 1, wheel1: Int32(delta), wheel2: 0, wheel3: 0),
                       let event = NSEvent(cgEvent: cg) {
                        (content.hitTest(point) ?? content).scrollWheel(with: event)
                    }
                    if i == steps - 1 {
                        let elapsed = Date().timeIntervalSince(started)
                        let sorted = late.sorted()
                        let mean = late.reduce(0, +) / Double(max(1, late.count))
                        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
                        PicnidoAppDelegate.report("""
                        --- grid scroll test ---
                        steps=\(steps) interval=\(String(format: "%.0f", gap))ms  deltaY=\(delta)
                        elapsed=\(String(format: "%.2f", elapsed))s
                        lateness mean=\(String(format: "%.2f", mean))ms  p95=\(String(format: "%.2f", p95))ms
                        thumbs before: \(before)
                        thumbs after : \(ThumbnailCache.shared.statsLine())
                        """)
                        if let snap = hooks["PICNIDO_SNAPSHOT"] { PicnidoAppDelegate.snapshotAll(to: snap + "_after") }
                    }
                }
            }
        }

        // Hooks that do not need a command line, run before the argument handling below.
        //
        // This used to sit *after* `guard !args.isEmpty else { return }`, which quietly made every
        // hook down there dead on exactly the runs that need them: a scripted verification passes
        // its configuration in the environment and has no arguments at all, so the guard returned
        // first and `PICNIDO_SCAN_DUMP` / `PICNIDO_VIEWER_CYCLE` / `PICNIDO_CLICK` never ran.
        await runScriptedHooks(hooks: hooks)

        guard !args.isEmpty else { return }
        var target: String?
        var wants: Set<String> = []

        for arg in args {
            if arg.hasPrefix("--") { wants.insert(String(arg.dropFirst(2))); continue }
            if arg.hasPrefix("-") { continue }
            let url = URL(fileURLWithPath: arg)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                store.addRoot(url)
            } else {
                // NOTE: the command line keeps the import semantics deliberately, and it is not
                // an oversight that this differs from `importPaths`. `Picnido <image>` is a
                // scripted invocation: the caller wants the library built up and the picture
                // selected in it, and the verification scripts are written against exactly that.
                // A double-click carries no such intent — see the note on `importPaths`.
                store.addRoot(url.deletingLastPathComponent())
                target = url.path
            }
        }

        // wait for the background scan to surface the requested photo
        var waited = 0.0
        while waited < 25 {
            if !store.photos.isEmpty {
                if target == nil { break }
                if store.photos.contains(where: { $0.url.path == target }) { break }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            waited += 0.2
        }

        if let target, let photo = store.photos.first(where: { $0.url.path == target }) {
            store.selection = [photo.id]
            await openInViewer(photo.id)
        } else if let first = store.visiblePhotos.first {
            store.selection = [first.id]
        }

        if wants.contains("view"), let id = store.selection.first { await openInViewer(id) }
        if wants.contains("edit"), let id = store.selection.first { startEditing(id) }
        if wants.contains("slideshow") { startSlideshow() }
        if wants.contains("collage") { showCollage = true }
        if wants.contains("movie") { showMovie = true }
        if wants.contains("poster") { showPoster = true }
        if wants.contains("gallery") { showGalleryExport = true }
        if wants.contains("export") { showExport = true }
    }

    /// Hooks that a scripted verification needs but that do not take a command line.
    ///
    /// These used to sit at the tail of `applyLaunchArguments`, behind
    /// `guard !args.isEmpty else { return }`. A scripted run configures itself entirely through
    /// the environment and passes no arguments at all, so that guard returned first and every
    /// hook below it was dead on exactly the runs that needed it. They now run up front.
    ///
    /// Running up front means they can no longer lean on the argument handling to have waited for
    /// the scan, so the photo-dependent ones do their own waiting.
    func runScriptedHooks(hooks: [String: String]) async {
        let scripted = ["PICNIDO_VIEW", "PICNIDO_SCAN", "PICNIDO_SCAN_DUMP",
                        "PICNIDO_VIEWER_CYCLE", "PICNIDO_CLICK", "PICNIDO_SAVE_TEST"]
        guard scripted.contains(where: { hooks[$0] != nil }) else { return }

        // `PICNIDO_ROOTS` has already waited by this point if it was set. A run that gets its
        // photos from a saved library or a path argument has waited for nothing yet, so the
        // hooks that index into `store.photos` wait here instead.
        if hooks["PICNIDO_VIEW"] != nil || hooks["PICNIDO_VIEWER_CYCLE"] != nil {
            var waited = 0.0
            while store.photos.isEmpty {
                if waited > 30 { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
                waited += 0.2
            }
            if store.photos.isEmpty {
                PicnidoAppDelegate.report("[hooks] library still empty after \(Int(waited))s")
            }
        }
        // Scripted-verification hooks, same family as PICNIDO_SNAPSHOT / PICNIDO_ZOOM_TEST.
        if hooks["PICNIDO_VIEW"] != nil, let id = store.selection.first ?? store.visiblePhotos.first?.id {
            store.selection = [id]
            await openInViewer(id)
        }
        if hooks["PICNIDO_SCAN"] != nil { showScanFolders = true }

        // PICNIDO_SCAN_DUMP=<dir>: run the fd sweep headlessly, print the folder tree, exit.
        // Verifies the scan/tree without needing the sheet on screen.
        if let dump = hooks["PICNIDO_SCAN_DUMP"], !dump.isEmpty {
            let root = URL(fileURLWithPath: dump)
            let kb = Double(hooks["PICNIDO_SCAN_MIN_KB"] ?? "0") ?? 0
            let existing = Set(store.roots.map { $0.standardizedFileURL.path })
            let started = Date()
            let nodes = await Task.detached(priority: .userInitiated) {
                FolderScanner.scanTree(root: root, minBytes: Int64(kb * 1024), existingRoots: existing)
            }.value
            var text = "SCANDUMP root=\(dump)\nengine=\(FolderScanner.fdVersion() ?? "built-in")\n"
            text += "elapsed=\(String(format: "%.2f", Date().timeIntervalSince(started)))s\n"
            func walk(_ ns: [ScanNode], _ depth: Int) {
                for n in ns {
                    text += String(repeating: "    ", count: depth)
                        + "\(n.name) (\(n.totalCount))  own=\(n.ownCount)  \(n.sizeText)\n"
                    walk(n.children, depth + 1)
                }
            }
            walk(nodes, 0)
            PicnidoAppDelegate.report(text)
            exit(0)
        }

        // PICNIDO_SAVE_TEST=1: run "save in place" over the loaded library and report, per photo,
        // where the pixels actually landed.
        //
        // The interesting rows are the formats ImageIO reads but cannot write — every RAW, WebP,
        // AVIF and JPEG XL. Those must come out of a save with the original file byte-identical
        // and a `-edited.jpg` beside it. The bug this guards against left JPEG bytes inside a
        // file still named `.dng`, which then no longer decodes at all.
        if hooks["PICNIDO_SAVE_TEST"] != nil {
            var waited = 0.0
            while store.photos.isEmpty, waited < 30 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                waited += 0.2
            }
            var text = "SAVETEST photos=\(store.photos.count)\n"
            text += "  " + "source".padding(toLength: 18, withPad: " ", startingAt: 0)
                + "writable".padding(toLength: 12, withPad: " ", startingAt: 0)
                + "result\n"
            for photo in store.photos.prefix(24) {
                let before = photo.url
                let original = (try? Data(contentsOf: before))?.count ?? 0
                let writable = Exporter.writableType(forExtension: before.pathExtension)?.identifier
                do {
                    let written = try Exporter.saveInPlace(photo: photo, backupOriginals: false)
                    let inPlace = written.standardizedFileURL.path == before.standardizedFileURL.path
                    let after = (try? Data(contentsOf: written))?.count ?? 0
                    let readable = MetadataReader.read(url: written).pixelWidth > 0
                    text += "  \(before.lastPathComponent.padding(toLength: 18, withPad: " ", startingAt: 0))"
                        + (writable ?? "-").padding(toLength: 12, withPad: " ", startingAt: 0)
                        + "  -> \(written.lastPathComponent)"
                        + "  \(inPlace ? "IN PLACE" : "COPY")"
                        + "  bytes \(original) -> \(after)"
                        + "  reads=\(readable ? "yes" : "NO")\n"
                } catch {
                    text += "  \(before.lastPathComponent)  failed: \(error)\n"
                }
            }
            PicnidoAppDelegate.report(text)
            exit(0)
        }

        // PICNIDO_VIEWER_CYCLE=<n>: open and close the viewer n times, then report whether
        // the chrome survived. This is the regression test for "after opening and closing
        // the full-screen viewer a few times, the filmstrip stops coming back".
        if let raw = hooks["PICNIDO_VIEWER_CYCLE"], let cycles = Int(raw), cycles > 0,
           let id = store.visiblePhotos.first?.id {
            store.selection = [id]
            for _ in 0..<cycles {
                viewerID = id
                try? await Task.sleep(nanoseconds: 900_000_000)
                let wasOpen = await MainActor.run { ViewerHost.shared.isOpen }
                await MainActor.run { ViewerHost.shared.close() }
                viewerID = nil
                try? await Task.sleep(nanoseconds: 450_000_000)
                PicnidoAppDelegate.report("cycle: opened=\(wasOpen) windows=\(NSApp.windows.count)")
            }
            viewerID = id
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            PicnidoAppDelegate.report("""
            --- viewer cycle test ---
            cycles=\(cycles)
            viewerOpen=\(await MainActor.run { ViewerHost.shared.isOpen })
            viewerID=\(viewerID ?? "nil")
            windows=\(NSApp.windows.count)
            """)
            if let snap = hooks["PICNIDO_SNAPSHOT"] {
                PicnidoAppDelegate.snapshotAll(to: snap + "_aftercycle")
            }
        }

        // PICNIDO_CLICK="x,y;x,y": post synthetic left clicks at those window-relative
        // points (top-left origin) into the topmost sheet, snapshotting after each one.
        // `PICNIDO_CLICK_TARGET=viewer` aims them at the full-screen viewer panel instead.
        //
        // Why this exists: the scan tree's rows carry a row-wide tap gesture *and* a
        // borderless button for the disclosure triangle. A synthetic click is the only way
        // to prove the triangle actually wins the hit test rather than the row gesture
        // swallowing it — accessibility-driven clicking is not available here.
        //
        // The viewer target was added for the same reason. Its bottom hint line claims that
        // clicking anywhere outside the picture closes it, and a claim about what a pointer
        // does is only worth what a pointer test says it is worth. A *real* posted click is
        // not available on this machine: `CGPreflightPostEventAccess()` reads false, so
        // `CGEvent.post` is dropped silently (work/probe/clickat measured it — the panel never
        // reported a tap). Handing the event to the window directly takes the app's own
        // hit-testing path, which is enough to separate "the tap branch closed the viewer" from
        // "the tap branch did not".
        if let spec = hooks["PICNIDO_CLICK"], !spec.isEmpty {
            let gap = Double(hooks["PICNIDO_CLICK_DELAY"] ?? "0.7") ?? 0.7
            let snap = hooks["PICNIDO_SNAPSHOT"]
            try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))

            let visible = NSApp.windows.filter { $0.isVisible && $0.frame.width > 1 }
            let target: NSWindow?
            if hooks["PICNIDO_CLICK_TARGET"] == "viewer" {
                target = await ViewerHost.shared.nsWindow
            } else {
                target = visible.first(where: { String(describing: type(of: $0)).contains("Sheet") })
                    ?? visible.first(where: { $0 != NSApp.mainWindow && $0.frame.height <= 700 })
            }
            guard let sheet = target else {
                PicnidoAppDelegate.report("clicksheet: no sheet window found (windows=\(visible.map { "\(String(describing: type(of: $0))) \($0.frame.size)" }))")
                return
            }
            sheet.makeKey()
            let height = sheet.contentLayoutRect.height
            PicnidoAppDelegate.report("clicksheet: window=\(String(describing: type(of: sheet))) size=\(sheet.frame.size) contentHeight=\(height)")

            for (index, pair) in spec.split(separator: ";").enumerated() {
                let parts = pair.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard parts.count == 2 else { continue }
                let point = CGPoint(x: parts[0], y: height - parts[1])   // flip to bottom-left
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: sheet.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: 1) {
                        sheet.sendEvent(event)
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
                PicnidoAppDelegate.report("clicksheet: click \(index) at \(parts[0]),\(parts[1])")
                if let snap { PicnidoAppDelegate.snapshotAll(to: "\(snap)_click\(index)") }
            }
        }
    }
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case jpeg = "JPEG"
    case png = "PNG"
    case tiff = "TIFF"
    case original = "Original"
    var id: String { rawValue }
    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .tiff: return "tif"
        case .original: return "jpg"     // only reached if `matching` had nothing to go on
        }
    }

    /// The format that writes the same format the photo is already in — what "Original" has
    /// always claimed to do. Falls back to JPEG for the formats ImageIO can read but not write
    /// (every RAW, WebP, AVIF, JPEG XL), because the alternative is JPEG bytes in a file named
    /// `.dng`. Decided per photo, since a selection can mix formats.
    static func matching(_ sourceExtension: String) -> ExportFormat {
        guard let type = Exporter.writableType(forExtension: sourceExtension) else { return .jpeg }
        switch type.identifier {
        case UTType.png.identifier: return .png
        case UTType.tiff.identifier: return .tiff
        default: return .jpeg
        }
    }
}

enum TransitionKind: String, CaseIterable, Identifiable {
    case fade = "Fade"
    case crossFade = "Cross Fade"
    case slideLeft = "Slide Left"
    case slideRight = "Slide Right"
    case wipeUp = "Wipe Up"
    case kenBurns = "Ken Burns"
    case none = "None"
    var id: String { rawValue }
}

enum MovieResolution: String, CaseIterable, Identifiable {
    case sd480 = "480p"
    case hd720 = "720p"
    case hd1080 = "1080p"
    var id: String { rawValue }
    var size: CGSize {
        switch self {
        case .sd480: return CGSize(width: 854, height: 480)
        case .hd720: return CGSize(width: 1280, height: 720)
        case .hd1080: return CGSize(width: 1920, height: 1080)
        }
    }
}

enum CollageLayout: String, CaseIterable, Identifiable {
    case grid = "Grid"
    case picturePile = "Picture Pile"
    case mosaic = "Mosaic"
    case frame = "Frame"
    case multipleExposure = "Multiple Exposure"
    case contactSheet = "Contact Sheet"
    var id: String { rawValue }
}

enum CollageBackground: String, CaseIterable, Identifiable {
    case white = "White"
    case black = "Black"
    case gray = "Gray"
    case checkerboard = "Checkerboard"
    var id: String { rawValue }
    var color: NSColor {
        switch self {
        case .white: return .white
        case .black: return .black
        case .gray: return NSColor(white: 0.35, alpha: 1)
        case .checkerboard: return NSColor(white: 0.85, alpha: 1)
        }
    }
}

/// Lets SwiftUI reach the underlying NSWindow (used to force full screen / borderless chrome).
struct WindowAccessor: NSViewRepresentable {
    var onResolve: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            if let w = v.window { onResolve(w) }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let w = nsView.window { onResolve(w) }
        }
    }
}
