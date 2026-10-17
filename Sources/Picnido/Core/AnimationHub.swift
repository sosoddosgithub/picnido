import Foundation
import CoreGraphics
import QuartzCore

/// The one place animated images are played from.
///
/// Every surface that can show an animation — the grid, the filmstrip, the viewer, the
/// slideshow — asks this for frames and gets a stream of `CGImage`s back. Nothing else decodes
/// them, and that is deliberate: decoding is the expensive part, and a grid can hold hundreds of
/// cells. Left to themselves each cell would open its own decoder for its own file, and the
/// machine would spend all its time on animations scrolled half off the screen.
///
/// So the hub owns three decisions:
///
/// * **Who is open.** A file is opened only when something subscribes to it, and closed a moment
///   after the last subscriber leaves. The delay is what makes scrolling back and forth cheap.
/// * **Who is playing.** At most `maxConcurrent` animations advance per tick. Everything else
///   holds its first frame on screen. Without this, opening a folder of animated stickers would
///   start a decoder per visible cell and the grid would stutter — the animations would be
///   technically correct and the application unusable.
/// * **When.** One timer drives every animation. A timer per animation would mean hundreds of
///   run-loop sources waking the process independently, each with its own drift.
@MainActor
final class AnimationHub {

    static let shared = AnimationHub()

    enum Priority: Int {
        /// The grid and the filmstrip. These compete for the concurrency budget and may be
        /// starved when the screen is full of animations.
        case visible
        /// The viewer and the slideshow — the picture the user actually asked to look at. These
        /// never count against the budget, because the one animation on screen at full size is
        /// by definition the one that matters.
        case focused
    }

    /// A live subscription. Cancel it and the frames stop.
    ///
    /// Cancelling is idempotent and works from any thread, because the two ways a subscription
    /// ends are not the same: a view cancels it deliberately on the main actor, but a view that
    /// is torn down without running its cleanup gets here through `deinit`, which the runtime may
    /// call wherever the last reference happened to be released. Holding the hub strongly (it is
    /// a singleton, so this cannot keep anything alive that was not already) is what makes that
    /// path work at all — a weak reference is already nil by the time `deinit` runs.
    final class Token: @unchecked Sendable {
        private let id: Int
        private let hub: AnimationHub
        private let lock = NSLock()
        private var done = false

        fileprivate init(id: Int, hub: AnimationHub) {
            self.id = id
            self.hub = hub
        }

        func cancel() {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            guard first else { return }

            let hub = self.hub
            let id = self.id
            if Thread.isMainThread {
                MainActor.assumeIsolated { hub.unsubscribe(token: id) }
            } else {
                Task { @MainActor in hub.unsubscribe(token: id) }
            }
        }

        deinit { cancel() }
    }

    /// How many animations may advance at once. Overridable with `PICNIDO_ANIM_MAX` for measurement.
    ///
    /// Measured on a grid of eighteen animated stickers: this hub sustains about a hundred and
    /// twenty frames a second in total, and that total is what the budget divides. Four animations
    /// therefore play at the thirty frames a second their files were authored at, and eight play at
    /// about fifteen each. Eight is the deliberate choice — a grid of stickers is better served by
    /// every one of them moving than by half of them moving at full rate — and it costs nothing on
    /// the surfaces that matter most, because a focused subscription never takes a share of the
    /// budget: the picture in the viewer plays at its authored rate whatever the grid is doing.
    ///
    /// The ceiling itself is not CPU. Sampling the process during playback puts it near thirty per
    /// cent whether nought, four or eight animations are running, so what caps the total is the
    /// per-frame round trip, not the work in it.
    private let maxConcurrent: Int
    /// Ceiling on open files, which is really a memory ceiling: each open animation holds its
    /// whole file plus a full-resolution RGBA canvas.
    private let maxEntries = 16
    /// How long an unsubscribed animation stays open. Long enough that scrolling past a cell and
    /// back does not re-read the file; short enough that a swept grid releases its memory.
    private let linger: TimeInterval = 1.2

    private final class Entry {
        let photoID: String
        let url: URL
        let info: AnimationInfo
        let queue: DispatchQueue

        var handlers: [Int: (CGImage) -> Void] = [:]
        var focusedSubscribers = 0
        var order = 0

        var image: AnimatedImage?
        var opening = false
        var openFailed = false
        var decoding = false
        var decodeStartedAt: CFTimeInterval = 0
        var nextDue: CFTimeInterval = 0
        var teardown: DispatchWorkItem?
        /// The last frame handed out. A new subscriber gets it immediately rather than waiting
        /// for the next tick, so a cell scrolling into view does not flash its placeholder.
        var lastProvided: CGImage?

        init(photoID: String, url: URL, info: AnimationInfo) {
            self.photoID = photoID
            self.url = url
            self.info = info
            self.queue = DispatchQueue(label: "picnido.animation.\(photoID)",
                                       qos: .userInitiated)
        }

        var frameBytes: Int {
            Int(info.canvas.width) * Int(info.canvas.height) * 4
        }
    }

    private var entries: [String: Entry] = [:]
    private var nextToken = 1
    private var nextOrder = 1
    private var timer: Timer?

    private init() {
        if let raw = DevHook.string("PICNIDO_ANIM_MAX"), let n = Int(raw), n > 0 {
            maxConcurrent = n
        } else {
            maxConcurrent = 8
        }
    }

    // MARK: - Subscribing

    /// Whether this photo is something the hub would play.
    ///
    /// Reads the container header, and the answer is cached with the file's stamp, so a view may
    /// ask in its body without turning a redraw into a disk read. Answers false for every still
    /// image — which is nearly every photo — and for a file whose animation the app cannot decode.
    func isAnimating(_ photo: PhotoItem) -> Bool {
        guard AnimationProbe.mayAnimate(photo.url),
              let info = AnimationProbe.info(for: photo.url)
        else { return false }
        return info.isAnimated
    }

    /// Starts sending frames of `photo` to `onFrame`, on the main actor.
    ///
    /// Returns nil when the file is not an animation this app plays — a still image, or a format
    /// with no animation support — in which case the caller keeps whatever still picture it
    /// already had. The first call to `onFrame` may arrive before this function returns, when the
    /// file is already open and playing.
    @discardableResult
    func subscribe(_ photo: PhotoItem,
                   priority: Priority = .visible,
                   onFrame: @escaping (CGImage) -> Void) -> Token? {
        guard isAnimating(photo), let info = AnimationProbe.info(for: photo.url) else { return nil }

        let token = nextToken
        nextToken += 1

        let entry: Entry
        if let existing = entries[photo.id] {
            entry = existing
        } else {
            guard entries.count < maxEntries else { return nil }
            entry = Entry(photoID: photo.id, url: photo.url, info: info)
            entries[photo.id] = entry
        }

        entry.teardown?.cancel()
        entry.teardown = nil
        entry.order = nextOrder
        nextOrder += 1
        if priority == .focused { entry.focusedSubscribers += 1 }
        entry.handlers[token] = onFrame

        // Immediately, if there is something to give. Waiting for the tick would show a placeholder
        // for one refresh on a cell that already has a perfectly good frame available.
        if let ready = entry.lastProvided { onFrame(ready) }

        startTimer()
        tick()
        return Token(id: token, hub: self)
    }

    fileprivate func unsubscribe(token id: Int) {
        for (key, entry) in entries {
            guard entry.handlers.removeValue(forKey: id) != nil else { continue }
            if entry.handlers.isEmpty {
                scheduleTeardown(entry, key: key)
            }
            break
        }
    }

    private func scheduleTeardown(_ entry: Entry, key: String) {
        entry.focusedSubscribers = 0
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let current = self.entries[key], current === entry, current.handlers.isEmpty else { return }
            self.entries.removeValue(forKey: key)
            if self.entries.isEmpty { self.stopTimer() }
        }
        entry.teardown = item
        DispatchQueue.main.asyncAfter(deadline: .now() + linger, execute: item)
    }

    // MARK: - The tick

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // `.common` so animations keep running while a menu is open or a scroll is being tracked;
        // the default mode stops during both.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard !entries.isEmpty else { stopTimer(); return }
        let now = CACurrentMediaTime()

        // Focused animations first and unconditionally, then visible ones in the order they were
        // last asked for — so the newest cells to appear are the ones that animate, which is what
        // scrolling into a wall of animated stickers should feel like.
        var budget = maxConcurrent
        var allowed = Set<String>()
        let ordered = entries.values.sorted { $0.order > $1.order }
        for entry in ordered where entry.focusedSubscribers > 0 {
            allowed.insert(entry.photoID)
        }
        for entry in ordered where entry.focusedSubscribers == 0 {
            guard budget > 0 else { break }
            budget -= 1
            allowed.insert(entry.photoID)
        }

        for entry in entries.values {
            // Watchdog. `decoding` is a claim that a frame is being produced, and a frame takes
            // single-digit milliseconds — two seconds means the claim is wrong, whatever the
            // reason. Releasing it costs at worst one duplicate decode and turns a permanently
            // frozen animation into a hiccup.
            if entry.decoding, now - entry.decodeStartedAt > 2.0 {
                entry.decoding = false
            }
            guard allowed.contains(entry.photoID) else { continue }
            guard now >= entry.nextDue else { continue }
            advance(entry)
        }
    }

    private func advance(_ entry: Entry) {
        guard let image = entry.image else {
            open(entry)
            return
        }
        guard !entry.decoding else { return }
        entry.decoding = true
        entry.decodeStartedAt = CACurrentMediaTime()
        // The deadline this frame was scheduled for. Handing it to the completion is what keeps the
        // round trip out of the period — see the note on `nextDue` below.
        let dueAt = entry.nextDue

        entry.queue.async { [weak self] in
            let frame = image.advance()
            Task { @MainActor in
                // The `decoding` flag is cleared before anything else can return early, because a
                // path that bails out without clearing it wedges the animation for good: the
                // entry stays subscribed, the tick keeps firing, and every one of them returns on
                // this guard. That is exactly what a generation counter used to do here — a
                // subscription that lapsed and was re-taken inside the linger window bumped the
                // generation, so the decode already in flight was discarded on arrival and the
                // flag was never cleared. Measured with eighteen animations on screen: six
                // hundred frames in the first four seconds, ten more in the next four.
                guard let self, self.entries[entry.photoID] === entry else { return }
                entry.decoding = false
                guard let frame else {
                    // The decoder gave up. Stop asking; the still image stays on screen.
                    entry.openFailed = true
                    return
                }
                entry.lastProvided = frame.image
                // Scheduled from the deadline this frame was due for, not from the moment its
                // decode came back. The two differ by the round trip — a hop to the decode queue,
                // the decode, a hop back to the main actor — which measured 17 ms here. Adding
                // that to every period is what made a single animation in the viewer play at 20
                // frames a second when the file said 29, and the file was right. Only when the
                // animation has fallen so far behind that the next deadline is already past does it
                // resynchronise, which is what keeps eight competing animations from stampeding.
                let period = entry.info.duration(at: frame.index)
                let now = CACurrentMediaTime()
                let target = dueAt + period
                entry.nextDue = target > now ? target : now + period
                for handler in entry.handlers.values {
                    handler(frame.image)
                }
                if DevHook.isSet("PICNIDO_ANIM_AUDIT") {
                    PicnidoAppDelegate.report("[anim] \(entry.url.lastPathComponent) frame=\(frame.index)/\(entry.info.frameCount) \(Int(entry.info.canvas.width))x\(Int(entry.info.canvas.height))")
                }
            }
        }
    }

    /// Opens the file and builds its decoder. Off the main thread: this reads the whole animation
    /// into memory, which for an eighteen-megabyte file is not something to do between two
    /// frames of a scroll.
    private func open(_ entry: Entry) {
        guard entry.image == nil, !entry.opening, !entry.openFailed else { return }
        entry.opening = true

        let url = entry.url
        let info = entry.info
        entry.queue.async { [weak self] in
            let image = AnimatedImage(url: url, info: info)
            Task { @MainActor in
                guard let self, self.entries[entry.photoID] === entry else { return }
                entry.opening = false
                guard let image else {
                    entry.openFailed = true
                    return
                }
                entry.image = image
                entry.nextDue = 0
                if DevHook.isSet("PICNIDO_ANIM_AUDIT") {
                    // What the container said, next to what the decoder was handed. A mismatch
                    // between this line and the `[anim]` frames that follow it is the difference
                    // between a metadata bug and a playback bug.
                    let sample = info.durations.prefix(8)
                        .map { String(format: "%.0f", $0 * 1000) }
                        .joined(separator: ",")
                    PicnidoAppDelegate.report("[anim-open] \(url.lastPathComponent) frames=\(info.frameCount) "
                        + "canvas=\(Int(info.canvas.width))x\(Int(info.canvas.height)) "
                        + "loop=\(info.loopCount) ms=[\(sample)]")
                }
                self.tick()
            }
        }
    }

    // MARK: - Introspection for tests

    /// One line per open animation, in the order they were last asked for.
    func snapshot() -> String {
        let ordered = entries.values.sorted { $0.order > $1.order }
        var open = 0, playing = 0
        for entry in ordered {
            if entry.image != nil { open += 1 }
            if entry.handlers.isEmpty == false && entry.focusedSubscribers > 0 { playing += 1 }
        }
        let names = ordered.prefix(6).map { entry -> String in
            let state = entry.image == nil ? (entry.openFailed ? "failed" : "opening") : "open"
            return "\(entry.url.lastPathComponent):\(state):x\(entry.handlers.count)"
        }
        return "[hub] entries=\(entries.count) open=\(open) focused=\(playing) "
             + "budget=\(maxConcurrent) [\(names.joined(separator: ", "))]"
    }
}
