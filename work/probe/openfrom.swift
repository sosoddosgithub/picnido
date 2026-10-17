import AppKit

// Usage: openfrom <app> <file> <left|right|display-name>
//
// Reproduces "the user double-clicks a picture in a Finder window that lives on display X" without
// a human and without an Accessibility grant.
//
// The viewer decides where to appear from the pointer position at the instant the file arrives
// (see `ViewerHost.noteOpenOrigin`), so the one thing a test has to fake is the pointer. Finder's
// own window geometry is not readable without permissions, but the cursor is — the pointer sits on
// the icon being double-clicked, which is exactly the fact the app uses.
//
// `CGWarpMouseCursorPosition` moves the real cursor and needs no granting. It speaks CoreGraphics
// global coordinates: origin at the *top-left* of the primary display, y growing downwards, while
// AppKit measures y upwards from the primary display's bottom-left. Hence the flip below.

func die(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 3 else { die("usage: openfrom <app|-> <file|-> <left|right|name>") }

_ = NSApplication.shared   // NSScreen is empty until AppKit has been initialised

let appURL = URL(fileURLWithPath: args[0])
let fileURL = URL(fileURLWithPath: args[1])
let want = args[2].lowercased()

let screens = NSScreen.screens
guard !screens.isEmpty else { die("no displays") }
guard let primary = screens.first(where: { $0.frame.origin == .zero }) ?? screens.first else { die("no primary") }

let target: NSScreen?
switch want {
case "left":  target = screens.min { $0.frame.minX < $1.frame.minX }
case "right": target = screens.max { $0.frame.minX < $1.frame.minX }
default:      target = screens.first { $0.localizedName.localizedCaseInsensitiveContains(want) }
}
guard let screen = target else {
    die("no display matched '\(want)' among \(screens.map(\.localizedName))")
}

// A point well inside the display, and not on its very edge where rounding could tip it into the
// neighbour. A quarter in from the left, a quarter down from the top.
let centre = CGPoint(x: screen.frame.minX + screen.frame.width * 0.25,
                     y: screen.frame.minY + screen.frame.height * 0.75)
let cgPoint = CGPoint(x: centre.x, y: primary.frame.height - centre.y)

print("warping cursor -> \(screen.localizedName)  nsscreen=(\(Int(centre.x)),\(Int(centre.y))) cg=(\(Int(cgPoint.x)),\(Int(cgPoint.y)))")
CGWarpMouseCursorPosition(cgPoint)
CGAssociateMouseAndMouseCursorPosition(1)

// `-` as the file means "move the pointer and stop". Used by tests that drive the open from inside
// the app and only need the pointer parked somewhere misleading, to check that it is *not* believed.
guard args[1] != "-" else { exit(0) }

// Let the window server settle on the new position before the open event carries it over.
Thread.sleep(forTimeInterval: 0.35)

print("opening \(fileURL.lastPathComponent) with \(appURL.lastPathComponent)")
let done = DispatchSemaphore(value: 0)
NSWorkspace.shared.open([fileURL], withApplicationAt: appURL,
                        configuration: NSWorkspace.OpenConfiguration()) { _, error in
    if let error { print("open error: \(error.localizedDescription)") }
    done.signal()
}
_ = done.wait(timeout: .now() + 15)
