import Foundation
import CoreServices
import UniformTypeIdentifiers

// Which physical copy of an app would LaunchServices actually start for a given
// extension? The handler table stores a bundle ID, and three copies on this machine
// share one ID, so the answer is not obvious from the prefs file alone.

func fourCC(_ v: UInt32) -> String {
    let b = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    return String(bytes: b, encoding: .isoLatin1) ?? "?"
}

func defaultHandler(forExtension ext: String) -> String {
    guard let ut = UTType(filenameExtension: ext) else { return "(no UTI for .\(ext))" }
    let handler = LSCopyDefaultRoleHandlerForContentType(ut.identifier as CFString, LSRolesMask.all)
    return (handler?.takeRetainedValue() as String?) ?? "(nil)"
}

let extensions = CommandLine.arguments.count > 1
    ? Array(CommandLine.arguments.dropFirst())
    : ["jpg", "png", "heic", "tiff", "nefx", "rwl"]

print("=== 默认处理程序（按扩展名）===")
// Several extensions usually resolve to the same bundle ID; list its physical
// copies only the first time so the output stays readable.
var alreadyListed = Set<String>()

for ext in extensions {
    let id = defaultHandler(forExtension: ext)
    print(".\(ext)\t-> \(id)")
    guard id.hasPrefix("app.picnido") || id.hasPrefix("com.") || id.hasPrefix("local.") else { continue }
    guard !alreadyListed.contains(id) else { continue }
    alreadyListed.insert(id)
    var err: Unmanaged<CFError>?
    guard let urls = LSCopyApplicationURLsForBundleIdentifier(id as CFString, &err)?.takeRetainedValue() as? [URL] else {
        print("      (无法解析该 bundle ID 的副本)")
        continue
    }
    print("      副本数量=\(urls.count)，LaunchServices 优先顺序：")
    for (i, u) in urls.enumerated() {
        let plist = u.appendingPathComponent("Contents/Info.plist")
        var version = "?"
        if let d = NSDictionary(contentsOf: plist) {
            version = "\(d["CFBundleShortVersionString"] ?? "?") (\(d["CFBundleVersion"] ?? "?"))"
        }
        print("      [\(i)] \(u.path)  version=\(version)")
    }
}
