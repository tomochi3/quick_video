import AppKit
import AVFoundation
import CoreImage
import Darwin

struct PlaybackSpeed: Hashable, Sendable {
    let hundredths: Int32
    static let presets: [Self] = {
        let values: [Int32] = [125, 150, 175, 200, 225, 250, 275, 300, 350, 400, 500, 600, 800, 1000]
        return values.map(Self.init(hundredths:))
    }()
    static let standard = Self(hundredths: 200)

    var multiplier: Double { Double(hundredths) / 100 }
    var number: String {
        hundredths.isMultiple(of: 100) ? String(hundredths / 100) : String(multiplier)
    }
    var caption: String { number + "倍速" }
    var labelAspectRatio: CGFloat { 2.35 + CGFloat(number.count - 1) * 0.36 }

    func scaledDuration(_ duration: CMTime) -> CMTime {
        let precise = CMTimeConvertScale(duration, timescale: 600_000, method: .default)
        return CMTimeMultiplyByRatio(precise, multiplier: 100, divisor: hundredths)
    }
}

struct LabelPlacement: Equatable {
    var x: CGFloat
    var y: CGFloat
    static let topRight = Self(x: 1, y: 0)

    func frame(in size: CGSize, speed: PlaybackSpeed) -> CGRect {
        let shortEdge = min(size.width, size.height)
        let height = shortEdge * 0.092
        let width = height * speed.labelAspectRatio
        let inset = shortEdge * 0.035
        return CGRect(
            x: inset + x * max(0, size.width - 2 * inset - width),
            y: inset + y * max(0, size.height - 2 * inset - height),
            width: width, height: height
        )
    }

    static func from(point: CGPoint, in size: CGSize, speed: PlaybackSpeed) -> Self {
        let first = Self(x: 0, y: 0).frame(in: size, speed: speed)
        let last = Self(x: 1, y: 1).frame(in: size, speed: speed)
        func fraction(_ point: CGFloat, _ start: CGFloat, _ end: CGFloat) -> CGFloat {
            guard end > start else { return 0.5 }
            return min(1, max(0, (point - start) / (end - start)))
        }
        return Self(
            x: fraction(point.x, first.midX, last.midX),
            y: fraction(point.y, first.midY, last.midY)
        )
    }
}

@MainActor
enum SpeedLabel {
    private static var images: [PlaybackSpeed: CGImage] = [:]

    static func image(for speed: PlaybackSpeed) -> CGImage {
        if let cached = images[speed] { return cached }
        let size = NSSize(width: 400 * speed.labelAspectRatio, height: 400)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(srgbRed: 0.035, green: 0.058, blue: 0.074, alpha: 0.90).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 9, dy: 9), xRadius: 92, yRadius: 92).fill()
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 15, dy: 15), xRadius: 87, yRadius: 87)
            NSColor.white.withAlphaComponent(0.60).setStroke()
            outline.lineWidth = 9
            outline.stroke()
            let text = NSAttributedString(string: speed.caption, attributes: [
                .font: NSFont.systemFont(ofSize: 210, weight: .bold),
                .foregroundColor: NSColor.white
            ])
            let textSize = text.size()
            text.draw(at: NSPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2))
            return true
        }
        let rendered = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        images[speed] = rendered
        return rendered
    }
}

enum MovieError: LocalizedError {
    case unreadable, exportUnavailable, sameFile
    var errorDescription: String? {
        switch self {
        case .unreadable: "再生できる映像が見つかりませんでした。MP4やMOVの動画を選んでください。"
        case .exportUnavailable: "この動画をMP4に書き出せませんでした。"
        case .sameFile: "元の動画と異なる保存先を選んでください。"
        }
    }
}

struct Movie {
    let url: URL
    let asset: AVURLAsset
    let track: AVAssetTrack
    let transform: CGAffineTransform
    let size: CGSize
    let duration: CMTime

    static func open(_ url: URL) async throws -> Self {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MovieError.unreadable
        }
        async let playable = asset.load(.isPlayable)
        async let duration = asset.load(.duration)
        let (nativeSize, transform) = try await track.load(.naturalSize, .preferredTransform)
        let size = CGRect(origin: .zero, size: nativeSize).applying(transform).standardized.size
        let length = try await duration
        guard try await playable, length.seconds.isFinite, length.seconds > 0,
              size.width >= 2, size.height >= 2 else { throw MovieError.unreadable }
        return Self(url: url, asset: asset, track: track, transform: transform, size: size, duration: length)
    }

    @MainActor
    func export(
        to destination: URL, speed: PlaybackSpeed, placement: LabelPlacement,
        progress: @escaping (Double) -> Void
    ) async throws {
        guard url.standardizedFileURL.resolvingSymlinksInPath() !=
                destination.standardizedFileURL.resolvingSymlinksInPath() else { throw MovieError.sameFile }

        let composition = AVMutableComposition()
        let sourceRange = CMTimeRange(start: .zero, duration: duration)
        try await composition.insertTimeRange(sourceRange, of: asset, at: .zero)
        // Preserve rotation metadata from phone recordings before configuring the compositor.
        guard let videoTrack = composition.tracks(withMediaType: .video).first else { throw MovieError.unreadable }
        videoTrack.preferredTransform = transform
        let outputDuration = speed.scaledDuration(duration)
        composition.scaleTimeRange(sourceRange, toDuration: outputDuration)

        let badge = CIImage(cgImage: SpeedLabel.image(for: speed))
        let videoComposition: AVMutableVideoComposition = try await withCheckedThrowingContinuation { continuation in
            AVMutableVideoComposition.videoComposition(with: composition, applyingCIFiltersWithHandler: { request in
                let source = request.sourceImage
                let extent = source.extent
                let label = placement.frame(in: extent.size, speed: speed)
                let renderedLabel = badge.transformed(by: CGAffineTransform(
                    scaleX: label.width / badge.extent.width, y: label.height / badge.extent.height
                )).transformed(by: CGAffineTransform(
                    translationX: extent.minX + label.minX, y: extent.maxY - label.maxY
                ))
                request.finish(with: renderedLabel.composited(over: source).cropped(to: extent), context: nil)
            }, completionHandler: { result, error in
                if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: error ?? MovieError.exportUnavailable)
                }
            })
        }
        let sourceFPS = Double(try await track.load(.nominalFrameRate))
        let outputFPS = sourceFPS.isFinite && sourceFPS > 0 ? min(60, sourceFPS * speed.multiplier) : 30
        videoComposition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        let frameDuration = CMTime(seconds: 1 / outputFPS, preferredTimescale: 600_000)
        videoComposition.frameDuration = CMTimeMinimum(frameDuration, outputDuration)

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality),
              session.supportedFileTypes.contains(.mp4) else { throw MovieError.exportUnavailable }
        session.videoComposition = videoComposition
        session.audioTimePitchAlgorithm = .spectral
        session.shouldOptimizeForNetworkUse = true

        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".speed-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let monitor = Task { @MainActor in
            for await state in session.states(updateInterval: 0.15) {
                if case .exporting(let progressState) = state { progress(progressState.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }
        try await session.export(to: temporary, as: .mp4)
        guard rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        progress(1)
    }
}
