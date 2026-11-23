import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

private let accent = Color(red: 0.37, green: 0.91, blue: 0.79)
private let backdrop = Color(red: 0.055, green: 0.076, blue: 0.100)
private let panel = Color(red: 0.082, green: 0.108, blue: 0.139)
private let line = Color.white.opacity(0.10)

@main
struct SpeedMakerApp: App {
    @NSApplicationDelegateAdaptor(FinderOpenDelegate.self) private var finder

    var body: some Scene {
        Window("倍速メーカー", id: "editor") {
            Editor(finder: finder)
                .frame(minWidth: 820, minHeight: 540)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1060, height: 670)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
private final class FinderOpenDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    struct Request: Equatable {
        let id = UUID()
        let urls: [URL]
    }

    @Published var request: Request?

    func application(_ application: NSApplication, open urls: [URL]) {
        request = Request(urls: urls.filter(\.isFileURL))
    }
}

@MainActor
private final class Playback: ObservableObject {
    let player = AVPlayer()
    @Published var elapsed: Double = 0
    @Published var playing = false
    private var observer: Any?
    private var rateObserver: NSKeyValueObservation?

    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            Task { @MainActor in self?.elapsed = time.seconds.isFinite ? time.seconds : 0 }
        }
        rateObserver = player.observe(\.rate, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.rate != 0
            Task { @MainActor in self?.playing = playing }
        }
    }

    deinit {
        if let observer { player.removeTimeObserver(observer) }
    }

    func load(_ movie: Movie) {
        let item = AVPlayerItem(asset: movie.asset)
        item.audioTimePitchAlgorithm = .spectral
        player.pause()
        player.replaceCurrentItem(with: item)
        elapsed = 0
    }

    func seek(_ seconds: Double) {
        elapsed = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func toggle(duration: Double, speed: PlaybackSpeed) {
        if player.rate != 0 {
            player.pause()
        } else {
            if elapsed >= duration - 0.05 { seek(0) }
            player.rate = Float(speed.multiplier)
        }
    }

    func updateSpeed(_ speed: PlaybackSpeed) {
        if player.rate != 0 { player.rate = Float(speed.multiplier) }
    }
}

private final class PlayerSurface: NSView {
    let videoLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = videoLayer
        videoLayer.videoGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { nil }
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerSurface {
        let view = PlayerSurface()
        view.videoLayer.player = player
        return view
    }
    func updateNSView(_ view: PlayerSurface, context: Context) {}
}

private struct Editor: View {
    @ObservedObject var finder: FinderOpenDelegate
    @StateObject private var playback = Playback()
    @State private var movie: Movie?
    @State private var speed = PlaybackSpeed.standard
    @State private var placement = LabelPlacement.topRight
    @State private var opening = false
    @State private var exporting = false
    @State private var progress = 0.0
    @State private var saved: URL?
    @State private var error: String?
    @State private var dropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(line).frame(height: 1)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    previewTitle
                    preview
                    if let movie { transport(movie) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                inspector
            }
            .padding(22)
        }
        .background(backdrop)
        .tint(accent)
        .onChange(of: speed) { _, newSpeed in playback.updateSpeed(newSpeed) }
        .onChange(of: finder.request, initial: true) { _, _ in openFinderSelection() }
        .onChange(of: opening || exporting) { _, busy in
            if !busy { openFinderSelection() }
        }
        .alert("動画を処理できませんでした", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) { Button("閉じる", role: .cancel) {} } message: { Text(error ?? "") }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "forward.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(backdrop)
                .frame(width: 38, height: 38)
                .background(accent, in: RoundedRectangle(cornerRadius: 11))
            Text("倍速メーカー")
                .font(.system(size: 20, weight: .bold))
            Spacer()
            Button(action: chooseVideo) {
                Label("動画を開く", systemImage: "folder")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .controlSize(.large)
            .keyboardShortcut("o", modifiers: .command)
            .disabled(opening || exporting)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var previewTitle: some View {
        HStack(spacing: 10) {
            Text("プレビュー").font(.system(size: 15, weight: .semibold))
            Spacer()
            if let movie {
                Text(movie.url.lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var preview: some View {
        GeometryReader { geometry in
            if let movie {
                let scale = min(geometry.size.width / movie.size.width, geometry.size.height / movie.size.height)
                let size = CGSize(width: movie.size.width * scale, height: movie.size.height * scale)
                let label = placement.frame(in: size, speed: speed)
                ZStack(alignment: .topLeading) {
                    PlayerView(player: playback.player)
                        .allowsHitTesting(false)
                    Image(decorative: SpeedLabel.image(for: speed), scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: label.width, height: label.height)
                        .position(x: label.midX, y: label.midY)
                        .allowsHitTesting(false)
                }
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    if !exporting { placement = .from(point: value.location, in: size, speed: speed) }
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 13) {
                    Image(systemName: "film")
                        .font(.system(size: 29, weight: .medium))
                        .foregroundStyle(accent)
                        .frame(width: 62, height: 62)
                        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 17))
                    Text(opening ? "動画を読み込み中…" : "動画をここにドロップ")
                        .font(.system(size: 19, weight: .semibold))
                    if opening {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("ファイルを選択", action: chooseVideo)
                            .buttonStyle(.link)
                            .foregroundStyle(accent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(movie == nil ? panel : .black, in: RoundedRectangle(cornerRadius: 15))
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15).strokeBorder(
                dropTarget ? accent : line,
                style: StrokeStyle(lineWidth: dropTarget ? 2 : 1, dash: movie == nil ? [5, 5] : [])
            )
            .allowsHitTesting(false)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.isFileURL, !exporting, !opening else { return false }
            load(url)
            return true
        } isTargeted: { dropTarget = $0 && !exporting && !opening }
    }

    private func transport(_ movie: Movie) -> some View {
        HStack(spacing: 14) {
            Button {
                playback.toggle(duration: movie.duration.seconds, speed: speed)
            } label: {
                Image(systemName: playback.playing ? "pause.fill" : "play.fill")
                    .frame(width: 23, height: 22)
            }
            .help(playback.playing ? "一時停止" : "\(speed.caption)で再生")
            .keyboardShortcut(.space, modifiers: [])
            Slider(value: Binding(
                get: { min(max(0, playback.elapsed), movie.duration.seconds) },
                set: { playback.seek($0) }
            ), in: 0...movie.duration.seconds) { Text("再生位置") }
                .labelsHidden()
            Text("\(timeText(playback.elapsed / speed.multiplier)) / \(timeText(movie.duration.seconds / speed.multiplier))")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("書き出し設定").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("MP4")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(accent.opacity(0.10), in: Capsule())
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("再生速度").font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("再生速度", selection: $speed) {
                    ForEach(PlaybackSpeed.presets, id: \.self) { option in
                        Text(option.caption).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.large)
                .disabled(exporting)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("「\(speed.caption)」の表示位置").font(.system(size: 13, weight: .semibold))
                positionGrid
                Text("プレビューをクリック・ドラッグして微調整")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(movie == nil || exporting)
            .opacity(movie == nil ? 0.55 : 1)
            Spacer(minLength: 0)
            if let movie {
                HStack {
                    Text("書き出し後の長さ").foregroundStyle(.secondary)
                    Spacer()
                    Text(timeText(movie.duration.seconds / speed.multiplier, fractional: true)).monospacedDigit()
                }
                .font(.system(size: 12))
            }
            if exporting {
                ProgressView(value: progress) { Text("書き出し中…").font(.system(size: 12)) }
            } else if let saved {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([saved])
                } label: {
                    Label("保存した動画を表示", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
            }
            Button(action: chooseDestination) {
                Label("MP4を書き出す", systemImage: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(backdrop)
                    .background(accent, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("e", modifiers: .command)
            .disabled(movie == nil || exporting || opening)
            .opacity(movie == nil || exporting || opening ? 0.4 : 1)
        }
        .padding(17)
        .frame(width: 241)
        .frame(maxHeight: .infinity)
        .background(panel, in: RoundedRectangle(cornerRadius: 15))
        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(line).allowsHitTesting(false) }
    }

    private var positionGrid: some View {
        let names = ["左上", "上中央", "右上", "左中央", "中央", "右中央", "左下", "下中央", "右下"]
        return Grid(horizontalSpacing: 5, verticalSpacing: 5) {
            ForEach(0..<3) { row in
                GridRow {
                    ForEach(0..<3) { column in
                        let point = LabelPlacement(x: CGFloat(column) / 2, y: CGFloat(row) / 2)
                        let selected = placement == point
                        Button {
                            placement = point
                        } label: {
                            Image(systemName: selected ? "circle.inset.filled" : "circle.fill")
                                .font(.system(size: selected ? 12 : 6, weight: .medium))
                                .foregroundStyle(selected ? accent : .white.opacity(0.3))
                                .frame(maxWidth: .infinity)
                                .frame(height: 27)
                                .background(selected ? accent.opacity(0.13) : Color.white.opacity(0.055),
                                            in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .help(names[row * 3 + column])
                        .accessibilityLabel(names[row * 3 + column])
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
        }
    }

    private func chooseVideo() {
        let dialog = NSOpenPanel()
        dialog.allowedContentTypes = [.movie]
        guard dialog.runModal() == .OK, let url = dialog.url else { return }
        load(url)
    }

    private func openFinderSelection() {
        guard !opening, !exporting, let request = finder.request else { return }
        finder.request = nil
        guard request.urls.count == 1, let url = request.urls.first else {
            error = "Finderで動画を1本選んでください。"
            return
        }
        error = nil
        load(url)
    }

    private func load(_ url: URL) {
        opening = true
        Task {
            defer { opening = false }
            do {
                let newMovie = try await Movie.open(url)
                playback.load(newMovie)
                movie = newMovie
                placement = .topRight
                saved = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func chooseDestination() {
        guard let movie else { return }
        let dialog = NSSavePanel()
        dialog.allowedContentTypes = [.mpeg4Movie]
        let selectedSpeed = speed
        dialog.nameFieldStringValue = movie.url.deletingPathExtension().lastPathComponent + "_\(selectedSpeed.number)x.mp4"
        dialog.directoryURL = movie.url.deletingLastPathComponent()
        guard dialog.runModal() == .OK, let destination = dialog.url else { return }
        playback.player.pause()
        let selectedPlacement = placement
        progress = 0
        saved = nil
        exporting = true
        Task {
            defer { exporting = false }
            do {
                try await movie.export(
                    to: destination, speed: selectedSpeed, placement: selectedPlacement
                ) { progress = $0 }
                saved = destination
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func timeText(_ seconds: Double, fractional: Bool = false) -> String {
        let count = Int(max(0, seconds))
        let time = String(format: "%d:%02d", count / 60, count % 60)
        return fractional ? time + ".\(Int(seconds * 10) % 10)" : time
    }
}
