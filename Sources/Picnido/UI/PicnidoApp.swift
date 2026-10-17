import SwiftUI
import AppKit

/// AppKit-side hooks: activation plus the drag-and-drop / "Open With" file events.
final class PicnidoAppDelegate: NSObject, NSApplicationDelegate {

    /// Starts as an accessory: no Dock icon, no Cmd-Tab entry.
    ///
    /// The question "is this run about a picture or about the library?" cannot be asked here — the
    /// picture arrives at the very end of `finishLaunching`, and nothing before that says whether
    /// one is coming (see `AppState.noteExternalPicture`). So the process starts with no Dock
    /// presence at all, and an ordinary launch puts one back in `applicationDidFinishLaunching` at
    /// the moment that icon has always appeared. A picture launch never gets one, not even for the
    /// fraction of a second between the process starting and the file arriving — small, but it
    /// happens on every single picture, and that is the flicker being complained about.
    func applicationWillFinishLaunching(_ notification: Notification) {
        // First, and before anything can open a catalogue or a thumbnail store: take over the
        // directories the app used under its former name, so a rename does not read to the user
        // as "all my folders are gone". See LegacyAdoption.
        LegacyAdoption.run()
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Which of the app's two faces this run wears. A picture that claimed the launch has already
        // asked for picture mode — `noteExternalPicture` runs during `finishLaunching`, before this
        // method — so anything still in library mode really is a library launch.
        if MainActor.assumeIsolated({ AppState.shared.isPictureMode }) {
            MainActor.assumeIsolated { AppState.shared.enterPictureMode() }
        } else {
            MainActor.assumeIsolated { AppState.shared.enterLibraryMode() }
        }

        // Decides whether the library window may be shown yet, and arms the launch window that a
        // picture can claim while it lasts. See `AppState.beginLaunchWindow`.
        //
        // NOTE — do not be tempted to classify the launch by installing a handler for
        // `kAEOpenApplication` instead. That was tried, and measured: taking that event over
        // stopped SwiftUI from opening the library window at all on macOS 15.7.4 (app runs,
        // library loads, `NSApp.windows` empty, and it stays empty — see the comparison in
        // CHANGELOG 1.1.3). The unclaimed event is load-bearing for the scene system.
        MainActor.assumeIsolated { AppState.shared.beginLaunchWindow() }

        // Dev hook: render the main window straight to a PNG (no screen-recording needed).
        // Read through `DevHook` so a run started by `open` — the only kind that reproduces a
        // Finder double-click — can be told to take one.
        if let out = DevHook.string("PICNIDO_SNAPSHOT") {
            let delay = DevHook.double("PICNIDO_SNAPSHOT_DELAY") ?? 10
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                PicnidoAppDelegate.snapshotAll(to: out)
            }
        }

        // PICNIDO_SHOW_SETTINGS is handled in AppState.applyLaunchArguments — it needs the
        // `openSettingsAction` captured from the view tree, which does not exist yet here.
    }

    /// Optional second sink for `report`, enabled by `PICNIDO_REPORT_FILE=<path>`.
    ///
    /// `open --stderr` is silently ignored as soon as a document argument is also passed, so a
    /// run that most needs the log — a LaunchServices launch carrying a picture, which is the
    /// Finder "Open With" path — is exactly the one that leaves no trace at all. Verified by
    /// isolation: launching with `--stderr` alone works, launching with a file alone works,
    /// and the two together produce a process with no log file.
    ///
    /// That run cannot carry the variable either, which is why the value comes through `DevHook`
    /// and can be left in a file instead. Development aid only.
    private static let reportSink: FileHandle? = {
        guard let path = DevHook.string("PICNIDO_REPORT_FILE") else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    /// Writes a line to stderr — visible in the captured run log — and to `PICNIDO_REPORT_FILE`
    /// when one was asked for.
    static func report(_ text: String) {
        let data = (text + "\n").data(using: .utf8) ?? Data()
        FileHandle.standardError.write(data)
        try? reportSink?.write(contentsOf: data)
    }

    /// The display `PICNIDO_SCREEN` asks for, if any. `left` / `right` pick by position, anything
    /// else matches the display's name (`PICNIDO_SCREEN=U2719D`).
    ///
    /// This machine drives two 4K panels side by side and the right-hand one is in use, so
    /// scripted runs and screenshots move themselves onto the left-hand panel instead of
    /// appearing in the middle of someone's work. Shared with `ViewerHost` on purpose: a
    /// full-screen viewer that ignored it would land on the display the *library* window is on
    /// and cover the wrong screen entirely.
    static func preferredScreen() -> NSScreen? {
        guard let want = ProcessInfo.processInfo.environment["PICNIDO_SCREEN"], !want.isEmpty else { return nil }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        switch want.lowercased() {
        case "left":  return screens.min { $0.frame.minX < $1.frame.minX }
        case "right": return screens.max { $0.frame.minX < $1.frame.minX }
        default:      return screens.first { $0.localizedName.localizedCaseInsensitiveContains(want) }
        }
    }

    static func snapshotAll(to path: String) {
        var lines: [String] = []
        for (i, window) in NSApp.windows.enumerated() {
            let view = window.contentView
            let bounds = view?.bounds ?? .zero
            PicnidoAppDelegate.report("window[\(i)] number=\(window.windowNumber) title=\"\(window.title)\" class=\(type(of: window)) bounds=\(bounds) visible=\(window.isVisible) alpha=\(window.alphaValue) screen=\(String(describing: window.screen != nil))")
            guard let view, view.bounds.width > 120, view.bounds.height > 120 else { continue }

            // Skip hidden windows. They have nothing to show, and `cacheDisplay` on an
            // off-screen internal window (the `TUINSWindow` AppKit keeps around for text
            // input) raised an Auto Layout NSException that took the whole process down —
            // which cost us every snapshot after the first one in a scripted run.
            guard window.isVisible else { continue }

            // Ask the window server for the composited pixels first — `cacheDisplay` alone
            // cannot reproduce CoreImage blurs or NSVisualEffectView vibrancy.
            var data: Data?
            if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                CGWindowID(window.windowNumber),
                                                [.boundsIgnoreFraming, .bestResolution]) {
                data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            }
            if data == nil, DevHook.isSet("PICNIDO_SNAPSHOT_DISPLAY"),
               let rep = view.bitmapImageRepForCachingDisplay(in: bounds) {
                view.cacheDisplay(in: bounds, to: rep)
                data = rep.representation(using: .png, properties: [:])
            }
            guard let data else { continue }

            let safe = window.title.isEmpty ? "win" : window.title.replacingOccurrences(of: "/", with: "_")
            let out = "\(path)_\(i)_\(safe).png"
            try? data.write(to: URL(fileURLWithPath: out))
            lines.append("\(i)\t\"\(window.title)\"\t\(Int(bounds.width))x\(Int(bounds.height))\t\(out)")

            // Second opinion: ask AppKit to draw the view tree itself. This cannot reproduce
            // vibrancy, but it *does* show every SwiftUI layer, so comparing the two tells a
            // window-server compositing problem apart from a layout problem.
            if DevHook.isSet("PICNIDO_SNAPSHOT_DISPLAY"),
               let rep = view.bitmapImageRepForCachingDisplay(in: bounds) {
                view.cacheDisplay(in: bounds, to: rep)
                if let d2 = rep.representation(using: .png, properties: [:]) {
                    try? d2.write(to: URL(fileURLWithPath: out.replacingOccurrences(of: ".png", with: "_display.png")))
                }
            }
        }
        if lines.isEmpty { lines.append("no windows captured") }
        try? lines.joined(separator: "\n").write(toFile: path + ".list", atomically: true, encoding: .utf8)
    }

    /// A folder is a library root; a picture is a viewer session. The decision lives in
    /// `AppState.importPaths` so the command line and the environment override take the same
    /// route — see the note there for why a picture must not be filed.
    ///
    /// `external: true` is what distinguishes this from our own `PICNIDO_OPEN` hook: only a
    /// document handed over by the system may reinterpret the launch as "just showing a picture".
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        AppState.shared.importPaths(filenames, external: true)
        sender.reply(toOpenOrPrint: .success)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        AppState.shared.importPaths(urls.map(\.path), external: true)
    }

    /// The Dock icon. After a viewer-only launch the library window is off screen, so this is how
    /// it comes back — and asking for it also ends viewer-only mode, so closing the next viewer
    /// will not quit the app out from under someone who is now using the library.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let app = MainActor.assumeIsolated { AppState.shared }
        // Before the launch has settled, silence. AppKit sends this in the instant where one window
        // has just gone and the next is not yet up — which, during a picture launch, is the instant
        // the library window is being taken off screen. Answering that with the library window is
        // precisely the behaviour this version exists to remove.
        guard app.isLaunchSettled else { return true }
        // `flag` cannot be the test here, and that is worth spelling out: picture mode hides the
        // library window by fading it rather than ordering it out (see `AppState.hideLibraryWindow`),
        // so AppKit counts it as visible and `flag` comes back true even when there is nothing on
        // screen. Mode is what actually distinguishes the two cases.
        if !flag || app.isPictureMode { app.showLibraryWindow() }
        return true
    }

    /// The app outlives its last window.
    ///
    /// Closing the library window steps the app back to the menu bar rather than ending it, and the
    /// library window is not really closed at all — `AppState.dismissLibraryWindow` fades it out so
    /// it can come straight back. Answering `true` here would let AppKit end the process the moment
    /// that window went away, which is exactly the behaviour this design exists to remove.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// The viewer auto-hides the menu bar and Dock while it is up. Make sure that is undone
    /// even if the app is quit from the Dock or with ⌘Q while the viewer is still open.
    func applicationWillTerminate(_ notification: Notification) {
        NSApp.presentationOptions = []
    }
}

@main
struct PicnidoApp: App {

    @NSApplicationDelegateAdaptor(PicnidoAppDelegate.self) private var appDelegate
    @State private var app = AppState.shared

    /// Puts the shared state and the chosen interface language into a scene's environment.
    ///
    /// The language belongs here rather than being written to `AppleLanguages` because of *when*
    /// it has to take effect. `AppleLanguages` is read by the frameworks when a bundle is first
    /// asked for a string and cached from then on, so the change would land at the next launch —
    /// and a Settings picker that only takes effect after a relaunch is a picker that has to
    /// explain itself. SwiftUI instead resolves `Text("…")` against the environment's locale, so
    /// putting the locale here re-resolves every string the moment `app.language` changes, and the
    /// window redraws in the new language on the next frame.
    ///
    /// Applied to every scene, not just the library window: the Settings window is where the
    /// picker lives, and a picker that changes everything except the window it is in would be
    /// worse than one that changes nothing.
    private struct AppEnvironment: ViewModifier {
        let app: AppState

        func body(content: Content) -> some View {
            content
                .environment(app)
                .environment(\.locale, app.language.locale)
        }
    }

    var body: some Scene {
        // `WindowGroup`, not `Window`, and for a measured reason. A single-window `Window` scene
        // does stop the extra windows described in `LibraryWindow.adopt` — but on macOS 15.7.4 it
        // sometimes does not create its window at all: the process runs, SwiftUI builds the
        // library behind the scenes (`[library] catalogue gave 1097 photos`), and `NSApp.windows`
        // is *empty*. The app then has no way to show a library at all, which is far worse than
        // one window too many. So the scene stays as it was, and the extra windows are closed as
        // they appear instead.
        WindowGroup("Picnido") {
            rootContent
                .onAppear(perform: configureWindow)
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands { menuCommands }

        // The Photo Viewer is presented by `ViewerHost`, not by this scene — a scene is
        // ordered on screen at its default size before any of our code can touch it, which
        // made the full-screen viewer visibly grow from 1400x900 on every open, and
        // `dismissWindow`/`openWindow` could reuse the view identity so the chrome came
        // back hidden. `ViewerHost` builds the window by hand instead: full screen from the
        // first frame, fresh state on every open.
        //
        // NOTE: the scene has to stay declared anyway. Deleting it made SwiftUI create *no*
        // windows at all on this OS — process alive, delegate running, `NSApp.windows`
        // empty, not even the library window. (The same family of bug as the one documented
        // on `rootContent`.) It is never opened; it only keeps the scene graph intact.
        Window("Photo Viewer (unused)", id: "viewer") {
            ViewerWindow()
                .modifier(AppEnvironment(app: app))
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1400, height: 900)

        Window("Slideshow", id: "slideshow") {
            SlideshowWindow()
                .modifier(AppEnvironment(app: app))
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1400, height: 900)

        Settings {
            SettingsView()
                .modifier(AppEnvironment(app: app))
                // Wide enough for the File Types tab's two-column checkbox grid, tall enough
                // that its handler table does not need the scroll view's own scrollbar.
                .frame(width: 660, height: 560)
        }
    }

    /// The library window root.
    ///
    /// NOTE: keep this as a separate `@ViewBuilder` property rather than inlining the
    /// chain straight into the `WindowGroup` closure. Inlining it made SwiftUI skip
    /// window creation entirely on macOS 15 (process alive, but `MainWindow.body` was
    /// never evaluated and no NSWindow was ever ordered on screen).
    @ViewBuilder
    private var rootContent: some View {
        MainWindow()
            .modifier(AppEnvironment(app: app))
            .frame(minWidth: 1060, minHeight: 680)
            .task { await app.applyLaunchArguments() }
    }

    private func configureWindow() {
        DispatchQueue.main.async {
            // Picture mode owns the activation policy, and it is not `.regular`: the window this
            // runs inside is the one being kept out of sight, so pushing the app back into the Dock
            // from here would undo the whole arrangement. `enterLibraryMode` also activates, which
            // is why there is no separate `activate` call — activating an app with no visible
            // window is the other half of the reopen problem described on
            // `applicationShouldHandleReopen`.
            if !AppState.shared.isPictureMode { AppState.shared.enterLibraryMode() }
            Self.placeOnPreferredScreen()
        }
        // The frame can still be settled by AppKit a frame or two after `onAppear`, so the
        // placement is re-asserted once the window has definitely landed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { Self.placeOnPreferredScreen() }
    }

    /// Development hook: put the library window on a chosen display.
    ///
    /// `PICNIDO_WINDOW_SIZE=1060x680` overrides the size, which is what makes it possible to
    /// verify a layout at the window's *minimum* rather than at whatever the display happens to
    /// allow. The minimum is where a layout breaks if it is going to — a bar that fits at 1680
    /// points can still overflow at 1060 — and a scripted run cannot drag a window edge.
    static func placeOnPreferredScreen() {
        let env = ProcessInfo.processInfo.environment
        let want = env["PICNIDO_SCREEN"] ?? ""
        guard let window = NSApp.windows.first(where: { $0.isVisible && !($0 is ViewerPanel) }) else { return }

        // Size first, and independently of the display lookup. The window restores whatever frame
        // it was last left at, which for a scripted run is a frame nobody chose — and the point of
        // a size override is to see a layout at a size the display happens not to produce, such as
        // the 1060x680 minimum where a bar that fits at 1680 points starts to overflow.
        var size: NSSize?
        if let spec = env["PICNIDO_WINDOW_SIZE"] {
            let parts = spec.lowercased().split(separator: "x")
            if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 {
                size = NSSize(width: w, height: h)
            } else {
                PicnidoAppDelegate.report("[screen] PICNIDO_WINDOW_SIZE='\(spec)' is not WxH — ignored")
            }
        }

        guard let screen = PicnidoAppDelegate.preferredScreen() else {
            if let size {
                var frame = window.frame
                frame.size = size
                window.setFrame(frame, display: true)
                PicnidoAppDelegate.report("[screen] main window sized to \(Int(size.width))x\(Int(size.height)), display unchanged")
            } else if !want.isEmpty {
                PicnidoAppDelegate.report("[screen] no display matched '\(want)' among \(NSScreen.screens.map(\.localizedName))")
            }
            return
        }

        let visible = screen.visibleFrame
        let width = size?.width ?? min(visible.width - 120, 1680)
        let height = size?.height ?? min(visible.height - 120, 1050)
        let frame = NSRect(x: visible.midX - width / 2,
                           y: visible.midY - height / 2,
                           width: width, height: height)
        window.setFrame(frame, display: true)
        PicnidoAppDelegate.report("[screen] main window -> \(screen.localizedName) \(Int(visible.width))x\(Int(visible.height)) at \(frame)")
    }

    @CommandsBuilder
    private var menuCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Find Photo Folders…") { app.showScanFolders = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button("Import Folder…") { importFolder(app) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Import from Camera…") { importFolder(app) }
            Divider()
            Button("Rename Files…") { app.showRename = true }
                // `KeyEquivalent` ships no function-key constants, but NSF2FunctionKey is 0xF705
                // and that is the key the original bound rename to. Spelled out rather than
                // dropped, so muscle memory from the Windows app still works.
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(0xF705)!)), modifiers: [])
                .disabled(app.store.selection.isEmpty)
            Button("Adjust Photo Date…") { app.showAdjustDate = true }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(app.store.selection.isEmpty)
        }

        CommandGroup(after: .saveItem) {
            Button("Export…") { app.showExport = true }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Export as HTML Gallery…") { app.showGalleryExport = true }
            Button("Back Up…") { app.showBackup = true }
            Divider()
            Button("Print…") { app.showPrint = true }
                .keyboardShortcut("p", modifiers: .command)
        }

        CommandGroup(after: .undoRedo) {
            Button("Undo Edit") {
                if let id = app.editingID ?? app.store.selection.first { app.store.undo(id) }
            }
            .keyboardShortcut("z", modifiers: .command)
            Button("Redo Edit") {
                if let id = app.editingID ?? app.store.selection.first { app.store.redo(id) }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            Divider()
            // The batch workflow the original led with: get one photo right, put those effects
            // on the rest. It lives in Edit because that is where a user who has just finished
            // editing one photo goes looking for "now do that to the others".
            Button("Copy All Effects") {
                if let photo = app.editingPhoto ?? app.store.selection.first.flatMap({ app.store.photo($0) }) {
                    app.copyAllEffects(from: photo)
                }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled((app.editingPhoto ?? app.store.selection.first.flatMap { app.store.photo($0) })
                        .map { AppState.transferableSteps(of: $0).isEmpty } ?? true)
            Button("Paste All Effects") { app.pasteAllEffects(on: app.batchTargets) }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(app.copiedEffects == nil || app.batchTargets.isEmpty)
            Divider()
            Button("Hide Photo") { app.store.setHidden(true, ids: app.batchTargets) }
                .keyboardShortcut("h", modifiers: [.command, .option])
                .disabled(app.batchTargets.isEmpty)
            Button("Show Hidden") {
                app.store.showHidden.toggle()
                if !app.store.showHidden, app.store.view == .hidden { app.store.view = .allPhotos }
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            Divider()
            Button("Find…") { app.focusSearchRequest += 1 }
                .keyboardShortcut("f", modifiers: .command)
        }

        CommandMenu("View") {
            Button("Library") { app.returnToLibrary() }
                .keyboardShortcut("1", modifiers: .command)
            Button("Edit Photo") {
                if let id = app.store.selection.first { app.startEditing(id) }
            }
            .keyboardShortcut("2", modifiers: .command)
            Button("Photo Viewer") {
                if let id = app.store.selection.first { app.openInViewer(id) }
            }
            .keyboardShortcut(.return, modifiers: .command)
            Divider()
            Menu("Thumbnail Caption") {
                ForEach(CaptionMode.allCases) { mode in
                    Button(localizedString(mode.rawValue)) { app.captionMode = mode }
                }
            }
            Toggle("Show Hidden", isOn: Binding(
                get: { app.store.showHidden },
                set: { app.store.showHidden = $0 }))
            Divider()
            Toggle("Show Info Panel", isOn: Binding(
                get: { app.infoPaneVisible },
                set: { app.infoPaneVisible = $0 }))
            if app.store.hasDateFilter {
                Button("Clear Date Filter") {
                    app.store.dateFrom = nil
                    app.store.dateTo = nil
                }
            }
            Divider()
            Button("Slideshow") { app.startSlideshow() }
            Button("Collage…") { app.showCollage = true }
            Button("Movie…") { app.showMovie = true }
            Button("Poster…") { app.showPoster = true }
        }

        CommandMenu("Tools") {
            Button("Add Starred to Tray") {
                app.store.addToTray(app.store.visiblePhotos.filter { $0.starred }.map { $0.id })
            }
            Button("Batch Edit Selection…") { app.editTab = .effects }
            Button("Empty Tray") { app.store.clearTray() }
            Divider()
            // A duplicate finder belongs under the batch actions, not up with the file commands.
            Button("Show Duplicate Files") { app.showDuplicates = true }
            Divider()
            Button("Keyboard Shortcuts") { app.showShortcuts = true }
                .keyboardShortcut("/", modifiers: .command)
            // `SettingsLink`, not a button that flips a flag: the flag was never bound to any
            // view, so the old `Button { app.showSettings = true }` did exactly nothing.
            SettingsLink { Text("Preferences…") }
                .keyboardShortcut(",", modifiers: .command)
        }
    }

    private func importFolder(_ app: AppState) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.message = "Choose a folder to add to the Picnido Library"
        if panel.runModal() == .OK {
            for url in panel.urls { app.store.addRoot(url) }
        }
    }
}
