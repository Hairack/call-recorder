import Foundation
import AVFoundation
import Combine
import UIKit
import CallKit

/// Запись через микрофон. Рассчитана на разговор по громкой связи.
///
/// Запись НИКОГДА не останавливается сама: пока пользователь не нажал «Стоп»,
/// она остаётся включённой. Если систему прерывает звонок или будильник,
/// приложение не выключает запись, а ждёт и возобновляет её сразу, как только
/// микрофон снова доступен, продолжая тот же файл.
@MainActor
final class Recorder: NSObject, ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0          // 0...1, для индикатора
    @Published private(set) var peak: Float = 0

    /// Микрофон на время занят системой (звонок, будильник). Запись при этом
    /// НЕ выключается: файл остаётся открытым, и приложение само вернёт запись,
    /// как только микрофон освободится. Останавливает запись только пользователь.
    @Published private(set) var micBusy = false

    /// Автозапись: старт, когда звук дольше порога держится громким.
    @Published var autoRecord = false
    @Published var autoLevelThreshold: Float = 0.25

    /// Настройка из раздела «Настройки»: продолжать запись после звонка.
    /// Сейчас запись всегда продолжается, поэтому значение только хранится.
    @Published var resumeAfterInterruption = true

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var autoTimer: Timer?
    /// Сторож: пока запись включена, постоянно проверяет, что звук пишется,
    /// и возвращает его при первой возможности.
    private var watchdog: Timer?
    /// Файлы одной записи. Обычно он один. Если звуковая подсистема телефона
    /// перезапустится, приложение продолжит писать в НОВЫЙ файл, а не сотрёт уже
    /// записанное: части идут подряд в списке записей.
    private var parts: [(url: URL, startedAt: Date)] = []
    private var currentURL: URL? { parts.last?.url }
    private var startedAt: Date? { parts.first?.startedAt }
    private var loudSince: Date?
    private var observers: [NSObjectProtocol] = []
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    /// Системный наблюдатель за звонками: пока идёт разговор, микрофон занят,
    /// и пытаться что-то записать бессмысленно — ждём конца звонка.
    private let callObserver = CXCallObserver()

    var onFinish: ((Recording) -> Void)?

    override init() {
        super.init()
        let center = NotificationCenter.default

        // Система забрала или вернула микрофон.
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
            // Этот флаг означает «сессия уснула сама», а не настоящий звонок:
            // тогда достаточно просто включить её обратно.
            let wasSuspended = (note.userInfo?["AVAudioSessionInterruptionWasSuspendedKey"] as? Bool) ?? false
            Task { @MainActor in
                guard let self else { return }
                if type == .began, !wasSuspended {
                    self.markMicBusy()
                } else {
                    self.tryResumeNow()
                }
            }
        })

        // Смена маршрута (наушники, гарнитура) тоже может остановить запись.
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tryResumeNow() }
        })

        // Звуковая подсистема перезапустилась — запись надо поднять заново.
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildAfterReset() }
        })

        callObserver.setDelegate(self, queue: .main)
    }

    /// Идёт ли прямо сейчас телефонный разговор.
    private var inCall: Bool { callObserver.calls.contains { !$0.hasEnded } }

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

    /// Вызывается, когда приложение снова на экране.
    func appBecameActive() {
        guard isRecording else { return }
        startTicking()
        tryResumeNow()
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

    /// Единственный способ закончить запись — решение пользователя.
    func stop() {
        // Сначала закрываем файл: так весь звук, включая последние секунды,
        // гарантированно дописывается на диск.
        isRecording = false
        micBusy = false
        timer?.invalidate(); timer = nil
        watchdog?.invalidate(); watchdog = nil
        autoTimer?.invalidate(); autoTimer = nil
        if let rec = recorder {
            rec.updateMeters()
            rec.stop()
        }
        recorder = nil

        let end = Date()
        let finished = parts
        parts = []
        deliver(finished, end: end)

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        endBgTask()

        elapsed = 0
        level = 0
        peak = 0
    }

    // MARK: - Внутренняя часть

    /// Настраивает и включает звуковую сессию так, чтобы запись шла и в фоне.
    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try session.setActive(true)
        } catch {
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
        beginBgTask()

        let url = Self.newFileURL()
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
        parts = [(url, Date())]
        isRecording = true
        micBusy = false
        elapsed = 0
        peak = 0
        startTicking()
        startWatchdog()
    }

    private func startTicking() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.recordTick() }
        }
    }

    private func recordTick() {
        // Время считаем по часам, а не по числу «тиков»: в фоне таймер
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

    // MARK: - Возврат записи

    private func markMicBusy() {
        guard isRecording else { return }
        micBusy = true
        // Сессию НЕ выключаем: так система вернёт звук быстрее.
        startWatchdog()
    }

    /// Сторож: пока запись включена, проверяет, что звук действительно пишется,
    /// и возвращает запись при первой возможности. Пока идёт телефонный разговор,
    /// ничего не трогаем — ждём, когда звонок отпустит микрофон.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.watchdogTick() }
        }
    }

    private func watchdogTick() {
        guard isRecording else { watchdog?.invalidate(); watchdog = nil; return }
        if inCall { micBusy = true; return }
        guard let rec = recorder else { return }
        if rec.isRecording {
            if micBusy { micBusy = false }
            return
        }
        activateSession()
        if rec.record() {
            micBusy = false
            startTicking()
        }
    }

    /// Немедленная попытка вернуть запись (после прерывания, смены маршрута).
    private func tryResumeNow() {
        guard isRecording else { return }
        if inCall { micBusy = true; startWatchdog(); return }
        guard let rec = recorder else { return }
        activateSession()
        if rec.record() {
            micBusy = false
            startTicking()
        } else {
            startWatchdog()
        }
    }

    /// Звуковая подсистема перезапустилась: поднимаем запись с нуля, но в тот же
    /// файл, чтобы разговор остался одной записью.
    private func rebuildAfterReset() {
        guard isRecording else { return }
        // Закрываем текущий файл и продолжаем в новый, чтобы не потерять уже
        // записанный звук.
        recorder?.stop()
        recorder = nil
        activateSession()
        let url = Self.newFileURL()
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
        parts.append((url, Date()))
        micBusy = false
        startTicking()
        startWatchdog()
    }

    /// Имя нового файла записи. Если файл с таким именем уже есть (например,
    /// части пишутся в одну и ту же секунду), добавляется уточнение.
    nonisolated static func newFileURL() -> URL {
        let stamp = fileStamp.string(from: Date())
        var url = RecordingsStore.audioDirectory.appendingPathComponent("Запись " + stamp + ".m4a")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = RecordingsStore.audioDirectory.appendingPathComponent("Запись " + stamp + " (" + String(n) + ").m4a")
            n += 1
        }
        return url
    }

    /// Выдаёт готовые записи в список. Если звук писался кусками (например,
    /// из-за перезапуска звуковой подсистемы), куски склеиваются в один файл,
    /// чтобы разговор остался одной записью.
    private func deliver(_ finished: [(url: URL, startedAt: Date)], end: Date) {
        guard let first = finished.first else { return }

        if finished.count == 1 {
            let duration = end.timeIntervalSince(first.startedAt)
            if duration >= 1, let rec = Recording(url: first.url, createdAt: first.startedAt, duration: duration) {
                onFinish?(rec)
            } else {
                try? FileManager.default.removeItem(at: first.url)
            }
            return
        }

        let total = end.timeIntervalSince(first.startedAt)
        let urls = finished.map { $0.url }
        Task { @MainActor in
            if let merged = await Self.merge(parts: urls),
               let rec = Recording(url: merged, createdAt: first.startedAt, duration: total) {
                for url in urls where url != merged {
                    try? FileManager.default.removeItem(at: url)
                }
                self.onFinish?(rec)
            } else {
                // Склеить не вышло — показываем куски отдельными записями.
                var index = 0
                while index < finished.count {
                    let part = finished[index]
                    let partEnd = index + 1 < finished.count ? finished[index + 1].startedAt : end
                    let duration = partEnd.timeIntervalSince(part.startedAt)
                    if duration >= 1, let rec = Recording(url: part.url, createdAt: part.startedAt, duration: duration) {
                        self.onFinish?(rec)
                    } else {
                        try? FileManager.default.removeItem(at: part.url)
                    }
                    index += 1
                }
            }
        }
    }

    /// Склеивает части записи в один m4a. Итоговый файл получает имя первой части.
    nonisolated static func merge(parts: [URL]) async -> URL? {
        guard parts.count > 1 else { return parts.first }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        var cursor = CMTime.zero
        for url in parts {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration),
                  let source = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
            let range = CMTimeRange(start: .zero, duration: duration)
            guard (try? track.insertTimeRange(range, of: source, at: cursor)) != nil else { return nil }
            cursor = CMTimeAdd(cursor, duration)
        }
        guard let exporter = AVAssetExportSession(asset: composition,
                                                  presetName: AVAssetExportPresetAppleM4A) else { return nil }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("merge-" + UUID().uuidString + ".m4a")
        exporter.outputURL = tmp
        exporter.outputFileType = .m4a
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously { cont.resume() }
        }
        guard exporter.status == .completed else {
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
        let target = parts[0]
        try? FileManager.default.removeItem(at: target)
        do { try FileManager.default.moveItem(at: tmp, to: target) } catch { return nil }
        return target
    }

    // MARK: - Удержание приложения в фоне

    private func beginBgTask() {
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "CallRecorder") { [weak self] in
            Task { @MainActor in self?.endBgTask() }
        }
    }

    private func endBgTask() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
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

// MARK: - Реакция на начало и конец звонка

extension Recorder: CXCallObserverDelegate {
    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        let busy = callObserver.calls.contains { !$0.hasEnded }
        Task { @MainActor in
            guard self.isRecording else { return }
            if busy {
                self.markMicBusy()
            } else {
                self.tryResumeNow()
            }
        }
    }
}
