import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

// MARK: - Size buckets

/// The pixel sizes we are willing to materialise and store.
///
/// A continuously draggable "thumbnail size" slider would otherwise ask for a new pixel size
/// on every frame of the drag and fill the cache with thousands of near-identical entries.
/// Requests snap *up* to the next step, so the cache stays bounded and the disk keeps a
/// handful of sizes per photo instead of hundreds.
enum ThumbBuckets {
    static let steps: [Int] = [64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096, 6144, 8192]

    static func snap(_ pixels: Int) -> Int {
        for s in steps where s >= pixels { return s }
        return steps[steps.count - 1]
    }

    /// The step just above the requested one, or nil at the top — used to decide whether a
    /// sharper render is available without going all the way to the original.
    static func next(after pixels: Int) -> Int? {
        for s in steps where s > pixels { return s }
        return nil
    }
}

// MARK: - Cache

/// Two-tier thumbnail store: a bounded in-memory `NSCache` in front of a sharded JPEG store on
/// disk.
///
/// Why this exists
/// ---------------
/// The first version of this app decoded straight from the file on every request, with only an
/// in-process `NSCache` in front of it. That is fine for a hundred photos and falls over at
/// five hundred: every cold launch re-decoded everything, scrolling outran the decoder, and
/// opening the viewer on a 24-megapixel frame meant a full-resolution decode plus a CoreImage
/// pass before anything appeared on screen.
///
/// This is the same shape the original app used — it kept its thumbnails in a database under
/// the user's profile and never re-decoded a file it had already seen. What we keep on disk is
/// only a small JPEG per (file, mtime, size), which is a fraction of the original's cost to
/// produce and turns every subsequent launch into a folder read.
///
/// Concurrency
/// -----------
/// Generation is capped at `max(2, cores - 1)` operations. One detached task per visible cell
/// used to mean hundreds of simultaneous decodes fighting for the same disk, which is why
/// scrolling got *worse* the faster the user scrolled. Requests for the same key are also
/// coalesced, so ten cells asking for the same photo produce one decode.
final class ThumbnailCache {

    static let shared = ThumbnailCache()

    /// A decoded thumbnail plus the byte cost we charge `NSCache` for it.
    private final class Box {
        let image: CGImage
        let cost: Int
        init(_ image: CGImage) {
            self.image = image
            self.cost = image.bytesPerRow * image.height
        }
    }

    /// Where a caller sits in the queue.
    ///
    /// * `visible` — something on screen is waiting for it. Highest priority, its own queue.
    /// * `warm` — speculative prefetch for what the user is about to scroll to. Thrown away
    ///   wholesale when they move on.
    /// * `bulk` — an explicit whole-folder build. Measured on an 11 GB / 554-photo folder:
    ///   4 warm slots took 23.4 s, 8 bulk slots 18.7 s, 12 with a raised QoS 16.9 s. Same work,
    ///   same decoder, 28% less wall time — the limit was never the decode, it was how much of
    ///   the machine the work was allowed to use. Warm work stays throttled (it must not crowd
    ///   out the viewport); a build the user asked for does not have to be.
    enum Priority { case visible, warm, bulk }

    // MARK: State

    private let memory = NSCache<NSString, Box>()
    private let lock = NSLock()
    private var inFlight: [String: [(CGImage?) -> Void]] = [:]
    private var failures: Set<String> = []
    /// Keys already given an extra high-priority operation, so a burst of visible requests for
    /// the same key promotes it once rather than once per request.
    private var promoted: Set<String> = []

    private let visibleQueue: OperationQueue
    private let warmQueue: OperationQueue
    private let bulkQueue: OperationQueue

    /// Disk store root.
    let root: URL
    private let thumbsDir: URL

    private let diskQueue = DispatchQueue(label: "picnido.thumbs.disk", qos: .utility)

    private var generated = 0
    private var diskHits = 0
    private var memoryHits = 0
    private var coalesced = 0

    // MARK: Init

    private init() {
        // PICNIDO_THUMB_DIR lets a scripted run use a scratch store, so a measurement pass can
        // start genuinely cold without evicting the user's real cache. Read through `DevHook`,
        // not the environment: the run that needs a cold store most is the one LaunchServices
        // started — a real double-click, the only kind that reproduces a Finder open — and that
        // one cannot be given an environment variable at all.
        if let override = DevHook.string("PICNIDO_THUMB_DIR") {
            root = URL(fileURLWithPath: override)
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            root = caches.appendingPathComponent("Picnido", isDirectory: true)
        }
        thumbsDir = root.appendingPathComponent("thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)

        memory.countLimit = 20_000
        memory.totalCostLimit = 320 * 1024 * 1024

        let cores = max(2, ProcessInfo.processInfo.activeProcessorCount)
        visibleQueue = OperationQueue()
        visibleQueue.name = "picnido.thumbs.visible"
        visibleQueue.maxConcurrentOperationCount = max(2, cores - 2)
        visibleQueue.qualityOfService = .userInitiated

        // Prefetch is deliberately throttled — it must never crowd out what is on screen — but
        // two slots was far too few to keep up with a scroll: measured on a cold cache, a grid
        // cell entering the viewport waited a median of 1891 ms for its picture. Four, plus real
        // promotion (see `promote`), is the working compromise.
        warmQueue = OperationQueue()
        warmQueue.name = "picnido.thumbs.warm"
        warmQueue.maxConcurrentOperationCount = 4
        warmQueue.qualityOfService = .utility

        // The explicit build pass. Sized to the machine rather than to a fixed number: the work
        // is one long file read plus a decode per photo, so it scales until the disk or the cores
        // run out. `PICNIDO_WARM_SLOTS` overrides it, which is how the numbers above were taken.
        bulkQueue = OperationQueue()
        bulkQueue.name = "picnido.thumbs.bulk"
        bulkQueue.maxConcurrentOperationCount = max(1, Int(ProcessInfo.processInfo.environment["PICNIDO_WARM_SLOTS"] ?? "")
                                                    ?? max(4, cores - 2))
        bulkQueue.qualityOfService = .userInitiated

        diskQueue.async { [weak self] in self?.pruneIfNeeded() }
    }

    // MARK: Keys

    /// A key that changes when the bytes on disk would change, when the edits change, or when
    /// the requested size changes. Stable across launches — that is what makes the disk cache
    /// survive a restart, and it is why the edit stack is hashed with SHA-256 rather than
    /// `hashValue` (Swift randomises string hashing per process).
    ///
    /// The policy tag is the one field that is not about the picture. Thumbnails are JPEGs on
    /// disk, so a change to *how* one is produced silently outlives the code that made it: the
    /// poisoned entry keeps being served, and the fix looks like it did nothing. Bumping the tag
    /// retires every thumbnail an older policy wrote, at the price of one rebuild.
    ///   e1 — first policy
    ///   e2 — a file's own preview is only used when it is at least the size asked for, and when
    ///        it is shaped like the frame. (See `embeddedQualityGate` for what e1 got wrong.)
    static let renderPolicy = "e2"

    func key(for photo: PhotoItem, pixels: Int) -> String {
        let stamp = Int(photo.modified.timeIntervalSince1970)
        return "\(photo.url.path)|\(stamp)|\(photo.fileSize)|\(editTag(photo))|\(Self.renderPolicy)|\(pixels)"
    }

    private func editTag(_ photo: PhotoItem) -> String {
        guard photo.hasEdits else { return "s0" }
        guard let data = try? JSONEncoder().encode(photo.stack) else { return "s?" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    private func url(forKey key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let shard = String(digest.prefix(2))
        return thumbsDir.appendingPathComponent(shard, isDirectory: true)
            .appendingPathComponent(String(digest.dropFirst(2).prefix(38)) + ".jpg")
    }

    // MARK: Lookup

    /// Memory-only. Safe to call from a view body — never touches the file system.
    func cached(_ key: String) -> CGImage? {
        if let hit = memory.object(forKey: key as NSString) {
            memoryHits += 1
            return hit.image
        }
        return nil
    }

    /// Stores a bitmap the caller produced itself (the viewer's crop renders). Nothing touches
    /// the disk: a screen-sized crop of one photo is worthless the moment the user moves on.
    func adopt(_ image: CGImage, key: String) {
        memory.setObject(Box(image), forKey: key as NSString)
    }

    func cached(photo: PhotoItem, pixels: Int) -> CGImage? {
        cached(key(for: photo, pixels: ThumbBuckets.snap(pixels)))
    }

    /// Synchronous full lookup — memory, then disk, then decode. Blocks the caller, so it is
    /// only for scripted verification and for the editor where we genuinely need the pixels now.
    func imageNow(photo: PhotoItem, pixels: Int, transform: ((CGImage) -> CGImage?)?) -> CGImage? {
        let snapped = ThumbBuckets.snap(pixels)
        let key = key(for: photo, pixels: snapped)
        if let hit = cached(key) { return hit }
        if let fromDisk = loadFromDisk(key: key) {
            memory.setObject(Box(fromDisk), forKey: key as NSString)
            diskHits += 1
            return fromDisk
        }
        guard let raw = ThumbnailCache.render(url: photo.url, pixels: snapped) else { return nil }
        let out = transform?(raw) ?? raw
        store(key: key, image: out)
        return out
    }

    /// The main entry point. Resolves on the main queue; calls `completion` exactly once.
    ///
    /// - Parameter transform: applied after decoding, for photos that carry edits. Runs on the
    ///   cache's own worker queue, so it must not touch UI state.
    func request(photo: PhotoItem, pixels: Int, priority: Priority = .visible,
                 transform: ((CGImage) -> CGImage?)? = nil,
                 completion: @escaping (CGImage?) -> Void) {
        let snapped = ThumbBuckets.snap(pixels)
        let key = key(for: photo, pixels: snapped)

        if let hit = cached(key) {
            DispatchQueue.main.async { completion(hit) }
            return
        }

        lock.lock()
        if failures.contains(key), priority != .visible {
            lock.unlock()
            DispatchQueue.main.async { completion(nil) }
            return
        }
        // Coalesce: the same key requested twice while the first decode is in flight.
        if inFlight[key] != nil {
            inFlight[key]?.append(completion)
            coalesced += 1
            // A visible request must not stay behind the prefetch that happened to claim it
            // first: see `promote`.
            let wantsPromotion = priority == .visible && !promoted.contains(key)
            if wantsPromotion { promoted.insert(key) }
            lock.unlock()
            if wantsPromotion {
                promote(photo: photo, pixels: snapped, key: key, transform: transform)
            }
            return
        }
        inFlight[key] = [completion]
        lock.unlock()

        enqueue(queue(for: priority), priority: priority,
                photo: photo, pixels: snapped, key: key, transform: transform)
    }

    private func queue(for priority: Priority) -> OperationQueue {
        switch priority {
        case .visible: return visibleQueue
        case .warm: return warmQueue
        case .bulk: return bulkQueue
        }
    }

    /// Adds a second, high-priority operation for a key someone else is already decoding.
    ///
    /// Without this the two-queue arrangement could not help a scroll at all. A photo the user
    /// had just scrolled *to* would be claimed by whichever prefetch wave passed over it first,
    /// land on the warm queue with its two slots, and stay there while the eight visible slots
    /// sat idle — the visible request merely coalesced onto that job and waited. The median wait
    /// for a newly visible cell was 1891 ms.
    ///
    /// (The old code named this intent `bumpToVisible` and then did nothing, on the reasonable-
    /// sounding grounds that re-queueing a job already on a queue would decode it twice. The
    /// guard at the top of the operation is what makes the duplicate safe: if the original
    /// finished first, the second operation stands down without touching the decoder.)
    private func promote(photo: PhotoItem, pixels: Int, key: String,
                         transform: ((CGImage) -> CGImage?)?) {
        enqueue(visibleQueue, priority: .visible,
                photo: photo, pixels: pixels, key: key, transform: transform)
    }

    private func enqueue(_ queue: OperationQueue, priority: Priority,
                         photo: PhotoItem, pixels: Int, key: String,
                         transform: ((CGImage) -> CGImage?)?) {
        let work = BlockOperation { [weak self] in
            guard let self else { return }
            // Stand down if some other operation already produced this key while this one was
            // waiting its turn. Nothing to decode, and `finish` has already run.
            self.lock.lock()
            let stillWanted = self.inFlight[key] != nil
            self.lock.unlock()
            guard stillWanted else { return }

            var image: CGImage?
            if let fromDisk = self.loadFromDisk(key: key) {
                self.diskHits += 1
                image = fromDisk
            } else if let raw = ThumbnailCache.render(url: photo.url, pixels: pixels) {
                self.generated += 1
                image = transform?(raw) ?? raw
                if let image { self.writeToDisk(key: key, image: image) }
            }
            self.finish(key: key, image: image)
        }
        switch priority {
        case .visible:
            work.qualityOfService = .userInitiated
            work.queuePriority = .veryHigh
        case .warm:
            work.qualityOfService = .utility
            work.queuePriority = .low
        case .bulk:
            // `.high`, not `.veryHigh`: a build should lose the race for a free core to something
            // the user is looking at, and win it against idle-time prefetch.
            work.qualityOfService = .userInitiated
            work.queuePriority = .high
        }
        queue.addOperation(work)
    }

    /// Builds a thumbnail for every photo in `photos` and reports progress.
    ///
    /// This is the "prepare this folder" pass. It is deliberately not the prefetcher: the
    /// prefetcher only ever looks a window ahead of the viewport, so a folder was otherwise
    /// warmed at the speed the user happened to scroll it — which is why scrolling a freshly
    /// imported folder still felt like waiting for a cache to fill. Requests go through the same
    /// entry point as everything else, so a photo already on disk costs nothing and one the
    /// viewport asks for at the same moment is decoded once, not twice.
    @discardableResult
    func buildCache(photos: [PhotoItem], pixels: Int,
                    transform: (PhotoItem) -> ((CGImage) -> CGImage?)? = { _ in nil },
                    progress: @escaping (Int, Int) -> Void = { _, _ in },
                    finished: @escaping (Int) -> Void = { _ in }) -> Int {
        let total = photos.count
        guard total > 0 else { finished(0); return 0 }
        let box = Counter(expecting: total)
        // Report about forty times over the whole pass rather than once per photo, so the status
        // line moves smoothly without a main-queue hop per tile.
        let every = max(1, total / 40)
        for photo in photos {
            request(photo: photo, pixels: pixels, priority: .bulk,
                    transform: transform(photo)) { _ in
                let count = box.complete()
                if count % every == 0 || count == total { progress(count, total) }
                if count == total {
                    self.quiet()
                    finished(total)
                }
            }
        }
        return total
    }

    /// A tiny lock-protected counter — `@unchecked Sendable` because that is what the lock is for.
    ///
    /// It counts *completions*, not requests. Getting that wrong is easy and the symptom is quiet:
    /// an earlier version counted up as the loop dispatched, so the very first completion already
    /// read "554 of 554" and the pass reported itself finished before it had started.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private let expected: Int
        private var done = 0
        init(expecting: Int) { expected = expecting }
        /// Returns how many have finished, 1…`expected`.
        func complete() -> Int { lock.lock(); defer { lock.unlock() }; done += 1; return done }
    }

    /// Forgets the "recently failed" set, so a file that was momentarily unreadable gets another
    /// chance on the next pass instead of being skipped for the rest of the session.
    func quiet() { lock.lock(); failures.removeAll(); lock.unlock() }

    private func finish(key: String, image: CGImage?) {
        lock.lock()
        let waiting = inFlight.removeValue(forKey: key) ?? []
        promoted.remove(key)
        if image == nil { failures.insert(key) }
        lock.unlock()
        DispatchQueue.main.async {
            for c in waiting { c(image) }
        }
    }

    // MARK: Prefetch

    /// Warms a window of photos around the current position. `warmQueue` is drained first so a
    /// fast scroll does not leave the cache building pictures the user has already passed.
    ///
    /// The transform is resolved per photo because an edited photo needs its own stack applied,
    /// and a prefetch wave usually mixes edited and untouched files.
    func prefetch(photos: [PhotoItem], pixels: Int,
                  transform: (PhotoItem) -> ((CGImage) -> CGImage?)? = { _ in nil }) {
        guard !photos.isEmpty else { return }
        let snapped = ThumbBuckets.snap(pixels)
        for photo in photos {
            // Bounded backlog. A fast scroll through a long folder would otherwise queue up work
            // for pictures the user has already flown past; the queue is drained in order, so
            // capping the depth keeps it close to the pointer. It no longer has to be huge to
            // keep the viewport responsive — a visible request promotes its own key — so this is
            // sized to "one window ahead", not to "absorb a scroll".
            if warmQueue.operationCount > 200 { return }
            let key = key(for: photo, pixels: snapped)
            lock.lock()
            let busy = inFlight[key] != nil
            lock.unlock()
            if busy || cached(key) != nil { continue }
            request(photo: photo, pixels: snapped, priority: .warm,
                    transform: transform(photo), completion: { _ in })
        }
    }

    /// Drops queued prefetch work. Called when the visible window jumps, so the cache spends its
    /// time on what is actually on screen.
    func cancelWarm() {
        warmQueue.cancelAllOperations()
    }

    // MARK: Disk

    private func loadFromDisk(key: String) -> CGImage? {
        let file = url(forKey: key)
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private func writeToDisk(key: String, image: CGImage) {
        // Only the small sizes are worth persisting. A grid or filmstrip thumbnail is requested
        // again on every launch, so having it on disk is a straight win; a 4000-pixel viewer
        // preview is fetched once per viewing session, and JPEG-encoding it cost more than the
        // decode it saved — a 24-megapixel frame took seconds to round-trip through the encoder.
        guard max(image.width, image.height) <= Self.persistMaxPixels else { return }
        let file = url(forKey: key)
        diskQueue.async {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            guard let data = ThumbnailCache.encodeJPEG(image) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Above this size a thumbnail lives only in memory.
    static let persistMaxPixels = 1024

    private func store(key: String, image: CGImage) {
        memory.setObject(Box(image), forKey: key as NSString)
    }

    // MARK: Purging

    private var lastPrune: Date = .distantPast
    private static let pruneInterval: TimeInterval = 60 * 30
    private static let diskLimit: Int64 = 3 * 1024 * 1024 * 1024

    /// Keeps the disk store under `diskLimit` by dropping the least recently used files. Runs off
    /// the main thread; the directory is sharded so this is a couple of hundred `stat` calls in
    /// the worst case, not a deep tree walk.
    private func pruneIfNeeded(force: Bool = false) {
        if !force, Date().timeIntervalSince(lastPrune) < Self.pruneInterval { return }
        lastPrune = Date()

        let fm = FileManager.default
        guard let shards = try? fm.contentsOfDirectory(at: thumbsDir,
                                                       includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles]) else { return }
        var files: [(url: URL, size: Int64, used: Date)] = []
        var total: Int64 = 0
        for shard in shards {
            guard let entries = try? fm.contentsOfDirectory(at: shard,
                                                            includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey],
                                                            options: [.skipsHiddenFiles]) else { continue }
            for f in entries {
                guard let v = try? f.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]) else { continue }
                let size = Int64(v.fileSize ?? 0)
                total += size
                files.append((f, size, v.contentAccessDate ?? v.contentModificationDate ?? .distantPast))
            }
        }
        guard total > Self.diskLimit else { return }
        files.sort { $0.used < $1.used }
        var target = total - Self.diskLimit + Self.diskLimit / 8   // drop a little extra
        for f in files {
            guard target > 0 else { break }
            try? fm.removeItem(at: f.url)
            target -= f.size
        }
    }

    func purgeAll() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: thumbsDir)
        try? FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
    }

    func diskUsage() -> Int64 {
        let fm = FileManager.default
        guard let shards = try? fm.contentsOfDirectory(at: thumbsDir, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for shard in shards {
            guard let entries = try? fm.contentsOfDirectory(at: shard,
                                                            includingPropertiesForKeys: [.fileSizeKey],
                                                            options: [.skipsHiddenFiles]) else { continue }
            for f in entries {
                total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return total
    }

    // MARK: Stats (diagnostics)

    func statsLine() -> String {
        lock.lock()
        let pending = inFlight.count
        let failed = failures.count
        lock.unlock()
        let mb = Double(diskUsage()) / 1024 / 1024
        return "thumbs: memHits=\(memoryHits) diskHits=\(diskHits) generated=\(generated) coalesced=\(coalesced) inFlight=\(pending) failed=\(failed) disk=\(String(format: "%.1f", mb))MB \(Self.routesLine())"
    }

    func resetStats() {
        memoryHits = 0; diskHits = 0; generated = 0; coalesced = 0
        Self.resetRoutes()
    }

    // MARK: Rendering primitives

    /// Pixel size below which an embedded preview is considered too coarse to use.
    ///
    /// **1.0, and it used to be 0.75 — that was the bug.** A preview smaller than the tile it is
    /// asked to fill has to be *upscaled*, and accepting up to a quarter of that was meant to be
    /// a quality compromise. On real files it turned out to be a correctness one: a 192-pixel
    /// filmstrip cell happily accepted a 160-pixel preview, so every tile in a folder was drawn
    /// from whatever the file carried — and a folder whose files had been stamped with a shared
    /// placeholder thumbnail (55 files, one byte-identical 5667-byte JPEG at offset 990, verified
    /// outside ImageIO) showed that same placeholder in every cell. "All the filmstrip thumbnails
    /// are the same picture" was not a rendering fault at all.
    ///
    /// The grid never showed it because it asks for a size above any preview an ordinary camera
    /// writes, so the 0.75 gate rejected them there and the decode produced the real photograph.
    /// The strip is the one surface that asks small enough to be lied to.
    ///
    /// Requiring the requested size costs a decode on files that carry only a 160-pixel preview —
    /// which is most camera JPEGs — but a decode is always right. A file whose preview is already
    /// large enough (phones and HEIC often carry a full-size one) still takes the free path.
    private static let embeddedQualityGate = 1.0

    /// The one and only decode entry point.
    ///
    /// Three strategies, in order of cost:
    ///
    /// 1. **The preview the file already carries.** A JPEG/HEIC written by a camera or a phone
    ///    usually embeds a small copy of itself, and pulling that out is a few hundred kilobytes
    ///    of I/O with no image decoding at all. It is used when it is at least ¾ of the size we
    ///    actually asked for — otherwise the grid would be a field of mush. (Most files only
    ///    carry a 160-pixel preview, which fails that test for anything but the filmstrip.)
    ///    Read `embeddedPreview` before touching this call: the obvious-looking option
    ///    dictionary does not do what it says, and the failure is silent and slow.
    /// 2. **A decimating decode at `decodeTarget`** — see below, and the note on why the target
    ///    is deliberately *larger* than the answer for small requests.
    /// 3. **A plain downscale of the result**, which is a fraction of a millisecond and is what
    ///    actually produces the requested size.
    ///
    /// `WithTransform` bakes the EXIF orientation in, so every consumer downstream can assume
    /// upright pixels.
    static func render(url: URL, pixels: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL,
                                                   [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }

        if let embedded = embeddedPreview(src),
           Double(max(embedded.width, embedded.height)) >= Double(pixels) * embeddedQualityGate,
           previewDepictsFrame(embedded, src) {
            noteRoute(embedded: true)
            return fit(embedded, into: pixels)
        }

        let native = nativeLongestSide(src)
        let target = Self.legacyDecode ? pixels : decodeTarget(requested: pixels, native: native)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            return nil
        }
        noteRoute(embedded: false)
        return fit(decoded, into: pixels)
    }

    // MARK: Route counters
    //
    // Which of the two strategies actually ran, counted. Without this the only evidence that the
    // embedded-preview branch is working is wall-clock time, and a branch that silently returns
    // full decodes for a whole folder looks exactly like a slow disk.

    private static let routeLock = NSLock()
    private static var embeddedRouted = 0
    private static var decodedRouted = 0

    static func noteRoute(embedded: Bool) {
        routeLock.lock(); defer { routeLock.unlock() }
        if embedded { embeddedRouted += 1 } else { decodedRouted += 1 }
    }

    static func resetRoutes() {
        routeLock.lock(); embeddedRouted = 0; decodedRouted = 0; routeLock.unlock()
    }

    static func routesLine() -> String {
        routeLock.lock(); defer { routeLock.unlock() }
        return "routes: embedded=\(embeddedRouted) decoded=\(decodedRouted)"
    }

    /// `PICNIDO_DECODE_LEGACY=1` asks the decoder for exactly the size requested, which is what the
    /// app did before `decodeTarget` existed. Kept as a switch so the two policies can be measured
    /// on the same machine in the same session instead of being compared across runs.
    static let legacyDecode = ProcessInfo.processInfo.environment["PICNIDO_DECODE_LEGACY"] != nil

    /// The size to *decode* at, which is not necessarily the size that was asked for.
    ///
    /// Asking ImageIO for a very small thumbnail and asking it for a moderate one are not
    /// priced the way you would expect. Measured on the user's 24-megapixel JPEGs
    /// (`work/probe/curve.swift`, 4024×6048, five runs each, median):
    ///
    /// | requested | median | note                                            |
    /// |-----------|--------|-------------------------------------------------|
    /// | 96–640    | ~91 ms | ImageIO decodes at 1/8 and then runs an expensive multi-tap resample |
    /// | 768       | 58 ms  | the cheap corner of its scaled-decode path       |
    /// | 1024      | 62 ms  |                                                  |
    /// | 1536      | 78 ms  |                                                  |
    /// | 2048      | 83 ms  |                                                  |
    /// | 4096      | 172 ms |                                                  |
    ///
    /// So a 256-pixel grid thumbnail cost *half again as much* as a 768-pixel one, and the
    /// whole folder took 91 ms per file instead of 58. Decoding at `native/8` and then scaling
    /// down here costs 58 + ~1 ms and produces the same 256-pixel tile — a third less work for
    /// a job this folder does 554 times.
    ///
    /// The same decode also cannot help but be sharper: a 3:1 reduction from a real decode beats
    /// whatever the small-target path was doing to earn its extra 33 ms.
    static func decodeTarget(requested: Int, native: Int) -> Int {
        guard native > 0 else { return requested }
        let cheapFloor = ThumbBuckets.snap((native + 7) / 8)   // native/8, rounded up
        return min(native, max(requested, cheapFloor))
    }

    /// True pixel dimensions from the header alone — no decode.
    private static func nativeLongestSide(_ src: CGImageSource) -> Int {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return 0 }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        return max(w, h)
    }

    /// The preview embedded in the file, if any. Does not decode the main image.
    ///
    /// The ceiling below is not a size we ever want. It is the *permission slip*.
    ///
    /// `kCGImageSourceCreateThumbnailFromImageIfAbsent: false` does not, on its own, mean "the
    /// embedded preview or nothing" — `CGImageSourceCreateThumbnailAtIndex` ignores both source
    /// flags unless the dictionary also carries `kCGImageSourceThumbnailMaxPixelSize`, and with
    /// neither it hands back **the full-resolution image**. This function used to pass exactly
    /// that dictionary, so it never returned a preview: it returned a full decode, the quality
    /// gate below then accepted it (a full-size image clears any threshold), and `decodeTarget`
    /// was dead code on every file. Measured (`work/probe/formats.swift opts`), request / what
    /// came back:
    ///
    /// | file                | without a ceiling    | with one        |
    /// |---------------------|----------------------|-----------------|
    /// | Canon 24 MP JPEG    | 6048×4024, 121 ms    | 160×106, 0 ms   |
    /// | SYNTH PNG           | 4024×6048, 256 ms    | nil             |
    /// | SYNTH PSD / TIFF    | 4024×6048, 87/34 ms  | nil             |
    /// | SYNTH GIF / BMP/TGA | 4024×6048, 28–68 ms  | nil             |
    /// | SYNTH WebP / AVIF   | 4024×6048, 117/68 ms | nil             |
    /// | SYNTH JPEG 2000     | 4024×6048, 843 ms    | 252×378, 29 ms  |
    ///
    /// With the ceiling in place the call means what its name says: a file that carries no
    /// preview returns nil and falls through to `decodeTarget`. That is what makes the JPEG 2000
    /// line 29× cheaper and what keeps twelve concurrent bulk workers from each holding a 96 MB
    /// full-resolution buffer to produce a 256-pixel tile.
    private static func embeddedPreview(_ src: CGImageSource) -> CGImage? {
        guard CGImageSourceGetCount(src) > 0 else { return nil }
        if legacyEmbedded {
            // The old, wrong dictionary — kept so the two can be measured in one session.
            return CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceCreateThumbnailFromImageAlways: false,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: embeddedPreviewCeiling,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    /// Above any plausible embedded preview, so the returned image is the preview at its own size
    /// and the quality gate can judge it honestly rather than judging a rescale of it.
    private static let embeddedPreviewCeiling = 8192

    /// Is the file's preview actually a picture *of this frame*? Header only — no decode.
    ///
    /// The size gate cannot see this class of file: something wrote a placeholder thumbnail into
    /// every file of a set (a downloader, a watermarking pass — the origin does not matter here),
    /// and a preview that happens to be large enough would sail past a size test and be shown as
    /// if it were the photograph. Shape is the cheap discriminator. It costs a few header fields:
    /// the frame's *displayed* proportions, from the stored width/height with the EXIF quarter
    /// turns applied — and the preview is built with `kCGImageSourceCreateThumbnailWithTransform`,
    /// so it carries the same orientation.
    ///
    /// Deliberately one-directional: answering "no" can only cost a decode, never a wrong picture.
    /// That is why it is allowed to be strict. Some cameras do write a cropped preview (16:9 for a
    /// 4:3 frame) and will now be decoded instead of short-circuited; that is a few milliseconds.
    private static func previewDepictsFrame(_ preview: CGImage, _ src: CGImageSource) -> Bool {
        guard let frame = frameShape(src), preview.height > 0 else { return false }
        let frameRatio = Double(frame.0) / Double(frame.1)
        let previewRatio = Double(preview.width) / Double(preview.height)
        return abs(frameRatio - previewRatio) <= 0.02 * max(frameRatio, previewRatio)
    }

    /// The frame's displayed pixel proportions: stored size, sides swapped for the EXIF quarter
    /// turns (5…8), which is what the viewer and every consumer of a normalised bitmap expect.
    private static func frameShape(_ src: CGImageSource) -> (Int, Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard w > 0, h > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? (h, w) : (w, h)
    }

    /// `PICNIDO_EMBEDDED_LEGACY=1` restores the dictionary that returned full images. For A/B only.
    static let legacyEmbedded = ProcessInfo.processInfo.environment["PICNIDO_EMBEDDED_LEGACY"] != nil

    /// Scales a CGImage so its longest side is at most `maxSide`. Returns the input untouched when
    /// it already fits, so this is free on the common path.
    static func fit(_ image: CGImage, into maxSide: Int) -> CGImage {
        let w = image.width, h = image.height
        let longest = max(w, h)
        guard longest > maxSide, longest > 0 else { return image }
        let scale = Double(maxSide) / Double(longest)
        let tw = max(1, Int((Double(w) * scale).rounded()))
        let th = max(1, Int((Double(h) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        return ctx.makeImage() ?? image
    }

    /// True native pixel dimensions, from the image's own header — no decode. Used for the zoom
    /// read-out, which must report against the *original*, not against whatever preview we have
    /// decoded so far.
    static func pixelSize(of url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    static func encodeJPEG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: 0.82
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
