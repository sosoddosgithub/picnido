import SwiftUI
import AppKit

/// Geometry shared by the canvas and the hit-testing overlay, so the two always agree on
/// exactly where the photo sits.
///
/// The picture lives in the band the chrome leaves: the tool bar owns `topBand` at the top,
/// the filmstrip owns `clearance` at the bottom, and the picture is centred in what is left,
/// keeping `breath` of air at each end. Both `topBand` and `clearance` are constants of the
/// layout, not of the moment — they describe what the chrome *occupies*, whether or not it is
/// on screen, which is what keeps the picture from jumping when the filmstrip times out.
///
/// This replaces a rule that looked right and was not. The old one centred the picture in the
/// **whole window** with both margins at least `clearance` tall. That produces equal margins,
/// but an equal margin is not the same thing as air: at the tall-photo limit — which is where
/// *every* 3:2-and-taller photo lands, since the height limit binds long before the width one
/// — the margin comes out exactly `clearance`, so the bottom edge of the photo sits flush on
/// the top edge of the filmstrip while the top still has the tool bar's height to spare. The
/// measured numbers were `topGap=114 bottomGap=114` with 114-point strip and a 67-point bar:
/// 47 points of glass above the picture and **zero** below. That is the "上面比较宽，和胶片条
/// 离得比较近" report, and it is arithmetic, not taste.
///
/// Centring in the band instead makes the two *airs* equal rather than the two margins. On the
/// same 2048×1152 display a tall photo now gets 24 points above and 24 below, and only pays
/// about 2% of its height for it.
enum ViewerGeometry {

    /// How much of the viewport the photo fills at zoom 1 — its "resting" size. The rest is
    /// the frosted margin that makes the viewer feel like a floating window. It caps the width
    /// only; the height is capped by the band between the bar and the strip.
    static let fillRatio: CGFloat = 0.82

    /// Air the picture keeps between itself and the chrome at each end of the band.
    ///
    /// Measured in points off a 1152-point-tall display. Bigger than a hairline on purpose: at
    /// 4–6 points the picture still reads as touching the strip, because the strip's top row of
    /// thumbnails has its own breathing room above it.
    static let breath: CGFloat = 24

    /// The picture's resting size.
    static func baseSize(image: CGSize, viewport: CGSize,
                         topBand: CGFloat, clearance: CGFloat) -> CGSize {
        guard image.width > 0, image.height > 0,
              viewport.width > 1, viewport.height > 1 else { return .zero }

        let span = max(1, viewport.height - topBand - clearance - 2 * breath)
        let scale = min(viewport.width * fillRatio / image.width,
                        span / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    /// The photo's frame in top-left view coordinates.
    ///
    /// The centre is the middle of the band the chrome leaves, not the middle of the window —
    /// those coincide only when the bar and the strip happen to be equally tall, which is never.
    static func photoRect(image: CGSize, viewport: CGSize, topBand: CGFloat, clearance: CGFloat,
                          zoom: CGFloat, pan: CGSize) -> CGRect {
        let base = baseSize(image: image, viewport: viewport,
                            topBand: topBand, clearance: clearance)
        let w = base.width * zoom
        let h = base.height * zoom
        let bandTop = topBand
        let bandBottom = viewport.height - clearance
        return CGRect(x: viewport.width / 2 + pan.width - w / 2,
                      y: (bandTop + bandBottom) / 2 + pan.height - h / 2,
                      width: w, height: h)
    }

    /// Distance from the picture's top edge to the bottom of the tool bar, in the same
    /// coordinates as `photoRect`. Reported by `PICNIDO_GEOM_REPORT` and asserted by
    /// `work/verify_viewer_band.sh`, because "looks balanced" needs a number to be checked on.
    static func topAir(image: CGSize, viewport: CGSize, topBand: CGFloat, clearance: CGFloat,
                       zoom: CGFloat, pan: CGSize) -> CGFloat {
        photoRect(image: image, viewport: viewport, topBand: topBand, clearance: clearance,
                  zoom: zoom, pan: pan).minY - topBand
    }

    /// Distance from the picture's bottom edge to the top of the filmstrip.
    static func bottomAir(image: CGSize, viewport: CGSize, topBand: CGFloat, clearance: CGFloat,
                          zoom: CGFloat, pan: CGSize) -> CGFloat {
        (viewport.height - clearance)
            - photoRect(image: image, viewport: viewport, topBand: topBand, clearance: clearance,
                        zoom: zoom, pan: pan).maxY
    }
}

/// Counts how many times the photo canvas actually re-renders.
///
/// Used by the pan benchmark (`PICNIDO_PAN_BENCH`): the only honest measure of "dragging is
/// smooth" is how many frames the canvas managed to produce per second while a drag was in
/// progress. Counting here rather than in a profiler keeps the number comparable between runs.
final class FrameCounter {
    static let shared = FrameCounter()
    private let lock = NSLock()
    private var count = 0
    func tick() { lock.lock(); count += 1; lock.unlock() }
    func take() -> Int { lock.lock(); let v = count; count = 0; lock.unlock(); return v }
}

/// GPU-composited photo surface for the viewer.
///
/// This was briefly an `NSView` holding a `CALayer`, so CoreAnimation owned the zoom. That
/// did keep the scaling on the GPU, but it carried a fatal side effect: **an AppKit subview
/// always draws above the hosting view's own SwiftUI content**, so the photo painted over
/// every piece of chrome — the filmstrip and the buttons existed, were laid out, and were
/// invisible. (Their hit tests still worked, because that view returned nil from
/// `hitTest`, which is exactly what made the bug so quiet.)
///
/// `scaleEffect` and `offset` are layer transforms too, so nothing is lost by staying in
/// SwiftUI. The stutter that motivated the CALayer detour came from a *live* `.blur()` in
/// the backdrop re-rasterising on every wheel notch; that blur is now a cached bitmap.
///
/// The drop shadow, however, *was* re-rasterised on every frame: `.shadow` forces an offscreen
/// pass, and a drag changes `pan` sixty times a second. It is now applied only while the picture
/// is at or below its resting size — where there is nothing to pan and the pass is cheap — and
/// dropped the moment the user zooms in, which is where the dragging actually happens.
struct ZoomCanvasView: View {
    var image: CGImage?
    /// The original's true pixel size. Geometry is derived from this rather than from `image`,
    /// because `image` may be a downscaled placeholder or a cropped tile — using its dimensions
    /// would make the picture jump as sharper versions arrive.
    var sourceSize: CGSize
    /// The region of the photo that `image` actually covers, in unit coordinates with a top-left
    /// origin. `(0, 0, 1, 1)` means the bitmap is the whole picture; anything smaller is a tile.
    var tileRect: CGRect
    var zoom: CGFloat
    var pan: CGSize
    /// Height owned by the tool bar at the top and by the filmstrip at the bottom; the picture
    /// keeps at least `ViewerGeometry.breath` of glass inside both edges.
    var topBand: CGFloat
    var clearance: CGFloat

    /// The shadow is only drawn while the picture is at or below its resting size. `.shadow`
    /// forces an offscreen pass, and a drag changes `pan` sixty times a second — that pass, not
    /// the GPU transform, is what made dragging a zoomed photo stutter.
    private var needsShadow: Bool { zoom <= 1.02 }

    var body: some View {
        GeometryReader { geo in
            let viewport = geo.size
            let _ = FrameCounter.shared.tick()
            if let image, sourceSize.width > 0, viewport.width > 1, viewport.height > 1 {
                let full = ViewerGeometry.photoRect(image: sourceSize, viewport: viewport,
                                                    topBand: topBand, clearance: clearance,
                                                    zoom: zoom, pan: pan)
                // Where the tile lands. When `tileRect` is the whole picture this reduces to
                // exactly `full`, so the resting layout is unchanged.
                let frame = CGRect(x: full.minX + tileRect.minX * full.width,
                                   y: full.minY + tileRect.minY * full.height,
                                   width: tileRect.width * full.width,
                                   height: tileRect.height * full.height)

                let framed = Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    // Lanczos while the picture is near its resting size, where the extra
                    // sharpness is visible; plain bilinear once it is magnified, where the
                    // difference is invisible and the filter is several times cheaper.
                    .interpolation(zoom > 2 ? .medium : .high)
                    .frame(width: frame.width, height: frame.height)

                Group {
                    if needsShadow {
                        framed.shadow(color: .black.opacity(0.45), radius: 24, y: 2)
                    } else {
                        framed
                    }
                }
                .position(x: frame.midX, y: frame.midY)
            }
        }
    }
}
