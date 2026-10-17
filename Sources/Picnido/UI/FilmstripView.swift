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

struct FilmstripView: View {
    let photos: [PhotoItem]
    let currentID: PhotoItem.ID?
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
        }
    }

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
                                 isCurrent: photo.id == currentID)
                            .id(photo.id)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(photo.id) }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, Self.topPad)
                .padding(.bottom, Self.bottomPad)
                // The strip is full width but its cells are centred, exactly as the original
                // lays them out: they only start scrolling once they no longer fit.
                .frame(minWidth: viewportWidth, alignment: .center)
            }
            .onChange(of: currentID) { _, newValue in
                if let newValue {
                    withAnimation(.easeOut(duration: 0.22)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
    }
}

/// One frame of the strip: the cell, plus the mirrored "skirt" reflection beneath it.
private struct FilmCell: View {
    let photo: PhotoItem
    let side: CGFloat
    let skirt: CGFloat
    let isCurrent: Bool

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
