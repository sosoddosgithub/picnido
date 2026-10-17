import Foundation
import AVFoundation
import CoreImage
import CoreGraphics
import AppKit

enum MovieMaker {

    struct Settings {
        var photos: [PhotoItem] = []
        var secondsPerPhoto: Double = 3.0
        var transition: TransitionKind = .crossFade
        var transitionSeconds: Double = 0.8
        var resolution: MovieResolution = .hd1080
        var kenBurns: Bool = true
        var music: URL?
        var title: String = ""
    }

    enum MovieError: LocalizedError {
        case noPhotos
        case writerSetup(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noPhotos: return "No photos selected"
            case .writerSetup(let s): return "Could not start the video writer: \(s)"
            case .writeFailed(let s): return "Writing failed: \(s)"
            }
        }
    }

    private static let fps: Int32 = 30

    static func make(settings: Settings, output: URL,
                     progress: @escaping (Double) -> Void,
                     completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try render(settings: settings, output: output, progress: progress)
                completion(.success(url))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private static func render(settings: Settings, output: URL,
                               progress: @escaping (Double) -> Void) throws -> URL {
        guard !settings.photos.isEmpty else { throw MovieError.noPhotos }
        let size = settings.resolution.size
        let tmpVideo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("picnido_movie_\(UUID().uuidString).mp4")

        try? FileManager.default.removeItem(at: tmpVideo)
        let writer = try AVAssetWriter(outputURL: tmpVideo, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(size.width * size.height * 0.11),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ])
        guard writer.canAdd(input) else { throw MovieError.writerSetup("input rejected") }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let context = ImageEngine.shared.makeContext()
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

        // prepare clip images, scaled to cover the frame
        var clips: [CIImage] = []
        for photo in settings.photos {
            guard let cg = ImageEngine.shared.exportCGImage(photo: photo, maxDimension: max(size.width, size.height) * 2) else { continue }
            clips.append(CIImage(cgImage: cg))
        }
        guard !clips.isEmpty else { throw MovieError.noPhotos }

        let framesPerPhoto = max(Int(Double(fps) * settings.secondsPerPhoto), 4)
        let overlap = settings.transition == .none ? 0 : max(Int(Double(fps) * settings.transitionSeconds), 2)

        var frameIndex = 0
        for (i, clip) in clips.enumerated() {
            let next: CIImage? = i + 1 < clips.count ? clips[i + 1] : nil
            for f in 0..<framesPerPhoto {
                if i < clips.count - 1, let next, overlap > 0, f >= framesPerPhoto - overlap {
                    let t = Double(f - (framesPerPhoto - overlap)) / Double(overlap)
                    let a = framed(clip, progress: Double(f) / Double(framesPerPhoto),
                                   kenBurns: settings.kenBurns, size: size)
                    let b = framed(next, progress: 0, kenBurns: settings.kenBurns, size: size)
                    let blended = transitionImage(from: a, to: b, t: t,
                                                  kind: settings.transition, size: size)
                    try write(blended, context: context, adaptor: adaptor, index: frameIndex,
                              size: size, colorSpace: colorSpace, input: input)
                    // the overlap frames count for both clips
                    frameIndex += 1
                } else {
                    let a = framed(clip, progress: Double(f) / Double(framesPerPhoto),
                                   kenBurns: settings.kenBurns, size: size)
                    try write(a, context: context, adaptor: adaptor, index: frameIndex,
                              size: size, colorSpace: colorSpace, input: input)
                    frameIndex += 1
                }
                if frameIndex % 4 == 0 {
                    let total = Double(clips.count * framesPerPhoto)
                    progress(min(Double(frameIndex) / max(total, 1), 0.98))
                }
            }
        }

        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        if writer.status != .completed {
            throw MovieError.writeFailed(writer.error?.localizedDescription ?? "unknown")
        }

        // mux in the soundtrack if one was chosen
        if let music = settings.music {
            try? FileManager.default.removeItem(at: output)
            try mux(video: tmpVideo, audio: music, to: output)
            try? FileManager.default.removeItem(at: tmpVideo)
        } else {
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: tmpVideo, to: output)
        }
        progress(1.0)
        return output
    }

    // MARK: - Frame composition

    private static func framed(_ image: CIImage, progress: Double, kenBurns: Bool, size: CGSize) -> CIImage {
        let target = CGRect(origin: .zero, size: size)
        let e = image.extent
        let cover = max(size.width / e.width, size.height / e.height)
        var scale = cover * (kenBurns ? (1.0 + 0.10 * CGFloat(progress)) : 1.0)
        var transformed = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if kenBurns {
            let dx = (transformed.extent.width - size.width) * (CGFloat(progress) - 0.5) * 0.6
            let dy = (transformed.extent.height - size.height) * 0.35
            transformed = transformed.transformed(by: CGAffineTransform(translationX: -transformed.extent.origin.x - dx,
                                                                        y: -transformed.extent.origin.y - dy))
        } else {
            transformed = transformed.transformed(by: CGAffineTransform(translationX: -transformed.extent.origin.x - (transformed.extent.width - size.width) / 2,
                                                                        y: -transformed.extent.origin.y - (transformed.extent.height - size.height) / 2))
        }
        scale = 1
        _ = scale
        return transformed.cropped(to: target)
    }

    private static func transitionImage(from a: CIImage, to b: CIImage, t: Double,
                                        kind: TransitionKind, size: CGSize) -> CIImage {
        let target = CGRect(origin: .zero, size: size)
        switch kind {
        case .none:
            return t < 0.5 ? a : b
        case .fade:
            let black = CIImage(color: .black).cropped(to: target)
            if t < 0.5 {
                let f = 1 - t * 2
                return Filters.make("CIDissolveTransition", [kCIInputImageKey: a, "inputTargetImage": black,
                                                             "inputTime": f])?.cropped(to: target) ?? a
            } else {
                let f = (t - 0.5) * 2
                return Filters.make("CIDissolveTransition", [kCIInputImageKey: black, "inputTargetImage": b,
                                                             "inputTime": f])?.cropped(to: target) ?? b
            }
        case .crossFade, .kenBurns:
            return Filters.make("CIDissolveTransition", [kCIInputImageKey: a, "inputTargetImage": b,
                                                         "inputTime": t])?.cropped(to: target) ?? b
        case .slideLeft, .slideRight:
            let dir: CGFloat = kind == .slideLeft ? -1 : 1
            let shiftA = a.transformed(by: CGAffineTransform(translationX: dir * CGFloat(t) * size.width, y: 0))
            let shiftB = b.transformed(by: CGAffineTransform(translationX: -dir * CGFloat(1 - t) * size.width, y: 0))
            return shiftB.composited(over: shiftA).cropped(to: target)
        case .wipeUp:
            let gradient = Filters.make("CILinearGradient", [
                "inputPoint0": CIVector(x: 0, y: size.height * CGFloat(t)),
                "inputPoint1": CIVector(x: 0, y: size.height * CGFloat(t) + 40),
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 1)
            ])?.cropped(to: target) ?? CIImage(color: .black).cropped(to: target)
            return Filters.blend(b, over: a, mask: gradient).cropped(to: target)
        }
    }

    private static func write(_ image: CIImage, context: CIContext, adaptor: AVAssetWriterInputPixelBufferAdaptor,
                              index: Int, size: CGSize, colorSpace: CGColorSpace,
                              input: AVAssetWriterInput) throws {
        while !input.isReadyForMoreMediaData { usleep(2000) }
        var pixelBuffer: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool else { throw MovieError.writeFailed("no pixel buffer pool") }
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let buffer = pixelBuffer else { throw MovieError.writeFailed("no pixel buffer") }
        context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
        let time = CMTime(value: CMTimeValue(index), timescale: fps)
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw MovieError.writeFailed("append rejected at frame \(index)")
        }
    }

    // MARK: - Audio muxing

    private static func mux(video: URL, audio: URL, to output: URL) throws {
        let composition = AVMutableComposition()
        let vAsset = AVURLAsset(url: video)
        let aAsset = AVURLAsset(url: audio)
        guard let vTrack = vAsset.tracks(withMediaType: .video).first else {
            throw MovieError.writeFailed("no video track")
        }

        let videoDuration = vAsset.duration
        guard let compVideo = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MovieError.writeFailed("cannot add video track")
        }
        try compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration),
                                      of: vTrack, at: .zero)

        if let aTrack = aAsset.tracks(withMediaType: .audio).first,
           let compAudio = composition.addMutableTrack(withMediaType: .audio,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid) {
            var cursor = CMTime.zero
            let audioDuration = aAsset.duration
            while cursor < videoDuration {
                let remaining = CMTimeSubtract(videoDuration, cursor)
                let chunk = CMTimeMinimum(audioDuration, remaining)
                try compAudio.insertTimeRange(CMTimeRange(start: .zero, duration: chunk), of: aTrack, at: cursor)
                cursor = CMTimeAdd(cursor, chunk)
            }
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw MovieError.writeFailed("cannot create export session")
        }
        export.outputURL = output
        export.outputFileType = .mp4
        let sem = DispatchSemaphore(value: 0)
        export.exportAsynchronously { sem.signal() }
        sem.wait()
        if export.status != .completed {
            throw MovieError.writeFailed(export.error?.localizedDescription ?? "mux failed")
        }
    }
}
