import SwiftUI
import AppKit
import AVFoundation

struct SlideshowWindow: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var index = 0
    @State private var image: CGImage?
    @State private var backdrop: CGImage?
    @State private var timer: Timer?
    @State private var player: AVAudioPlayer?
    @State private var window: NSWindow?
    @State private var progress: Double = 0
    @State private var showControls = true
    @State private var kenScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var transitionProgress: Double = 1

    /// Set when the slide on screen is an animation being driven by the hub, so the still-image
    /// load below knows not to overwrite it with a frozen first frame.
    @State private var animated = false
    @State private var animation: AnimationHub.Token?

    private var photos: [PhotoItem] { app.store.visiblePhotos }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let backdrop {
                Image(decorative: backdrop, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 60, opaque: true)
                    .saturation(1.3)
                    .overlay(Color.black.opacity(0.5))
                    .ignoresSafeArea()
            }
            VisualEffectView(material: .hudWindow, blending: .withinWindow)
                .opacity(0.4)
                .ignoresSafeArea()

            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(kenScale)
                    .offset(offset)
                    .opacity(transitionProgress)
                    .shadow(color: .black.opacity(0.6), radius: 24, y: 6)
                    .padding(30)
                    .id(index)
            }

            if showControls {
                VStack {
                    Spacer()
                    HStack(spacing: 14) {
                        Button { step(-1) } label: { Image(systemName: "backward.fill") }
                        Button { paused.toggle() } label: {
                            Image(systemName: paused ? "play.fill" : "pause.fill")
                        }
                        Button { step(1) } label: { Image(systemName: "forward.fill") }
                        Divider().frame(height: 16)
                        Text(currentCaption)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                            .frame(maxWidth: 300)
                        Text("\(index + 1) / \(photos.count)")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.6))
                        Button { exit() } label: { Image(systemName: "xmark") }
                    }
                    .buttonStyle(GlassButtonStyle())
                    .padding(.bottom, 26)
                }
                .transition(.opacity)
            }
        }
        .background(WindowAccessor { w in
            if window !== w {
                window = w
                w.backgroundColor = .black
                w.collectionBehavior.insert(.fullScreenPrimary)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
                }
            }
        })
        .onKeyPress(.escape) { exit(); return .handled }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.space) { paused.toggle(); return .handled }
        .onContinuousHover { phase in
            switch phase {
            case .active: showControls = true
            default: break
            }
        }
        .onAppear { start() }
        .onDisappear { stop() }
    }

    @State private var paused = false

    private var currentCaption: String {
        guard index < photos.count else { return "" }
        let p = photos[index]
        return p.caption.isEmpty ? p.fileName : p.caption
    }

    // MARK: - Playback

    private func start() {
        index = 0
        load()
        startMusic()
        scheduleAdvance()
        warmChrome()
    }

    private func warmChrome() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { showControls = false }
        }
    }

    private func startMusic() {
        guard let url = app.slideshowMusic else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.numberOfLoops = app.slideshowLoop ? -1 : 0
        player?.play()
    }

    private func scheduleAdvance() {
        timer?.invalidate()
        let interval = max(app.slideshowInterval, 0.8)
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            if paused { return }
            progress += 0.05 / interval
            if progress >= 1 {
                progress = 0
                advance()
            }
        }
    }

    private func advance() {
        guard !photos.isEmpty else { return }
        if index + 1 >= photos.count {
            if app.slideshowLoop { index = 0; load() } else { exit() }
        } else {
            index += 1
            load()
        }
    }

    private func step(_ delta: Int) {
        guard !photos.isEmpty else { return }
        index = (index + delta + photos.count) % photos.count
        progress = 0
        load()
    }

    private func load() {
        guard index < photos.count else { return }
        let photo = photos[index]
        transitionProgress = 0
        withAnimation(.easeInOut(duration: 0.6)) { transitionProgress = 1 }

        if app.slideshowKenBurns {
            kenScale = 1.0
            offset = .zero
            withAnimation(.linear(duration: max(app.slideshowInterval, 1))) {
                kenScale = 1.12
                offset = CGSize(width: 14, height: -10)
            }
        }

        let p = photo
        DispatchQueue.global(qos: .userInitiated).async {
            let full = ImageEngine.shared.render(photo: p, maxDimension: 2800, quality: .preview)
            let soft = ImageEngine.shared.thumbnailNow(for: p, displaySize: 900)
            DispatchQueue.main.async {
                backdrop = soft
                if !animated { image = full }
            }
        }

        // An animated slide plays. The still load above still runs, because it supplies the
        // blurred backdrop and a first frame to show while the animation's own decoder is being
        // opened — but it does not get to replace a playing animation.
        animation?.cancel()
        animated = false
        animation = AnimationHub.shared.subscribe(photo, priority: .focused) { frame in
            if !animated {
                PicnidoAppDelegate.report("[slides] first animation frame \(frame.width)x\(frame.height) for \(photo.fileName)")
            }
            animated = true
            image = frame
        }
        PicnidoAppDelegate.report("[slides] load #\(index + 1)/\(photos.count) \(photo.fileName) "
            + "animated=\(AnimationHub.shared.isAnimating(photo))")
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        animation?.cancel()
        animation = nil
    }

    private func exit() {
        stop()
        if let w = window, w.styleMask.contains(.fullScreen) {
            w.toggleFullScreen(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { dismissWindow(id: "slideshow") }
        } else {
            dismissWindow(id: "slideshow")
        }
    }
}
