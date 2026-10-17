import AppKit
import CoreServices
import UniformTypeIdentifiers

/// Reading and writing the system's "open this kind of file with…" mapping.
///
/// Deliberately a thin wrapper with no state of its own: the authority is the LaunchServices
/// database, and anything cached here would eventually disagree with what Finder does. Every
/// getter therefore re-asks the system.
///
/// Two APIs exist for the write. `NSWorkspace.setDefaultApplication` is the modern one and is
/// tried first; `LSSetDefaultRoleHandlerForContentType` is the older C call and is kept as the
/// fallback for the case where the app has not yet been registered with LaunchServices (which
/// happens the first time it is launched from a location LaunchServices tracks).
enum DefaultViewer {

    enum Outcome {
        case set(String)          // claimed
        case already(String)      // was already ours
        case unknown(String)      // no concrete UTI for this extension
        case refused(String)      // the system said no
    }

    static var selfBundleID: String? { Bundle.main.bundleIdentifier }

    // MARK: - Reading

    /// Bundle identifier of whatever opens `uti` today.
    static func handlerBundleID(forUTI uti: String) -> String? {
        guard let type = UTType(uti),
              let url = NSWorkspace.shared.urlForApplication(toOpen: type) else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    /// Display name of whatever opens `ext` today, for the "Currently: …" column.
    static func handlerName(for ext: String) -> String? {
        guard let type = FileTypeCatalog.uti(for: ext) else { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: type) else { return nil }
        return FileManager.default.displayName(atPath: url.path)
    }

    static func isSelfHandler(for ext: String) -> Bool {
        guard let id = FileTypeCatalog.utiIdentifier(for: ext) else { return false }
        return handlerBundleID(forUTI: id) == selfBundleID
    }

    /// Every application the system considers able to open `uti`. Exists to answer "is this app
    /// even in the running?" — a refused write and a queued one look identical from the outside,
    /// but only one of them leaves the app out of this list.
    static func allHandlers(forUTI uti: String) -> [String] {
        guard let ids = LSCopyAllRoleHandlersForContentType(uti as CFString, .viewer)?
            .takeRetainedValue() as? [String] else { return [] }
        return ids
    }

    /// The LaunchServices default handler, straight from the database rather than through
    /// NSWorkspace — the second opinion that tells the two failure modes apart.
    static func defaultHandlerID(forUTI uti: String) -> String? {
        LSCopyDefaultRoleHandlerForContentType(uti as CFString, .viewer)?
            .takeRetainedValue() as String?
    }

    /// The C write with no fallback and no interpretation, for the diagnostic hook. `claim`
    /// collapses "the API threw", "the API lied" and "the system ignored it" into one word.
    static func rawSetDefault(_ uti: String) -> OSStatus {
        guard let id = selfBundleID else { return -1 }
        return LSSetDefaultRoleHandlerForContentType(uti as CFString, .viewer, id as CFString)
    }

    // MARK: - Writing

    /// Claims `ext` for this application. Failures are per-extension and *returned*, never
    /// thrown: one format the system declines must not abort the other forty.
    ///
    /// `async` for a reason that is easy to get wrong: the only Swift spelling of the modern call
    /// is `setDefaultApplication(at:toOpen:completion:)`, whose completion defaults to `nil` —
    /// so a *synchronous* call to it compiles, does nothing yet, and returns. Awaiting the
    /// bridged async form is what makes the returned `Outcome` mean anything.
    static func claim(_ ext: String) async -> Outcome {
        guard let type = FileTypeCatalog.uti(for: ext) else { return .unknown(ext) }
        if isSelfHandler(for: ext) { return .already(ext) }

        do {
            try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL,
                                                               toOpen: type)
            return .set(ext)
        } catch {
            // The modern call refuses when the app has not been registered with LaunchServices
            // yet (a fresh build that has never been launched from this path). The older C call
            // does not care, so it is the fallback rather than the other way round.
            guard let id = selfBundleID else { return .refused(ext) }
            let status = LSSetDefaultRoleHandlerForContentType(type.identifier as CFString,
                                                               .viewer,
                                                               id as CFString)
            return status == noErr ? .set(ext) : .refused(ext)
        }
    }

    static func claim(_ extensions: [String]) async -> [Outcome] {
        var results: [Outcome] = []
        for ext in extensions { results.append(await claim(ext)) }
        return results
    }

    // MARK: - Undo

    private static let snapshotKey = "defaultViewerSnapshot"

    /// Records who owned each UTI *before* the first claim, so a mis-click is recoverable.
    /// Written once per session and kept until restored — re-snapshotting after a claim would
    /// capture our own bundle id and make the undo a no-op.
    static func snapshotIfNeeded() {
        let d = UserDefaults.standard
        if d.object(forKey: snapshotKey) != nil { return }
        var map: [String: String] = [:]
        for uti in FileTypeCatalog.uniqueUTIIdentifiers {
            if let owner = handlerBundleID(forUTI: uti) { map[uti] = owner }
        }
        d.set(map, forKey: snapshotKey)
    }

    static var hasSnapshot: Bool { UserDefaults.standard.object(forKey: snapshotKey) != nil }

    /// Hands every format in the snapshot back to the application that had it. Returns the
    /// number actually restored. The snapshot is *not* cleared — restoring twice is harmless
    /// and clearing it would strand a user who restored by accident.
    @discardableResult
    static func restoreSnapshot() -> Int {
        guard let map = UserDefaults.standard.dictionary(forKey: snapshotKey) as? [String: String]
        else { return 0 }
        guard let mine = selfBundleID else { return 0 }
        var restored = 0
        for (uti, owner) in map where owner != mine {
            let type = UTType(uti) != nil ? uti : nil
            guard let identifier = type else { continue }
            let status = LSSetDefaultRoleHandlerForContentType(identifier as CFString,
                                                               .viewer,
                                                               owner as CFString)
            if status == noErr { restored += 1 }
        }
        return restored
    }

    static func clearSnapshot() { UserDefaults.standard.removeObject(forKey: snapshotKey) }
}
