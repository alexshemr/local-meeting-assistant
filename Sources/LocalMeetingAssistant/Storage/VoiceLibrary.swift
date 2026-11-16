import Foundation

struct KnownVoice: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var company: String
    var side: Side
    var embedding: [Float]
    var samples: Int = 1
    /// Сводка по человеку: когда встречались и о чём договаривались (составляется по запросу).
    var digest: String?
    var digestAt: Date?
    var email: String?

    /// Голос этого человека ещё не записан (человек добавлен вручную или из календаря).
    var hasVoice: Bool { !embedding.isEmpty }
}

/// Голоса участников, которым пользователь уже назначал имена.
/// Используется, чтобы узнавать их на следующих встречах.
@MainActor
final class VoiceLibrary: ObservableObject {
    @Published private(set) var voices: [KnownVoice] = []

    nonisolated static let matchThreshold: Float = 0.62

    func load() {
        guard let data = try? Data(contentsOf: AppPaths.voiceLibrary),
              let decoded = try? JSONDecoder().decode([KnownVoice].self, from: data) else { return }
        voices = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(voices) else { return }
        try? data.write(to: AppPaths.voiceLibrary, options: .atomic)
    }

    nonisolated static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let denom = (na * nb).squareRoot()
        return denom > 0 ? dot / denom : -1
    }

    /// Насколько лучший кандидат должен опережать следующего, чтобы имя подставилось само.
    nonisolated static let ambiguityMargin: Float = 0.05

    /// Знакомые голоса, похожие на этот, — от самого похожего.
    nonisolated static func candidates(_ embedding: [Float], in voices: [KnownVoice],
                                       excluding rejected: [UUID] = []) -> [(voice: KnownVoice, score: Float)] {
        voices.filter { !rejected.contains($0.id) }
            .map { (voice: $0, score: cosine(embedding, $0.embedding)) }
            .filter { $0.score >= matchThreshold }
            .sorted { $0.score > $1.score }
    }

    /// Голос, который можно подставить автоматически. Если похожих знакомых голосов несколько и они
    /// почти одинаково близки (бывают очень похожие голоса), не угадываем: выбор остаётся за пользователем.
    nonisolated static func bestMatch(_ embedding: [Float], in voices: [KnownVoice]) -> KnownVoice? {
        let found = candidates(embedding, in: voices)
        guard let best = found.first else { return nil }
        if found.count > 1, best.score - found[1].score < ambiguityMargin { return nil }
        return best.voice
    }

    /// Слова двух имён не пересекаются — значит, это другой человек, а не исправление опечатки.
    nonisolated static func isDifferentPerson(_ a: String, _ b: String) -> Bool {
        func words(_ s: String) -> [String] {
            s.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 3 }
        }
        let first = words(a), second = words(b)
        guard !first.isEmpty, !second.isEmpty else { return false }
        return !first.contains { x in second.contains { y in x.hasPrefix(y.prefix(3)) } }
    }

    /// Запоминает (или уточняет) голос названного участника. Возвращает идентификатор записи.
    func remember(_ speaker: Speaker) -> UUID? {
        let name = speaker.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !speaker.isUser, let embedding = speaker.embedding, !embedding.isEmpty else {
            return speaker.voiceID
        }
        let index = voices.firstIndex { $0.id == speaker.voiceID }
            ?? voices.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        if let index {
            var voice = voices[index]
            voice.name = name
            voice.company = speaker.company
            voice.side = speaker.side
            if voice.embedding.isEmpty {
                // Человек был известен только по имени (из календаря или добавлен вручную) — теперь есть и голос.
                voice.embedding = embedding
            } else if voice.embedding.count == embedding.count, Self.cosine(voice.embedding, embedding) < 0.999 {
                let n = Float(min(voice.samples, 10))
                voice.embedding = zip(voice.embedding, embedding).map { ($0 * n + $1) / (n + 1) }
                voice.samples += 1
            }
            voices[index] = voice
            save()
            return voice.id
        }
        let voice = KnownVoice(name: name, company: speaker.company, side: speaker.side, embedding: embedding)
        voices.append(voice)
        save()
        return voice.id
    }

    func voice(_ id: UUID?) -> KnownVoice? { voices.first { $0.id == id } }

    /// Человек по адресу почты или, если адреса нет, по имени.
    func person(email: String, name: String) -> KnownVoice? {
        let email = email.trimmingCharacters(in: .whitespaces).lowercased()
        if !email.isEmpty, let found = voices.first(where: { ($0.email ?? "").lowercased() == email }) { return found }
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return voices.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Добавляет человека без голоса. Возвращает его идентификатор.
    @discardableResult
    func add(name: String, company: String = "", side: Side = .other, email: String = "") -> UUID {
        let person = KnownVoice(name: name, company: company, side: side, embedding: [], email: email.isEmpty ? nil : email)
        voices.append(person)
        save()
        return person.id
    }

    func update(_ id: UUID, _ mutate: (inout KnownVoice) -> Void) {
        guard let index = voices.firstIndex(where: { $0.id == id }) else { return }
        mutate(&voices[index])
        save()
    }

    func remove(_ id: UUID) {
        voices.removeAll { $0.id == id }
        save()
    }
}
