import SwiftUI
import AVFoundation

struct RecordingsListView: View {
    @EnvironmentObject private var store: RecordingsStore
    @State private var renameTarget: Recording?
    @State private var renameText = ""
    @State private var player: Recording?

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    ContentUnavailableView("Пока нет записей",
                                           systemImage: "mic.slash",
                                           description: Text("На вкладке «Запись» нажмите кнопку, чтобы создать первую запись."))
                } else {
                    List {
                        ForEach(store.filtered) { rec in
                            Button { player = rec } label: {
                                row(rec)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    store.delete(rec)
                                } label: { Label("Удалить", systemImage: "trash") }

                                Button {
                                    renameTarget = rec
                                    renameText = rec.title
                                } label: { Label("Переименовать", systemImage: "pencil") }
                                .tint(.orange)
                            }
                        }
                    }
                    .searchable(text: $store.query, prompt: "Поиск по записям")
                }
            }
            .navigationTitle("Мои записи")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("\(store.items.count) шт.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .sheet(item: $player) { rec in
                PlayerView(recording: rec, all: store.filtered)
            }
            .alert("Переименовать запись", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("Название", text: $renameText)
                Button("Отмена", role: .cancel) { renameTarget = nil }
                Button("Сохранить") {
                    if let t = renameTarget { store.rename(t, to: renameText) }
                    renameTarget = nil
                }
            }
        }
    }

    private func row(_ rec: Recording) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.18))
                    .frame(width: 46, height: 46)
                Image(systemName: "waveform").foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(rec.title).font(.body.weight(.medium)).lineLimit(1)
                Text("\(RecordingsStore.stamp.string(from: rec.createdAt)) · \(rec.durationText) · \(rec.sizeText)")
                    .font(.caption).foregroundStyle(.secondary)
                if let t = rec.transcript, !t.isEmpty {
                    Text(t).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
