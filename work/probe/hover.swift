import Cocoa

// hover.swift — post *real* mouse-moved events at a point on a given display.
//
// Why this exists: the viewer's chrome (filmstrip) reveals itself from `.onContinuousHover`,
// which is fed by genuine mouse-moved events. `CGWarpMouseCursorPosition` — what `openfrom`
// uses to place the cursor for the open-origin probe — moves the pointer without generating
// any event, so it can never wake the chrome. This posts a short drift of real events
// instead, which the window server delivers like any other movement.
//
//   hover <left|right|index> [dx dy]
//
// Prints the target point so a script can cross-check it against the screenshot.

func die(_ s: String) -> Never {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 1 else { die("usage: hover <left|right|index> [dx dy]") }

let screens = NSScreen.screens
let primary = screens.first { $0.frame.origin == .zero } ?? screens[0]

let target: NSScreen
if let idx = Int(args[0]) {
    guard idx >= 0, idx < screens.count else { die("display index \(idx) out of range (0..\(screens.count - 1))") }
    target = screens[idx]
} else {
    let side = args[0].lowercased()
    let cx = primary.frame.midX
    let ordered = screens.sorted { $0.frame.minX < $1.frame.minX }
    switch side {
    case "left":  target = ordered.first ?? primary
    case "right": target = ordered.last ?? primary
    default:
        let named = screens.first { $0.localizedName.lowercased().contains(side) }
        guard let named else { die("no display matching '\(side)' — have: "
                                   + screens.map { $0.localizedName }.joined(separator: ", ")) }
        target = named
    }
    _ = cx
}

let dx = args.count >= 3 ? (Double(args[1]) ?? 0) : 0
let dy = args.count >= 3 ? (Double(args[2]) ?? 0) : 0

// AppKit point -> CGEvent point (CGEvent's origin is the top-left of the *primary* display).
let appKit = CGPoint(x: target.frame.midX + dx, y: target.frame.midY + dy)
let cg = CGPoint(x: appKit.x, y: primary.frame.height - appKit.y)

func post(_ p: CGPoint) {
    let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                    mouseCursorPosition: p, mouseButton: .left)
    e?.post(tap: .cghidEventTap)
}

// A short drift, not a single jump: `.onContinuousHover` needs movement *within* the view,
// and one event that lands already at the destination is easy to miss while the window is
// still settling.
for i in 0...12 {
    let t = Double(i) / 12.0
    post(CGPoint(x: cg.x - 120 * (1 - t), y: cg.y - 60 * (1 - t)))
    Thread.sleep(forTimeInterval: 0.03)
}
post(cg)

print("hovered \(target.localizedName)  nsscreen=(\(Int(appKit.x)),\(Int(appKit.y)))  cg=(\(Int(cg.x)),\(Int(cg.y)))")
