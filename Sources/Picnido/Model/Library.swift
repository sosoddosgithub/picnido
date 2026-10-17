import Foundation
import Observation

// MARK: - Photo

struct GeoPoint: Codable, Hashable {
    var latitude: Double
    var longitude: Double
}

struct PhotoItem: Codable, Identifiable, Hashable {
    var url: URL
    var id: String { url.path }

    var fileSize: Int64 = 0
    var created: Date = .distantPast
    var modified: Date = .distantPast
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    var exifOrientation: Int = 1

    var caption: String = ""
    var starred: Bool = false
    var tags: [String] = []
    var geo: GeoPoint?

    /// Hidden from the grid. The original's Hide is the reversible middle ground between
    /// keeping a picture you do not want to look at and deleting one you might want later —
    /// which is the choice the Desktop sweep kept forcing ("is this a real album or a
    /// program's icon folder?"). Hidden photos are never removed from the library or the
    /// index; they are filtered out of `visiblePhotos` unless `showHidden` is on.
    var hidden: Bool = false

    /// The original's six colour labels: 0 = none, 1…6 = red, orange, yellow, green, blue, purple.
    /// Coarser than a tag and faster than a star — three clicks sort five hundred photos into
    /// "print these", "maybe", "no".
    var colorLabel: Int = 0

    var exif: [String: String] = [:]

    /// The full, ordered, non-destructive edit history.
    var stack: [EditStep] = []
    /// Undone steps, kept so Redo works exactly like the original.
    var redoStack: [EditStep] = []

    var folder: URL { url.deletingLastPathComponent() }
    var fileName: String { url.lastPathComponent }
    var hasEdits: Bool { !stack.isEmpty }
    var isPortrait: Bool { pixelHeight > pixelWidth }

    var dimensionsText: String { "\(pixelWidth) × \(pixelHeight)" }

    /// Width over height as the picture is *displayed*, i.e. with the EXIF quarter turns applied.
    ///
    /// `pixelWidth`/`pixelHeight` are what the file says, and a phone that turned the camera on
    /// its side records a landscape frame plus an instruction to rotate it — so the stored pair
    /// describes the picture sideways. `ThumbnailCache.frameShape` applies the same swap when it
    /// checks an embedded preview against the frame, and every decoded bitmap the app hands out is
    /// already normalised, so anything reasoning about shape has to do this or it will disagree
    /// with what is on screen.
    ///
    /// Falls back to square when the size was never recorded. A wrong ratio only misjudges how
    /// tall a cell should be, and a square is the least surprising guess of the available ones.
    var displayAspectRatio: CGFloat {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1 }
        let swapped = (5...8).contains(exifOrientation)
        let w = swapped ? pixelHeight : pixelWidth
        let h = swapped ? pixelWidth : pixelHeight
        return CGFloat(w) / CGFloat(h)
    }
}

// MARK: - Album

struct Album: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var members: [String] = []   // photo ids (paths)
}

// MARK: - Sidebar model

enum LibraryView: Hashable {
    case allPhotos
    case starred
    case recent
    case folder(String)
    case album(UUID)
    case tag(String)
    case places
    case screensaverFolder(String)
    /// One of the six colour labels. `colorLabel(0)` would be "no label", which is not a view —
    /// the sidebar only offers 1…6.
    case colorLabel(Int)
    /// The hidden photos. Reachable only through the "Show hidden" switch, so it is not a
    /// destination in the sidebar; it exists so `showHidden` has something to reveal.
    case hidden

    var title: String {
        switch self {
        case .allPhotos: return "All Photos"
        case .starred: return "Starred"
        case .recent: return "Recent Changes"
        case .folder(let p): return URL(fileURLWithPath: p).lastPathComponent
        case .album: return "Album"
        case .tag(let t): return "#\(t)"
        case .places: return "Places"
        case .screensaverFolder(let p): return URL(fileURLWithPath: p).lastPathComponent
        case .colorLabel(let i): return ColorLabel.name(i)
        case .hidden: return "Hidden Photos"
        }
    }
}

/// The original's six colour labels. Index 0 is "no label" and is not selectable.
enum ColorLabel {
    static let all: [Int] = [1, 2, 3, 4, 5, 6]

    static func name(_ index: Int) -> String {
        switch index {
        case 1: return "Red"
        case 2: return "Orange"
        case 3: return "Yellow"
        case 4: return "Green"
        case 5: return "Blue"
        case 6: return "Purple"
        default: return "No Label"
        }
    }

    /// The same six values the original painted, close enough to be recognisable.
    static func rgb(_ index: Int) -> (Double, Double, Double) {
        switch index {
        case 1: return (0.85, 0.24, 0.22)
        case 2: return (0.93, 0.55, 0.16)
        case 3: return (0.93, 0.80, 0.22)
        case 4: return (0.29, 0.62, 0.29)
        case 5: return (0.22, 0.45, 0.80)
        case 6: return (0.55, 0.36, 0.75)
        default: return (0.6, 0.6, 0.6)
        }
    }
}

enum SortMode: String, CaseIterable, Identifiable {
    case fileName = "Name"
    case dateTaken = "Date Taken"
    case dateModified = "Date Modified"
    case size = "Size"
    case star = "Star"
    var id: String { rawValue }
}

// MARK: - Folder tree

/// One folder in the left-hand tree.
///
/// The original app's sidebar shows the folders you *added* and the subfolders beneath them,
/// indented and expandable — not a flat list of every leaf that happens to hold a picture. The
/// previous version here flattened everything, so importing a folder named `1` that contained
/// `a`, `b` and `c` produced three unrelated rows and no way to tell where they came from.
///
/// Counts come in two flavours, exactly as in the original's `"%d photos (%s)"` selection tip: the
/// photos in this folder itself, and the photos in this folder plus everything below it.
struct FolderNode: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    /// Photos directly inside this folder.
    let ownCount: Int
    /// Photos inside this folder and any folder beneath it.
    let totalCount: Int
    let children: [FolderNode]

    var hasChildren: Bool { !children.isEmpty }

    /// Depth-first flattening, honouring the expanded set. Produced as a flat array so the
    /// sidebar can render it with a plain `ForEach` and keep full control over indentation and
    /// hit testing — the same shape used by the folder scanner's results list.
    static func flatten(_ nodes: [FolderNode], expanded: Set<String>,
                        depth: Int = 0) -> [FolderRow] {
        var out: [FolderRow] = []
        out.reserveCapacity(nodes.count)
        for node in nodes {
            out.append(FolderRow(node: node, depth: depth))
            if node.hasChildren, expanded.contains(node.path) {
                out.append(contentsOf: flatten(node.children, expanded: expanded, depth: depth + 1))
            }
        }
        return out
    }

    /// Builds the tree from the library's roots plus a map of folder path to the number of photos
    /// that live directly in it.
    ///
    /// Intermediate directories that hold no photos of their own still get a node, otherwise
    /// `1/a/b/c` with pictures only in `c` would lose `a` and `b` and the indentation would lie.
    /// Folders that belong to no root are promoted to top level rather than silently dropped.
    static func build(roots: [String], counts: [String: Int]) -> [FolderNode] {
        var tops = roots
        for path in counts.keys where !roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            if !tops.contains(path) { tops.append(path) }
        }
        guard !tops.isEmpty else { return [] }

        var needed = Set(counts.keys)
        needed.formUnion(tops)

        // Fill in the chain between every known folder and its top-level ancestor.
        for path in needed {
            guard let top = tops.first(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
            var parent = (path as NSString).deletingLastPathComponent
            while parent.count > top.count, parent.hasPrefix(top) {
                needed.insert(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }

        var childrenOf: [String: [String]] = [:]
        for path in needed {
            guard let top = tops.first(where: { path == $0 || path.hasPrefix($0 + "/") }),
                  path != top else { continue }
            let parent = (path as NSString).deletingLastPathComponent
            childrenOf[parent, default: []].append(path)
        }
        for key in childrenOf.keys {
            childrenOf[key]?.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        }

        func makeNode(_ path: String) -> FolderNode {
            let kids = (childrenOf[path] ?? []).map(makeNode)
            let own = counts[path] ?? 0
            return FolderNode(path: path,
                              name: URL(fileURLWithPath: path).lastPathComponent,
                              ownCount: own,
                              totalCount: own + kids.reduce(0) { $0 + $1.totalCount },
                              children: kids)
        }

        return tops
            .filter { needed.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map(makeNode)
    }
}

/// A flattened tree row: which node, and how deep to indent it.
struct FolderRow: Identifiable {
    var id: String { node.path }
    let node: FolderNode
    let depth: Int
}

// MARK: - Persisted document

struct LibraryDocument: Codable {
    var roots: [String] = []
    var albums: [Album] = []
    var photoRecords: [String: PhotoRecord] = [:]
    var watchedFolders: [String] = []
    var folderOrder: [String] = []
    /// Pictures smaller than this are left out of the library entirely; 0 means no limit.
    ///
    /// It has to be persisted and applied at *import*, not only while sweeping: the picker
    /// promises "(24 photos)" for a folder, and if the library then imports all three hundred
    /// icons in it, the number it showed was a lie. That is exactly what happened with a sweep
    /// of the Desktop — the list was honest about the size filter and the import ignored it.
    var minPhotoBytes: Int64 = 0
}

/// The mutable part of a photo, persisted keyed by absolute path.
struct PhotoRecord: Codable {
    var caption: String = ""
    var starred: Bool = false
    var tags: [String] = []
    var stack: [EditStep] = []
    var geo: GeoPoint?
    var hidden: Bool = false
    var colorLabel: Int = 0

    /// True when this record carries something the user typed. Records that carry nothing are
    /// dropped from the document rather than written out as a row of defaults, which is what
    /// kept the file small when it was only captions and stars. Every field must be listed here —
    /// forgetting one silently drops the setting the first time a photo is saved.
    var isEmpty: Bool {
        caption.isEmpty && !starred && tags.isEmpty && stack.isEmpty
            && geo == nil && !hidden && colorLabel == 0
    }
}

// MARK: - Store

@Observable
final class LibraryStore {

    // Content
    var roots: [URL] = []
    var photos: [PhotoItem] = []
    var albums: [Album] = []
    var watchedFolders: [URL] = []

    // Navigation / UI state
    var view: LibraryView = .allPhotos
    var selection = Set<String>()
    var tray: [String] = []                 // the Photo Tray (the original app's selection bin)
    var searchText: String = ""
    var sort: SortMode = .dateTaken
    var ascending: Bool = true
    var starredOnly: Bool = false
    var thumbnailSize: Double = 168

    /// Reveal the photos marked hidden. Off by default — that is the whole point of Hide.
    var showHidden: Bool = false

    /// Restricts the grid to one colour label. `nil` means every label.
    var colorLabelFilter: Int?

    /// Date-range filter, applied to the date taken (falling back to the file's own date, which
    /// is what `PhotoItem.created` already is). Both ends are inclusive; either can be nil, so
    /// "everything after June" and "everything before 2019" are both expressible.
    var dateFrom: Date?
    var dateTo: Date?

    var hasDateFilter: Bool { dateFrom != nil || dateTo != nil }

    /// Pictures at or below this many bytes never enter the library. Set from the sweep panel
    /// ("Ignore under …"), persisted, and applied to every folder this store imports — not just
    /// to the list of folders the sweep shows.
    var minPhotoBytes: Int64 = 0

    // Transient
    var isScanning = false
    var scanProgress = StatusNote()
    var statusMessage = StatusNote()

    private var records: [String: PhotoRecord] = [:]
    private var saveWorkItem: DispatchWorkItem?

    // MARK: Locations

    static var supportDirectory: URL {
        // Before the first `createDirectory`: if an older build left its library under the
        // former name, that directory has to become this one, not sit beside it. Doing this
        // here rather than at launch is what makes the ordering impossible to get wrong — this
        // property is reached through `AppState`, which exists before any app-delegate callback.
        LegacyAdoption.run()
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Picnido", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var documentURL: URL { supportDirectory.appendingPathComponent("library.json") }

    /// The persistent photo catalogue. Everything that can be learned about a file without
    /// decoding it lives here, so a relaunch never has to touch the file system to paint a grid.
    let index = LibraryIndex.shared

    // MARK: Load / save

    /// Restores the library.
    ///
    /// Two phases on purpose. The catalogue is read first — one SQLite query, tens of
    /// milliseconds even for thousands of rows — and the grid is painted from it immediately.
    /// Only then does a background pass walk the folders and reconcile. The previous version ran
    /// a full metadata sweep of every file before showing anything, which is what made a
    /// five-hundred-photo folder feel like it was still loading after the window had appeared.
    func load() {
        guard let data = try? Data(contentsOf: Self.documentURL),
              let doc = try? JSONDecoder().decode(LibraryDocument.self, from: data) else {
            return
        }
        roots = doc.roots.map { URL(fileURLWithPath: $0) }
        albums = doc.albums
        records = doc.photoRecords
        watchedFolders = doc.watchedFolders.map { URL(fileURLWithPath: $0) }
        minPhotoBytes = doc.minPhotoBytes

        // PICNIDO_ROOTS=a:b:c — point the library at specific folders for one scripted run.
        // Applied here, before the catalogue is filtered and before the reconcile starts, so a
        // measurement pass never walks (or writes rows for) the user's real folders.
        if let spec = ProcessInfo.processInfo.environment["PICNIDO_ROOTS"], !spec.isEmpty {
            roots = spec.split(separator: ":").map { URL(fileURLWithPath: String($0)).standardizedFileURL }
            PicnidoAppDelegate.report("[roots] transient override -> \(roots.map { $0.path })")
        }

        // PICNIDO_MIN_BYTES=<n> — applies a size floor for one scripted run. Transient on purpose:
        // the sweep panel is what persists it, and a verification run must not leave a setting
        // behind in the library the user actually works with.
        if let raw = ProcessInfo.processInfo.environment["PICNIDO_MIN_BYTES"], let bytes = Int64(raw) {
            minPhotoBytes = max(0, bytes)
            PicnidoAppDelegate.report("[minbytes] transient floor -> \(Self.sizeText(minPhotoBytes))")
        }

        let started = Date()
        let rootPaths = roots.map { $0.standardizedFileURL.path }
        let rows = index.loadAll()
        if !rootPaths.isEmpty {
            photos = rows
                .filter { row in rootPaths.contains { row.path.hasPrefix($0 + "/") } }
                .map { makePhoto(from: $0) }
        }
        PicnidoAppDelegate.report(String(format: "[library] catalogue gave %d photos in %.1f ms (db rows=%d)",
                                        photos.count, Date().timeIntervalSince(started) * 1000, rows.count))

        Task { await rescanAll() }
    }

    func saveSoon() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    func saveNow() {
        var doc = LibraryDocument()
        doc.roots = roots.map { $0.path }
        doc.albums = albums
        doc.watchedFolders = watchedFolders.map { $0.path }
        doc.minPhotoBytes = minPhotoBytes
        // Only persist photos that actually carry user data; keeps the file small.
        for p in photos {
            let record = PhotoRecord(caption: p.caption, starred: p.starred, tags: p.tags,
                                     stack: p.stack, geo: p.geo,
                                     hidden: p.hidden, colorLabel: p.colorLabel)
            if record.isEmpty {
                records.removeValue(forKey: p.id)
                continue
            }
            records[p.id] = record
        }
        doc.photoRecords = records
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(doc) {
            try? data.write(to: Self.documentURL, options: .atomic)
        }
    }

    // MARK: Folders

    func addRoot(_ url: URL) {
        let standard = url.standardizedFileURL
        guard !roots.contains(where: { $0.path == standard.path }) else { return }
        roots.append(standard)
        invalidateDerived()
        Task { await scan(folder: standard) }
        saveSoon()
    }

    /// Sets the size floor and makes it true of the library as it stands.
    ///
    /// A setting that only affects what the *next* sweep shows is not a setting. Lowering the
    /// floor back to 0 brings the small pictures back on the next reconcile, because nothing was
    /// marked as rejected — the files are simply skipped while scanning.
    func applyMinPhotoBytes(_ bytes: Int64) {
        let clamped = max(0, bytes)
        guard clamped != minPhotoBytes else { return }
        minPhotoBytes = clamped
        invalidateDerived()
        saveSoon()
        guard clamped > 0 else {
            statusMessage = StatusNote("Size floor cleared — small pictures will come back")
            Task { await rescanAll() }
            return
        }
        let dropped = photos.filter { $0.fileSize < clamped }.map { $0.url.path }
        guard !dropped.isEmpty else { return }
        photos.removeAll { dropped.contains($0.url.path) }
        selection.subtract(dropped)
        invalidateDerived()
        Task { index.delete(paths: dropped) }
        statusMessage = StatusNote("Ignoring %lld picture\(dropped.count == 1 ? "" : "s") under %@",
                                   [dropped.count, Self.sizeText(clamped)])
    }

    /// Binary units on purpose. This string only ever echoes a threshold the user typed into the
    /// sweep panel, where the unit picker offers KB and MB meaning 1024 and 1048576. Formatting it
    /// as decimal made the panel contradict itself: the field read "2 MB" and the footer right
    /// below it read "under 2.1 MB ignored" for the same number.
    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }

    func removeRoot(_ url: URL) {
        roots.removeAll { $0.path == url.path }
        let gone = photos.filter { $0.url.path.hasPrefix(url.path + "/") }.map { $0.url.path }
        photos.removeAll { $0.url.path.hasPrefix(url.path + "/") }
        if case .folder(let p) = view, p == url.path || p.hasPrefix(url.path + "/") { view = .allPhotos }
        invalidateDerived()
        Task { index.delete(paths: gone) }
        saveSoon()
    }

    /// Reconciles the library with the file system.
    ///
    /// Nothing is cleared up front. Photos already on screen stay on screen, and new files stream
    /// in as they are read — a large import fills in progressively instead of freezing and then
    /// appearing all at once. Files whose modification date or size moved are re-read; everything
    /// else is served straight from the catalogue with no disk access at all.
    func rescanAll() async {
        guard !roots.isEmpty else { return }
        let rescanStart = Date()
        await MainActor.run { isScanning = true; scanProgress = StatusNote("Checking folders…") }

        let snapshot = await Task.detached(priority: .utility) { [index] in index.loadAll() }.value
        let tSnapshot = Date()
        var known: [String: IndexedPhoto] = [:]
        known.reserveCapacity(snapshot.count)
        for row in snapshot { known[row.path] = row }

        for root in roots { await scan(folder: root, known: known) }
        let tScan = Date()

        let live = Set(photos.map { $0.url.path })
        let rootPaths = roots.map { $0.standardizedFileURL.path }
        let stale = snapshot.map { $0.path }.filter { rowPath in
            rootPaths.contains { rowPath.hasPrefix($0 + "/") } && !live.contains(rowPath)
        }
        if !stale.isEmpty {
            index.delete(paths: stale)
            await MainActor.run {
                photos.removeAll { stale.contains($0.url.path) }
                invalidateDerived()
            }
        }
        index.deleteOutside(roots: rootPaths)
        let tPrune = Date()
        await MainActor.run {
            isScanning = false
            scanProgress = StatusNote()
            statusMessage = StatusNote("%lld photos in library", [photos.count])
        }
        // Where the reconcile's wall time goes. `isScanning` is what the UI shows as "still
        // working", so it has to be clear whether a slow start is the disk, the scan, or the
        // main actor being unable to pick up the final state change.
        PicnidoAppDelegate.report(String(format: "[rescan] %d roots, %d photos: catalogue %.0f ms, scan %.0f ms, prune %.0f ms, total %.0f ms",
                                        roots.count, photos.count,
                                        tSnapshot.timeIntervalSince(rescanStart) * 1000,
                                        tScan.timeIntervalSince(tSnapshot) * 1000,
                                        tPrune.timeIntervalSince(tScan) * 1000,
                                        Date().timeIntervalSince(rescanStart) * 1000))
        startPreviewBuild()
    }

    /// Beyond this many photos the eager pass would run for minutes; the prefetcher is the right
    /// tool up there, and photos the user never opens never need a thumbnail.
    static let eagerBuildLimit = 1500
    private var didStartPreviewBuild = false

    /// Prepares every grid thumbnail once, in the background, right after the library settles.
    ///
    /// The prefetcher only ever warms a window around the viewport, so the rest of a freshly
    /// imported folder stayed cold until it was scrolled to — the user's "缓存建立还是不够快"
    /// was really "nobody ever asked for the other four hundred". Asking once, at bulk priority,
    /// turns a cost that was paid again on every visit into a cost paid once; the results go to
    /// disk, so the next launch is a folder read. Progress goes in the status line because it is
    /// otherwise twenty seconds of unexplained fan noise.
    func startPreviewBuild() {
        guard !didStartPreviewBuild, !photos.isEmpty, photos.count <= Self.eagerBuildLimit else { return }
        didStartPreviewBuild = true
        let list = photos
        let started = Date()
        ThumbnailCache.shared.resetStats()
        var lastReport = Date.distantPast
        ImageEngine.shared.buildThumbnails(for: list, displaySize: thumbnailSize, progress: { [weak self] done, total in
            guard let self else { return }
            let now = Date()
            guard now.timeIntervalSince(lastReport) > 0.4 || done == total else { return }
            lastReport = now
            self.statusMessage = StatusNote("Preparing previews %lld/%lld…", [done, total])
        }, finished: { [weak self] total in
            guard let self else { return }
            self.statusMessage = StatusNote("%lld photos in library", [self.photos.count])
            let elapsed = Date().timeIntervalSince(started)
            PicnidoAppDelegate.report(String(format: "[bulk] prepared %d previews in %.1f s (%.1f ms each across all workers) — %@",
                                            total, elapsed, elapsed * 1000 / Double(max(1, total)),
                                            ThumbnailCache.shared.statsLine()))
        })
    }

    // MARK: Scanning

    /// Every extension the scanner will pick up, as switched on by the user in Settings › File
    /// Types. Membership is a *claim*; what the file can actually be turned into is decided
    /// later, by ImageIO. `indexRow(for:)` drops anything ImageIO cannot read, so an over-broad
    /// list costs a stat call and nothing else — but a list that is too narrow loses photos
    /// silently, which is why the RAW variants are enumerated rather than guessed.
    ///
    /// The list itself lives in `FileTypeCatalog` (one source of truth for the scanner, the
    /// checkboxes and the plist); this is only the read side. An install that has never touched
    /// the setting reads as everything-on. Verified against `CGImageSourceCopyTypeIdentifiers()`
    /// on macOS 15.7.4 (`work/probe/formats.swift imageio`): all 39 resolve to a readable UTI.
    ///
    /// Read this into a local before a loop — it hits `UserDefaults`, and the directory walk
    /// asks once per file.
    static var imageExtensions: Set<String> { EnabledExtensions.current }

    // There is no `videoExtensions` here. One existed and was referenced by nothing: video was
    // never enumerated, never indexed and never shown. A constant that reads like support but
    // is wired to nothing is worse than its absence.

    /// Every image under `folder`, depth first, name-sorted. Pure file-system walking — no
    /// metadata is read here, which is what keeps it fast enough to run on every launch.
    ///
    /// Program trees are skipped, the same ones the sweep skips, so a root that happens to
    /// contain a WordPress backup cannot flood the grid with theme icons. `.skipsHiddenFiles`
    /// covers the dotted half of that rule already.
    static func enumerateImages(under folder: URL) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        guard let en = fm.enumerator(at: folder,
                                     includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        while let next = en.nextObject() {
            guard let f = next as? URL else { continue }
            let values = try? f.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                if FolderScanner.skipNames.contains(f.lastPathComponent) { en.skipDescendants() }
                continue
            }
            if imageExtensions.contains(f.pathExtension.lowercased()) { result.append(f) }
            if result.count > 50_000 { break }
        }
        return result
    }

    /// The pictures sitting *next to* `url` in its own folder, in Finder name order.
    ///
    /// Deliberately not `enumerateImages`: that one walks the whole tree, so a folder of
    /// albums would index thousands of pictures in other folders just to page through the one
    /// that was double-clicked. The immediate directory is the user's mental "this folder" —
    /// it is what Preview pages through and what the Finder column shows.
    ///
    /// Name order, not date order, and `localizedStandardCompare` rather than `<`: the library
    /// grid sorts by capture time, but a folder opened from the Finder should step through in
    /// the order the Finder displays, where `IMG_2` comes before `IMG_10`.
    nonisolated static func siblingImages(of url: URL) -> [URL] {
        let dir = url.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [url] }
        let images = names.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        return images.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    /// Reads the metadata for one file, off the main thread. Returns nil for anything ImageIO
    /// cannot make sense of, which is also how unsupported RAW variants get filtered out.
    nonisolated static func indexRow(for url: URL) -> IndexedPhoto? {
        let meta = MetadataReader.read(url: url)
        guard meta.pixelWidth > 0 else { return nil }
        return IndexedPhoto(path: url.path,
                            dir: url.deletingLastPathComponent().path,
                            name: url.lastPathComponent,
                            size: meta.fileSize,
                            mtime: meta.modified.timeIntervalSince1970,
                            btime: meta.created.timeIntervalSince1970,
                            width: meta.pixelWidth,
                            height: meta.pixelHeight,
                            orientation: meta.orientation,
                            exifJSON: LibraryStore.encodeExif(meta.exif),
                            lat: meta.geo?.latitude ?? 0,
                            lon: meta.geo?.longitude ?? 0,
                            geoPresent: meta.geo != nil)
    }

    static func encodeExif(_ exif: [String: String]) -> String {
        guard !exif.isEmpty, let data = try? JSONEncoder().encode(exif) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeExif(_ json: String) -> [String: String] {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// Scans one folder, streaming results in.
    func scan(folder: URL, known: [String: IndexedPhoto]? = nil) async {
        let rootPath = folder.standardizedFileURL.path
        let title = folder.lastPathComponent
        let started = Date()
        await MainActor.run {
            isScanning = true
            scanProgress = StatusNote("Scanning %@…", [title])
        }

        let urls = await Task.detached(priority: .userInitiated) {
            LibraryStore.enumerateImages(under: folder)
        }.value

        let knownRows: [String: IndexedPhoto]
        if let known {
            knownRows = known
        } else {
            knownRows = await Task.detached(priority: .utility) { [index] in
                var m: [String: IndexedPhoto] = [:]
                for row in index.loadAll() where row.path.hasPrefix(rootPath + "/") { m[row.path] = row }
                return m
            }.value
        }

        let recordSnapshot = await MainActor.run { self.records }

        // `.picasa.ini` is read once per folder, not once per photo. Reading it per photo meant a
        // five-hundred-photo import did five hundred redundant file opens.
        var iniRead: Set<String> = []
        var iniCache: [String: [String: SidecarINI.Section]] = [:]
        func iniEntry(_ url: URL) -> [String: String]? {
            let dir = url.deletingLastPathComponent()
            if !iniRead.contains(dir.path) {
                iniCache[dir.path] = SidecarINI.read(folder: dir)
                iniRead.insert(dir.path)
            }
            return iniCache[dir.path]?[url.lastPathComponent]?.values
        }

        var reused: [PhotoItem] = []
        var pending: [URL] = []
        var skippedSmall = 0
        for url in urls {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            // The size floor applies to the library, not just to the sweep that found the folder.
            // Asking for "ignore anything under 100 KB" and then getting three hundred theme
            // icons in the grid is precisely the complaint this answers.
            if minPhotoBytes > 0, size < minPhotoBytes { skippedSmall += 1; continue }
            if let row = knownRows[url.path], row.mtime == mtime, row.size == size {
                reused.append(makePhoto(from: row, ini: iniEntry(url), record: recordSnapshot[url.path]))
            } else {
                pending.append(url)
            }
        }
        if skippedSmall > 0 {
            PicnidoAppDelegate.report("[scan] \(title): skipped \(skippedSmall) files under \(Self.sizeText(minPhotoBytes))")
        }

        if !reused.isEmpty {
            let items = reused
            await MainActor.run { mergePhotos(items) }
        }

        let batch = max(4, ProcessInfo.processInfo.activeProcessorCount)
        var cursor = 0
        while cursor < pending.count {
            let slice = Array(pending[cursor..<min(cursor + batch, pending.count)])
            let prepared = slice.map { ($0, iniEntry($0)) }
            let rows = await withTaskGroup(of: IndexedPhoto?.self) { group -> [IndexedPhoto] in
                for (url, _) in prepared {
                    group.addTask(priority: .userInitiated) { LibraryStore.indexRow(for: url) }
                }
                var out: [IndexedPhoto] = []
                for await r in group { if let r { out.append(r) } }
                return out
            }
            var iniByPath: [String: [String: String]] = [:]
            for (url, entry) in prepared { if let entry { iniByPath[url.path] = entry } }
            let items = rows.map {
                makePhoto(from: $0, ini: iniByPath[$0.path], record: recordSnapshot[$0.path])
            }
            index.upsert(rows)
            let done = min(cursor + batch, pending.count)
            await MainActor.run {
                mergePhotos(items)
                scanProgress = StatusNote("Scanning %@… %lld/%lld", [title, done, pending.count])
            }
            cursor += batch
        }

        await MainActor.run {
            isScanning = false
            scanProgress = StatusNote()
            statusMessage = StatusNote("%lld photos in library", [photos.count])
        }
        PicnidoAppDelegate.report(String(format: "[scan] %@: %d files, %d from catalogue, %d re-read, %.0f ms total",
                                        title, urls.count, reused.count, pending.count,
                                        Date().timeIntervalSince(started) * 1000))
    }

    /// Inserts or refreshes a batch without disturbing the rest of the library.
    @MainActor
    private func mergePhotos(_ items: [PhotoItem]) {
        guard !items.isEmpty else { return }
        var byID: [String: PhotoItem] = [:]
        byID.reserveCapacity(photos.count + items.count)
        for p in photos { byID[p.id] = p }
        for item in items { byID[item.id] = item }
        photos = Array(byID.values)
        invalidateDerived()
    }

    /// Drops the derived caches (folder tree, filtered list). Called whenever `photos`, `roots`
    /// or `records` move.
    func invalidateDerived() {
        treeSignature = ""
        visibleSignature = ""
        contentVersion &+= 1
    }

    /// Dev hook (`PICNIDO_ROOTS=a:b:c`): point the library at a given set of folders for one
    /// scripted run. Deliberately never persisted — a verification run must not disturb the
    /// library the user actually works with.
    func setRootsTransient(_ urls: [URL]) {
        roots = urls.map { $0.standardizedFileURL }
        photos = []
        selection.removeAll()
        invalidateDerived()
    }

    func makePhoto(from row: IndexedPhoto,
                   ini: [String: String]? = nil,
                   record: PhotoRecord? = nil) -> PhotoItem {        var item = PhotoItem(url: URL(fileURLWithPath: row.path))
        item.fileSize = row.size
        item.modified = Date(timeIntervalSince1970: row.mtime)
        item.created = Date(timeIntervalSince1970: row.btime > 0 ? row.btime : row.mtime)
        item.pixelWidth = row.width
        item.pixelHeight = row.height
        item.exifOrientation = row.orientation
        item.exif = LibraryStore.decodeExif(row.exifJSON)
        item.geo = row.geo
        // Merge the on-disk .picasa.ini produced by the original app, if present.
        if let ini {
            if let s = ini["star"] { item.starred = (s == "yes" || s == "1") }
            if let c = ini["caption"] { item.caption = c }
            if let k = ini["keywords"] {
                item.tags = k.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        }
        if let r = record {
            if !r.caption.isEmpty { item.caption = r.caption }
            if r.starred { item.starred = true }
            if !r.tags.isEmpty { item.tags = r.tags }
            item.stack = r.stack
            item.hidden = r.hidden
            item.colorLabel = r.colorLabel
            if item.geo == nil { item.geo = r.geo }
        }
        return item
    }

    func refresh(_ url: URL) async {
        guard let row = await Task.detached(priority: .utility) { LibraryStore.indexRow(for: url) }.value else { return }
        index.upsert([row])
        let record = await MainActor.run { self.records[row.path] }
        let item = makePhoto(from: row, record: record)
        await MainActor.run { mergePhotos([item]) }
    }

    // MARK: Derived collections
    //
    // Both of these are recomputed lazily and memoised. They are read several times per view
    // body, and with a five-hundred-photo library a filter-plus-sort on every access is
    // milliseconds of work per frame — enough to be felt while scrolling.

    private var treeCache: [FolderNode] = []
    private var treeSignature = "\u{0}"
    private var visibleCache: [PhotoItem] = []
    private var visibleSignature = "\u{0}"
    private var contentVersion = 0

    /// The sidebar's folder tree.
    var folderTree: [FolderNode] {
        let sig = "\(roots.count)|\(photos.count)|\(contentVersion)"
        if sig == treeSignature { return treeCache }
        var counts: [String: Int] = [:]
        counts.reserveCapacity(64)
        for p in photos { counts[p.folder.path, default: 0] += 1 }
        treeCache = FolderNode.build(roots: roots.map { $0.standardizedFileURL.path }, counts: counts)
        treeSignature = sig
        return treeCache
    }

    /// Every folder that holds a photo, roots first. Kept because other parts of the UI (the
    /// information panel, screensaver sources) still want the flat list.
    var folderPaths: [String] {
        var seen = Set<String>()
        var out: [String] = []
        let base = roots.map(\.path)
        for p in photos.map({ $0.folder.path }) where !seen.contains(p) {
            seen.insert(p); out.append(p)
        }
        return out.sorted { a, b in
            let da = base.contains { a.hasPrefix($0) }
            let db = base.contains { b.hasPrefix($0) }
            if da != db { return da }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    var allTags: [String] {
        var counts: [String: Int] = [:]
        for p in photos { for t in p.tags { counts[t, default: 0] += 1 } }
        return counts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var geoPhotos: [PhotoItem] { photos.filter { $0.geo != nil } }

    var hiddenPhotos: [PhotoItem] { photos.filter { $0.hidden } }

    func colorLabelCount(_ index: Int) -> Int { photos.filter { $0.colorLabel == index }.count }

    /// The date span of the library, as a convenience for the filter's range picker.
    var dateSpan: ClosedRange<Date>? {
        let dates = photos.map(\.created).filter { $0 != .distantPast }
        guard let lo = dates.min(), let hi = dates.max(), lo < hi else { return nil }
        return lo...hi
    }

    /// Photos visible for the current sidebar selection, before the search box.
    func photos(in view: LibraryView) -> [PhotoItem] {
        switch view {
        case .allPhotos:
            return photos
        case .starred:
            return photos.filter { $0.starred }
        case .recent:
            return photos.filter { $0.hasEdits }
        case .folder(let path):
            return photos.filter { $0.url.path.hasPrefix(path.hasSuffix("/") ? path : path + "/") }
        case .album(let id):
            guard let a = albums.first(where: { $0.id == id }) else { return [] }
            let set = Set(a.members)
            return photos.filter { set.contains($0.id) }
        case .tag(let t):
            return photos.filter { $0.tags.contains(t) }
        case .places:
            return photos.filter { $0.geo != nil }
        case .screensaverFolder(let path):
            return photos.filter { $0.url.path.hasPrefix(path) }
        case .colorLabel(let i):
            return photos.filter { $0.colorLabel == i }
        case .hidden:
            return photos.filter { $0.hidden }
        }
    }

    /// The final, sorted, filtered list the grid renders. Memoised — see the note above.
    var visiblePhotos: [PhotoItem] {
        let sig = "\(contentVersion)|\(view)|\(starredOnly)|\(searchText)|\(sort.rawValue)|\(ascending)"
            + "|\(showHidden)|\(colorLabelFilter.map(String.init) ?? "-")"
            + "|\(dateFrom?.timeIntervalSince1970 ?? -1)|\(dateTo?.timeIntervalSince1970 ?? -1)"
        if sig == visibleSignature { return visibleCache }
        var list = photos(in: view)
        // Hiding is a view-level idea, not a property of the `.hidden` destination itself —
        // otherwise "Hidden Photos" would always be empty.
        if !showHidden, view != .hidden { list = list.filter { !$0.hidden } }
        if let label = colorLabelFilter { list = list.filter { $0.colorLabel == label } }
        if let from = dateFrom { list = list.filter { $0.created >= from } }
        if let to = dateTo { list = list.filter { $0.created <= to } }
        if starredOnly { list = list.filter { $0.starred } }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            let needle = q.lowercased()
            list = list.filter { p in
                p.fileName.lowercased().contains(needle)
                || p.caption.lowercased().contains(needle)
                || p.tags.contains { $0.lowercased().contains(needle) }
            }
        }
        list.sort { a, b in
            let r: Bool
            switch sort {
            case .fileName: r = a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
            case .dateTaken: r = a.created < b.created
            case .dateModified: r = a.modified < b.modified
            case .size: r = a.fileSize < b.fileSize
            case .star: r = (a.starred ? 1 : 0, a.fileName) < (b.starred ? 1 : 0, b.fileName)
            }
            return ascending ? r : !r
        }
        visibleSignature = sig
        visibleCache = list
        return list
    }

    // MARK: Mutations

    func update(_ id: String, _ mutate: (inout PhotoItem) -> Void) {
        guard let idx = photos.firstIndex(where: { $0.id == id }) else { return }
        mutate(&photos[idx])
        invalidateDerived()
        saveSoon()
    }

    func photo(_ id: String) -> PhotoItem? { photos.first { $0.id == id } }

    func toggleStar(_ id: String) {
        update(id) { $0.starred.toggle() }
        syncINI(for: id)
    }

    // MARK: Colour labels and hiding

    /// Applies one of the six colour labels to a batch. 0 clears the label.
    ///
    /// Deliberately *not* written into `.picasa.ini`: the original kept labels in its own
    /// database rather than in the per-folder ini (which carries only star/caption/keywords),
    /// so writing one here would invent a file format the original never read.
    func setColorLabel(_ index: Int, ids: [String]) {
        let clamped = max(0, min(6, index))
        var changed = 0
        for id in ids {
            guard let i = photos.firstIndex(where: { $0.id == id }) else { continue }
            if photos[i].colorLabel == clamped { continue }
            photos[i].colorLabel = clamped
            changed += 1
        }
        guard changed > 0 else { return }
        invalidateDerived()
        saveSoon()
        statusMessage = clamped == 0
            ? StatusNote("Cleared the colour label on %lld photo\(changed == 1 ? "" : "s")", [changed])
            : StatusNote("%@ label on %lld photo\(changed == 1 ? "" : "s")", [ColorLabel.name(clamped), changed])
    }

    func setHidden(_ hidden: Bool, ids: [String]) {
        var changed = 0
        for id in ids {
            guard let i = photos.firstIndex(where: { $0.id == id }) else { continue }
            if photos[i].hidden == hidden { continue }
            photos[i].hidden = hidden
            changed += 1
        }
        guard changed > 0 else { return }
        // A hidden photo must not stay selected: it is about to disappear from the grid, and a
        // selection pointing at something invisible makes every following command a surprise.
        if hidden { selection.subtract(ids) }
        invalidateDerived()
        saveSoon()
        if hidden, visiblePhotos.isEmpty, !photos.isEmpty {
            statusMessage = StatusNote("Every photo in this view is hidden — turn on Show Hidden to see them")
        } else {
            statusMessage = hidden
                ? StatusNote("Hid %lld photo\(changed == 1 ? "" : "s") — View ▸ Show Hidden brings them back", [changed])
                : StatusNote("Unhid %lld photo\(changed == 1 ? "" : "s")", [changed])
        }
    }

    // MARK: Rename files

    struct RenameOutcome {
        var renamed = 0
        var failed = 0
        var unchanged = 0
        var firstError: String?

        /// The line the top bar shows afterwards.
        ///
        /// Built by appending clauses rather than by interpolating one long sentence, because the
        /// list is variable: a clean run says one thing, a run with failures says three. Each clause
        /// is its own table entry, and each brings its own leading ", " with it — see
        /// `StatusNote.Part`.
        var summary: StatusNote {
            if let firstError, renamed == 0 {
                return StatusNote("Rename failed: %@", [firstError])
            }
            var note = StatusNote("Renamed %lld file\(renamed == 1 ? "" : "s")", [renamed])
            if unchanged > 0 { note.append(", %lld already had that name", [unchanged]) }
            if failed > 0 { note.append(", %lld failed", [failed]) }
            if let firstError, failed > 0 { note.append(" (%@)", [firstError]) }
            return note
        }
    }

    /// Notified as `(oldPath, newPath)` after a file has been renamed.
    ///
    /// Anything that keys on a photo *path* but lives outside this class — the editor's current
    /// target, the viewer's, the inspector's — has to follow a rename too. The store cannot know
    /// about those, and a rename that leaves them pointing at a path that no longer exists shows
    /// up later as a blank editor, which is a confusing way to learn a file moved.
    var pathRemapObservers: [(String, String) -> Void] = []

    /// Renames files on disk and moves everything keyed by the old path along with them.
    ///
    /// The move is a plain `moveItem` within the same folder — no copying, no overwriting (the
    /// planner has already guaranteed every destination is free), and nothing leaves its folder.
    /// Every path-keyed thing in the library has to follow: the records (star/caption/edit
    /// stack), album membership, the tray, the selection, and the SQLite catalogue. Forgetting
    /// one of those is how a rename silently discards a photo's edits.
    @discardableResult
    func applyRename(_ plan: [RenamePlan]) -> RenameOutcome {
        var outcome = RenameOutcome()
        var movedPairs: [(String, String)] = []
        for step in plan {
            do {
                try FileManager.default.moveItem(at: step.from, to: step.to)
                remapPath(from: step.from, to: step.to)
                movedPairs.append((step.from.path, step.to.path))
                outcome.renamed += 1
            } catch {
                outcome.failed += 1
                if outcome.firstError == nil { outcome.firstError = error.localizedDescription }
            }
        }
        guard !movedPairs.isEmpty else {
            statusMessage = outcome.summary
            return outcome
        }
        invalidateDerived()
        saveNow()
        let pairs = movedPairs
        Task {
            index.delete(paths: pairs.map(\.0))
            let rows = await Task.detached(priority: .utility) { () -> [IndexedPhoto] in
                pairs.compactMap { LibraryStore.indexRow(for: URL(fileURLWithPath: $0.1)) }
            }.value
            index.upsert(rows)
        }
        statusMessage = outcome.summary
        return outcome
    }

    /// Rewrites every path-keyed structure after a file has been renamed.
    private func remapPath(from old: URL, to new: URL) {
        let oldPath = old.path
        let newPath = new.path
        if let i = photos.firstIndex(where: { $0.url.path == oldPath }) {
            photos[i].url = new
        }
        if let record = records.removeValue(forKey: oldPath) { records[newPath] = record }
        for i in albums.indices {
            albums[i].members = albums[i].members.map { $0 == oldPath ? newPath : $0 }
        }
        if let t = tray.firstIndex(of: oldPath) { tray[t] = newPath }
        if selection.remove(oldPath) != nil { selection.insert(newPath) }
        for observe in pathRemapObservers { observe(oldPath, newPath) }
    }

    // MARK: Adjust photo date

    /// Shifts or sets the created/modified stamps of a batch, on disk and in the catalogue.
    ///
    /// This is the fix for the two classic photo-date bugs: a camera whose clock was set to the
    /// wrong time zone (shift everything by ±N hours) and a scan that landed with today's date
    /// (set one file to the date on the print). Nothing is irreversible here — running the
    /// opposite shift puts it back.
    @discardableResult
    func adjustDates(ids: [String], _ adjustment: FileOrganizer.DateAdjustment) -> (ok: Int, failed: Int, firstError: String?) {
        var ok = 0
        var failed = 0
        var firstError: String?
        var touched: [URL] = []
        for id in ids {
            guard let i = photos.firstIndex(where: { $0.id == id }) else { continue }
            let photo = photos[i]
            let (created, modified) = FileOrganizer.adjustedDates(photo, adjustment)
            do {
                try FileManager.default.setAttributes([.creationDate: created, .modificationDate: modified],
                                                     ofItemAtPath: photo.url.path)
            } catch {
                failed += 1
                if firstError == nil { firstError = error.localizedDescription }
                continue
            }
            photos[i].created = created
            photos[i].modified = modified
            touched.append(photo.url)
            ok += 1
        }
        guard ok > 0 else {
            statusMessage = StatusNote("Could not change any photo date: %@", [firstError ?? "unknown error"])
            return (0, failed, firstError)
        }
        invalidateDerived()
        let urls = touched
        Task {
            let rows = await Task.detached(priority: .utility) { () -> [IndexedPhoto] in
                urls.compactMap { LibraryStore.indexRow(for: $0) }
            }.value
            index.upsert(rows)
        }
        var note = StatusNote("Adjusted the date on %lld photo\(ok == 1 ? "" : "s")", [ok])
        if failed > 0 { note.append(", %lld failed", [failed]) }
        statusMessage = note
        return (ok, failed, firstError)
    }

    func setCaption(_ id: String, _ text: String) {
        update(id) { $0.caption = text }
        syncINI(for: id)
    }

    func addTag(_ id: String, _ tag: String) {
        let t = tag.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        update(id) { if !$0.tags.contains(t) { $0.tags.append(t) } }
        syncINI(for: id)
    }

    func removeTag(_ id: String, _ tag: String) {
        update(id) { $0.tags.removeAll { $0 == tag } }
        syncINI(for: id)
    }

    func push(_ id: String, _ op: EditOp) {
        update(id) {
            $0.stack.append(EditStep(op: op))
            $0.redoStack.removeAll()
        }
    }

    func undo(_ id: String) {
        update(id) {
            guard let last = $0.stack.popLast() else { return }
            $0.redoStack.append(last)
        }
    }

    func redo(_ id: String) {
        update(id) {
            guard let last = $0.redoStack.popLast() else { return }
            $0.stack.append(last)
        }
    }

    func clearEdits(_ id: String) {
        update(id) { $0.stack.removeAll(); $0.redoStack.removeAll() }
    }

    /// Swaps the *effect* part of the edit stack, keeping the structural part.
    ///
    /// "Paste All Effects" in the original replaced the photo's effect list. Dropping the whole
    /// stack here would also throw away the crop and the straightening — work that has nothing
    /// to do with the effects being pasted — so the structural steps stay exactly where they
    /// were and only what `transferableSteps` would have copied is replaced.
    func replaceEffects(_ id: String, with steps: [EditStep]) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        let structural = photos[i].stack.filter { $0.op.isStructural }
        photos[i].stack = structural + steps
        photos[i].redoStack.removeAll()
        invalidateDerived()
        saveSoon()
    }

    func applyToSelection(appending op: EditOp) {
        for id in selection { push(id, op) }
    }

    // MARK: Tray helpers

    func addToTray(_ ids: [String]) {
        for id in ids where !tray.contains(id) { tray.append(id) }
    }

    func removeFromTray(_ ids: [String]) { tray.removeAll { ids.contains($0) } }
    func clearTray() { tray.removeAll() }
    var trayPhotos: [PhotoItem] { tray.compactMap { photo($0) } }

    // MARK: Albums

    func createAlbum(named name: String, with ids: [String]) {
        var a = Album(name: name)
        a.members = ids
        albums.append(a)
        invalidateDerived()
        saveSoon()
    }

    func addToAlbum(_ albumID: UUID, ids: [String]) {
        guard let i = albums.firstIndex(where: { $0.id == albumID }) else { return }
        for id in ids where !albums[i].members.contains(id) { albums[i].members.append(id) }
        invalidateDerived()
        saveSoon()
    }

    func deleteAlbum(_ id: UUID) {
        albums.removeAll { $0.id == id }
        if case .album(let v) = view, v == id { view = .allPhotos }
        invalidateDerived()
        saveSoon()
    }

    func renameAlbum(_ id: UUID, to name: String) {
        guard let i = albums.firstIndex(where: { $0.id == id }) else { return }
        albums[i].name = name
        saveSoon()
    }

    // MARK: .picasa.ini interop (the format the original app wrote)

    func syncINI(for id: String) {
        guard let photo = photo(id) else { return }
        SidecarINI.writeStarCaptionTags(
            folder: photo.folder,
            fileName: photo.fileName,
            starred: photo.starred,
            caption: photo.caption,
            tags: photo.tags
        )
    }
}
