import Cocoa

// drag.swift — post a *real* mouse drag on a given display.
//
//   drag <left|right|index> --bottom N --dx D --dy D [--steps N] [--gap MS] [--hold MS]
//
// `--bottom N` is measured from the bottom edge, the same convention as `wheel` and `hover`,
// so "the middle of the picture" can be aimed at without hard-coding a display size.
// `--dy` is positive downwards on screen (the pointer moves towards the bottom edge), which is
// the direction that was reported to jump. AppKit's own y grows upwards, so the sign is flipped
// once when the start point is built — getting that wrong makes every run test the other way.
//
// Why real events and not a call into the view: the bug under test is about what happens
// *between* gesture events — the anchor a drag is measured from, and what lands on screen when
// the button comes up. Driving `pan` directly would skip exactly the code in question.

func die(_ s: String) -> Never {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 7 else {
    die("usage: drag <left|right|index> --bottom N --dx D --dy D [--steps N] [--gap MS] [--hold MS]")
}

let screens = NSScreen.screens
let primary = screens.first { $0.frame.origin == .zero } ?? screens[0]

let target: NSScreen
if let idx = Int(args[0]) {
    guard idx >= 0, idx < screens.count else { die("display index \(idx) out of range") }
    target = screens[idx]
} else {
    let side = args[0].lowercased()
    let ordered = screens.sorted { $0.frame.minX < $1.frame.minX }
    switch side {
    case "left":  target = ordered.first ?? primary
    case "right": target = ordered.last ?? primary
    default:
        guard let named = screens.first(where: { $0.localizedName.lowercased().contains(side) }) else {
            die("no display matching '\(side)'")
        }
        target = named
    }
}

guard args[1] == "--bottom" else { die("second argument must be --bottom <points>") }
guard let fromBottom = Double(args[2]) else { die("--bottom needs a number") }
guard args[3] == "--dx" else { die("fourth argument must be --dx <points>") }
guard let dx = Double(args[4]) else { die("--dx needs a number") }
guard args[5] == "--dy" else { die("sixth argument must be --dy <points>") }
guard let dy = Double(args[6]) else { die("--dy needs a number") }

var steps = 30
var gap = 0.016
var hold = 0.35
var i = 7
while i < args.count {
    switch args[i] {
    case "--steps": steps = Int(args[safe: i + 1] ?? "") ?? steps; i += 2
    case "--gap":   gap = (Double(args[safe: i + 1] ?? "") ?? 16) / 1000.0; i += 2
    case "--hold":  hold = (Double(args[safe: i + 1] ?? "") ?? 350) / 1000.0; i += 2
    default: die("unknown option \(args[i])")
    }
}

let startAppKit = CGPoint(x: target.frame.midX, y: target.frame.minY + fromBottom)
func cgPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: primary.frame.height - p.y) }

func post(_ type: CGEventType, at p: CGPoint, clicks: Int64 = 1) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: cgPoint(p), mouseButton: .left)
    e?.setIntegerValueField(.mouseEventClickState, value: clicks)
    e?.post(tap: .cghidEventTap)
}

// Park the pointer on the start point first: the first click of a run is also what makes the
// viewer key, and a drag that starts in a different window would test nothing.
for _ in 0..<3 {
    post(.mouseMoved, at: startAppKit)
    Thread.sleep(forTimeInterval: 0.02)
}

post(.leftMouseDown, at: startAppKit)
Thread.sleep(forTimeInterval: 0.08)

for n in 1...steps {
    let f = Double(n) / Double(steps)
    let p = CGPoint(x: startAppKit.x + dx * f, y: startAppKit.y - dy * f)
    post(.leftMouseDragged, at: p)
    if n < steps { Thread.sleep(forTimeInterval: gap) }
}

// Sit still at the end before letting go: the report is that the jump happens while the hand
// has stopped and the button is released, so the still period is part of the test.
Thread.sleep(forTimeInterval: hold)
post(.leftMouseUp, at: CGPoint(x: startAppKit.x + dx, y: startAppKit.y - dy))
Thread.sleep(forTimeInterval: 0.05)
// A pointer move after the release: some panels only learn the gesture is over when another
// event arrives, and a run whose `onEnded` never fires cannot test what release does.
post(.mouseMoved, at: CGPoint(x: startAppKit.x + dx, y: startAppKit.y - dy))

print("dragged \(Int(dx)),\(Int(dy)) in \(steps) steps at \(target.localizedName) "
      + "nsscreen=(\(Int(startAppKit.x)),\(Int(startAppKit.y))) hold=\(Int(hold * 1000))ms")

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
