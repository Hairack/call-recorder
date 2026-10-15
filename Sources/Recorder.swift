import Foundation
import AVFoundation
import Combine

/// Запись разговора через микрофон.
/// Рассчитана на разговор по громкой связи: микрофон слышит оба голоса.
///
/// Запись продолжается, когда приложение свёрнуто или экран заблокирован:
/// в Info.plist включён фоновый режим «audio», а звуковая сессия остаётся
/// активной всё время, пока идёт запись.
@MainActor
final class Recorder: NSObject, ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0          // 0...1, для индикатора
    @Published private(set) var peak: Float = 0

    /// Система забрала микрофон (начался звонок или сработал будильник).
    /// Запись продолжится, когда микрофон освободится, если включено
    /// «Продолжать после звонка».
    @Published private(set) var interrupted = false

    /// Автозапись: старт, когда звук дольше порога держится громким.
    @Published var autoRecord = false
    @Published var autoLevelThreshold: Float = 0.25

    /// Продолжать писать после звонка, когда микрофон снова доступен.
    @Published var resumeAfterInterruption = true

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var autoTimer: Timer?
    private var currentURL: URL?
    private var startedAt: Date?
    private var loudSince: Date?
    private var observers: [NSObjectProtocol] = []
    private var resumeAttempts = 0

    var onFinish: ((Recording) -> Void)?

    override init() {
        super.init()
        // Следим за тем, когда система забирает и возвращает микрофон.
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let began = (type == .began)
            Task { @MainActor in self?.handleInterruption(began: began) }
        })
        // Смена маршрута (вынули наушники, подключили гарнитуру) тоже может
        // остановить запись — возвращаем её.
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resumeIfNeeded() }
        })
    }

    deinit {
        let center = NotificationCenter.default
        for token in observers { center.removeObserver(token) }
    }

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

    /// Вызывается, когда приложение снова на экране: поправляет таймер, если
    /// запись всё это время шла в фоне.
    func appBecameActive() {
        guard isRecording else { return }
        startTicking()
        resumeIfNeeded()
    }

    /// Включает режим ожидания громкого звука (для автостарта).
    func armAutoRecord() {
        guard autoRecord, !isRecording else { return }
        Task { @MainActor in
            guard await Self.ensurePermission() else { return }
            guard self.autoRecord, !self.isRecording else { return }
            self.activateSession()
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
        autoTimer?.invalidate(); autoTimer = nil
        recorder?.stop()
        let url = currentURL
        recorder = nil
        isRecording = false
        interrupted = false
        resumeAttempts = 0

        if let url, let startedAt {
            let duration = Date().timeIntervalSince(startedAt)
            if duration >= 1, let rec = Recording(url: url, createdAt: startedAt, duration: duration) {
                onFinish?(rec)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        currentURL = nil
        startedAt = nil
        elapsed = 0
        level = 0
        peak = 0
    }

    // MARK: - Внутренняя часть

    /// Настраивает и включает звуковую сессию так, чтобы запись шла и в фоне.
    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .mixWithOthers не даёт другим приложениям (музыка, видео) прерывать
            // нашу запись — система прерывает только на звонок или будильник.
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try session.setActive(true)
        } catch {
            // Не получилось с расширенным набором — пробуем самый простой.
            try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try? session.setActive(true)
        }
    }

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
        activateSession()

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
        interrupted = false
        resumeAttempts = 0
        elapsed = 0
        peak = 0
        startTicking()
    }

    private func startTicking() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.recordTick() }
        }
    }

    private func recordTick() {
        // Время считаем от начала записи, а не по числу «тиков»: в фоне таймер
        // останавливается, но запись идёт — время должно быть верным.
        if let s = startedAt { elapsed = Date().timeIntervalSince(s) }
        guard let rec = recorder else { return }
        rec.updateMeters()
        let lvl = Self.normalized(power: rec.averagePower(forChannel: 0))
        level = lvl
        peak = max(peak, lvl)
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

    // MARK: - Прерывания (звонок, будильник, смена маршрута)

    private func handleInterruption(began: Bool) {
        if began {
            // Микрофон забрала система (обычно — входящий или исходящий звонок).
            if isRecording { interrupted = true }
            timer?.invalidate(); timer = nil
        } else {
            resumeIfNeeded()
        }
    }

    /// Пытается вернуть запись после паузы. Держит тот же файл, поэтому разговор
    /// остаётся одной записью.
    private func resumeIfNeeded() {
        guard isRecording, !interrupted || resumeAfterInterruption else { return }
        guard resumeAttempts < 6 else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.isRecording else { return }
            guard let rec = self.recorder else { return }

            self.activateSession()
            if rec.record() {
                self.interrupted = false
                self.resumeAttempts = 0
                self.startTicking()
            } else {
                self.resumeAttempts += 1
                self.resumeIfNeeded()
            }
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
