import Foundation

/// Локальное хранилище встреч: по папке на встречу в Application Support
/// (meeting.json + дорожки mic.wav / system.wav + промежуточные результаты обработки).
@MainActor
final class MeetingStore: ObservableObject {
    @Published private(set) var meetings: [Meeting] = []

    var onChange: ((Meeting) -> Void)?
    var onDelete: ((Meeting) -> Void)?

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func load() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: AppPaths.meetings, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Meeting] = []
        for dir in dirs {
            let file = dir.appendingPathComponent("meeting.json")
            guard let data = try? Data(contentsOf: file),
                  let meeting = try? decoder.decode(Meeting.self, from: data) else { continue }
            loaded.append(meeting)
        }
        meetings = loaded.sorted { $0.startedAt > $1.startedAt }
    }

    nonisolated func dir(_ id: UUID) -> URL {
        AppPaths.meetings.appendingPathComponent(id.uuidString, isDirectory: true)
    }
    nonisolated func micURL(_ id: UUID) -> URL { dir(id).appendingPathComponent("mic.wav") }
    nonisolated func systemURL(_ id: UUID) -> URL { dir(id).appendingPathComponent("system.wav") }
    /// Дорожка микрофона после эхоподавления (есть только если эхо было обнаружено).
    nonisolated func cleanMicURL(_ id: UUID) -> URL { dir(id).appendingPathComponent("mic.aec.wav") }
    nonisolated func sidecarURL(_ id: UUID, _ name: String) -> URL { dir(id).appendingPathComponent(name) }

    func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }

    func add(_ meeting: Meeting) {
        try? FileManager.default.createDirectory(at: dir(meeting.id), withIntermediateDirectories: true)
        meetings.insert(meeting, at: 0)
        meetings.sort { $0.startedAt > $1.startedAt }
        save(meeting)
    }

    func update(_ id: UUID, _ mutate: (inout Meeting) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        var meeting = meetings[index]
        mutate(&meeting)
        meetings[index] = meeting
        save(meeting)
        onChange?(meeting)
    }

    /// Запоминает путь встречи в базе знаний, не запуская повторный экспорт.
    func setKnowledgeBasePath(_ id: UUID, _ path: String?) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[index].kbPath = path
        save(meetings[index])
    }

    func delete(_ id: UUID) {
        guard let meeting = meeting(id) else { return }
        meetings.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: dir(id))
        onDelete?(meeting)
    }

    func deleteAudio(_ id: UUID) {
        try? FileManager.default.removeItem(at: micURL(id))
        try? FileManager.default.removeItem(at: systemURL(id))
        try? FileManager.default.removeItem(at: cleanMicURL(id))
        update(id) { $0.hasAudio = false }
    }

    func audioBytes(_ id: UUID) -> Int64 {
        [micURL(id), systemURL(id), cleanMicURL(id)].reduce(Int64(0)) { sum, url in
            sum + (((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0)
        }
    }

    var totalAudioBytes: Int64 { meetings.reduce(0) { $0 + audioBytes($1.id) } }

    private func save(_ meeting: Meeting) {
        guard let data = try? encoder.encode(meeting) else { return }
        try? data.write(to: dir(meeting.id).appendingPathComponent("meeting.json"), options: .atomic)
    }
}
