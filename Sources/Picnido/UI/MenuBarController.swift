import AppKit

/// The app's presence in the menu bar.
///
/// In picture mode the app runs as an accessory — `NSApp.setActivationPolicy(.accessory)` — which
/// is to say: no Dock icon, no Cmd-Tab entry. That is the whole point. The complaint this mode
/// exists to answer is the Dock icon appearing when a picture opened and vanishing when it closed,
/// so that opening and closing a handful of pictures in a row made the Dock flicker; an app with
/// no Dock icon cannot flicker one.
///
/// The cost of having no Dock icon is having no handle at all — no way to bring the library back
/// and no way to quit. This is that handle:
///
/// * **Left click** — opens the library window, which also leaves picture mode.
/// * **Right click** (or control-click) — drops a menu, whose "退出 Picnido" is the only way this
///   app can be quit from while it is an accessory. That is deliberate: the app no longer quits
///   itself, so quitting has to be something the user asks for by name.
@MainActor
final class MenuBarController: NSObject {

    static let shared = MenuBarController()

    private var item: NSStatusItem?
    private var menu: NSMenu?

    /// True while the glyph is in the menu bar. Library mode takes it away — the Dock icon is the
    /// handle there, and two handles for one app is one too many.
    var isShown: Bool { item != nil }

    // MARK: - Showing and hiding

    func show() {
        if let item {
            item.isVisible = true
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // The default behaviour is left alone deliberately: it is `.terminateOnRemoval`, i.e. no
        // ⌘-drag-to-remove. The icon is the only way into this app while it is an accessory and the
        // only way out of it, and `.removalAllowed` would hand someone a one-gesture route to an
        // app they can neither see nor quit.
        if let button = item.button {
            // A template image, so the glyph is drawn in the menu bar's own ink and follows the
            // light/dark treatment and the highlight colour the way every other status item does.
            let glyph = NSImage(systemSymbolName: "photo", accessibilityDescription: "Picnido")
            glyph?.isTemplate = true
            button.image = glyph
            button.toolTip = "Picnido — 左键打开图库，右键退出"
            button.target = self
            button.action = #selector(buttonClicked(_:))
            // Both mouse buttons have to reach the action, because the two of them mean different
            // things and the default is only the left one.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.item = item
        PicnidoAppDelegate.report("[menu-bar] status item shown")
    }

    func hide() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
        self.menu = nil
        PicnidoAppDelegate.report("[menu-bar] status item hidden")
    }

    // MARK: - Clicks

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        // `currentEvent` is how a status item tells a left click from a right one: the action is
        // the same selector for both, and nothing is passed in that says which it was.
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if secondary {
            popUpMenu(from: sender)
        } else {
            AppState.shared.showLibraryWindow()
        }
    }

    private func popUpMenu(from button: NSStatusBarButton) {
        let menu = self.menu ?? buildMenu()
        self.menu = menu
        // `popUp` rather than the usual "set `item.menu`, `performClick`, clear it" dance: that
        // idiom re-enters this button's own action, and there is nothing to gain from it here.
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 4),
                   in: button)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let open = NSMenuItem(title: "打开 Picnido 图库",
                              action: #selector(openLibrary),
                              keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Picnido",
                              action: #selector(quit),
                              keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func openLibrary() {
        AppState.shared.showLibraryWindow()
    }

    @objc private func quit() {
        PicnidoAppDelegate.report("[menu-bar] quit from the status item")
        NSApp.terminate(nil)
    }
}

/// Replaces what the library window's red button does.
///
/// The red button used to close the window for good. In this design closing it for good is the one
/// thing that must not happen: the window belongs to a SwiftUI `WindowGroup` scene, and once it is
/// really gone there is no supported way to ask for it back — `AppState.showLibraryWindow` can
/// only un-hide a window it still holds. Intercepting the button is also the gentler of the two
/// available hooks: taking over `NSWindow.delegate` would mean standing in front of SwiftUI's own
/// delegate, which this app has already learned not to do on this OS.
///
/// The button keeps its appearance and its place; only its action changes.
@MainActor
final class LibraryCloseButtonHook: NSObject {

    static let shared = LibraryCloseButtonHook()

    /// Points the window's red button at this object. Safe to call more than once for the same
    /// window — the target and action end up the same either way.
    func install(on window: NSWindow) {
        guard let close = window.standardWindowButton(.closeButton) else { return }
        guard close.target !== self else { return }
        close.target = self
        close.action = #selector(closePressed(_:))
        PicnidoAppDelegate.report("[mode] library close button re-pointed at the menu-bar path")
    }

    @objc private func closePressed(_ sender: Any?) {
        AppState.shared.dismissLibraryWindow()
    }
}
