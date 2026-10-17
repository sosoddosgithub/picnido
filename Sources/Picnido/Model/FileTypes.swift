import Foundation
import UniformTypeIdentifiers

/// The formats this application claims to handle, grouped the way the original's own file-type
/// list grouped them.
///
/// The extension strings are the single source of truth, and everything else is derived from
/// them: the scanner's allow-list reads `EnabledExtensions`, the settings checkboxes iterate
/// `families`, and the Info.plist's `CFBundleDocumentTypes` is *verified* against
/// `uniqueUTIIdentifiers` at runtime rather than trusted. That check matters because
/// LaunchServices drops an identifier it does not recognise **silently** — a typo in the plist
/// is invisible everywhere except in `undeclaredByPlist()`.
enum FileTypeCatalog {

    struct Family: Identifiable {
        let id: String
        let title: String
        let note: String
        let extensions: [String]
    }

    static let families: [Family] = [
        Family(
            id: "common",
            title: "Common",
            note: "What cameras, phones and screenshots produce. ImageIO reads every one of these today.",
            extensions: ["jpg", "jpeg", "png", "gif", "bmp", "tif", "tiff", "heic", "heif",
                         "webp", "psd", "tga", "jp2", "avif", "jxl"]),
        Family(
            id: "raw",
            title: "Camera RAW",
            note: "Vendor and cross-vendor RAW. Decoding goes through the system RAW pipeline, so a "
                + "format starts working the day Apple ships a decoder for it — and not before.",
            extensions: ["dng", "raw", "3fr", "fff", "iiq", "mos", "mrw", "dcr", "erf", "dxo",
                         "cr2", "cr3", "crw",
                         "nef", "nrw", "nefx",
                         "arw", "sr2", "srf", "axr",
                         "orf", "rw2", "raf", "srw", "pef", "rwl"]),
    ]

    /// Every extension, in catalogue order.
    static let allExtensions: [String] = families.flatMap(\.extensions)

    /// The concrete UTI for an extension, or `nil` when this machine has no idea what the
    /// extension is. Dynamic types are rejected here as well: they are invented per-file and
    /// cannot be named in a plist or targeted by a default-application call.
    static func uti(for ext: String) -> UTType? {
        guard let t = UTType(filenameExtension: ext.lowercased()), !t.isDynamic else { return nil }
        return t
    }

    static func utiIdentifier(for ext: String) -> String? { uti(for: ext)?.identifier }

    /// De-duplicated, ordered UTI list — `jpg`/`jpeg` collapse into one `public.jpeg`, likewise
    /// `tif`/`tiff`. This is exactly the set the plist has to declare.
    static var uniqueUTIIdentifiers: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for ext in allExtensions {
            guard let id = utiIdentifier(for: ext), seen.insert(id).inserted else { continue }
            out.append(id)
        }
        return out
    }

    /// What the *shipped* Info.plist actually declares, read back from the launched bundle.
    static func plistDeclaredUTIs() -> [String] {
        guard let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes")
                as? [[String: Any]] else { return [] }
        return types.compactMap { $0["LSItemContentTypes"] as? [String] }.flatMap { $0 }
    }

    /// Extensions whose UTI the plist failed to declare — the ones "Set as Default" would be
    /// refused on. Empty is the only acceptable answer.
    static func undeclaredByPlist() -> [String] {
        let declared = Set(plistDeclaredUTIs())
        return allExtensions.filter { ext in
            guard let id = utiIdentifier(for: ext) else { return true }
            return !declared.contains(id)
        }
    }

    /// The self-check behind `PICNIDO_FILETYPES_CHECK=1`.
    static func auditReport() -> [String] {
        var lines: [String] = []
        lines.append("extensions: \(allExtensions.count)  →  unique UTIs: \(uniqueUTIIdentifiers.count)")
        let unknown = allExtensions.filter { utiIdentifier(for: $0) == nil }
        lines.append("no UTI on this machine: \(unknown.isEmpty ? "none" : unknown.joined(separator: ", "))")
        let missing = undeclaredByPlist()
        lines.append("declared in plist: \(plistDeclaredUTIs().count) entries")
        lines.append("NOT declared in plist: \(missing.isEmpty ? "none" : missing.joined(separator: ", "))")
        return lines
    }
}

/// Which extensions the user has left switched on.
///
/// One set drives both meanings of "on": it is the scanner's allow-list *and* the set of formats
/// the "Set as Default Viewer" button will claim. Splitting them would let the app import a
/// format it refuses to open, which is a worse state than either extreme.
///
/// Absent key means "never configured" and reads as everything-on, so a format added in a later
/// version arrives enabled instead of silently missing. An *empty* value means the user really
/// did switch them all off, and is kept distinct from absent for that reason.
enum EnabledExtensions {
    private static let key = "enabledImageExtensions"

    static var current: Set<String> {
        guard let raw = UserDefaults.standard.string(forKey: key) else {
            return Set(FileTypeCatalog.allExtensions)
        }
        return Set(raw.split(separator: ",").map(String.init))
    }

    static func isOn(_ ext: String) -> Bool { current.contains(ext) }

    static func store(_ set: Set<String>) {
        UserDefaults.standard.set(set.sorted().joined(separator: ","), forKey: key)
    }

    static func set(_ ext: String, on: Bool) {
        var s = current
        if on { s.insert(ext) } else { s.remove(ext) }
        store(s)
    }

    static func reset() { UserDefaults.standard.removeObject(forKey: key) }
}
