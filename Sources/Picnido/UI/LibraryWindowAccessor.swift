import SwiftUI
import AppKit

/// The library window, reachable from outside SwiftUI.
///
/// The library window is a `WindowGroup` scene, so no code outside SwiftUI holds a reference to
/// it. Scanning `NSApp.windows` for it means guessing which window is which — the app also owns
/// the settings window and the viewer's `ViewerPanel`, and a guess that lands on the wrong one
/// orders the wrong window out. The accessor below sits inside the library window and reports
/// the exact `NSWindow` it was installed into, so there is nothing to guess.
@MainActor
enum LibraryWindow {

    /// The window the app treats as *the* library window.
    private(set) static weak var primary: NSWindow?

    /// Library windows SwiftUI built in addition to it.
    ///
    /// A `WindowGroup` scene is entitled to build another window whenever the system hands a
    /// document over, and this one does: measured from outside the process
    /// (`CGWindowListCopyWindowInfo`), opening a picture from the Finder left one library window,
    /// opening a second left two, a third left three — all of them the library size, cascaded 34
    /// points down and right, and all of them *visible*, which is the 「最后有多个 picnido 的窗口被
    /// 打开」report. The app manages one library, so a second window is never wanted.
    ///
    /// Closing it is safe in a way that ordering it out is not: the extras come from SwiftUI, and
    /// SwiftUI puts a scene's window back when it re-evaluates the scene, so hiding one only
    /// invites another. Closed, the scene has one window again and nothing left to restore.
    private static var extras: [NSWindow] = []

    /// How many extra library windows have been closed in this run. Diagnostics only.
    private(set) static var closedExtras = 0

    static var window: NSWindow? { primary }

    /// True when the library window is on screen *and* actually visible to someone.
    ///
    /// The alpha test is not a detail: a viewer-only launch hides the window by fading it to
    /// transparent rather than ordering it out (see `AppState.hideLibraryWindow`), and a window
    /// with `isVisible == true` and an alpha of zero is still "on screen" as far as AppKit is
    /// concerned while being invisible to the user.
    static var isVisible: Bool {
        guard let primary else { return false }
        return primary.isVisible && primary.alphaValue > 0
    }

    /// Takes over a window the library view has just been installed into.
    ///
    /// The first one becomes the library window; anything after that is a window SwiftUI built on
    /// top and is closed. Called from the marker's `viewDidMoveToWindow`, which runs while the
    /// window is still being assembled — earlier than `onAppear`, and early enough that closing an
    /// extra is not a visible event.
    static func adopt(_ window: NSWindow) {
        guard let current = primary, current !== window, current.isVisible else {
            primary = window
            return
        }
        extras.append(window)
        // Not closed inline: this runs in the middle of AppKit installing the view into the
        // window, and tearing a window down from there is asking for trouble. One run-loop turn
        // later the window is assembled and closing it is an ordinary operation.
        DispatchQueue.main.async {
            extras.removeAll { !$0.isVisible }
            guard window.isVisible else { return }
            window.close()
            closedExtras += 1
            PicnidoAppDelegate.report("[library] closed an extra library window: number=\(window.windowNumber) total=\(closedExtras)")
        }
    }
}

/// A zero-sized marker whose only job is to hand `LibraryWindow` the window it lives in.
struct LibraryWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Marker() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Marker: NSView {
        /// AppKit calls this when the view is put into (or taken out of) a window, which happens
        /// while the window is being assembled — earlier than `onAppear`, and early enough that
        /// ordering the window out afterwards is not a visible event.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            MainActor.assumeIsolated {
                // Claims the window for the library, closes it if SwiftUI built a second one, and
                // holds it back if the launch has not been classified yet or has been classified
                // as "showing a picture". All of that has to happen before the first frame is
                // drawn, which is why it lives here and not in `onAppear`.
                AppState.shared.windowRegistered(window)
            }
        }
    }
}
