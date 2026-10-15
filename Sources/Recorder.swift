import Foundation
import AVFoundation
import Combine
import UIKit
import CallKit

/// Запись через микрофон. Рассчитана на разговор по громкой связи.
///
/// Запись НЕ останавливается сама: пока пользователь не нажал «Стоп», приложение
/// держит её включённой и возвращает звук при первой возможности — например,
/// сразу после окончания телефонного разговора.
///
/// Важно: каждый раз, когда звук приходится начинать заново, пишется НОВЫЙ
/// файл-кусок, а старый закрывается. Переоткрывать один и тот же файл нельзя —
/// именно из-за этого звук получался рваным. При остановке куски автоматически
/// склеиваются в одну запись.
@MainActor
final class Recorder: NSObject, ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0          // 0...1, для индикатора
    @Published private(set) var peak: Float = 0

    /// Микрофон на время занят системой (звонок, будильник). Запись при этом
    /// НЕ выключается: приложение само продолжит её, как только микрофон
    /// освободится. Останавливает запись только пользователь.
    @Published private(set) var micBusy = false

    /// Сколько кусков уже записано. Обычно один.
    @Published private(set) var partsCount = 0

    /// Автозапись: старт, когда звук дольше порога держится громким.
    @Published var autoRecord = false
    @Published var autoLevelThreshold: Float = 0.25

    /// Настройка из раздела «Настройки». Сейчас запись всегда продолжается,
    /// поэтому значение только хранится.
    @Published var resumeAfterInterruption = true

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var autoTimer: Timer?
    /// Сторож: пока запись включена, проверяет, что звук пишется, и возвращает
    /// запись при первой возможности.
    private var watchdog: Timer?
    /// Тихая «подложка»: не даёт системе усыпить приложение, пока идёт запись
    /// (в том числе пока микрофон занят звонком).
    private var keepAlive: AVAudioPlayer?
    private var loudSince: Date?
    private var observers: [NSObjectProtocol] = []
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    /// Системный наблюдатель за звонками.
    private let callObserver = CXCallObserver()

    /// Куски одной записи: файл, начало и конец (nil — пишется прямо сейчас).
    private var parts: [(url: URL, start: Date, end: Date?)] = []

    var onFinish: ((Recording) -> Void)?

    override init() {
        super.init()
        let center = NotificationCenter.default

        // Система забрала или вернула микрофон.
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
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

        // Звуковая подсистема перезапустилась — кусок закрываем и начинаем новый.
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tryResumeNow() }
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
            guard !self.isRecording else { return }
            self.isRecording = true
            self.parts = []
            self.partsCount = 0
            self.elapsed = 0
            self.peak = 0
            self.micBusy = false
            self.beginBgTask()
            self.startKeepAlive()
            self.openPart()
            self.startTicking()
            self.startWatchdog()
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
        isRecording = false
        micBusy = false

        timer?.invalidate(); timer = nil
        watchdog?.invalidate(); watchdog = nil
        autoTimer?.invalidate(); autoTimer = nil

        closePart()
        stopKeepAlive()

        let finished = parts
        parts = []
        partsCount = 0
        deliver(finished)

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        endBgTask()

        elapsed = 0
        level = 0
        peak = 0
    }

    // MARK: - Куски записи

    /// Начинает новый кусок: всегда новый файл, никогда не старый.
    private func openPart() {
        closePart()
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
        r.delegate = self
        guard r.record() else { return }

        recorder = r
        parts.append((url: url, start: Date(), end: nil))
        partsCount = parts.count
        micBusy = false
    }

    /// Закрывает текущий кусок, чтобы файл корректно дописался на диск.
    private func closePart() {
        if let rec = recorder {
            rec.updateMeters()
            rec.stop()
        }
        recorder = nil
        if let index = parts.indices.last, parts[index].end == nil {
            parts[index].end = Date()
        }
    }

    /// Время, которое реально записано (без вычета пауз, когда микрофон был занят).
    private func recordedTime(now: Date) -> TimeInterval {
        var total: TimeInterval = 0
        for part in parts {
            total += (part.end ?? now).timeIntervalSince(part.start)
        }
        return total
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

    private func startTicking() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.recordTick() }
        }
    }

    private func recordTick() {
        guard isRecording else { return }
        elapsed = recordedTime(now: Date())
        guard let rec = recorder, rec.isRecording else { return }
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
                start()
            }
        } else {
            loudSince = nil
        }
    }

    // MARK: - Возврат записи

    private func markMicBusy() {
        guard isRecording else { return }
        micBusy = true
        // Текущий кусок аккуратно закрываем: дальше пойдёт новый файл.
        closePart()
        startWatchdog()
    }

    /// Сторож: пока запись включена, проверяет, что звук действительно пишется,
    /// и возвращает запись при первой возможности.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.watchdogTick() }
        }
    }

    private func watchdogTick() {
        guard isRecording else { watchdog?.invalidate(); watchdog = nil; return }
        if inCall { micBusy = true; return }
        if let rec = recorder, rec.isRecording {
            if micBusy { micBusy = false }
            return
        }
        openPart()
    }

    /// Немедленная попытка вернуть запись (после прерывания, смены маршрута).
    private func tryResumeNow() {
        guard isRecording else { return }
        if inCall { micBusy = true; startWatchdog(); return }
        if let rec = recorder, rec.isRecording { micBusy = false; return }
        openPart()
    }

    /// Имя нового файла записи. Если такой уже есть, добавляется уточнение.
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

    /// Выдаёт готовые записи в список. Куски склеиваются в один файл, чтобы
    /// разговор остался одной записью.
    private func deliver(_ finished: [(url: URL, start: Date, end: Date?)]) {
        guard let first = finished.first else { return }

        if finished.count == 1 {
            let duration = (first.end ?? Date()).timeIntervalSince(first.start)
            if duration >= 1, let rec = Recording(url: first.url, createdAt: first.start, duration: duration) {
                onFinish?(rec)
            } else {
                try? FileManager.default.removeItem(at: first.url)
            }
            return
        }

        let total = recordedTime(now: Date())
        let urls = finished.map { $0.url }
        Task { @MainActor in
            if let merged = await Self.merge(parts: urls),
               let rec = Recording(url: merged, createdAt: first.start, duration: total) {
                for url in urls where url != merged {
                    try? FileManager.default.removeItem(at: url)
                }
                self.onFinish?(rec)
            } else {
                for part in finished {
                    let duration = (part.end ?? Date()).timeIntervalSince(part.start)
                    if duration >= 1, let rec = Recording(url: part.url, createdAt: part.start, duration: duration) {
                        self.onFinish?(rec)
                    } else {
                        try? FileManager.default.removeItem(at: part.url)
                    }
                }
            }
        }
    }

    /// Склеивает куски в один m4a. Итоговый файл получает имя первого куска.
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

    /// Тихая «подложка» на время записи. Без неё система может усыпить
    /// приложение, пока микрофон занят звонком, и запись не вернётся сама.
    private func startKeepAlive() {
        guard keepAlive == nil else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            Self.writeSilentWav(to: url)
        }
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.numberOfLoops = -1
        player.volume = 0
        player.prepareToPlay()
        player.play()
        keepAlive = player
    }

    private func stopKeepAlive() {
        keepAlive?.stop()
        keepAlive = nil
    }

    /// Создаёт короткий файл тишины.
    nonisolated static func writeSilentWav(to url: URL) {
        let sampleRate: UInt32 = 8000
        let seconds: UInt32 = 1
        let dataBytes = sampleRate * seconds * 2
        var data = Data()
        func append(_ value: UInt32) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(36 + dataBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(16)
        append16(1)
        append16(1)
        append(sampleRate)
        append(sampleRate * 2)
        append16(2)
        append16(16)
        data.append(contentsOf: Array("data".utf8))
        append(dataBytes)
        data.append(Data(count: Int(dataBytes)))
        try? data.write(to: url)
    }

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

// MARK: - Реакция на звонок и на неожиданную остановку записи

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

extension Recorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            guard self.isRecording else { return }
            // Кусок закончился сам — продолжаем новым файлом.
            self.tryResumeNow()
        }
    }
}
