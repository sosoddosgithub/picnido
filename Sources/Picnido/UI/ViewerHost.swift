import SwiftUI
import AppKit

/// A borderless window that can actually take keyboard focus.
///
/// `.borderless` windows refuse `canBecomeKey` by default, which would silently kill every
/// keyboard shortcut in the viewer — the arrow keys, `Esc`, `+`/`-`. Overriding the two
/// flags is the whole reason this subclass exists.
final class ViewerPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The viewer's hosting view, with the automatic focus ring switched off for its whole subtree.
///
/// This is not cosmetic — it was the single largest cost in the viewer. AppKit's focus ring
/// works out *where* to draw by asking the focused view to describe its own shape, and it
/// derives that shape by rasterising the view into a bitmap and running `CGSRegionFromBitmap`
/// over it. Here the focused view is this one: a full-screen hosting view whose content is a
/// twelve-megapixel photo. `sample` caught the entire main thread inside
/// `_NSAutomaticFocusRing showForView:` for the whole four seconds of a drag, which is exactly
/// the "卡到很夸张" in the report — the run loop was spending milliseconds per pass computing a
/// focus ring nobody would ever see, because nothing in a full-screen photo panel is reachable
/// with the Tab key.
///
/// SwiftUI builds its view tree lazily, so a one-shot walk at open time would miss everything
/// created later; `didAddSubview` sets the same flag on each new child as it arrives.
final class FocusRingFreeHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var focusRingMaskBounds: NSRect { .zero }
    override func drawFocusRingMask() {}

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        subview.focusRingType = .none
    }

    /// Walks the tree that SwiftUI has built so far. Called again on every layout for the first
    /// few seconds of the window's life, when the tree is still growing.
    func disarmFocusRing() {
        func walk(_ view: NSView, depth: Int) {
            guard depth < 40 else { return }
            view.focusRingType = .none
            for sub in view.subviews { walk(sub, depth: depth + 1) }
        }
        walk(self, depth: 0)
    }
}

/// Owns the full-screen photo viewer window.
///
/// The viewer used to be a SwiftUI `Window` scene. That had two problems that could not be
/// papered over:
///
/// * **It opened at the scene's default size and then grew.** The window is ordered on
///   screen by SwiftUI before our `WindowAccessor` ever runs, so the viewer appeared as a
///   1400×900 window for a frame or two and then snapped to the screen. `setFrame` inside
///   the accessor only made the snap happen later, not disappear.
/// * **State survived close/reopen.** `dismissWindow` + `openWindow` can reuse the same
///   SwiftUI view identity, so `@State private var chromeVisible` came back as `false` and
///   the filmstrip was missing on reopen — it only returned if you happened to click the
///   photo. Opening and closing a few times in a row and "the filmstrip never comes back"
///   is exactly that bug.
///
/// Building the window by hand fixes both: it is created at the full screen frame and
/// ordered front once, and every open gets a brand-new hosting view, so every piece of
/// `@State` starts from scratch.
@MainActor
final class ViewerHost {

    static let shared = ViewerHost()

    private var window: ViewerPanel?
    private var glass: NSVisualEffectView?
    private var monitor: Any?

    /// The display the next open should land on because that is where the picture came from.
    ///
    /// Lives here rather than being read at window-build time for a reason: the window is created
    /// after an ImageIO header read on a background thread, and by then the pointer can be
    /// anywhere. `noteOpenOrigin()` is called the instant the file arrives — while the cursor is
    /// still sitting on the icon that was double-clicked — and this holds that answer until the
    /// window is actually built.
    private var pendingScreen: NSScreen?

    /// Set by the viewer while it is on screen.
    ///
    /// The wheel monitor has to live out here rather than in the view: an `NSEvent` monitor
    /// handed back to AppKit is retained until it is explicitly removed, so a monitor owned
    /// by the view keeps that view's state — and through it the window — alive for ever.
    /// That leaked one borderless window per open/close cycle (NSApp.windows went 3 → 4 → 5
    /// → 6 → 7 over five cycles). The view registers a plain closure instead, and closing
    /// drops it.
    var scrollHandler: ((NSEvent) -> Bool)?

    var isOpen: Bool { window != nil }

    /// The window the scroll monitor and the geometry diagnostics talk to.
    var nsWindow: NSWindow? { window }

    func show(app: AppState) {
        let target = resolveTargetScreen()

        if let window {
            // A session that arrived from another display takes the viewer with it. The panel is a
            // single full-screen window, so "show the picture on the screen it was opened from"
            // can only mean moving this one — and with two displays the user can see the Finder on
            // one of them while the viewer covers the other, so this is a real sequence, not a
            // contrived one. Same-screen opens are left alone, so paging through a set never
            // nudges the window.
            if let target, window.screen?.frame != target.frame {
                PicnidoAppDelegate.report("[viewer] moving to \(target.localizedName) — opened from there")
                window.setFrame(target.frame, display: true)
                window.contentView?.superview?.layoutSubtreeIfNeeded()
            }
            window.makeKeyAndOrderFront(nil)
            return
        }

        // Full screen on the display the picture was opened from — or, when it came from inside
        // the app, the one the library window is on. On a two-monitor desk those are not always
        // the same thing, and putting a full-screen viewer on the screen the user is not looking
        // at is worse than useless. See `resolveTargetScreen` for the order of preference.
        let screen = target
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let panel = ViewerPanel(contentRect: frame,
                                styleMask: [.borderless],
                                backing: .buffered,
                                defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none          // no fade/scale-in — the viewer just appears
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.styleMask.insert(.fullSizeContentView)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }

        // Auto-hiding the menu bar and Dock makes `visibleFrame` cover the display, so the
        // glass really does reach every edge. Restored in `close()`.
        NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]

        // Built by hand, so this view gets exactly the environment given here — no scene is
        // involved and nothing else can supply the locale. Without `.interfaceLanguage` the
        // viewer's own chrome comes up in the machine's language while the library behind it is
        // in the chosen one; the strings that go through `localizedString` are right either way,
        // which is what makes it look like a partial translation rather than a missing modifier.
        let host = FocusRingFreeHostingView(
            rootView: ViewerWindow(menuBand: Self.menuBand(of: screen))
                .environment(app)
                .interfaceLanguage(app.language))
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        // The SwiftUI tree is still being built at this point, so sweep a few times over the
        // first second as well rather than trusting a single pass.
        for delay in [0.0, 0.15, 0.5, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak host] in
                host?.disarmFocusRing()
            }
        }

        installGlass(on: panel, host: host)
        panel.setFrame(frame, display: true)
        window = panel
        installMonitor()

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        // Only now is the library window taken down, and only while the app is in picture mode.
        // Doing it earlier left an instant in which the app had no visible window — the library
        // gone, the viewer not yet up — and AppKit reads that instant as a request to reopen, which
        // brought the library window straight back behind the viewer. Measured, not assumed: with
        // the order-out on the other side of this line, the log showed the library window visible
        // again ("window[0] ... visible=true") while the viewer was up.
        app.hideLibraryWindowIfPictureMode()

        if ProcessInfo.processInfo.environment["PICNIDO_WINDOW_REPORT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak panel] in
                guard let panel else { return }
                PicnidoAppDelegate.report("""
                --- viewer window report ---
                isOpaque=\(panel.isOpaque)
                backgroundColor alpha=\(panel.backgroundColor.alphaComponent)
                visualEffectViews=\(panel.contentView?.superview?.subviews.filter { $0 is NSVisualEffectView }.count ?? -1)
                frame=\(panel.frame) screen=\(String(describing: panel.screen?.frame))
                level=\(panel.level.rawValue)
                canBecomeKey=\(panel.canBecomeKey)
                """)
            }
        }
    }

    // MARK: - Which display an open belongs on

    /// The strip at the top of a display that the menu bar is composited over.
    ///
    /// The panel is built at `screen.frame`, so it reaches the physical top edge of the display
    /// and the menu bar is drawn on top of the first few points of it. Nothing the viewer puts
    /// there can be seen — the Close button and the file name were laid out at y=14 and the menu
    /// bar covers 0…25, which is the "左上角那一行显示不完全" report.
    ///
    /// `frame.maxY - visibleFrame.maxY` is exact while the menu bar is showing and 0 while it is
    /// set to auto-hide — but an auto-hidden menu bar still slides back out the moment the pointer
    /// reaches the top edge, so a reserve of 0 is wrong half the time and wrong at the worst
    /// moment. `NSStatusBar.system.thickness` is the one number that holds in both states, so the
    /// reserve is the larger of the two. Measured on this desk: 25 and 22 -> 25.
    static func menuBand(of screen: NSScreen?) -> CGFloat {
        guard let screen else { return NSStatusBar.system.thickness }
        let showing = screen.frame.maxY - screen.visibleFrame.maxY
        return max(showing, NSStatusBar.system.thickness)
    }

    /// Remembers the display the pointer is on, for the open that is about to happen.
    ///
    /// Called the moment a file is handed over by the Finder, before anything asynchronous gets a
    /// chance to run. The cursor at that instant is the only trustworthy statement of "this picture
    /// came from that screen": Finder keeps its window frames to itself without an Accessibility
    /// grant, and the file path says nothing about geometry. Double-clicking an icon in a folder on
    /// the right-hand display puts the cursor over that display, which is exactly the fact needed.
    ///
    /// If the pointer is in the seam between two displays of unequal height — the region below the
    /// shorter one belongs to no screen — the answer is simply "unknown", and the next source down
    /// in `resolveTargetScreen` decides.
    func noteOpenOrigin() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
        pendingScreen = screen
        let where_ = screen.map { "\($0.localizedName) \($0.frame)" } ?? "no display (pointer in a seam)"
        PicnidoAppDelegate.report("[viewer] open origin <- cursor \(Int(mouse.x)),\(Int(mouse.y)) -> \(where_)")
    }

    /// Forgets any remembered origin. Used by opens that came from inside the app, so a value left
    /// over from an outside open cannot hijack a library double-click that follows it.
    func dropOpenOrigin() {
        guard pendingScreen != nil else { return }
        pendingScreen = nil
        PicnidoAppDelegate.report("[viewer] open origin dropped (open came from inside the app)")
    }

    /// The display the viewer should occupy, in order of authority.
    ///
    /// 1. **`PICNIDO_SCREEN`** — the development hook, so scripted runs and screenshots land on a
    ///    chosen panel no matter where the pointer happens to be. It outranks the real answer on
    ///    purpose: a script that has just clicked something has no opinion anyone wants.
    /// 2. **The display the picture was opened from** (`noteOpenOrigin`) — the answer to "my photos
    ///    folder lives on the right-hand screen".
    /// 3. **The library window's display** — for opens that started inside the app, where the
    ///    window the user is working in is the right anchor.
    ///
    /// `NSScreen.main` is the last resort, not the first. It reports "the screen holding the window
    /// with keyboard focus", and an accessory app whose only window is a photo panel has no such
    /// window — which is how this used to end up on whichever display was left over.
    private func resolveTargetScreen() -> NSScreen? {
        if let forced = PicnidoAppDelegate.preferredScreen() { return forced }
        if let pending = pendingScreen {
            pendingScreen = nil
            return pending
        }
        if let anchor = ([NSApp.mainWindow] + NSApp.windows).compactMap({ $0 }).first(where: isAnchor) {
            return anchor.screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Whether a window may say which display an open belongs on.
    ///
    /// `isVisible` alone is not enough, and that is the whole bug this fixes: picture mode fades the
    /// library window to alpha 0 rather than ordering it out, so it reports itself visible while
    /// nobody can see it — and as the only "visible" window it became the anchor for every picture
    /// opened from the Finder, dragging the viewer onto the library window's display. A window
    /// nobody can see and nobody can click has no business choosing a screen.
    private func isAnchor(_ candidate: NSWindow) -> Bool {
        guard candidate.isVisible, candidate.alphaValue > 0, !candidate.ignoresMouseEvents else { return false }
        return !(candidate is ViewerPanel)
    }

    func close() {
        guard let panel = window else { return }
        window = nil
        glass = nil
        scrollHandler = nil
        removeMonitor()
        NSApp.presentationOptions = []
        panel.contentView = nil
        panel.close()
    }

    /// Re-fits the window to the current screen — cheap insurance for display changes.
    func refit() {
        guard let panel = window, let screen = panel.screen ?? NSScreen.main else { return }
        panel.setFrame(screen.frame, display: true)
    }

    // MARK: - Wheel monitor

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let panel = self.window, panel.isVisible,
                  let handler = self.scrollHandler else { return event }
            // Only claim the wheel when this viewer is the window in play.
            guard event.window === panel || NSApp.keyWindow === panel else { return event }
            // The filmstrip scrolls horizontally on its own — leave it alone.
            if event.window === panel,
               event.locationInWindow.y < FilmstripView.interactionZone { return event }
            return handler(event) ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// The behind-window blur is a sibling *below* the SwiftUI hosting view.
    ///
    /// It cannot live in the SwiftUI tree: `NSVisualEffectView` is an AppKit subview, and
    /// AppKit subviews always draw above the hosting view's own content, so putting it in
    /// the ZStack hid the filmstrip and the buttons instead of sitting behind the photo.
    private func installGlass(on panel: NSWindow, host: NSView) {
        let parent = panel.contentView?.superview ?? host.superview ?? panel.contentView
        guard let parent else { return }
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        blur.frame = parent.bounds
        parent.addSubview(blur, positioned: .below, relativeTo: host)
        glass = blur
    }
}
