import Foundation

/// One-time adoption of the directories this app used before it was renamed.
///
/// A rename moves the library: the SQLite catalogue (`index.db`), the settings document
/// (`library.json`) and the thumbnail store all live under directories named after the app.
/// Without this step every existing user would launch the new build into an empty library and
/// watch several thousand thumbnails be decoded again — indistinguishable from data loss, and
/// for the catalogue an actual one, because the folder list the user curated is in there.
///
/// The **move** (rather than a copy) is deliberate. Those directories belong to this app alone,
/// nothing else reads them, and leaving the old one in place would let two builds keep two
/// catalogues of the same folders while both claiming to show the truth.
enum LegacyAdoption {

    /// The directory name used up to 1.3.3. This is the only place the old name still appears,
    /// and it has to: it is a path on disk, not an identity.
    private static let formerName = "PicasaMac"
    private static let currentName = "Picnido"

    // Called from both directory resolvers, whichever is reached first, plus from the app
    // delegate as a backstop. The move must happen exactly once: a second pass would see the
    // new directory already populated and (correctly) refuse, but the lock keeps two threads
    // from racing between "does it exist" and "create it".
    private static let lock = NSLock()
    private static var didRun = false

    /// Called before anything reads `Library.supportDirectory` or `ThumbnailCache`'s root.
    static func run() {
        lock.lock()
        defer { lock.unlock() }
        guard !didRun else { return }
        didRun = true

        let fm = FileManager.default
        let bases = [
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            fm.urls(for: .cachesDirectory, in: .userDomainMask).first,
        ]
        for base in bases.compactMap({ $0 }) {
            adopt(in: base, using: fm)
        }
    }

    private static func adopt(in base: URL, using fm: FileManager) {
        let old = base.appendingPathComponent(formerName, isDirectory: true)
        let new = base.appendingPathComponent(currentName, isDirectory: true)

        guard fm.fileExists(atPath: old.path) else { return }

        // Only into an absent or empty home. A library the user has already built under the new
        // name must never be replaced by a stale one — that would be the very loss this exists
        // to prevent.
        if fm.fileExists(atPath: new.path) {
            let contents = (try? fm.contentsOfDirectory(atPath: new.path)) ?? []
            guard contents.isEmpty else { return }
            try? fm.removeItem(at: new)
        }

        do {
            try fm.moveItem(at: old, to: new)
            bootLog("[adopt] \(base.lastPathComponent): \(formerName) -> \(currentName)")
        } catch {
            // Different volumes, or an open handle. A copy is slower but ends in the same place;
            // the original is left alone rather than risk a half-moved directory.
            try? fm.copyItem(at: old, to: new)
            bootLog("[adopt] \(base.lastPathComponent): copied \(formerName) -> \(currentName) (\(error.localizedDescription))")
        }
    }
}
