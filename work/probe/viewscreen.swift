import AppKit
import CoreGraphics

// Usage: viewscreen [bundle-id]
//
// Answers "which display is the picture viewer covering?" from outside the process, which is the
// only place the question can be answered honestly — the app's own belief about where it put the
// window is exactly what is under test.
//
// Window bounds from `CGWindowListCopyWindowInfo` are CoreGraphics global coordinates (origin at
// the primary display's top-left, y downwards); NSScreen frames are AppKit coordinates (y upwards).
// The window's centre is flipped into AppKit space and matched against the screen frames, so the
// verdict is a real geometric containment test rather than a comparison of hand-picked numbers.

let bundleID = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "app.picnido.mac"

_ = NSApplication.shared
let screens = NSScreen.screens
guard let primary = screens.first(where: { $0.frame.origin == .zero }) ?? screens.first else {
    print("no displays"); exit(1)
}

let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleID }
guard let app = apps.first else { print("\(bundleID): 未在运行"); exit(1) }

// Label the displays by position so the report reads the same way the user talks about them.
func label(for screen: NSScreen) -> String {
    let xs = screens.map(\.frame.minX).sorted()
    if let minX = xs.first, let maxX = xs.last, minX != maxX {
        if screen.frame.minX == minX { return "LEFT" }
        if screen.frame.minX == maxX { return "RIGHT" }
    }
    return "ONLY"
}

guard let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
    print("no window list"); exit(1)
}

print("pid=\(app.processIdentifier)  displays=\(screens.map { "\(label(for: $0)) \($0.localizedName) \(Int($0.frame.width))x\(Int($0.frame.height))" })")

var found = 0
var biggest: (area: CGFloat, label: String, frame: String, name: String)?
for w in raw {
    guard (w[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier) else { continue }
    guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
    let width = b["Width"] ?? 0, height = b["Height"] ?? 0
    // Ignore the little things AppKit keeps around (text-input hosts, status-item shadows).
    guard width > 200, height > 200 else { continue }
    let alpha = (w[kCGWindowAlpha as String] as? Double) ?? -1
    let layer = (w[kCGWindowLayer as String] as? Int) ?? -1
    let name = (w[kCGWindowName as String] as? String) ?? ""
    let onscreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false

    let centreCG = CGPoint(x: (b["X"] ?? 0) + width / 2, y: (b["Y"] ?? 0) + height / 2)
    let centreAppKit = CGPoint(x: centreCG.x, y: primary.frame.height - centreCG.y)
    let hit = screens.first { $0.frame.contains(centreAppKit) }
    let verdict = hit.map { "\(label(for: $0)) (\($0.localizedName))" } ?? "?? outside every display"

    found += 1
    print(String(format: "  window %@ layer=%d alpha=%.2f onScreen=%@ frame=%d,%d %dx%d  ->  %@",
                 name, layer, alpha, onscreen ? "yes" : "no",
                 Int(b["X"] ?? 0), Int(b["Y"] ?? 0), Int(width), Int(height), verdict))

    // The viewer is the largest window the app owns by a wide margin — it is full-screen. Reporting
    // it on a line of its own means a script can read the verdict without parsing the table.
    if width * height > (biggest?.area ?? 0) {
        biggest = (width * height, hit.map(label(for:)) ?? "??", "\(Int(width))x\(Int(height))", name)
    }
}
if found == 0 { print("  (no windows larger than 200x200)") }
if let biggest {
    print("VIEWER_DISPLAY=\(biggest.label)  size=\(biggest.frame)")
}
