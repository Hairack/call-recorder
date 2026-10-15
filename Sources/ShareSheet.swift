import SwiftUI
import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct TranscriptView: View {
    let recording: Recording
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Расшифровка")
                    .font(.headline)
                Text("Вставьте или исправьте текст разговора. Он сохранится рядом с записью и будет искать по нему.")
                    .font(.footnote).foregroundStyle(.secondary)

                TextEditor(text: $text)
                    .frame(minHeight: 220)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))

                Spacer()
            }
            .padding()
            .navigationTitle("Текст записи")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Сохранить") {
                        TranscriptStore.shared.write(text, for: recording.id)
                        dismiss()
                    }
                }
            }
            .onAppear { text = TranscriptStore.shared.text(for: recording.id) ?? "" }
        }
    }
}
