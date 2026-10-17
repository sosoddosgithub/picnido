import Cocoa

// clickat.swift — post a *real* left click at an offset from a display's centre.
//
// Why this exists: the viewer's only other dismissal paths are the tool bar's Close button and
// the Esc key. The hint line at the bottom of the viewer claims tapping *outside the picture*
// also closes it, and a claim about what a pointer does cannot be checked from inside the
// process that made it — `PICNIDO_CLICK` only reaches sheet windows (`sheet.sendEvent`), never the
// viewer panel. This posts the click through the window server, so the panel is hit-tested
// exactly as it would be for a person.
//
//   clickat <left|right|index> <dx> <dy>
//
// dx/dy are AppKit points from the centre of that display, same convention as `hover.swift`.

func die(_ s: String) -> Never {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3 else { die("usage: clickat <left|right|index> <dx> <dy>") }

let screens = NSScreen.screens
let primary = screens.first { $0.frame.origin == .zero } ?? screens[0]

let target: NSScreen
if let idx = Int(args[0]) {
    guard idx >= 0, idx < screens.count else { die("display index \(idx) out of range") }
    target = screens[idx]
} else {
    let ordered = screens.sorted { $0.frame.minX < $1.frame.minX }
    switch args[0].lowercased() {
    case "left":  target = ordered.first ?? primary
    case "right": target = ordered.last ?? primary
    default:
        guard let named = screens.first(where: { $0.localizedName.lowercased().contains(args[0].lowercased()) })
        else { die("no display matching '\(args[0])'") }
        target = named
    }
}

let dx = Double(args[1]) ?? 0
let dy = Double(args[2]) ?? 0

// AppKit point -> CGEvent point (CGEvent's origin is the top-left of the *primary* display).
let appKit = CGPoint(x: target.frame.midX + dx, y: target.frame.midY + dy)
let cg = CGPoint(x: appKit.x, y: primary.frame.height - appKit.y)

func post(_ type: CGEventType, _ p: CGPoint) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: p, mouseButton: .left)
    e?.post(tap: .cghidEventTap)
}

// Drift in first, for the same reason `hover.swift` does: a pointer that arrives already at the
// destination is easy to miss while the panel is still settling, and the viewer's own
// `.onContinuousHover` needs movement *within* the window before it believes the mouse is there.
//
// …but before any of that, the app has to be made frontmost. The viewer runs as an agent
// (`LSUIElement` in the bundle, `.accessory` in picture mode), which is exactly the case that
// does *not* take focus on launch — so while one of these clicks is being posted, whoever else
// was frontmost still is, and the first click on a non-active app is spent activating it rather
// than delivered to the view underneath. That is invisible from the outside: the click "works"
// as far as the poster is concerned, and the panel simply does not react. Measured here — the
// outside-the-picture case reported no change until this was added.
let bundleID = ProcessInfo.processInfo.environment["CLICKAT_ACTIVATE"] ?? "app.picnido.mac"
if !bundleID.isEmpty,
   let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
    app.activate(options: [.activateAllWindows])
    Thread.sleep(forTimeInterval: 0.6)
    print("activated \(bundleID) pid=\(app.processIdentifier)")
}

for i in 0...10 {
    let t = Double(i) / 10.0
    post(.mouseMoved, CGPoint(x: cg.x - 100 * (1 - t), y: cg.y - 40 * (1 - t)))
    Thread.sleep(forTimeInterval: 0.02)
}
post(.mouseMoved, cg)
Thread.sleep(forTimeInterval: 0.20)

post(.leftMouseDown, cg)
Thread.sleep(forTimeInterval: 0.09)
post(.leftMouseUp, cg)

print("clicked \(target.localizedName)  nsscreen=(\(Int(appKit.x)),\(Int(appKit.y)))  cg=(\(Int(cg.x)),\(Int(cg.y)))")
