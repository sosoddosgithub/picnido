import Cocoa

// wheel.swift — post *real* scroll-wheel events at a point on a given display.
//
// The app reads the wheel through an `NSEvent` local monitor, and the only honest way to test
// that path is to let the window server deliver real events. Driving the maths directly (as
// `PICNIDO_ZOOM_TEST` does for zoom) would prove the arithmetic and nothing about which region
// claims the wheel — which is precisely the thing under test.
//
//   wheel <left|right|index> --bottom N <ticks> [--up] [--gap MS]
//
// `--bottom N` measures from the bottom edge, the same convention as `hover`, so "the filmstrip"
// can be aimed at without hard-coding a screen size. Default direction is wheel-down (negative
// deltaY); `--up` flips it.

func die(_ s: String) -> Never {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 4 else { die("usage: wheel <left|right|index> --bottom N <ticks> [--up] [--gap MS]") }

let screens = NSScreen.screens
let primary = screens.first { $0.frame.origin == .zero } ?? screens[0]

let target: NSScreen
if let idx = Int(args[0]) {
    guard idx >= 0, idx < screens.count else { die("display index \(idx) out of range (0..\(screens.count - 1))") }
    target = screens[idx]
} else {
    let side = args[0].lowercased()
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
}

guard args[1] == "--bottom" else { die("second argument must be --bottom <points>") }
guard let fromBottom = Double(args[2]) else { die("--bottom needs a number") }
guard let ticks = Int(args[3]) else { die("tick count must be an integer") }

var up = false
var gap = 0.06
var i = 4
while i < args.count {
    switch args[i] {
    case "--up": up = true; i += 1
    case "--gap": gap = (Double(args[safe: i + 1] ?? "") ?? 60) / 1000.0; i += 2
    default: die("unknown option \(args[i])")
    }
}

let appKit = CGPoint(x: target.frame.midX, y: target.frame.minY + fromBottom)
let cg = CGPoint(x: appKit.x, y: primary.frame.height - appKit.y)

func postMouse() {
    let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                    mouseCursorPosition: cg, mouseButton: .left)
    e?.post(tap: .cghidEventTap)
}

// Put the pointer there first. The strip's band is decided from `locationInWindow` on the event
// itself, so this is not strictly needed — but the chrome's hover state is, and a run that starts
// with the pointer parked elsewhere would be testing a different situation.
for _ in 0..<3 {
    postMouse()
    Thread.sleep(forTimeInterval: 0.03)
}

let lines: Int32 = up ? 1 : -1
for n in 0..<ticks {
    guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                          wheel1: lines, wheel2: 0, wheel3: 0) else { die("could not create wheel event") }
    e.location = cg
    e.post(tap: .cghidEventTap)
    if n < ticks - 1 { Thread.sleep(forTimeInterval: gap) }
}

print("wheeled \(ticks)x \(up ? "up" : "down") at \(target.localizedName)  nsscreen=(\(Int(appKit.x)),\(Int(appKit.y)))  cg=(\(Int(cg.x)),\(Int(cg.y)))")

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
