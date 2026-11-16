import Foundation

/// Генерация саммари и follow-up локальной языковой моделью.
struct MeetingAI {
    let client: LLMClient
    let userName: String
    let userCompany: String

    /// Транскрипция такого размера помещается в контекст модели целиком.
    private var singlePassChars: Int { client.singlePassChars }
    private let chunkChars = 18_000

    private static let rules = """
    Ты готовишь итоги рабочих встреч. Работай строго по предоставленным материалам.

    Правила:
    - Используй только то, что прямо сказано участниками. Не придумывай договорённости, решения, сроки и ответственных.
    - Если срок не называли — пиши «срок не обсуждался». Если ответственного не назначали — «ответственный не назначен».
    - Транскрипция получена автоматическим распознаванием речи, в ней возможны ошибки в отдельных словах и именах. \
    Очевидные ошибки распознавания исправляй по смыслу, но факты не меняй.
    - Английские термины, названия продуктов и технические обозначения (API, методы, вебхуки, статусы, коды ошибок) \
    оставляй в оригинальном написании.
    - Технические детали передавай точно: интеграции, методы API, ошибки, требования к доработкам, изменения в работе продуктов.
    - Учитывай, кто к какой стороне относится (наша команда, партнёр, подрядчик), и указывай, кто что предложил или пообещал.
    - Пиши по-русски, по существу, без пересказа разговора реплика за репликой и без вступительных фраз.
    """

    // MARK: Саммари

    struct SummaryResult {
        var title: String?
        var body: String
    }

    func summarize(_ meeting: Meeting, style: SummaryStyle,
                   onStage: @escaping @Sendable (String, Double?) -> Void,
                   onText: @escaping @Sendable (String) -> Void) async throws -> SummaryResult {
        let lines = transcriptLines(meeting)
        guard !lines.isEmpty else { throw ProcessingError.failed("В записи не найдено речи — саммари формировать не из чего.") }
        let header = contextHeader(meeting)
        let full = lines.joined(separator: "\n")
        let remarks = meeting.summaryFeedback.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let remarkList = remarks.map { "- \($0)" }.joined(separator: "\n")

        let material: String
        if full.count <= singlePassChars {
            material = "Транскрипция встречи:\n\n\(full)"
        } else {
            // Длинная встреча: сначала заметки по частям, затем итоговое саммари по заметкам.
            let chunks = split(lines)
            var notes: [String] = []
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                onStage("Анализ части \(index + 1) из \(chunks.count)", Double(index) / Double(chunks.count + 1))
                let prompt = """
                \(Self.rules)

                \(header)

                Ниже — часть \(index + 1) из \(chunks.count) транскрипции длинной встречи. Составь рабочие заметки по этой части \
                маркированным списком (до 350 слов): обсуждавшиеся темы и аргументы сторон, принятые решения, \
                задачи (кто, что, срок), открытые вопросы, технические детали. Только факты из текста.
                \(remarks.isEmpty ? "" : "\nВладелец записи просил обратить особое внимание на следующее — если это есть в этой части, отрази подробно:\n\(remarkList)\n")

                \(chunk)
                """
                notes.append("### Часть \(index + 1)\n" + (try await client.generate(prompt: prompt, maxTokens: 900) { _ in }))
            }
            onStage("Сборка итогового саммари", Double(chunks.count) / Double(chunks.count + 1))
            material = "Заметки по частям транскрипции (в хронологическом порядке):\n\n" + notes.joined(separator: "\n\n")
        }

        let volume: String
        switch style {
        case .brief: volume = "Формат краткий: 2–3 предложения в кратком содержании и не более 4 самых важных пунктов в каждом разделе."
        case .standard: volume = "Формат стандартный: 3–5 предложений в кратком содержании, в разделах — все значимые пункты без воды."
        case .detailed: volume = "Формат подробный: развёрнутое краткое содержание, в «Обсуждённых вопросах» — позиции и аргументы сторон, технические детали полностью."
        }

        var revision = ""
        if !remarks.isEmpty {
            let previous = meeting.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !previous.isEmpty {
                revision += "\nПредыдущая версия саммари, которую владелец записи просил доработать:\n\n\(previous.prefix(6000))\n"
            }
            revision += """

            Замечания владельца записи к саммари (от ранних к поздним; при противоречии важнее более позднее):
            \(remarkList)

            Составь саммари заново с учётом всех замечаний. Замечания определяют, на что обратить внимание, что добавить, \
            убрать или изложить иначе, но факты бери только из материалов встречи: если того, о чём просят, в материалах нет, \
            не выдумывай, а отметь это в разделе «Открытые вопросы». Сами замечания в текст саммари не включай.

            """
        }

        let prompt = """
        \(Self.rules)

        \(header)

        \(material)
        \(revision)
        Составь структурированное саммари этой встречи. \(volume)
        Ответ дай строго в таком виде (Markdown), без текста до и после:

        НАЗВАНИЕ: <короткое название встречи по её основной теме, 3–8 слов>

        ## Краткое содержание
        <основные темы встречи и ключевые выводы>

        ## Обсуждённые вопросы
        - <тема: что обсуждали, какие были предложения и аргументы>

        ## Принятые решения
        - <конкретное решение или договорённость>

        ## Задачи и ответственные
        - **<ответственный>** — <что нужно сделать> (срок: <срок или «не обсуждался»>)

        ## Открытые вопросы
        - <вопрос, по которому окончательного решения не приняли>

        ## Следующие шаги
        - <действие после встречи>

        Если по какому-то разделу в разговоре ничего не было, напиши в нём одну строку: «Не зафиксировано».
        """
        let raw = try await client.generate(prompt: prompt, maxTokens: 3000, onText: { onText(Self.parse($0).body) })
        return Self.parse(raw)
    }

    static func parse(_ raw: String) -> SummaryResult {
        var title: String?
        var body = raw
        if let range = raw.range(of: "НАЗВАНИЕ:") {
            let after = raw[range.upperBound...]
            let line = after.prefix { $0 != "\n" }
            let candidate = line.trimmingCharacters(in: CharacterSet(charactersIn: " *«»\"<>#"))
            if !candidate.isEmpty { title = String(candidate.prefix(90)) }
            body = String(after.dropFirst(line.count))
        }
        if let start = body.range(of: "## ") { body = String(body[start.lowerBound...]) }
        return SummaryResult(title: title, body: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Follow-up

    func followUp(_ meeting: Meeting, format: FollowUpFormat,
                  onText: @escaping @Sendable (String) -> Void) async throws -> String {
        let summary = meeting.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = transcriptLines(meeting).joined(separator: "\n")
        guard !summary.isEmpty || !full.isEmpty else {
            throw ProcessingError.failed("Нет ни транскрипции, ни саммари — follow-up формировать не из чего.")
        }
        if summary.isEmpty, full.count > singlePassChars {
            throw ProcessingError.failed("Сначала сформируйте саммари: встреча слишком длинная, чтобы готовить письмо напрямую по транскрипции.")
        }

        var material = ""
        if !summary.isEmpty { material += "Саммари встречи:\n\n\(summary)\n\n" }
        if full.count <= singlePassChars - summary.count, !full.isEmpty {
            material += "Транскрипция встречи:\n\n\(full)\n"
        }

        let style: String
        switch format {
        case .brief:
            style = "Формат — краткий: 1–2 предложения о встрече, затем только основные договорённости и следующие шаги. Письмо должно читаться за минуту."
        case .detailed:
            style = "Формат — подробный: содержание встречи по темам, принятые решения, задачи с ответственными и сроками, следующие шаги."
        case .technical:
            style = "Формат — технический: основной акцент на интеграциях, API, ошибках, требованиях к доработкам и технических договорённостях. Организационные детали — кратко."
        }

        let author = userCompany.trimmingCharacters(in: .whitespaces).isEmpty ? userName : "\(userName) (\(userCompany))"
        let prompt = """
        \(Self.rules)

        \(contextHeader(meeting))

        \(material)
        Напиши follow-up — письмо по итогам этой встречи от лица участника «\(author)», который относится к нашей команде. \
        Письмо адресовано остальным участникам встречи. О нашей команде пиши «мы», к другой стороне обращайся на «вы». \
        Тон деловой и дружелюбный.

        \(style)

        Структура письма:
        1. Первая строка — «Тема: <тема письма>».
        2. Приветствие.
        3. Краткое содержание обсуждения.
        4. Достигнутые договорённости.
        5. Задачи и ответственные (со сроками, если они назывались).
        6. Следующие шаги.
        7. Вопросы, которые требуют ответа или подтверждения от адресатов (если такие есть).
        8. Подпись.

        Это обычный текст письма: без Markdown-заголовков и жирного шрифта, списки оформляй через дефис. \
        Не добавляй ничего, чего нет в материалах. Дай только текст письма.
        """
        return try await client.generate(prompt: prompt, maxTokens: 2500, temperature: 0.3, onText: onText)
    }

    // MARK: Сводка по человеку

    /// Сводка по всем встречам с одним человеком: когда встречались, о чём договорились, что осталось открытым.
    func personDigest(_ voice: KnownVoice, meetings: [Meeting],
                      onText: @escaping @Sendable (String) -> Void) async throws -> String {
        let ordered = meetings.sorted { $0.startedAt < $1.startedAt }
        // Материалы должны поместиться в контекст модели: чем больше встреч, тем короче выдержка из каждой.
        let budget = max(1_200, 22_000 / max(1, ordered.count))
        var material = ""
        for meeting in ordered {
            material += "### \(Fmt.dayLong.string(from: meeting.startedAt)), \(Fmt.hm.string(from: meeting.startedAt)) — \(meeting.title)\n"
            material += "Участники: \(meeting.activeSpeakers.map(\.fullDescription).joined(separator: "; "))\n"
            let summary = meeting.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty {
                material += String(summary.prefix(budget)) + "\n\n"
            } else {
                let lines = transcriptLines(meeting).joined(separator: "\n")
                material += "(саммари нет, начало транскрипции)\n" + String(lines.prefix(budget)) + "\n\n"
            }
        }
        let who = voice.company.trimmingCharacters(in: .whitespaces).isEmpty ? voice.name : "\(voice.name) (\(voice.company))"
        let prompt = """
        \(Self.rules)

        Ниже — материалы встреч, в которых участвовал \(who), сторона: \(voice.side.title.lowercased()). \
        Владелец записей — \(userName). Встречи идут в хронологическом порядке.

        \(material)
        Составь сводку по этому человеку для владельца записей. Ответ дай строго в таком виде (Markdown), без текста до и после:

        ## Встречи
        - **<дата>** — <тема встречи>: <что обсуждали с участием этого человека, 1–2 предложения>

        ## Договорённости
        - <о чём договорились с этим человеком> (<дата встречи>)

        ## Что обещал он
        - <задача или обещание этого человека> (<дата>, срок: <срок или «не обсуждался»>)

        ## Что обещали мы
        - <задача или обещание нашей стороны перед ним> (<дата>, срок: <срок или «не обсуждался»>)

        ## Открытые вопросы
        - <вопрос, который с ним остался нерешённым>

        Включай только то, что относится к этому человеку. Если по разделу ничего нет, напиши в нём «Не зафиксировано». \
        Более поздние договорённости важнее ранних: если что-то пересмотрели, укажи актуальное.
        """
        return try await client.generate(prompt: prompt, maxTokens: 2500, onText: onText)
    }

    // MARK: Подготовка материалов

    private func contextHeader(_ m: Meeting) -> String {
        var s = "Сведения о встрече:\n"
        s += "- Дата и время: \(Fmt.dayLong.string(from: m.startedAt)), \(Fmt.hm.string(from: m.startedAt))–\(Fmt.hm.string(from: m.endedAt))\n"
        s += "- Продолжительность: \(Fmt.duration(m.duration))\n"
        s += "- Участники:\n"
        for speaker in m.activeSpeakers {
            s += "  - \(speaker.fullDescription)\(speaker.isUser ? " — владелец записи" : "")\n"
        }
        if let event = m.calendar {
            s += "- Тема встречи по календарю: \(event.title)\n"
            let invited = event.attendees.map(\.name).joined(separator: ", ")
            if !invited.isEmpty {
                s += "- Приглашены по календарю: \(invited). Приглашённый мог не прийти или молчать: "
                s += "не приписывай ему слов и присутствия, если его нет среди участников выше.\n"
            }
        }
        s += "Участники с обозначением «Спикер N» не опознаны: имён им не придумывай, называй их так же."
        return s
    }

    private func transcriptLines(_ m: Meeting) -> [String] {
        m.utterances.map { u in
            "[\(Fmt.clock(u.start))] \(m.speaker(u.speakerID)?.displayName ?? "Спикер"): \(u.text)"
        }
    }

    private func split(_ lines: [String]) -> [String] {
        var chunks: [String] = []
        var current: [String] = []
        var size = 0
        for line in lines {
            if size + line.count > chunkChars, !current.isEmpty {
                chunks.append(current.joined(separator: "\n"))
                current = []
                size = 0
            }
            current.append(line)
            size += line.count + 1
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
        return chunks
    }
}
