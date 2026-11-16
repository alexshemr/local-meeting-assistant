import Foundation

enum Side: String, Codable, CaseIterable, Identifiable {
    case ours, partner, contractor, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ours: return "Наша команда"
        case .partner: return "Партнёр"
        case .contractor: return "Подрядчик"
        case .other: return "Другая"
        }
    }
}

enum Track: String, Codable {
    case mic, system
}

enum MeetingStatus: String, Codable {
    case recording, queued, transcribing, diarizing, summarizing, ready, failed

    var isProcessing: Bool {
        switch self {
        case .queued, .transcribing, .diarizing, .summarizing: return true
        default: return false
        }
    }

    var title: String {
        switch self {
        case .recording: return "Идёт запись"
        case .queued: return "В очереди на обработку"
        case .transcribing: return "Распознавание речи"
        case .diarizing: return "Определение участников"
        case .summarizing: return "Подготовка саммари"
        case .ready: return "Готово"
        case .failed: return "Ошибка обработки"
        }
    }
}

struct Speaker: Codable, Identifiable, Hashable {
    var id: String
    /// «Спикер 1», «Спикер 2»… — обозначение до того, как пользователь назначит имя.
    var label: String
    var name: String = ""
    var company: String = ""
    var side: Side = .other
    var isUser: Bool = false
    /// Имя подставлено автоматически по совпадению голоса с ранее названным участником.
    var autoIdentified: Bool = false
    var voiceID: UUID?
    var embedding: [Float]?
    /// Адрес почты — по нему спикер сопоставляется с приглашённым из календаря.
    var email: String?
    /// Знакомые голоса, про которые пользователь сказал «это не он», — повторно их не предлагаем.
    var rejectedVoices: [UUID]?

    var displayName: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? label : name }

    var fullDescription: String {
        var parts: [String] = []
        if !company.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(company) }
        parts.append(side.title.lowercased())
        return "\(displayName) (\(parts.joined(separator: ", ")))"
    }
}

/// Сопоставление имён: в календаре человек часто записан латиницей или адресом почты
/// («mikhail.milovanov», «Grigor Cymbal»), а в приложении — по-русски («Михаил Милованов»).
enum NameMatch {
    private static let map: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh", "з": "z", "и": "i", "й": "i",
        "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u", "ф": "f",
        "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch", "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "iu", "я": "ia",
    ]

    /// Слова имени латиницей в нижнем регистре; короткие обрывки («se», «a») отбрасываются.
    static func tokens(_ name: String) -> [String] {
        var latin = ""
        for character in name.lowercased() { latin += map[character] ?? String(character) }
        let folded = latin.folding(options: .diacriticInsensitive, locale: nil)
        return folded.components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 4 }
    }

    /// Два слова — одно и то же имя с поправкой на разные способы транслитерации (Цымбал — Cymbal, Tsymbal).
    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = Array(a), y = Array(b)
        guard abs(x.count - y.count) <= 2 else { return false }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + [Int](repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[y.count] <= (min(x.count, y.count) >= 6 ? 2 : 1)
    }

    static func same(_ first: String, _ second: String) -> Bool {
        let a = tokens(first), b = tokens(second)
        guard !a.isEmpty, !b.isEmpty else { return false }
        let matched = a.filter { x in b.contains { similar(x, $0) } }.count
        // Имя и фамилия должны совпасть оба, если они есть с обеих сторон: одного «Михаила» мало.
        return matched >= min(2, min(a.count, b.count))
    }

    static func same(speakerName: String, speakerEmail: String?, attendee: CalendarAttendee) -> Bool {
        if let email = speakerEmail, !email.isEmpty, !attendee.email.isEmpty,
           email.caseInsensitiveCompare(attendee.email) == .orderedSame { return true }
        if same(speakerName, attendee.name) { return true }
        // Имя в календаре бывает пустым или неинформативным — тогда сравниваем с адресом почты.
        let local = attendee.email.split(separator: "@").first.map(String.init) ?? ""
        return !local.isEmpty && same(speakerName, local)
    }
}

/// Момент записи, где, похоже, один звонок сменился другим.
struct SplitMark: Codable, Hashable {
    /// Секунды от начала записи.
    var time: Double
    /// Пользователь подтвердил, что это разные встречи: запись будет разделена после остановки.
    var confirmed = false
}

struct Utterance: Codable, Identifiable, Hashable {
    var id = UUID()
    var speakerID: String
    var start: Double
    var end: Double
    var text: String
    var track: Track
    var edited: Bool = false
}

enum SummaryStyle: String, Codable, CaseIterable, Identifiable {
    case brief, standard, detailed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .brief: return "Краткое"
        case .standard: return "Стандартное"
        case .detailed: return "Подробное"
        }
    }
}

enum FollowUpFormat: String, Codable, CaseIterable, Identifiable {
    case brief, detailed, technical
    var id: String { rawValue }
    var title: String {
        switch self {
        case .brief: return "Краткий"
        case .detailed: return "Подробный"
        case .technical: return "Технический"
        }
    }
    var hint: String {
        switch self {
        case .brief: return "Основные договорённости и следующие шаги"
        case .detailed: return "Содержание встречи, решения и задачи"
        case .technical: return "Акцент на интеграциях, ошибках и технических договорённостях"
        }
    }
}

struct Meeting: Codable, Identifiable {
    var id = UUID()
    var title: String
    var titleIsCustom = false
    var startedAt: Date
    var duration: Double = 0
    var status: MeetingStatus = .recording
    var errorMessage: String?
    var sourceApp: String?

    var speakers: [Speaker] = []
    var utterances: [Utterance] = []

    /// Саммари в Markdown (разделы 2–7; общая информация добавляется приложением).
    var summary: String = ""
    var summaryGeneratedAt: Date?
    /// Транскрипция или участники изменились после генерации саммари.
    var summaryStale = false

    /// Черновик follow-up. Хранится только внутри приложения и в базу знаний не попадает.
    var followUp: String = ""
    var followUpFormat: FollowUpFormat?

    /// Путь папки встречи относительно корня базы знаний.
    var kbPath: String?
    var hasAudio = true
    /// Встреча шла через колонки: голоса собеседников попали в микрофон и были из него убраны.
    var echoCancelled = false
    /// Встреча создана из импортированного файла, а не записана приложением.
    var imported = false

    /// Саммари отложено до тех пор, пока пользователь не назовёт участников.
    var awaitingParticipants = false
    /// Замечания пользователя к саммари — дополнительные указания модели при повторной генерации.
    var summaryFeedback: [String] = []
    /// Сколько человек было на встрече вместе с владельцем записи (задано вручную); nil — определять автоматически.
    var speakerCountHint: Int?
    /// Замеченные во время записи смены звонка — возможные границы между встречами.
    var splitMarks: [SplitMark] = []
    /// Событие календаря, во время которого шла встреча: тема и состав приглашённых.
    var calendar: CalendarEvent?
    /// Пользователь отвязал событие календаря — автоматически заново не привязываем.
    var calendarDetached = false
    /// Событие привязано вручную — автоматическая проверка его не снимает.
    var calendarManual = false
    /// Название встречи до того, как его заменила тема из календаря (чтобы вернуть при отвязке).
    var titleBeforeCalendar: String?

    init(title: String, startedAt: Date) {
        self.title = title
        self.startedAt = startedAt
    }

    /// Терпимое чтение: отсутствующие поля получают значения по умолчанию,
    /// поэтому файлы встреч остаются читаемыми при обновлении приложения.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? Meeting.defaultTitle(for: startedAt)
        titleIsCustom = try c.decodeIfPresent(Bool.self, forKey: .titleIsCustom) ?? false
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        status = try c.decodeIfPresent(MeetingStatus.self, forKey: .status) ?? .ready
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        sourceApp = try c.decodeIfPresent(String.self, forKey: .sourceApp)
        speakers = try c.decodeIfPresent([Speaker].self, forKey: .speakers) ?? []
        utterances = try c.decodeIfPresent([Utterance].self, forKey: .utterances) ?? []
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        summaryGeneratedAt = try c.decodeIfPresent(Date.self, forKey: .summaryGeneratedAt)
        summaryStale = try c.decodeIfPresent(Bool.self, forKey: .summaryStale) ?? false
        followUp = try c.decodeIfPresent(String.self, forKey: .followUp) ?? ""
        followUpFormat = try c.decodeIfPresent(FollowUpFormat.self, forKey: .followUpFormat)
        kbPath = try c.decodeIfPresent(String.self, forKey: .kbPath)
        hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? true
        echoCancelled = try c.decodeIfPresent(Bool.self, forKey: .echoCancelled) ?? false
        imported = try c.decodeIfPresent(Bool.self, forKey: .imported) ?? false
        awaitingParticipants = try c.decodeIfPresent(Bool.self, forKey: .awaitingParticipants) ?? false
        summaryFeedback = try c.decodeIfPresent([String].self, forKey: .summaryFeedback) ?? []
        speakerCountHint = try c.decodeIfPresent(Int.self, forKey: .speakerCountHint)
        splitMarks = try c.decodeIfPresent([SplitMark].self, forKey: .splitMarks) ?? []
        calendar = try c.decodeIfPresent(CalendarEvent.self, forKey: .calendar)
        calendarDetached = try c.decodeIfPresent(Bool.self, forKey: .calendarDetached) ?? false
        calendarManual = try c.decodeIfPresent(Bool.self, forKey: .calendarManual) ?? false
        titleBeforeCalendar = try c.decodeIfPresent(String.self, forKey: .titleBeforeCalendar)
    }

    var endedAt: Date { startedAt.addingTimeInterval(duration) }

    var activeSpeakers: [Speaker] {
        let used = Set(utterances.map(\.speakerID))
        return speakers.filter { used.contains($0.id) }
    }

    var companies: [String] {
        var seen = Set<String>()
        return activeSpeakers
            .map { $0.company.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Спикер, которому соответствует приглашённый из календаря (по имени; владелец записи — по отметке «это вы»).
    func speaker(for attendee: CalendarAttendee) -> Speaker? {
        if attendee.isSelf { return activeSpeakers.first(where: \.isUser) }
        return activeSpeakers.first { speaker in
            !speaker.isUser && NameMatch.same(speakerName: speaker.name, speakerEmail: speaker.email, attendee: attendee)
        }
    }

    /// Названные собеседники (без владельца записи).
    var namedSpeakers: [Speaker] {
        activeSpeakers.filter { !$0.isUser && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Приглашённые по календарю, которых не слышно в записи: не пришли или молчали.
    var silentInvitees: [CalendarAttendee] {
        guard let calendar else { return [] }
        return calendar.attendees.filter { speaker(for: $0) == nil }
    }

    /// Собеседники, которым ещё не дали имя.
    var unnamedSpeakers: [Speaker] {
        activeSpeakers.filter { !$0.isUser && $0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Образец голоса: самый длинный отрезок, где спикер говорит один, без наложения чужих реплик.
    func voiceSample(for speakerID: String, maxLength: Double = 12) -> (track: Track, start: Double, end: Double)? {
        let own = utterances.filter { $0.speakerID == speakerID }
        guard let longest = own.max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) else { return nil }
        let others = utterances.filter { $0.speakerID != speakerID }.sorted { $0.start < $1.start }
        var best: (track: Track, start: Double, end: Double)?
        for utterance in own {
            var cursor = utterance.start
            func consider(_ end: Double) {
                if end - cursor > (best.map { $0.end - $0.start } ?? 0) { best = (utterance.track, cursor, end) }
            }
            for other in others where other.end + 0.3 > utterance.start && other.start - 0.3 < utterance.end {
                consider(min(utterance.end, other.start - 0.3))
                cursor = max(cursor, other.end + 0.3)
            }
            consider(utterance.end)
        }
        var chosen = (track: longest.track, start: longest.start, end: longest.end)
        if let best, best.end - best.start >= 2 { chosen = best }
        return (chosen.track, chosen.start, min(chosen.end, chosen.start + maxLength))
    }

    func speaker(_ id: String) -> Speaker? { speakers.first { $0.id == id } }

    static func defaultTitle(for date: Date) -> String {
        "Встреча \(Fmt.titleDate.string(from: date))"
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        func has(_ s: String) -> Bool { s.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        if has(title) || has(summary) || has(Fmt.dayLong.string(from: startedAt)) { return true }
        if speakers.contains(where: { has($0.name) || has($0.company) }) { return true }
        return utterances.contains { has($0.text) }
    }
}

enum Fmt {
    private static func make(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = format
        return f
    }

    static let titleDate = make("d MMMM, HH:mm")
    static let dayLong = make("d MMMM yyyy")
    static let dayShort = make("dd.MM.yyyy")
    static let hm = make("HH:mm")
    static let isoDay = make("yyyy-MM-dd")
    static let folderStamp = make("yyyy-MM-dd_HH-mm")

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int((seconds / 60).rounded())
        if total < 1 { return "меньше минуты" }
        let h = total / 60, m = total % 60
        if h == 0 { return "\(m) мин" }
        return m == 0 ? "\(h) ч" : "\(h) ч \(m) мин"
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
