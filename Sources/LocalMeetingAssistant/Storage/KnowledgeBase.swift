import Foundation

/// Экспорт встреч в папку базы знаний: обычные Markdown/JSON-файлы,
/// которые внешний AI-агент может читать без запуска приложения.
///
///     <корень>/README.md            — описание структуры для агента
///     <корень>/index.md, index.json — перечень всех встреч
///     <корень>/meetings/<дата>_<время>_<название>/
///         meeting.json   — метаданные и участники
///         summary.md     — саммари
///         transcript.md  — полная транскрипция
struct KnowledgeBase {
    let root: URL
    private var fm: FileManager { .default }
    private var meetingsDir: URL { root.appendingPathComponent("meetings", isDirectory: true) }

    // MARK: Экспорт одной встречи

    /// Записывает файлы встречи и возвращает путь папки относительно корня.
    @discardableResult
    func export(_ meeting: Meeting) throws -> String {
        let relative = "meetings/" + folderName(meeting)
        if let old = meeting.kbPath, old != relative {
            try? fm.removeItem(at: root.appendingPathComponent(old))
        }
        let dir = root.appendingPathComponent(relative, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        try write(metadataJSON(meeting, relative: relative), to: dir.appendingPathComponent("meeting.json"))
        try write(summaryDocument(meeting), to: dir.appendingPathComponent("summary.md"))
        try write(transcriptDocument(meeting), to: dir.appendingPathComponent("transcript.md"))
        return relative
    }

    func remove(_ meeting: Meeting) {
        guard let path = meeting.kbPath else { return }
        try? fm.removeItem(at: root.appendingPathComponent(path))
    }

    // MARK: Индекс

    func writeIndex(_ meetings: [Meeting]) throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let exported = meetings.filter { $0.kbPath != nil }.sorted { $0.startedAt > $1.startedAt }

        var md = "# Индекс встреч\n\n"
        md += "Обновлено: \(Fmt.iso.string(from: Date())). Всего встреч: \(exported.count).\n"
        md += "Описание структуры папки — в файле README.md.\n\n"
        md += "| Дата | Время | Длительность | Название | Участники | Компании | Папка |\n"
        md += "|---|---|---|---|---|---|---|\n"
        for m in exported {
            let people = m.activeSpeakers.map(\.displayName).joined(separator: ", ")
            md += "| \(Fmt.isoDay.string(from: m.startedAt)) | \(Fmt.hm.string(from: m.startedAt))–\(Fmt.hm.string(from: m.endedAt)) "
            md += "| \(Fmt.duration(m.duration)) | \(cell(m.title)) | \(cell(people)) | \(cell(m.companies.joined(separator: ", "))) "
            md += "| [\(m.kbPath!)](\(m.kbPath!.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? m.kbPath!)/) |\n"
        }
        try write(md, to: root.appendingPathComponent("index.md"))

        let items: [[String: Any]] = exported.map { metadata($0, relative: $0.kbPath!) }
        let data = try JSONSerialization.data(withJSONObject: ["meetings": items], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: root.appendingPathComponent("index.json"), options: .atomic)

        try write(Self.readme, to: root.appendingPathComponent("README.md"))
    }

    // MARK: Документы

    private func folderName(_ m: Meeting) -> String {
        var slug = m.title.lowercased()
        let allowed = CharacterSet.alphanumerics
        slug = String(slug.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = String(slug.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(60))
        let short = m.id.uuidString.prefix(4).lowercased()
        return "\(Fmt.folderStamp.string(from: m.startedAt))_\(slug.isEmpty ? "meeting" : slug)_\(short)"
    }

    private func metadata(_ m: Meeting, relative: String) -> [String: Any] {
        [
            "id": m.id.uuidString,
            "title": m.title,
            "date": Fmt.isoDay.string(from: m.startedAt),
            "start_time": Fmt.hm.string(from: m.startedAt),
            "end_time": Fmt.hm.string(from: m.endedAt),
            "started_at": Fmt.iso.string(from: m.startedAt),
            "ended_at": Fmt.iso.string(from: m.endedAt),
            "duration_minutes": Int((m.duration / 60).rounded()),
            "companies": m.companies,
            "participants": m.activeSpeakers.map { s -> [String: Any] in
                ["name": s.displayName, "company": s.company, "side": s.side.title, "is_owner": s.isUser]
            },
            "calendar_event": m.calendar.map { event -> [String: Any] in
                ["title": event.title, "calendar": event.calendar,
                 "invited": event.attendees.map { ["name": $0.name, "email": $0.email, "response": $0.status] },
                 "invited_but_silent": m.silentInvitees.map(\.name)]
            } ?? NSNull(),
            "folder": relative,
            "files": [
                "metadata": "\(relative)/meeting.json",
                "summary": "\(relative)/summary.md",
                "transcript": "\(relative)/transcript.md",
            ],
        ]
    }

    private func metadataJSON(_ m: Meeting, relative: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: metadata(m, relative: relative),
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private func frontmatter(_ m: Meeting, type: String, siblings: [(String, String)]) -> String {
        var y = "---\n"
        y += "type: \(type)\n"
        y += "meeting_id: \(m.id.uuidString)\n"
        y += "title: \(quoted(m.title))\n"
        y += "date: \(Fmt.isoDay.string(from: m.startedAt))\n"
        y += "start_time: \(quoted(Fmt.hm.string(from: m.startedAt)))\n"
        y += "end_time: \(quoted(Fmt.hm.string(from: m.endedAt)))\n"
        y += "started_at: \(Fmt.iso.string(from: m.startedAt))\n"
        y += "duration_minutes: \(Int((m.duration / 60).rounded()))\n"
        y += "companies: [\(m.companies.map(quoted).joined(separator: ", "))]\n"
        y += "participants:\n"
        for s in m.activeSpeakers {
            y += "  - name: \(quoted(s.displayName))\n"
            y += "    company: \(quoted(s.company))\n"
            y += "    side: \(quoted(s.side.title))\n"
        }
        for (key, file) in siblings { y += "\(key): \(file)\n" }
        y += "---\n\n"
        return y
    }

    static func generalInfo(_ m: Meeting) -> String {
        var s = "## Общая информация\n\n"
        s += "- **Название:** \(m.title)\n"
        s += "- **Дата:** \(Fmt.dayLong.string(from: m.startedAt))\n"
        s += "- **Время:** \(Fmt.hm.string(from: m.startedAt))–\(Fmt.hm.string(from: m.endedAt))\n"
        s += "- **Продолжительность:** \(Fmt.duration(m.duration))\n"
        let people = m.activeSpeakers
        if people.isEmpty {
            s += "- **Участники:** не определены\n"
        } else {
            s += "- **Участники:**\n"
            for p in people { s += "  - \(p.fullDescription)\n" }
        }
        if !m.companies.isEmpty { s += "- **Компании:** \(m.companies.joined(separator: ", "))\n" }
        if let event = m.calendar {
            s += "- **Событие в календаре:** \(event.title)\n"
            let silent = m.silentInvitees.map(\.name)
            if !silent.isEmpty { s += "- **Приглашены, но не говорили:** \(silent.joined(separator: ", "))\n" }
        }
        return s
    }

    private func summaryDocument(_ m: Meeting) -> String {
        var doc = frontmatter(m, type: "meeting_summary",
                              siblings: [("transcript_file", "transcript.md"), ("metadata_file", "meeting.json")])
        doc += "# Саммари: \(m.title)\n\n"
        doc += Self.generalInfo(m) + "\n"
        let body = m.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        doc += body.isEmpty ? "_Саммари ещё не сформировано._\n" : body + "\n"
        return doc
    }

    private func transcriptDocument(_ m: Meeting) -> String {
        var doc = frontmatter(m, type: "meeting_transcript",
                              siblings: [("summary_file", "summary.md"), ("metadata_file", "meeting.json")])
        doc += "# Транскрипция: \(m.title)\n\n"
        doc += "\(Fmt.dayLong.string(from: m.startedAt)), \(Fmt.hm.string(from: m.startedAt))–\(Fmt.hm.string(from: m.endedAt)). "
        doc += "Временные метки — от начала записи.\n\n"
        for u in m.utterances {
            let speaker = m.speaker(u.speakerID)
            var who = speaker?.displayName ?? "Спикер"
            if let company = speaker?.company.trimmingCharacters(in: .whitespaces), !company.isEmpty { who += " (\(company))" }
            doc += "**[\(Fmt.clock(u.start))] \(who):** \(u.text)\n\n"
        }
        return doc
    }

    // MARK: Вспомогательное

    private func write(_ text: String, to url: URL) throws {
        try text.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    private func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ") + "\""
    }

    private func cell(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ")
    }

    static let readme = """
    # База знаний рабочих встреч

    Эта папка автоматически ведётся приложением Local Meeting Assistant. В ней лежат
    транскрипции и саммари рабочих встреч. Файлы можно читать обычными инструментами;
    приложение для этого запускать не нужно.

    ## Структура

    - `index.md` — таблица всех встреч: дата, время, длительность, название, участники, компании, папка.
    - `index.json` — тот же перечень в машиночитаемом виде.
    - `meetings/<ГГГГ-ММ-ДД>_<ЧЧ-ММ>_<название>_<код>/` — отдельная папка на каждую встречу:
      - `meeting.json` — метаданные: название, дата и время, длительность, участники, их компании и стороны переговоров;
      - `summary.md` — структурированное саммари: общая информация, краткое содержание, обсуждённые вопросы,
        принятые решения, задачи и ответственные, открытые вопросы, следующие шаги;
      - `transcript.md` — полная транскрипция без сокращений, с именами участников и временными метками.

    У `summary.md` и `transcript.md` в начале есть блок YAML с теми же метаданными
    (`title`, `date`, `start_time`, `participants`, `companies`) и ссылками на соседние файлы.

    ## Как найти нужную встречу

    1. По дате и времени: имя папки начинается с даты и времени начала (`2026-11-10_15-00_…`);
       то же есть в `index.md`.
    2. По участникам и компаниям: столбцы «Участники» и «Компании» в `index.md` либо поиск по `meeting.json`.
    3. По содержанию: полнотекстовый поиск по `summary.md`, затем по `transcript.md`.
    4. «Последняя встреча» — первая строка `index.md` (сортировка от новых к старым).

    Сначала читайте `summary.md`, а за точными формулировками и деталями обращайтесь к `transcript.md`.
    Саммари сформировано локальной языковой моделью; при расхождениях первоисточником считается транскрипция.

    Стороны переговоров: «Наша команда», «Партнёр», «Подрядчик», «Другая».
    Папку можно целиком перенести на другой компьютер — все ссылки внутри относительные.
    """
}
