import Foundation
import AVFoundation
import Combine
import UIKit
import CallKit

/// Пишет звук микрофона непрерывно в ОДИН файл.
///
/// Раньше запись шла «кусками»: при каждом возврате звука открывался новый
/// файл, а незавершённый система сбрасывала. Из-за этого звук был рваным, а
/// вместо одной записи получалось несколько файлов.
///
/// Здесь файл открывается один раз на всю запись и больше никогда не
/// переоткрывается. Аудиодвижок можно останавливать и запускать сколько угодно
/// раз (звонок, смена маршрута) — новые звуки просто дописываются в тот же файл.
final class AudioWriter {

    let format: AVAudioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: 44_100,
                                              channels: 1,
                                              interleaved: false)!

    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var frames: AVAudioFramePosition = 0
    private var level: Float = 0
    private var lastWrite: Date?

    /// Сколько кадров реально записано (это и есть длительность по звуку).
    var framesWritten: AVAudioFramePosition {
        lock.lock(); defer { lock.unlock() }
        return frames
    }

    /// Текущая громкость 0...1 для индикатора.
    var currentLevel: Float {
        lock.lock(); defer { lock.unlock() }
        return level
    }

    /// Когда последний раз был записан звук.
    var lastWriteAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return lastWrite
    }

    var recordedSeconds: TimeInterval {
        Double(framesWritten) / format.sampleRate
    }

    /// Открывает рабочий файл. Вызывается один раз на всю запись.
    func open(url: URL) {
        lock.lock(); defer { lock.unlock() }
        frames = 0
        level = 0
        lastWrite = nil
        converter = nil
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        file = try? AVAudioFile(forWriting: url,
                                settings: settings,
                                commonFormat: .pcmFormatFloat32,
                                interleaved: false)
    }

    /// Подбирает преобразование под текущий формат микрофона.
    func configure(inputFormat: AVAudioFormat) {
        lock.lock(); defer { lock.unlock() }
        if converter?.inputFormat.isEqual(inputFormat) != true {
            converter = AVAudioConverter(from: inputFormat, to: format)
        }
    }

    /// Принимает звук от микрофона и дописывает его в файл.
    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let file, let converter else { return }

        if let channels = buffer.floatChannelData, buffer.frameLength > 0 {
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n {
                let v = channels[0][i]
                sum += v * v
            }
            level = min(1, (sum / Float(n)).squareRoot() * 6)
        }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 2048
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return }
        guard (try? file.write(from: out)) != nil else { return }
        frames += AVAudioFramePosition(out.frameLength)
        lastWrite = Date()
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        converter = nil
        file = nil
    }
}

/// Запись разговора через микрофон. Рассчитана на громкую связь.
///
/// Запись НЕ останавливается сама: пока пользователь не нажал «Стоп», приложение
/// держит её включённой и возвращает звук при первой возможности — например,
/// сразу после окончания телефонного разговора. Всё пишется в один файл.
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

    /// Сколько файлов получится. Всегда один — оставлено для экрана записи.
    @Published private(set) var partsCount = 0

    /// Автозапись: старт, когда звук дольше порога держится громким.
    @Published var autoRecord = false
    @Published var autoLevelThreshold: Float = 0.25

    /// Настройка из раздела «Настройки».
    @Published var resumeAfterInterruption = true

    private let engine = AVAudioEngine()
    private let writer = AudioWriter()

    private var timer: Timer?
    private var autoTimer: Timer?
    private var watchdog: Timer?
    private var loudSince: Date?
    private var observers: [NSObjectProtocol] = []
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private let callObserver = CXCallObserver()

    private var tapInstalled = false
    private var installedFormat: AVAudioFormat?
    private var fileURL: URL?
    private var startedAt: Date?

    /// Тихий проигрыватель внутри движка. Пока он «играет», звуковая сессия
    /// остаётся активной и в фоне — поэтому запись не засыпает, когда приложение
    /// свёрнуто или экран заблокирован.
    private let silence = AVAudioPlayerNode()
    private var silenceReady = false

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
                    self.suspendForInterruption()
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

        // Звуковая подсистема перезапустилась — поднимаем движок заново.
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
            self.elapsed = 0
            self.peak = 0
            self.micBusy = false
            self.partsCount = 1
            self.startedAt = Date()
            self.beginBgTask()
            self.openFile()
            self.startEngine()
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
            self.armMeteringDetector()
        }
    }

    func disarmAutoRecord() {
        autoTimer?.invalidate(); autoTimer = nil
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        silence.stop()
        if engine.isRunning { engine.stop() }
    }

    /// Единственный способ закончить запись — решение пользователя.
    func stop() {
        isRecording = false
        micBusy = false
        partsCount = 0

        timer?.invalidate(); timer = nil
        watchdog?.invalidate(); watchdog = nil
        autoTimer?.invalidate(); autoTimer = nil

        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        installedFormat = nil
        silence.stop()
        if engine.isRunning { engine.stop() }

        let frames = writer.framesWritten
        writer.close()

        let url = fileURL
        let started = startedAt
        fileURL = nil
        startedAt = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        endBgTask()

        elapsed = 0
        level = 0
        peak = 0

        deliver(url: url, frames: frames, startedAt: started)
    }

    // MARK: - Файл записи

    /// Открывает один рабочий файл на всю запись. Больше он не переоткрывается.
    private func openFile() {
        guard let url = Self.newWorkingURL() else { return }
        fileURL = url
        writer.open(url: url)
    }

    // MARK: - Движок записи

    /// Настраивает и включает звуковую сессию так, чтобы запись шла и в фоне.
    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try? session.setActive(true)
        }
    }

    private func startEngine() {
        guard isRecording else { return }
        activateSession()
        if inCall {
            micBusy = true
            return
        }

        let input = engine.inputNode
        var fmt = input.inputFormat(forBus: 0)
        if fmt.sampleRate == 0 || fmt.channelCount == 0 {
            fmt = input.outputFormat(forBus: 0)
        }
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { return }

        if !tapInstalled || installedFormat?.isEqual(fmt) != true {
            if tapInstalled { input.removeTap(onBus: 0); tapInstalled = false }
            writer.configure(inputFormat: fmt)
            let writer = self.writer
            input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buffer, _ in
                writer.write(buffer)
            }
            tapInstalled = true
            installedFormat = fmt
        }

        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            silenceReady = true
            startSilentLoop()
            micBusy = false
        } catch {
            micBusy = true
        }
    }

    /// Запускает неслышимый поток звука внутри движка. Без него iOS может
    /// приостановить запись, когда приложение уходит в фон.
    private func startSilentLoop() {
        let mixer = engine.mainMixerNode
        if !silenceReady || silence.engine == nil {
            engine.attach(silence)
            engine.connect(silence, to: mixer, format: nil)
        }
        mixer.outputVolume = 0
        var fmt = silence.outputFormat(forBus: 0)
        if fmt.sampleRate == 0 || fmt.channelCount == 0 {
            fmt = mixer.outputFormat(forBus: 0)
        }
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { return }
        if !silence.isPlaying {
            let frames = AVAudioFrameCount(fmt.sampleRate)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
            buffer.frameLength = frames
            if let ch = buffer.floatChannelData {
                for c in 0..<Int(fmt.channelCount) {
                    memset(ch[c], 0, Int(frames) * MemoryLayout<Float>.size)
                }
            }
            silence.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            silence.play()
        }
    }

    /// Аккуратно останавливает движок, но НЕ закрывает файл: после звонка запись
    /// продолжится в тот же самый файл.
    private func suspendForInterruption() {
        guard isRecording else { return }
        micBusy = true
        if engine.isRunning { engine.stop() }
        startWatchdog()
    }

    // MARK: - Индикаторы и сторож

    private func startTicking() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.recordTick() }
        }
    }

    private func recordTick() {
        guard isRecording else { return }
        elapsed = writer.recordedSeconds
        let lvl = writer.currentLevel
        level = lvl
        peak = max(peak, lvl)
    }

    private func autoTick() {
        // Пока идёт разговор, микрофон занят — просто ждём.
        if inCall { return }
        let lvl = writer.currentLevel
        if lvl >= autoLevelThreshold {
            if loudSince == nil { loudSince = Date() }
            if let s = loudSince, Date().timeIntervalSince(s) >= 1.2 {
                autoTimer?.invalidate(); autoTimer = nil
                if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
                if engine.isRunning { engine.stop() }
                start()
            }
        } else {
            loudSince = nil
        }
    }

    /// Детектор громкости для автозаписи: отдельный движок, файл не пишется.
    private func armMeteringDetector() {
        let input = engine.inputNode
        var fmt = input.inputFormat(forBus: 0)
        if fmt.sampleRate == 0 || fmt.channelCount == 0 {
            fmt = input.outputFormat(forBus: 0)
        }
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { return }
        if !tapInstalled || installedFormat?.isEqual(fmt) != true {
            if tapInstalled { input.removeTap(onBus: 0); tapInstalled = false }
            let writer = self.writer
            input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buffer, _ in
                let lvl = AudioWriter.measureLevel(buffer)
                writer.setLevel(lvl)
            }
            tapInstalled = true
            installedFormat = fmt
        }
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        } catch { }
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
        if !engine.isRunning {
            startEngine()
            return
        }
        // Движок работает, но звук давно не приходил — значит, его надо поднять заново.
        if let last = writer.lastWriteAt {
            if Date().timeIntervalSince(last) > 2.5 { startEngine(); return }
        } else if let started = startedAt, Date().timeIntervalSince(started) > 2.5 {
            startEngine()
        }
        if micBusy { micBusy = false }
    }

    /// Немедленная попытка вернуть запись (после прерывания, смены маршрута).
    private func tryResumeNow() {
        guard isRecording else { return }
        if inCall { micBusy = true; startWatchdog(); return }
        if engine.isRunning { engine.stop() }
        startEngine()
    }

    /// Имя рабочего файла записи. Если такой уже есть, добавляется уточнение.
    nonisolated static func newWorkingURL() -> URL? {
        let stamp = fileStamp.string(from: Date())
        var url = RecordingsStore.audioDirectory.appendingPathComponent("Запись " + stamp + ".caf")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = RecordingsStore.audioDirectory.appendingPathComponent("Запись " + stamp + " (" + String(n) + ").caf")
            n += 1
        }
        return url
    }

    // MARK: - Выдача готовой записи

    /// Превращает рабочий файл в готовую запись m4a и отдаёт её в список.
    private func deliver(url: URL?, frames: AVAudioFramePosition, startedAt: Date?) {
        guard let url, frames > 0 else {
            if let url { try? FileManager.default.removeItem(at: url) }
            return
        }
        let duration = Double(frames) / writer.format.sampleRate
        let created = startedAt ?? Date()
        Task { @MainActor in
            if let m4a = await Self.convertToM4A(source: url),
               let rec = Recording(url: m4a, createdAt: created, duration: duration) {
                self.onFinish?(rec)
            } else if let rec = Recording(url: url, createdAt: created, duration: duration) {
                self.onFinish?(rec)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Переводит рабочий файл в m4a. Если не получилось — вернём nil и останется
    /// рабочий файл (он тоже проигрывается).
    nonisolated static func convertToM4A(source: URL) async -> URL? {
        let asset = AVURLAsset(url: source)
        guard let exporter = AVAssetExportSession(asset: asset,
                                                  presetName: AVAssetExportPresetAppleM4A) else { return nil }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-" + UUID().uuidString + ".m4a")
        exporter.outputURL = tmp
        exporter.outputFileType = .m4a
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously { cont.resume() }
        }
        guard exporter.status == .completed else {
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
        let target = RecordingsStore.audioDirectory
            .appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".m4a")
        try? FileManager.default.removeItem(at: target)
        guard (try? FileManager.default.moveItem(at: tmp, to: target)) != nil else { return nil }
        try? FileManager.default.removeItem(at: source)
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

    nonisolated static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        f.locale = Locale(identifier: "ru_RU")
        return f
    }()
}

extension AudioWriter {
    /// Громкость буфера 0...1 (для автозаписи).
    static func measureLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n {
            let v = channels[0][i]
            sum += v * v
        }
        return min(1, (sum / Float(n)).squareRoot() * 6)
    }

    func setLevel(_ value: Float) {
        lock.lock(); defer { lock.unlock() }
        level = value
    }
}

// MARK: - Реакция на звонок

extension Recorder: CXCallObserverDelegate {
    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        let busy = callObserver.calls.contains { !$0.hasEnded }
        Task { @MainActor in
            guard self.isRecording else { return }
            if busy {
                self.suspendForInterruption()
            } else {
                self.tryResumeNow()
            }
        }
    }
}