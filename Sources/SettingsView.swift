import SwiftUI
import AVFoundation

struct SettingsView: View {
    @ObservedObject var recorder: Recorder
    @State private var micStatus = "неизвестно"
    @State private var storage = "-"
    @State private var bgStatus = "—"
    @State private var autoRecord: Bool = UserDefaults.standard.bool(forKey: "autoRecord")
    @State private var threshold: Double = UserDefaults.standard.object(forKey: "threshold") as? Double ?? 0.25
    @State private var resume: Bool = UserDefaults.standard.object(forKey: "resume") as? Bool ?? true

    var body: some View {
        NavigationStack {
            Form {
                Section("Микрофон") {
                    HStack {
                        Text("Доступ")
                        Spacer()
                        Text(micStatus).foregroundStyle(.secondary)
                    }
                    Button("Запросить доступ к микрофону") {
                        Task { _ = await Recorder.ensurePermission(); refresh() }
                    }
                }

                Section("Фоновая запись") {
                    HStack {
                        Text("Режим «audio»")
                        Spacer()
                        Text(bgStatus).foregroundStyle(.secondary)
                    }
                    Toggle("Продолжать запись после звонка", isOn: $resume)
                        .onChange(of: resume) { _, v in
                            UserDefaults.standard.set(v, forKey: "resume")
                            recorder.resumeAfterInterruption = v
                        }
                    Text("Запись идёт постоянно: и когда приложение свёрнуто, и когда экран заблокирован, и во время звонка. Во время разговора система на время забирает микрофон — приложение не выключает запись, а ждёт и включает её снова само, когда микрофон освободится. Останавливает запись только кнопка «Стоп».")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Автозапись") {
                    Toggle("Включать запись при громкой речи", isOn: $autoRecord)
                        .onChange(of: autoRecord) { _, v in
                            UserDefaults.standard.set(v, forKey: "autoRecord")
                            recorder.autoRecord = v
                            v ? recorder.armAutoRecord() : recorder.disarmAutoRecord()
                        }
                    VStack(alignment: .leading) {
                        Text("Порог громкости: \(Int(threshold * 100))%")
                        Slider(value: $threshold, in: 0.1...0.8)
                            .onChange(of: threshold) { _, v in
                                UserDefaults.standard.set(v, forKey: "threshold")
                                recorder.autoLevelThreshold = Float(v)
                            }
                    }
                    Text("Автозапись пригодится, если телефон лежит рядом. Она тоже работает в фоне.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Хранилище") {
                    HStack {
                        Text("Занято")
                        Spacer()
                        Text(storage).foregroundStyle(.secondary)
                    }
                    Text("Файлы лежат в папке приложения «Записи», формат m4a. Их видно в приложении «Файлы» (медиатека приложения).")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("О приложении") {
                    LabeledContent("Название", value: "Диктофон разговоров")
                    LabeledContent("Версия", value: "1.3")
                    LabeledContent("Язык", value: "Русский")
                }
            }
            .navigationTitle("Настройки")
            .onAppear {
                recorder.autoRecord = autoRecord
                recorder.autoLevelThreshold = Float(threshold)
                recorder.resumeAfterInterruption = resume
                if autoRecord { recorder.armAutoRecord() }
                refresh()
            }
        }
    }

    private func refresh() {
        let s = AVAudioSession.sharedInstance()
        switch s.recordPermission {
        case .granted: micStatus = "разрешён"
        case .denied: micStatus = "запрещён"
        case .undetermined: micStatus = "не запрошен"
        @unknown default: micStatus = "неизвестно"
        }

        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        bgStatus = modes.contains("audio") ? "включён" : "выключен"

        let dir = RecordingsStore.audioDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let total = files.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +)
        storage = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }
}
