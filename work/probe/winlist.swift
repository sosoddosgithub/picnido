import CoreGraphics
import Foundation

// Independent window measurement: whatever is really on screen, from outside the
// process being measured. Alpha comes from the window server, so it shows a window
// that has been faded to invisible but is still "visible" as far as AppKit is concerned.

let filter = CommandLine.arguments.count > 1 ? CommandLine.arguments[1].lowercased() : ""

func s(_ v: Any?) -> String { (v as? String) ?? "?" }

let opts: CGWindowListOption = [.optionAll]
guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    print("no window list")
    exit(1)
}

var rows: [(pid: Int, layer: Int, alpha: Double, onscreen: Bool, owner: String, name: String, frame: String)] = []
for w in raw {
    let owner = s(w[kCGWindowOwnerName as String])
    let name = s(w[kCGWindowName as String])
    if !filter.isEmpty, !owner.lowercased().contains(filter), !name.lowercased().contains(filter) { continue }
    let pid = (w[kCGWindowOwnerPID as String] as? Int) ?? -1
    let layer = (w[kCGWindowLayer as String] as? Int) ?? -1
    let alpha = (w[kCGWindowAlpha as String] as? Double) ?? -1
    let onscreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
    var frame = "?"
    if let b = w[kCGWindowBounds as String] as? [String: CGFloat] {
        frame = "\(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0)) \(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0))"
    }
    rows.append((pid, layer, alpha, onscreen, owner, name, frame))
}

rows.sort { ($0.pid, -$0.layer) < ($1.pid, -$1.layer) }
print("pid\tlayer\talpha\tonScreen\tframe\towner\tname")
for r in rows {
    print("\(r.pid)\t\(r.layer)\t\(r.alpha)\t\(r.onscreen)\t\(r.frame)\t\(r.owner)\t\(r.name)")
}
print("--- windows=\(rows.count) pids=\(Set(rows.map(\.pid)).count) ---")
