import SwiftUI
import AppKit

// MARK: - Filmstrip
//
// The strip lives entirely in the programme, not in art assets: every pixel of it is
// drawn at runtime, so there is no bitmap to ship, scale or colour-manage.
//
// Its geometry is deliberately simple. The band is full width and pinned to the bottom
// edge, sitting under a separate translucent "skirt" layer, and the scroll wheel is
// scoped to the strip rather than to the photo above it — scrolling over the strip moves
// along the row instead of zooming.
//
// Three details carry the whole look:
//
//   * the trough shading, a mirrored alpha ramp of 24→237→24 across the band;
//   * the reflection falloff under each cell, 95→255→95;
//   * an 8 pt pad on the bottom hit test, so a click landing just under a cell still
//     selects it.
//
// The reflection is what makes the strip read as *film* rather than as a row of
// thumbnails, so that is the part implemented most carefully here.

/// Which end of the row a bump refers to.
enum StripEdge: String { case first, last }

/// One "you are at the end" event.
///
/// `nonce` exists because `onChange` compares values: two bumps in a row against the same end
/// are two different events, and without a changing field the second one would be invisible.
struct StripHit: Equatable {
    var edge: StripEdge
    var nonce: Int
}

struct FilmstripView: View {
    let photos: [PhotoItem]
    let currentID: PhotoItem.ID?
    /// Set by the viewer when the wheel tries to move past either end. Arriving at an end is
    /// noticed here; being *stopped* by one is noticed out there, and both have to look the same.
    var hit: StripHit?

    @State private var pulseID: PhotoItem.ID?
    @State private var pulseScale: CGFloat = 1
    @State private var nudge: CGFloat = 0
    @State private var beatToken = 0

    let onSelect: (PhotoItem.ID) -> Void

    /// Cell edge, reflection height and inter-cell gap. The original leaves 144 units of
    /// window height for this whole band (see the `- 144.0` reserve in the layout pass).
    static let cell: CGFloat = 78
    static let skirt: CGFloat = 22
    static let gap: CGFloat = 6
    static let topPad: CGFloat = 10
    static let bottomPad: CGFloat = 4
    static let height: CGFloat = topPad + cell + skirt + bottomPad

    /// The band at the bottom that the strip owns. The wheel is scoped to it so the strip
    /// scrolls horizontally instead of zooming the photo — the original does the same with
    /// its `ss/filmcontainer`. Also used by the viewer's drag-to-pan edge exclusion.
    static let interactionZone: CGFloat = height + 28

    var body: some View {
        GeometryReader { geo in
            strip(viewportWidth: geo.size.width)
                .onAppear { report(geo); auditList() }
                .onChange(of: geo.size) { _, _ in report(geo) }
                .onChange(of: photos.count) { _, _ in auditList() }
                .onChange(of: hit) { _, newValue in
                    if let newValue { beat(newValue.edge, from: "wheel") }
                }
        }
    }

    /// The "you have reached the end" tick.
    ///
    /// A row of thumbnails gives no sense of scale: in a folder of three hundred, nothing on
    /// screen says whether this is picture 2 or picture 297, and the ends are simply not there
    /// to see. So the end announces itself. The cell at that end swells and springs back, and
    /// the whole row shoves a few points outward and returns, the way a physical strip would if
    /// you pulled it against a stop.
    ///
    /// It fires twice per visit to an end, and both are wanted: once on *arrival* (this is an
    /// end) and once per further attempt (you are still here, there is nothing past me). Only
    /// the ends do this, so it can never become background noise.
    @MainActor
    private func beat(_ edge: StripEdge, from source: String) {
        guard let id = (edge == .first ? photos.first?.id : photos.last?.id) else { return }
        beatToken += 1
        let token = beatToken
        pulseID = id
        let outward: CGFloat = edge == .first ? 1 : -1

        let index = photos.firstIndex { $0.id == id } ?? -1
        PicnidoAppDelegate.report("[strip] beat edge=\(edge.rawValue) index=\(index) count=\(photos.count) via=\(source)")

        // Same contract as PICNIDO_CHROME_PIN: hold the extreme pose so a snapshot can measure
        // it. A 110 ms swell is not something a screenshot can be aimed at.
        if DevHook.isSet("PICNIDO_STRIP_BEAT_PIN") {
            pulseScale = Self.beatScale
            nudge = Self.beatNudge * outward
            return
        }

        withAnimation(.easeOut(duration: 0.10)) {
            pulseScale = Self.beatScale
            nudge = Self.beatNudge * outward
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            guard token == beatToken else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.55)) {
                pulseScale = 1
                nudge = 0
            }
        }
    }

    /// 12 % — enough to read as a pop, small enough that the cell does not quite close the 6 pt
    /// gap to its neighbours on both sides.
    private static let beatScale: CGFloat = 1.12
    private static let beatNudge: CGFloat = 7

    /// Diagnostic (PICNIDO_STRIP_AUDIT): prints what the strip was handed, so "every cell shows
    /// the same picture" can be traced to the list itself rather than guessed at from a screenshot.
    private func auditList() {
        guard DevHook.isSet("PICNIDO_STRIP_AUDIT") else { return }
        let head = photos.prefix(6).map { $0.fileName }.joined(separator: ", ")
        let distinct = Set(photos.map { $0.id }).count
        PicnidoAppDelegate.report("[strip] list count=\(photos.count) distinctIDs=\(distinct) head=[\(head)] current=\(currentID.map { ($0 as NSString).lastPathComponent } ?? "nil")")
    }

    /// Debug hook (PICNIDO_GEOM_REPORT): where the strip really landed, in window coordinates.
    /// Distinguishes "never laid out" from "laid out but not composited".
    private func report(_ geo: GeometryProxy) {
        guard ProcessInfo.processInfo.environment["PICNIDO_GEOM_REPORT"] != nil else { return }
        let local = geo.frame(in: .local)
        let global = geo.frame(in: .global)
        PicnidoAppDelegate.report("""
        --- filmstrip geometry ---
        photos=\(photos.count) current=\(currentID.map { "\($0)" } ?? "nil")
        local=\(local)
        global=\(global)
        stripHeightConst=\(Self.height)
        """)
    }

    private func strip(viewportWidth: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // `LazyHStack`, not `HStack`. A plain `HStack` builds *every* cell up front: with a
                // five-hundred-photo folder that meant five hundred `FilmCell` views, each with its
                // own load task and its own mirrored reflection pass, constructed the instant the
                // viewer opened — which is why the viewer showed a spinner instead of a picture and
                // why dragging the photo afterwards stuttered. Only the cells actually on screen
                // exist now.
                LazyHStack(spacing: Self.gap) {
                    ForEach(photos) { photo in
                        FilmCell(photo: photo,
                                 side: Self.cell,
                                 skirt: Self.skirt,
                                 isCurrent: photo.id == currentID,
                                 pulse: photo.id == pulseID ? pulseScale : 1)
                            .id(photo.id)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(photo.id) }
                    }
                }
                // Only the row moves, not the band: the stop is felt at the end of the strip,
                // and sliding the whole band would read as the window jumping.
                .offset(x: nudge)
                .padding(.horizontal, 24)
                .padding(.top, Self.topPad)
                .padding(.bottom, Self.bottomPad)
                // The strip is full width but its cells are centred, exactly as the original
                // lays them out: they only start scrolling once they no longer fit.
                .frame(minWidth: viewportWidth, alignment: .center)
            }
            // The row has to start on the current photo, not on the first one.
            //
            // `onChange` below cannot do that: when the viewer opens on picture 28, the id is
            // already 28 by the time this strip is built, so nothing has *changed* and the row
            // stays at offset zero showing pictures 1 to 30. And because the chrome is torn down
            // whenever it hides, every reveal rebuilds this `ScrollView` and it starts over from
            // the left again. Both are the same missing step, so both go through `centre`.
            .onAppear { centre(proxy, animated: false) }
            .onChange(of: photos.count) { _, _ in centre(proxy, animated: false) }
            .onChange(of: currentID) { _, newValue in
                if let newValue {
                    // Stepping from 28 to 29 is one cell away, and `centre` already scrolls
                    // without animation; only a *jump* (a click in the strip, or a slide) is worth
                    // animating, and that is the case where the row travels far.
                    centre(proxy, animated: true)
                    // Landing on either end is worth announcing: from then on the strip stops
                    // moving, and without a tick that looks like a dead gesture rather than
                    // like the end of the folder.
                    if let i = photos.firstIndex(where: { $0.id == newValue }) {
                        if i == 0 { beat(.first, from: "arrival") }
                        else if i == photos.count - 1 { beat(.last, from: "arrival") }
                    }
                }
            }
        }
    }

    /// Puts the current photo under the middle of the band.
    ///
    /// `anchor: .center` is the whole point: a strip that merely scrolls the current cell into
    /// view answers "is it on screen", which is not the question. In a folder of a few hundred,
    /// being six cells from the left edge and being dead centre look the same to `visibleRect`,
    /// but only one of them tells you where you are in the folder.
    ///
    /// Deferred by one turn of the run loop, and repeated shortly after, because the row is a
    /// `LazyHStack`: at `onAppear` its cells have no frames yet, so the first `scrollTo` is
    /// addressed to a row that does not exist and is discarded. The second pass then corrects the
    /// residual error — a lazy stack reports an estimate for cells it has never built, and with
    /// sixty cells the estimate is close but rarely exact.
    private func centre(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let id = currentID else { return }
        let scroll = {
            if animated {
                withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo(id, anchor: .center) }
            } else {
                proxy.scrollTo(id, anchor: .center)
            }
        }
        DispatchQueue.main.async(execute: scroll)
        // Only the no-animation case gets a second pass: an animated scroll is a deliberate jump
        // the user asked for, and re-issuing it 80 ms later would fight its own animation.
        if !animated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { scroll() }
        }
    }
}

/// One frame of the strip: the cell, plus the mirrored "skirt" reflection beneath it.
private struct FilmCell: View {
    let photo: PhotoItem
    let side: CGFloat
    let skirt: CGFloat
    let isCurrent: Bool
    /// 1 normally; above 1 for the 100 ms the end-of-row heartbeat lasts.
    var pulse: CGFloat = 1

    @State private var image: CGImage?
    /// See `ThumbnailView.animated` — the same two-writers-one-slot problem, solved the same way.
    @State private var animated = false
    @State private var animation: AnimationHub.Token?

    private static let corner = RoundedRectangle(cornerRadius: 3, style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            cell
            reflection
        }
        .opacity(isCurrent ? 1 : 0.62)
        .scaleEffect(pulse)
        // Drawn over its neighbours instead of under them: `scaleEffect` does not take part in
        // layout, so without this the swelling cell would be clipped by the cell to its right.
        .zIndex(pulse > 1 ? 1 : 0)
        .animation(.easeOut(duration: 0.18), value: isCurrent)
        .task(id: "\(photo.id)|\(photo.stack.count)|\(Int(photo.modified.timeIntervalSince1970))|\(Int(side))") { await load() }
        .onAppear { startAnimation() }
        .onDisappear { stopAnimation() }
        .onChange(of: photo.id) { _, _ in
            stopAnimation()
            animated = false
            startAnimation()
        }
    }

    @MainActor
    private func startAnimation() {
        guard animation == nil else { return }
        animation = AnimationHub.shared.subscribe(photo, priority: .visible) { frame in
            animated = true
            image = frame
        }
    }

    @MainActor
    private func stopAnimation() {
        animation?.cancel()
        animation = nil
    }

    private var cell: some View {
        art
            .frame(width: side, height: side)
            .clipShape(Self.corner)
            .overlay(
                Self.corner.strokeBorder(isCurrent ? Color.white : Color.white.opacity(0.22),
                                         lineWidth: isCurrent ? 2 : 1)
            )
            .shadow(color: .black.opacity(isCurrent ? 0.55 : 0.28), radius: 6, y: 1)
    }

    /// The mirror. Flipped about the centre so the tile's bottom edge meets the cell's
    /// bottom edge, then clipped to `skirt` and faded out with the ramp the original
    /// stores in its resource pack.
    private var reflection: some View {
        art
            .frame(width: side, height: side)
            .clipShape(Self.corner)
            .scaleEffect(x: 1, y: -1)
            .frame(height: skirt, alignment: .top)
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.40), location: 0.00),
                        .init(color: .white.opacity(0.16), location: 0.40),
                        .init(color: .white.opacity(0.00), location: 1.00),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .opacity(isCurrent ? 0.95 : 0.6)
    }

    @ViewBuilder private var art: some View {
        if let image {
            Image(decorative: image, scale: 1, orientation: .up)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Color.white.opacity(0.07)
        }
    }

    @MainActor
    private func load() async {
        if let hit = ImageEngine.shared.cachedThumbnail(for: photo, displaySize: side) {
            if !animated { image = hit }
            audit(hit, via: "mem")
            return
        }
        let p = photo
        let s = side
        let loaded: CGImage? = await withCheckedContinuation { continuation in
            ImageEngine.shared.thumbnail(for: p, displaySize: s, priority: .visible) { img in
                continuation.resume(returning: img)
            }
        }
        guard !Task.isCancelled else { return }
        if let loaded, !animated { image = loaded; audit(loaded, via: "req") }
    }

    /// Diagnostic (PICNIDO_STRIP_AUDIT). Three things per cell, which together decide where the
    /// fault is: the picture it asked for, the *identity* of the bitmap it got back (same object
    /// for different photos ⇒ the cache handed one image to everybody), and a content fingerprint
    /// (different objects, same fingerprint ⇒ the decode, not the plumbing).
    @MainActor
    private func audit(_ img: CGImage, via route: String) {
        guard DevHook.isSet("PICNIDO_STRIP_AUDIT") else { return }
        PicnidoAppDelegate.report("[cell] \(photo.fileName) via=\(route) obj=\(ObjectIdentifier(img)) \(img.width)x\(img.height) fp=\(Self.fingerprint(img))")
    }

    /// Avalanche hash of an 8×8 redraw — independent of how the bitmap is stored, so two images
    /// that look alike hash alike however they were produced.
    static func fingerprint(_ img: CGImage) -> String {
        let n = 8
        var buf = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &buf, width: n, height: n, bitsPerComponent: 8,
                                  bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return "?"
        }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n))
        var h: UInt64 = 1469598103934665603
        for b in buf { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 16)
    }
}
