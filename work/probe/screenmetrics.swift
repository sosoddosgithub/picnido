import AppKit

// Usage: swift screenmetrics.swift
//
// Prints the display geometry the viewer has to lay itself out against. Two of these numbers
// are not readable from inside the view tree at all, which is why this is a separate probe:
//
//   * the menu-bar band, i.e. `frame.maxY - visibleFrame.maxY` — the strip of the display the
//     viewer's panel covers but nothing may be drawn in, because the menu bar is composited
//     over it;
//   * `NSStatusBar.system.thickness` — the same band again, but as a constant. The two
//     disagree when the menu bar is set to auto-hide: `visibleFrame` then reports the whole
//     display (the menu bar *is* hidden right now) while the bar still slides back out the
//     moment the pointer reaches the top edge. `screen.frame` does not change for either, so
//     a view that lays out against `frame` is correct in the hidden case and clipped in the
//     visible one — the "关闭 button is half eaten" report.
//
// Screens are labelled LEFT/RIGHT by x position, the same way the user talks about them, so a
// verdict can be quoted without translating coordinates.

_ = NSApplication.shared

let screens = NSScreen.screens
let xs = screens.map(\.frame.minX).sorted()
let minX = xs.first, maxX = xs.last

func label(for screen: NSScreen) -> String {
    guard let minX, let maxX, minX != maxX else { return "ONLY" }
    if screen.frame.minX == minX { return "LEFT" }
    if screen.frame.maxX == maxX { return "RIGHT" }
    return "MIDDLE"
}

print("=== displays (\(screens.count)) ===")
for s in screens {
    let menuBand = s.frame.maxY - s.visibleFrame.maxY
    let dockBand = s.visibleFrame.minY - s.frame.minY
    print("""
    \(label(for: s))  \(s.localizedName)
      frame        \(s.frame)
      visibleFrame \(s.visibleFrame)
      backing      \(s.backingScaleFactor)x
      menu band    \(menuBand) pt   (frame.maxY - visibleFrame.maxY)
      dock band    \(dockBand) pt
      safeTop      \(s.safeAreaInsets.top) pt  (notch)
    """)
}

print("=== menu bar ===")
print("  NSStatusBar.system.thickness = \(NSStatusBar.system.thickness) pt")
print("  presentationOptions = \(NSApp.presentationOptions.rawValue)")
print("  自动隐藏菜单栏的当前设置 = \(UserDefaults.standard.string(forKey: "_HIHideMenuBar") ?? "未设置（默认 0）")")
