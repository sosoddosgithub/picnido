import SwiftUI
import AppKit

// Does a SwiftUI `WindowGroup` still build its window when the process is an accessory app
// (no Dock icon) from the very first moment of its life? This machine has already been bitten
// twice by scene-creation surprises on macOS 15.7.4, so the answer gets measured before the
// real app is changed. The window is faded out as soon as it is found so nothing flashes.

final class Probe: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        log("willFinishLaunching: policy -> accessory (\(NSApp.activationPolicy().rawValue))")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("didFinishLaunching: policy=\(NSApp.activationPolicy().rawValue) windows=\(NSApp.windows.count)")
        dump()
        for w in NSApp.windows where w.contentView != nil { w.alphaValue = 0 }   // no flash

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "photo",
                                            accessibilityDescription: "probe")
        statusItem?.button?.image?.isTemplate = true
        log("status item installed: \(statusItem != nil) visible=\(statusItem?.isVisible ?? false)")

        later(1.5) {
            self.log("t+1.5s windows=\(NSApp.windows.count)")
            self.dump()

            self.log("--- switching to .regular ---")
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)

            self.later(1.0) {
                self.log("after switch: policy=\(NSApp.activationPolicy().rawValue) active=\(NSApp.isActive) windows=\(NSApp.windows.count)")
                self.dump()

                self.log("--- switching back to .accessory ---")
                NSApp.setActivationPolicy(.accessory)
                self.later(0.8) {
                    self.log("back to accessory: policy=\(NSApp.activationPolicy().rawValue) windows=\(NSApp.windows.count)")
                    self.dump()
                    self.log("PROBE DONE")
                    exit(0)
                }
            }
        }
    }

    private func dump() {
        for (i, w) in NSApp.windows.enumerated() {
            log("  win[\(i)] class=\(type(of: w)) title=\"\(w.title)\" visible=\(w.isVisible) alpha=\(w.alphaValue) frame=\(w.frame)")
        }
    }

    private func later(_ t: TimeInterval, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: body)
    }

    private func log(_ s: String) { print("[probe] \(s)"); fflush(stdout) }
}

@main
struct ProbeApp: App {
    @NSApplicationDelegateAdaptor(Probe.self) var probe

    var body: some Scene {
        WindowGroup("Probe") {
            Text("library stand-in")
                .frame(width: 320, height: 200)
                .task { print("[probe] root view body evaluated"); fflush(stdout) }
        }
    }
}
