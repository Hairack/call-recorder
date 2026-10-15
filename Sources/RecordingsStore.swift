import Foundation
import AVFoundation
import Combine

struct Recording: Identifiable, Hashable {
    let id: String
    let url: URL
    let createdAt: Date
    let duration: TimeInterval
    var title: String
    var transcript: String?

    init?(url: URL, createdAt: Date, duration: TimeInterval) {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        self.id = url.lastPathComponent
        self.url = url
        self.createdAt = createdAt
        self.duration = duration
        let base = url.deletingPathExtension().lastPathComponent
        self.title = base
        self.transcript = nil
    }

    var sizeBytes: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    var durationText: String { Recording.hms(duration) }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }

    static func hms(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

@MainActor
final class RecordingsStore: ObservableObject {
    @Published var items: [Recording] = []
    @Published var query = ""

    nonisolated static var audioDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Записи", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    var filtered: [Recording] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        let q = query.lowercased()
        return items.filter {
            $0.title.lowercased().contains(q)
                || ($0.transcript ?? "").lowercased().contains(q)
                || RecordingsStore.stamp.string(from: $0.createdAt).contains(q)
        }
    }

    init() { reload() }

    func reload() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: Self.audioDirectory,
                                                includingPropertiesForKeys: [.contentModificationDateKey],
                                                options: [.skipsHiddenFiles])) ?? []
        items = urls
            .filter { ["m4a", "caf", "wav"].contains($0.pathExtension.lowercased()) }
            .compactMap { url in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                let dur = (try? AVAudioPlayer(contentsOf: url).duration) ?? 0
                var rec = Recording(url: url, createdAt: date, duration: dur)
                let id = url.lastPathComponent
                rec?.transcript = TranscriptStore.shared.text(for: id)
                if let t = MetaStore.shared.title(for: id) { rec?.title = t }
                return rec
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func add(_ rec: Recording) {
        items.insert(rec, at: 0)
        reload()
    }

    func rename(_ rec: Recording, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let idx = items.firstIndex(where: { $0.id == rec.id }) else { return }
        items[idx].title = trimmed
        MetaStore.shared.setTitle(trimmed, for: rec.id)
    }

    func delete(_ rec: Recording) {
        try? FileManager.default.removeItem(at: rec.url)
        items.removeAll { $0.id == rec.id }
        TranscriptStore.shared.remove(for: rec.id)
        MetaStore.shared.remove(rec.id)
    }

    func shareURL(_ rec: Recording) -> URL { rec.url }

    nonisolated static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy HH:mm"
        f.locale = Locale(identifier: "ru_RU")
        return f
    }()
}

/// Пользовательские названия записей (переживают перезапуск).
final class MetaStore {
    static let shared = MetaStore()
    private let url: URL
    private var titles: [String: String] = [:]

    private init() {
        url = RecordingsStore.audioDirectory.appendingPathComponent(".titles.json")
        if let d = try? Data(contentsOf: url),
           let obj = try? JSONDecoder().decode([String: String].self, from: d) {
            titles = obj
        }
    }

    func title(for id: String) -> String? { titles[id] }

    func setTitle(_ t: String, for id: String) {
        titles[id] = t
        persist()
    }

    func remove(_ id: String) {
        titles[id] = nil
        persist()
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(titles) { try? d.write(to: url) }
    }
}

/// Текстовые расшифровки рядом с аудио.
final class TranscriptStore {
    static let shared = TranscriptStore()
    private var cache: [String: String] = [:]

    func text(for id: String) -> String? {
        if let c = cache[id] { return c }
        let f = RecordingsStore.audioDirectory.appendingPathComponent(id).deletingPathExtension().appendingPathExtension("txt")
        guard let s = try? String(contentsOf: f, encoding: .utf8) else { return nil }
        cache[id] = s
        return s
    }

    func write(_ text: String, for id: String) {
        cache[id] = text
        let f = RecordingsStore.audioDirectory.appendingPathComponent(id).deletingPathExtension().appendingPathExtension("txt")
        try? text.write(to: f, atomically: true, encoding: .utf8)
    }

    func remove(for id: String) {
        cache[id] = nil
        let f = RecordingsStore.audioDirectory.appendingPathComponent(id).deletingPathExtension().appendingPathExtension("txt")
        try? FileManager.default.removeItem(at: f)
    }
}
