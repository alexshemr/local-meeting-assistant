import Foundation

/// Очередь обработки встреч: распознавание → участники → саммари.
/// Результат каждого этапа сохраняется на диск, поэтому сбой на любом шаге
/// не уничтожает ни запись, ни уже полученные результаты.
@MainActor
final class ProcessingPipeline: ObservableObject {
    /// full — всё заново; resume — продолжить с сохранённого этапа; rediarize — заново разделить голоса
    /// (распознанный текст сохраняется); summaryOnly — только саммари.
    enum Mode { case full, resume, rediarize, summaryOnly }

    struct Progress: Equatable {
        var stage: String
        var fraction: Double?
    }

    @Published private(set) var progress: [UUID: Progress] = [:]
    /// Текст саммари по мере генерации.
    @Published private(set) var liveSummary: [UUID: String] = [:]
    @Published private(set) var queue: [UUID] = []

    private let store: MeetingStore
    private let models: ModelManager
    private let settings: AppSettings
    private let voices: VoiceLibrary
    private let governor: LoadGovernor
    private var modes: [UUID: Mode] = [:]
    private var worker: Task<Void, Never>?
    private var summaryTasks: [UUID: Task<MeetingAI.SummaryResult, Error>] = [:]
    /// Встречи, которые сейчас ждут, пока компьютер освободится.
    @Published private(set) var paused: Set<UUID> = []
    /// Саммари облачной моделью этот Mac не нагружает, поэтому готовится отдельно от основной очереди:
    /// его не задерживают ни звонок, ни распознавание другой встречи, вставшее на паузу.
    private var cloudLane: Set<UUID> = []
    private var cloudWorker: Task<Void, Never>?
    /// Встречи, которые обрабатываются прямо сейчас (а не ждут очереди).
    private var running: Set<UUID> = []

    private var rerun: Set<UUID> = []

    /// Распознавание закончено, саммари отложено до указания участников.
    var onAwaitingParticipants: ((UUID) -> Void)?

    private struct RawTranscript: Codable {
        var mic: [RawSegment]
        var system: [RawSegment]
    }

    private struct RawDiarization: Codable {
        var mic: DiarOutput
        var system: DiarOutput
    }

    init(store: MeetingStore, models: ModelManager, settings: AppSettings, voices: VoiceLibrary, governor: LoadGovernor) {
        self.governor = governor
        self.store = store
        self.models = models
        self.settings = settings
        self.voices = voices
    }

    func isQueued(_ id: UUID) -> Bool { queue.contains(id) }

    /// Ждёт, пока компьютер освободится (звонок, запись, нехватка памяти), показывая причину паузы.
    private func gate(_ id: UUID) async {
        guard let reason = governor.pauseReason else { return }
        let saved = progress[id]
        setProgress(id, "Пауза: \(reason). Обработка продолжится сама", nil)
        paused.insert(id)
        await governor.waitUntilClear()
        paused.remove(id)
        if queue.contains(id) { progress[id] = saved ?? Progress(stage: "Обработка", fraction: nil) }
    }

    /// Компьютер понадобился пользователю: прерываем генерацию саммари, чтобы освободить память и видеоускоритель.
    /// Саммари будет сформировано заново, когда пауза закончится.
    func suspendForPause() {
        for (id, task) in summaryTasks {
            rerun.insert(id)
            task.cancel()
        }
    }

    /// Саммари этой встречи сейчас генерируется или ждёт очереди (распознавание сюда не относится).
    func isSummaryPending(_ id: UUID) -> Bool {
        summaryTasks[id] != nil || (queue.contains(id) && modes[id] == .summaryOnly)
    }

    /// Формирует саммари по текущему состоянию встречи; если оно как раз генерируется — начинает заново.
    func requestSummary(_ id: UUID) {
        if let current = summaryTasks[id] {
            rerun.insert(id)
            current.cancel()
        } else if !queue.contains(id) {
            enqueue(id, mode: .summaryOnly)
        }
        // Иначе встреча ещё распознаётся или ждёт очереди — саммари будет сформировано следом.
    }

    /// Прерывает генерацию саммари (или снимает её с очереди). Прежний текст саммари остаётся.
    func cancelSummary(_ id: UUID) {
        rerun.remove(id)
        if let current = summaryTasks[id] {
            current.cancel()
        } else if modes[id] == .summaryOnly, let index = queue.firstIndex(of: id), !running.contains(id) {
            cloudLane.remove(id)
            queue.remove(at: index)
            modes[id] = nil
            progress[id] = nil
        }
    }

    func enqueue(_ id: UUID, mode: Mode) {
        guard !queue.contains(id) else { return }
        queue.append(id)
        modes[id] = mode
        if mode != .summaryOnly { store.update(id) { $0.status = .queued; $0.errorMessage = nil } }
        progress[id] = Progress(stage: "В очереди", fraction: nil)
        if mode == .summaryOnly, !settings.llmEngine.loadsThisMac {
            cloudLane.insert(id)
            startCloudWorkerIfNeeded()
        } else {
            startWorkerIfNeeded()
        }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task {
            while let id = queue.first(where: { !cloudLane.contains($0) }) {
                await runToEnd(id)
            }
            worker = nil
        }
    }

    private func startCloudWorkerIfNeeded() {
        guard cloudWorker == nil else { return }
        cloudWorker = Task {
            while let id = queue.first(where: { cloudLane.contains($0) }) {
                await runToEnd(id)
                cloudLane.remove(id)
            }
            cloudWorker = nil
        }
    }

    private func runToEnd(_ id: UUID) async {
        running.insert(id)
        while true {
            await run(id, mode: modes[id] ?? .resume)
            // Саммари прервали, чтобы сразу сформировать заново (новые замечания или участники).
            guard rerun.remove(id) != nil else { break }
            modes[id] = .summaryOnly
            liveSummary[id] = nil
        }
        running.remove(id)
        queue.removeAll { $0 == id }
        modes[id] = nil
        progress[id] = nil
        liveSummary[id] = nil
        paused.remove(id)
    }

    private func run(_ id: UUID, mode: Mode) async {
        guard store.meeting(id) != nil else { return }
        if mode != .summaryOnly {
            do {
                if mode == .full {
                    try? FileManager.default.removeItem(at: store.sidecarURL(id, "raw.json"))
                    try? FileManager.default.removeItem(at: store.sidecarURL(id, "diar.json"))
                    try? FileManager.default.removeItem(at: store.cleanMicURL(id))
                }
                if mode == .rediarize {
                    try? FileManager.default.removeItem(at: store.sidecarURL(id, "diar.json"))
                }
                try await transcribeAndDiarize(id)
            } catch {
                store.update(id) {
                    $0.status = .failed
                    $0.errorMessage = error.localizedDescription
                }
                return
            }
            // Саммари имеет смысл готовить, когда известно, кто есть кто: иначе его придётся переделывать.
            if settings.summaryTiming == .afterParticipants, let meeting = store.meeting(id),
               !meeting.utterances.isEmpty, !meeting.unnamedSpeakers.isEmpty {
                store.update(id) {
                    $0.status = .ready
                    $0.awaitingParticipants = true
                }
                onAwaitingParticipants?(id)
                return
            }
        }
        await summarize(id)
    }

    // MARK: Распознавание и участники

    private func transcribeAndDiarize(_ id: UUID) async throws {
        let rawURL = store.sidecarURL(id, "raw.json")
        let diarURL = store.sidecarURL(id, "diar.json")
        let micURL = store.micURL(id)
        let systemURL = store.systemURL(id)
        let fm = FileManager.default

        var raw = (try? Data(contentsOf: rawURL)).flatMap { try? JSONDecoder().decode(RawTranscript.self, from: $0) }
        if raw == nil {
            guard fm.fileExists(atPath: micURL.path) || fm.fileExists(atPath: systemURL.path) else {
                throw ProcessingError.failed("Аудиозапись этой встречи удалена — повторное распознавание невозможно.")
            }
            guard let folder = models.currentWhisperFolder else { throw ProcessingError.modelMissing("Модель распознавания речи") }
            store.update(id) { $0.status = .transcribing }
            await gate(id)
            await cancelEchoIfNeeded(id)
            // Если эхо подавлялось, вашу речь распознаём по очищенной дорожке.
            let micURL = fm.fileExists(atPath: store.cleanMicURL(id).path) ? store.cleanMicURL(id) : micURL
            setProgress(id, "Загрузка модели распознавания", nil)

            let transcriber = Transcriber()
            try await transcriber.load(modelFolder: folder)
            let glossary = settings.glossary
            let micSamples = Double(WAVReader.sampleCount(micURL))
            let systemSamples = Double(WAVReader.sampleCount(systemURL))
            let total = max(1, micSamples + systemSamples)

            let wait: @Sendable () async -> Void = { await self.gate(id) }
            let system = try await transcriber.transcribe(wav: systemURL, glossary: glossary, gate: wait) { p in
                Task { @MainActor in self.setProgress(id, "Распознавание речи собеседников", p * systemSamples / total) }
            }
            let mic = try await transcriber.transcribe(wav: micURL, glossary: glossary, gate: wait) { p in
                Task { @MainActor in self.setProgress(id, "Распознавание вашей речи", (systemSamples + p * micSamples) / total) }
            }
            await transcriber.unload()

            let result = RawTranscript(mic: mic, system: system)
            try? JSONEncoder().encode(result).write(to: rawURL, options: .atomic)
            raw = result
        }
        guard let raw else { return }

        var diar = (try? Data(contentsOf: diarURL)).flatMap { try? JSONDecoder().decode(RawDiarization.self, from: $0) }
        if diar == nil {
            store.update(id) { $0.status = .diarizing }
            await gate(id)
            setProgress(id, "Определение участников", nil)
            var result = RawDiarization(mic: DiarOutput(), system: DiarOutput())
            // Сбой определения участников не должен обесценить транскрипцию:
            // в этом случае вся дорожка относится к одному спикеру, и это можно поправить вручную.
            do {
                // Число участников, заданное вручную, считается вместе с владельцем записи. Если речь есть
                // на обеих дорожках, собеседники — на системной (N − 1 голос), а микрофон делится автоматически:
                // лишние голоса на нём потом сводятся при сборке. Если дорожка одна — все N голосов на ней.
                let hint = store.meeting(id)?.speakerCountHint
                let both = !raw.system.isEmpty && !raw.mic.isEmpty
                let systemCount = hint.flatMap { both ? ($0 > 1 ? $0 - 1 : nil) : $0 }
                let micCount = both ? nil : hint
                let diarizer = SpeakerDiarizer()
                try await diarizer.prepare(speakers: systemCount)
                if !raw.system.isEmpty, fm.fileExists(atPath: systemURL.path) {
                    result.system = try await diarizer.process(wav: systemURL) { p in
                        Task { @MainActor in self.setProgress(id, "Определение участников", both ? p / 2 : p) }
                    }
                }
                let cleanMic = store.cleanMicURL(id)
                let micURL = fm.fileExists(atPath: cleanMic.path) ? cleanMic : micURL
                if !raw.mic.isEmpty, fm.fileExists(atPath: micURL.path) {
                    await gate(id)
                    if micCount != systemCount {
                        diarizer.unload()
                        try await diarizer.prepare(speakers: micCount)
                    }
                    result.mic = try await diarizer.process(wav: micURL) { p in
                        Task { @MainActor in self.setProgress(id, "Определение участников", both ? 0.5 + p / 2 : p) }
                    }
                }
                diarizer.unload()
                try? JSONEncoder().encode(result).write(to: diarURL, options: .atomic)
            } catch {
                store.update(id) { $0.errorMessage = "Участники не разделены автоматически: \(error.localizedDescription)" }
            }
            diar = result
        }

        let input = AssembleInput(mic: raw.mic, system: raw.system,
                                  micDiar: diar?.mic ?? DiarOutput(), systemDiar: diar?.system ?? DiarOutput(),
                                  userName: settings.userName, userCompany: settings.userCompany, voices: voices.voices,
                                  expectedTotal: store.meeting(id)?.speakerCountHint)
        var assembled = await Task.detached { Self.assemble(input) }.value
        // Имена, уже назначенные в этой встрече, переносим на новых спикеров по сходству голоса.
        if let previous = store.meeting(id)?.speakers {
            assembled.speakers = Self.carryOverNames(from: previous, to: assembled.speakers)
        }
        store.update(id) {
            $0.speakers = assembled.speakers
            $0.utterances = assembled.utterances
            $0.summaryStale = !$0.summary.isEmpty
        }
    }

    // MARK: Эхо

    /// Если собеседников слышно в микрофон (встреча шла через колонки), очищает дорожку микрофона
    /// от системного звука. Сбой здесь не критичен: обработка продолжится по исходной дорожке.
    private func cancelEchoIfNeeded(_ id: UUID) async {
        let mode = settings.echoMode
        let mic = store.micURL(id), system = store.systemURL(id), output = store.cleanMicURL(id)
        let fm = FileManager.default
        try? fm.removeItem(at: output)
        guard mode != .off, fm.fileExists(atPath: mic.path), fm.fileExists(atPath: system.path),
              let model = EchoCanceller.modelURL else { return }

        if mode == .auto {
            setProgress(id, "Проверка эха", nil)
            let result = await Task.detached { EchoBleedDetector.analyse(system: system, mic: mic) }.value
            guard result?.affected == true else { return }
        }
        setProgress(id, "Подавление эха", 0)
        do {
            try await Task.detached {
                try EchoCanceller.cancel(mic: mic, reference: system, output: output, model: model) { p in
                    Task { @MainActor in self.setProgress(id, "Подавление эха", p) }
                }
            }.value
            store.update(id) { $0.echoCancelled = true }
        } catch {
            try? fm.removeItem(at: output)
            store.update(id) { $0.echoCancelled = false }
        }
    }

    // MARK: Саммари

    private func summarize(_ id: UUID) async {
        // Облачная модель этот Mac не нагружает — ждать конца звонка незачем.
        if settings.llmEngine.loadsThisMac { await gate(id) }
        guard let meeting = store.meeting(id) else { return }
        guard !meeting.utterances.isEmpty else {
            store.update(id) {
                $0.status = .ready
                $0.errorMessage = $0.errorMessage ?? "В записи не найдено речи."
            }
            return
        }
        guard let client = models.llmClient(gpu: settings.performanceMode.usesGPU) else {
            let reason = models.llmUnavailableReason
            store.update(id) {
                $0.status = .ready
                $0.errorMessage = "Саммари не сформировано: \(reason). После этого нажмите «Сгенерировать заново»."
            }
            return
        }

        store.update(id) {
            $0.status = .summarizing
            $0.awaitingParticipants = false
        }
        setProgress(id, "Подготовка саммари", nil)
        let ai = MeetingAI(client: client, userName: settings.userDisplayName, userCompany: settings.userCompany)
        let style = settings.summaryStyle
        let task = Task {
            try await ai.summarize(meeting, style: style, onStage: { stage, fraction in
                Task { @MainActor in self.setProgress(id, stage, fraction) }
            }, onText: { text in
                Task { @MainActor in if self.summaryTasks[id] != nil { self.liveSummary[id] = text } }
            })
        }
        summaryTasks[id] = task
        defer { summaryTasks[id] = nil }
        do {
            let result = try await task.value
            store.update(id) {
                $0.summary = result.body
                $0.summaryGeneratedAt = Date()
                $0.summaryStale = false
                // Тема из календаря важнее придуманной моделью.
                if !$0.titleIsCustom, $0.calendar == nil, let title = result.title { $0.title = title }
                $0.status = .ready
                $0.errorMessage = nil
            }
        } catch {
            // Прервано пользователем (например, он продолжает называть участников) — это не ошибка.
            let cancelled = task.isCancelled
            store.update(id) {
                $0.status = .ready
                if !cancelled { $0.errorMessage = "Саммари не сформировано: \(error.localizedDescription)" }
            }
        }
    }

    private func setProgress(_ id: UUID, _ stage: String, _ fraction: Double?) {
        guard queue.contains(id) else { return }
        progress[id] = Progress(stage: stage, fraction: fraction)
    }

    // MARK: Сборка реплик

    struct AssembleInput: Sendable {
        var mic: [RawSegment]
        var system: [RawSegment]
        var micDiar: DiarOutput
        var systemDiar: DiarOutput
        var userName: String
        var userCompany: String
        var voices: [KnownVoice]
        /// Сколько человек было на встрече вместе с владельцем записи (задано вручную).
        var expectedTotal: Int?
    }

    /// Насколько похожи должны быть голос на дорожке микрофона и голос на системной дорожке,
    /// чтобы считать их одним человеком (собеседника слышно в микрофон из колонок).
    nonisolated static let bleedSimilarity: Float = 0.65

    /// Короткие «реплики», которые распознавание речи выдаёт на тишине и шуме.
    nonisolated private static let fillers: Set<String> = [
        "спасибо", "спасибо за внимание", "а", "э", "м", "и", "yeah", "thank you", "you",
    ]

    nonisolated private static func isFiller(_ text: String) -> Bool {
        let normalized = text.lowercased().components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
        return normalized.isEmpty || fillers.contains(normalized)
    }

    nonisolated static func assemble(_ input: AssembleInput) -> (speakers: [Speaker], utterances: [Utterance]) {
        // 1. Один и тот же голос может попасть на обе дорожки: собеседников слышно в микрофон (звук из колонок)
        //    или ваш голос возвращается в системный звук (эхо звонка). Из двух копий оставляем более полную.
        //    Сначала чистим микрофон, затем системный звук — уже относительно оставшихся фрагментов микрофона,
        //    поэтому обе копии одной фразы пропасть не могут.
        let micInput = input.mic.filter { !isFiller($0.text) }
        let systemInput = input.system.filter { !isFiller($0.text) }
        let mic = removeEchoes(from: micInput, against: systemInput, dropOnTie: true)
        let system = removeEchoes(from: systemInput, against: mic, dropOnTie: false)

        // 2. Каждому фрагменту — спикер из диаризации соответствующей дорожки.
        struct Tagged { var segment: RawSegment; var track: Track; var key: String }
        var tagged: [Tagged] = []
        for s in system {
            tagged.append(Tagged(segment: s, track: .system, key: "system|" + speaker(for: s, in: input.systemDiar)))
        }
        for m in mic {
            tagged.append(Tagged(segment: m, track: .mic, key: "mic|" + speaker(for: m, in: input.micDiar)))
        }

        // 3. Голос собеседника, который слышен в микрофон из колонок, диаризация микрофона выделяет
        //    в отдельного спикера. Узнаём его по сходству с голосом на системной дорожке.
        func embedding(_ key: String) -> [Float]? {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count > 1 else { return nil }
            return (parts[0] == "mic" ? input.micDiar : input.systemDiar).embeddings[parts[1]]
        }
        let systemKeys = Set(tagged.filter { $0.track == .system }.map(\.key))
        var bleed: [String: String] = [:]
        for key in Set(tagged.filter({ $0.track == .mic }).map(\.key)) {
            guard let own = embedding(key) else { continue }
            var best: (key: String, score: Float)?
            for other in systemKeys {
                guard let theirs = embedding(other) else { continue }
                let score = VoiceLibrary.cosine(own, theirs)
                if score >= bleedSimilarity, score > (best?.score ?? -1) { best = (other, score) }
            }
            if let best { bleed[key] = best.key }
        }

        // 4. Основной голос на дорожке микрофона — владелец записи (голоса собеседников из колонок не в счёт).
        var micDurations: [String: Double] = [:]
        for t in tagged where t.track == .mic { micDurations[t.key, default: 0] += t.segment.end - t.segment.start }
        let ownVoices = micDurations.filter { bleed[$0.key] == nil }
        let userKey = (ownVoices.isEmpty ? micDurations : ownVoices).max { $0.value < $1.value }?.key
        if let userKey { bleed[userKey] = nil }

        // Реплики собеседника, попавшие в микрофон: если то же самое время есть на системной дорожке —
        // это копия, убираем; иначе оставляем, но относим к тому же человеку.
        tagged = tagged.compactMap { item in
            guard item.track == .mic, let target = bleed[item.key] else { return item }
            let duplicated = tagged.contains {
                $0.track == .system && $0.key == target
                    && $0.segment.start < item.segment.end + 1.5 && $0.segment.end > item.segment.start - 1.5
            }
            if duplicated { return nil }
            var moved = item
            moved.key = target
            return moved
        }

        // Число участников задано вручную и собеседники слышны на системной дорожке —
        // значит, на микрофоне говорит только владелец записи.
        if input.expectedTotal != nil, !systemKeys.isEmpty, let userKey {
            for index in tagged.indices where tagged[index].key.hasPrefix("mic|") { tagged[index].key = userKey }
        }
        tagged.sort { $0.segment.start < $1.segment.start }

        var speakers: [Speaker] = []
        var idByKey: [String: String] = [:]
        var counter = 0
        for t in tagged where idByKey[t.key] == nil {
            let parts = t.key.split(separator: "|", maxSplits: 1).map(String.init)
            let diar = parts[0] == "mic" ? input.micDiar : input.systemDiar
            let embedding = parts.count > 1 ? diar.embeddings[parts[1]] : nil

            if t.key == userKey {
                idByKey[t.key] = "me"
                speakers.append(Speaker(id: "me", label: "Я", name: input.userName, company: input.userCompany,
                                        side: .ours, isUser: true, embedding: embedding))
                continue
            }
            counter += 1
            var speaker = Speaker(id: "s\(counter)", label: "Спикер \(counter)", embedding: embedding)
            if let embedding, let voice = VoiceLibrary.bestMatch(embedding, in: input.voices) {
                speaker.name = voice.name
                speaker.company = voice.company
                speaker.side = voice.side
                speaker.voiceID = voice.id
                speaker.autoIdentified = true
            }
            idByKey[t.key] = speaker.id
            speakers.append(speaker)
        }

        // 4. Склеиваем соседние фрагменты одного спикера в реплики.
        var utterances: [Utterance] = []
        for t in tagged {
            let speakerID = idByKey[t.key] ?? "s1"
            if var last = utterances.last, last.speakerID == speakerID, last.track == t.track,
               t.segment.start - last.end <= 1.5, t.segment.end - last.start <= 40 {
                last.end = max(last.end, t.segment.end)
                last.text += " " + t.segment.text
                utterances[utterances.count - 1] = last
            } else {
                utterances.append(Utterance(speakerID: speakerID, start: t.segment.start, end: t.segment.end,
                                            text: t.segment.text, track: t.track))
            }
        }
        return (speakers, utterances)
    }

    /// После повторного разделения голосов возвращает спикерам имена, которые пользователь уже назначал.
    nonisolated static func carryOverNames(from old: [Speaker], to new: [Speaker]) -> [Speaker] {
        var result = new
        let named = old.filter { !$0.isUser && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && $0.embedding != nil }
        var pairs: [(score: Float, old: Int, new: Int)] = []
        for (i, source) in named.enumerated() {
            for (j, target) in result.enumerated() where !target.isUser {
                guard let a = source.embedding, let b = target.embedding else { continue }
                let score = VoiceLibrary.cosine(a, b)
                if score >= 0.5 { pairs.append((score, i, j)) }
            }
        }
        var usedOld = Set<Int>(), usedNew = Set<Int>()
        for pair in pairs.sorted(by: { $0.score > $1.score }) where !usedOld.contains(pair.old) && !usedNew.contains(pair.new) {
            usedOld.insert(pair.old)
            usedNew.insert(pair.new)
            let source = named[pair.old]
            result[pair.new].name = source.name
            result[pair.new].company = source.company
            result[pair.new].side = source.side
            result[pair.new].voiceID = source.voiceID
            result[pair.new].autoIdentified = source.autoIdentified
        }
        return result
    }

    nonisolated private static func speaker(for segment: RawSegment, in diar: DiarOutput) -> String {
        guard !diar.segments.isEmpty else { return "0" }
        var overlaps: [String: Double] = [:]
        for d in diar.segments {
            let overlap = min(segment.end, d.end) - max(segment.start, d.start)
            if overlap > 0 { overlaps[d.speaker, default: 0] += overlap }
        }
        if let best = overlaps.max(by: { $0.value < $1.value }) { return best.key }
        let middle = (segment.start + segment.end) / 2
        let nearest = diar.segments.min {
            abs(($0.start + $0.end) / 2 - middle) < abs(($1.start + $1.end) / 2 - middle)
        }
        return nearest?.speaker ?? "0"
    }

    nonisolated private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 })
    }

    /// Убирает фрагменты-эхо: те, чьи слова в основном звучат в то же время на другой дорожке,
    /// причём другая дорожка в этом промежутке передаёт сказанное полнее.
    nonisolated private static func removeEchoes(from own: [RawSegment], against other: [RawSegment],
                                                 dropOnTie: Bool) -> [RawSegment] {
        guard !own.isEmpty, !other.isEmpty else { return own }
        let ownWords = own.map { words($0.text) }
        let otherWords = other.map { words($0.text) }

        func region(_ segments: [RawSegment], _ wordSets: [Set<String>], from start: Double, to end: Double) -> Set<String> {
            var result = Set<String>()
            for (index, candidate) in segments.enumerated() {
                if candidate.start > end { break }
                if candidate.end < start { continue }
                result.formUnion(wordSets[index])
            }
            return result
        }

        return own.enumerated().filter { index, segment in
            let mine = ownWords[index]
            guard mine.count >= 2 else { return true }
            let start = segment.start - 1.5, end = segment.end + 1.5
            let theirs = region(other, otherWords, from: start, to: end)
            guard !theirs.isEmpty else { return true }
            let contained = Double(mine.intersection(theirs).count) / Double(mine.count)
            guard contained >= 0.5 else { return true }
            let ours = region(own, ownWords, from: start, to: end)
            let isEcho = ours.count < theirs.count || (ours.count == theirs.count && dropOnTie)
            return !isEcho
        }.map(\.element)
    }
}
