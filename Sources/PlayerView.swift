import SwiftUI
import AVFoundation

struct PlayerView: View {
    let recording: Recording
    let all: [Recording]

    @Environment(\.dismiss) private var dismiss
    @StateObject private var engine = PlayerEngine()
    @State private var showShare = false
    @State private var showTranscript = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Text(recording.title)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Text(RecordingsStore.stamp.string(from: recording.createdAt))
                    .font(.footnote).foregroundStyle(.secondary)

                Slider(value: $engine.progress, in: 0...max(engine.duration, 0.01)) { editing in
                    engine.seek(to: engine.progress, commit: !editing)
                }
                .padding(.horizontal)

                HStack {
                    Text(Recording.hms(engine.current))
                    Spacer()
                    Text("-" + Recording.hms(max(0, engine.duration - engine.current)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal)

                HStack(spacing: 34) {
                    Button { engine.skip(-15) } label: {
                        Image(systemName: "gobackward.15").font(.title)
                    }
                    Button { engine.toggle() } label: {
                        Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 68))
                    }
                    Button { engine.skip(15) } label: {
                        Image(systemName: "goforward.15").font(.title)
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 4)

                HStack(spacing: 12) {
                    Button { showShare = true } label: {
                        Label("Отправить", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)

                    Button { showTranscript = true } label: {
                        Label("Текст", systemImage: "text.alignleft")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 6)

                Spacer()
            }
            .padding(.top, 20)
            .navigationTitle("Плеер")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
            .sheet(isPresented: $showShare) {
                ShareSheet(items: [recording.url])
            }
            .sheet(isPresented: $showTranscript) {
                TranscriptView(recording: recording)
            }
            .onAppear { engine.load(url: recording.url) }
            .onDisappear { engine.stop() }
        }
    }
}

final class PlayerEngine: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var current: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var progress: TimeInterval = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(url: URL) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        player?.isMeteringEnabled = false
        duration = player?.duration ?? 0
        progress = 0
        current = 0
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        player?.play(); isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let p = self.player else { return }
            self.current = p.currentTime
            self.progress = p.currentTime
        }
    }

    func pause() { player?.pause(); isPlaying = false; timer?.invalidate() }

    func stop() { player?.stop(); isPlaying = false; timer?.invalidate(); timer = nil }

    func skip(_ seconds: TimeInterval) {
        guard let p = player else { return }
        p.currentTime = min(max(0, p.currentTime + seconds), p.duration)
        current = p.currentTime; progress = p.currentTime
    }

    func seek(to time: TimeInterval, commit: Bool) {
        player?.currentTime = time
        current = time
        if commit { progress = time }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false; timer?.invalidate()
    }
}
