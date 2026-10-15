import SwiftUI

struct RecorderView: View {
    @ObservedObject var recorder: Recorder
    @State private var showHint = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Spacer(minLength: 8)

                Text(statusTitle)
                    .font(.title2.bold())
                    .foregroundStyle(recorder.isRecording ? .red : .secondary)

                timer

                levelMeter
                    .frame(height: 92)
                    .padding(.horizontal)

                recordButton

                Text(statusHint)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                if recorder.isRecording {
                    Label("Запись идёт постоянно — и в фоне, и во время звонка. Останавливает только кнопка «Стоп».",
                          systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                if recorder.autoRecord {
                    Label("Автозапись включена: запись начнётся при громкой речи",
                          systemImage: "waveform.badge.mic")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .navigationTitle("Диктофон разговоров")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        recorder.autoRecord.toggle()
                        recorder.autoRecord ? recorder.armAutoRecord() : recorder.disarmAutoRecord()
                    } label: {
                        Image(systemName: recorder.autoRecord ? "bolt.circle.fill" : "bolt.slash.circle")
                    }
                    .accessibilityLabel("Автозапись")
                }
            }
        }
    }

    private var statusTitle: String {
        if recorder.micBusy { return "Запись идёт — микрофон занят звонком" }
        return recorder.isRecording ? "Идёт запись" : "Готово к записи"
    }

    private var statusHint: String {
        if recorder.micBusy {
            return "Сейчас микрофон занят телефонным разговором. Запись никуда не делась и включится сама, как только звонок освободит микрофон. Остановит её только кнопка «Стоп»."
        }
        if recorder.isRecording {
            return "Говорите. Для записи обоих голосов включите громкую связь. Приложение можно свернуть — запись не остановится."
        }
        return "Нажмите «Начать запись» — и всё, что происходит вокруг, будет записано. Приложение можно свернуть, экран заблокировать, позвонить. Запись остановится только по кнопке «Стоп»."
    }

    private var timer: some View {
        Text(Recording.hms(recorder.elapsed))
            .font(.system(size: 64, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(recorder.isRecording ? .primary : .secondary)
    }

    private var levelMeter: some View {
        GeometryReader { geo in
            let bars = 36
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<bars, id: \.self) { i in
                    let t = Float(i) / Float(bars - 1)
                    let active = recorder.level >= t
                    Capsule()
                        .fill(active ? color(for: t) : Color.white.opacity(0.12))
                        .frame(height: max(6, geo.size.height * CGFloat(0.25 + 0.75 * Double(min(recorder.level, 1))) ))
                        .opacity(active ? 1 : 0.6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func color(for t: Float) -> Color {
        switch t {
        case ..<0.6: return .green
        case ..<0.85: return .yellow
        default: return .red
        }
    }

    private var recordButton: some View {
        Button {
            recorder.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(recorder.isRecording ? Color.red.opacity(0.22) : Color.accentColor.opacity(0.22))
                    .frame(width: 132, height: 132)
                Circle()
                    .fill(recorder.isRecording ? Color.red : Color.accentColor)
                    .frame(width: 104, height: 104)
                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recorder.isRecording ? "Остановить запись" : "Начать запись")
    }
}
