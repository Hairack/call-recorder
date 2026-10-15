import Foundation
import AVFoundation
import Combine

/// Запись разговора через микрофон.
/// Рассчитана на разговор по громкой связи: микрофон слышит оба голоса.
@MainActor
final class Recorder: NSObject, ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0          // 0...1, для индикатора
    @Published private(set) var peak: Float = 0

    /// Автозапись: старт, когда звук дольше порога держится громким.
    @Published var autoRecord = false
    @Published var autoLevelThreshold: Float = 0.25

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var autoTimer: Timer?
    private var currentURL: URL?
    private var startedAt: Date?
    private var loudSince: Date?

    var onFinish: ((Recording) -> Void)?

    // MARK: - Разрешение на микрофон

    /// Спрашивает разрешение. Ответ всегда приходит на главном потоке.
    nonisolated static func ensurePermission() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            }
        }
    }

    // MARK: - Публичный API

    func toggle() {
        isRecording ? stop() : start()
    }

    func start() {
        Task { @MainActor in
            guard await Self.ensurePermission() else { return }
            self.beginSessionAndRecord()
        }
    }

    /// Включает режим ожидания громкого звука (для автостарта).
    func armAutoRecord() {
        guard autoRecord, !isRecording else { return }
        Task { @MainActor in
            guard await Self.ensurePermission() else { return }
            guard self.autoRecord, !self.isRecording else { return }
            try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default,
                                                             options: [.defaultToSpeaker, .allowBluetooth])
            try? AVAudioSession.sharedInstance().setActive(true)
            self.loudSince = nil
            self.autoTimer?.invalidate()
            self.autoTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.autoTick() }
            }
            self.armMeteringRecorder()
        }
    }

    func disarmAutoRecord() {
        autoTimer?.invalidate(); autoTimer = nil
        recorder?.stop(); recorder = nil
        Self.cleanupProbe()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        recorder?.stop()
        let url = currentURL
        recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        if let url, let startedAt {
            let duration = Date().timeIntervalSince(startedAt)
            if duration >= 1, let rec = Recording(url: url, createdAt: startedAt, duration: duration) {
                onFinish?(rec)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        currentURL = nil
        startedAt = nil
        elapsed = 0
        level = 0
        peak = 0
    }

    // MARK: - Внутренняя часть

    private func armMeteringRecorder() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe.m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.low.rawValue
        ]
        recorder = try? AVAudioRecorder(url: url, settings: settings)
        recorder?.isMeteringEnabled = true
        recorder?.record()
    }

    private func beginSessionAndRecord() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch { return }

        let name = "Запись " + Self.fileStamp.string(from: Date()) + ".m4a"
        let url = RecordingsStore.audioDirectory.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        guard let r = try? AVAudioRecorder(url: url, settings: settings) else { return }
        r.isMeteringEnabled = true
        r.record()

        recorder = r
        currentURL = url
        startedAt = Date()
        isRecording = true
        elapsed = 0
        peak = 0

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.recordTick() }
        }
    }

    private func recordTick() {
        guard let rec = recorder else { return }
        rec.updateMeters()
        let lvl = Self.normalized(power: rec.averagePower(forChannel: 0))
        level = lvl
        peak = max(peak, lvl)
        if let s = startedAt { elapsed = Date().timeIntervalSince(s) }
    }

    private func autoTick() {
        guard let r = recorder else { return }
        r.updateMeters()
        let lvl = Self.normalized(power: r.averagePower(forChannel: 0))
        if lvl >= autoLevelThreshold {
            if loudSince == nil { loudSince = Date() }
            if let s = loudSince, Date().timeIntervalSince(s) >= 1.2 {
                autoTimer?.invalidate(); autoTimer = nil
                Self.cleanupProbe()
                try? AVAudioSession.sharedInstance().setActive(false)
                beginSessionAndRecord()
            }
        } else {
            loudSince = nil
        }
    }

    nonisolated static func cleanupProbe() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe.m4a")
        try? FileManager.default.removeItem(at: url)
    }

    /// averagePower: -160...0 дБ -> 0...1
    nonisolated static func normalized(power: Float) -> Float {
        let db = max(power, -60)
        return (db + 60) / 60
    }

    nonisolated static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        f.locale = Locale(identifier: "ru_RU")
        return f
    }()
}
