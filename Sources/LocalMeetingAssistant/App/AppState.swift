import AppKit
import Combine
import Foundation

enum SidebarSelection: Hashable {
    case meeting(UUID)
    /// Карточка человека.
    case person(UUID)
    /// Событие календаря.
    case event(String)
    case settings
}

/// Разделы нижнего меню.
enum SidebarTab: String, CaseIterable, Identifiable {
    case people, meetings, calendar, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .people: return "Люди"
        case .meetings: return "Встречи"
        case .calendar: return "Календарь"
        case .settings: return "Настройки"
        }
    }

    var icon: String {
        switch self {
        case .people: return "person.crop.circle.fill"
        case .meetings: return "bubble.left.and.bubble.right.fill"
        case .calendar: return "calendar"
        case .settings: return "gearshape.fill"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let settings = AppSettings.shared
    let store = MeetingStore()
    let voices = VoiceLibrary()
    let player = SegmentPlayer()
    let dictation = Dictation()
    let models: ModelManager
    let recorder: RecordingController
    let pipeline: ProcessingPipeline
    let governor: LoadGovernor
    let menuBar = MenuBarModel()
    let calendar: CalendarService
    private var menuBarObserver: AnyCancellable?

    private let monitor = MicActivityMonitor()
    private let notifier = Notifier()

    @Published var tab: SidebarTab = .meetings
    /// Что открыто справа. Раздел нижнего меню подстраивается под выбранное.
    @Published var selection: SidebarSelection? {
        didSet {
            switch selection {
            case .settings: if tab != .settings { tab = .settings }
            case .person: if tab != .people { tab = .people }
            case .event: if tab != .calendar { tab = .calendar }
            case .meeting: if tab == .settings || tab == .people { tab = .meetings }
            case nil: break
            }
        }
    }
    /// Приложение, которое сейчас использует микрофон (предложение начать запись).
    @Published var startSuggestion: String?
    /// Звонок, похоже, закончился (предложение завершить запись).
    @Published var stopSuggestion = false
    /// Почему предлагается завершить запись.
    @Published private(set) var stopReason = ""
    private var suggestedCall: DetectedCall?
    /// Напоминание о тишине уже показано для текущей паузы в разговоре.
    private var silenceSuggested = false
    private var summaryWork: [UUID: DispatchWorkItem] = [:]
    private var summaryFallback: [UUID: DispatchWorkItem] = [:]

    /// Через сколько секунд после последней правки участников запускается саммари.
    private let summarySettleDelay: TimeInterval = 5
    /// Если участников так и не назвали, саммари формируется само через это время.
    private let summaryFallbackDelay: TimeInterval = 600
    /// Сколько секунд тишины собеседников считается признаком конца встречи.
    private let silenceLimit: TimeInterval = 180

    @Published private(set) var followUpBusy: Set<UUID> = []
    @Published private(set) var liveFollowUp: [UUID: String] = [:]
    @Published var followUpError: [UUID: String] = [:]
    @Published var knowledgeBaseError: String?
    @Published private(set) var importsInProgress = 0
    @Published var importError: String?

    /// Во время записи сменился звонок: отметка времени, на которой предлагается разделить запись.
    @Published var splitSuggestion: SplitMark?
    @Published var cutInProgress: Set<UUID> = []
    @Published var cutError: String?

    @Published var digestBusy: Set<UUID> = []
    @Published var liveDigest: [UUID: String] = [:]
    @Published var digestError: [UUID: String] = [:]
    var digestTasks: [UUID: Task<Void, Never>] = [:]

    var openMainWindow: (() -> Void)?

    private var exportWork: [UUID: DispatchWorkItem] = [:]
    private var followUpTasks: [UUID: Task<Void, Never>] = [:]
    private var bootstrapped = false
    /// Только для `--demo-recording`: встреча-заглушка, которая не сохраняется на диск.
    @Published private(set) var demoMeeting: Meeting?
    private var modelsObserver: AnyCancellable?
    private var hadWhisper = false
    private var hadLLM = false

    private init() {
        models = ModelManager(settings: settings)
        recorder = RecordingController(store: store)
        governor = LoadGovernor(settings: settings)
        calendar = CalendarService(settings: settings)
        pipeline = ProcessingPipeline(store: store, models: models, settings: settings, voices: voices, governor: governor)
    }

    // MARK: Запуск

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true

        store.load()
        voices.load()
        store.onChange = { [weak self] meeting in self?.scheduleExport(meeting.id) }
        store.onDelete = { [weak self] meeting in self?.removeFromKnowledgeBase(meeting) }

        recorder.onFinished = { [weak self] id in
            guard let self else { return }
            self.stopSuggestion = false
            self.splitSuggestion = nil
            self.notifier.clearSuggestions()
            self.selection = .meeting(id)
            self.linkCalendarEvents()
            // Подтверждённые смены звонка: одна запись превращается в несколько встреч.
            let marks = (self.store.meeting(id)?.splitMarks ?? []).filter(\.confirmed).map(\.time).sorted(by: >)
            guard !marks.isEmpty else {
                self.pipeline.enqueue(id, mode: .full)
                return
            }
            Task {
                var parts = [id]
                for time in marks {
                    if let part = await self.splitMeeting(id, at: time, process: true) { parts.insert(part, at: 1) }
                }
                self.store.update(id) { $0.splitMarks.removeAll(where: \.confirmed) }
                for part in parts { self.pipeline.enqueue(part, mode: .full) }
            }
        }

        notifier.onStart = { [weak self] in self?.startRecording() }
        notifier.onStop = { [weak self] in self?.recorder.stop() }
        notifier.onOpen = { [weak self] in self?.showMainWindow() }
        notifier.setup()

        notifier.onNever = { [weak self] in self?.ignoreSuggestedApp() }
        notifier.onSplit = { [weak self] in self?.confirmSplit() }
        notifier.onSameMeeting = { [weak self] in self?.rejectSplit() }
        pipeline.onAwaitingParticipants = { [weak self] id in self?.awaitingParticipants(id) }

        monitor.isIgnoredByUser = { [weak self] bundleID in self?.settings.ignoredApps[bundleID] != nil }
        monitor.onCallSwitched = { [weak self] lostAt in self?.callSwitched(at: lostAt) }
        monitor.onCallStarted = { [weak self] call in
            guard let self else { return }
            // Запись идёт, прежний звонок закончился, начался новый — вероятно, это уже другая встреча.
            if self.recorder.isActive, let ended = self.monitor.lastCallEnd { self.callSwitched(at: ended) }
            guard self.settings.suggestStart, !self.recorder.isActive else { return }
            self.suggestedCall = call
            self.startSuggestion = call.name
            self.notifier.suggestStart(app: call.name)
        }
        monitor.onCallEnded = { [weak self] in
            guard let self else { return }
            self.startSuggestion = nil
            self.suggestedCall = nil
            if self.recorder.isActive, self.settings.suggestStop {
                self.suggestStop("Звонок, похоже, завершён.")
            } else {
                self.notifier.clearSuggestions()
            }
        }
        monitor.onPoll = { [weak self] in
            guard let self else { return }
            self.checkSilence()
            self.governor.update(recording: self.recorder.isActive, callApp: self.monitor.micUser)
        }
        // Начался звонок или запись: освобождаем память и видеоускоритель от языковой модели.
        // Follow-up пользователь запросил сам и ждёт его — его не прерываем.
        governor.onPause = { [weak self] in
            guard let self else { return }
            guard self.settings.llmEngine.loadsThisMac else { return }
            self.pipeline.suspendForPause()
            if self.followUpBusy.isEmpty, self.digestBusy.isEmpty { Task { await LlamaServer.shared.stop() } }
        }
        // Режим просмотра вёрстки (`--snapshot`): только показываем окно и ничего не меняем —
        // не обрабатываем встречи, не следим за микрофоном, не чистим аудио.
        let inspectOnly = CommandLine.arguments.contains("--snapshot")
        if !inspectOnly { monitor.start() }

        // Строка меню получает только то, что на ней видно, и только при изменении.
        menuBarObserver = Publishers.CombineLatest4(recorder.$state, $startSuggestion, $stopSuggestion, pipeline.$queue)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recording, start, stop, queue in
                self?.menuBar.update(recording: recording, startSuggestion: start, stopSuggestion: stop,
                                     processing: !queue.isEmpty)
            }

        models.engines.refresh()
        if !inspectOnly {
            calendar.onChange = { [weak self] in self?.linkCalendarEvents() }
        }
        calendar.start()
        hadWhisper = models.whisper == .installed
        hadLLM = models.llmReady
        modelsObserver = models.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in
            self?.modelsChanged()
        }

        if !inspectOnly {
            recoverInterruptedMeetings()
            applyAudioRetention()
            // Индекс базы знаний пересобирается при каждом запуске — на случай, если папку меняли вручную.
            writeIndex()
        }
        if !inspectOnly {
            for meeting in store.meetings where meeting.awaitingParticipants { scheduleSummaryFallback(meeting.id) }
        }
        if selection == nil, let first = store.meetings.first { selection = .meeting(first.id) }

        // Для автоматизированной установки: `open -a "Local Meeting Assistant" --args --install-models`.
        let arguments = CommandLine.arguments
        // `--import <файл>` — импортировать запись при запуске (автоматизация и проверка).
        if let index = arguments.firstIndex(of: "--import"), index + 1 < arguments.count {
            importFiles([URL(fileURLWithPath: arguments[index + 1])])
        }
        // `--split <id встречи> <секунды>` — разделить встречу при запуске (проверка деления).
        if let index = arguments.firstIndex(of: "--split"), index + 2 < arguments.count,
           let id = UUID(uuidString: arguments[index + 1]), let time = Double(arguments[index + 2]) {
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await splitMeeting(id, at: time)
            }
        }
        if arguments.contains("--install-models") {
            Task { await models.installAllMissing() }
        }
        // Отладка вёрстки: `--snapshot <файл.png>` сохраняет изображение главного окна.
        if arguments.contains("--show-settings") { selection = .settings }
        if arguments.contains("--show-person"), let voice = voices.voices.first { selection = .person(voice.id) }
        if arguments.contains("--demo-recording") {
            recorder.showDemoRecording()
            var demo = Meeting(title: Meeting.defaultTitle(for: Date()), startedAt: Date())
            demo.status = .recording
            demoMeeting = demo
        }
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            let path = arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { Self.snapshotMainWindow(to: path) }
        }
    }

    func shutdown() {
        if recorder.isActive { recorder.stop() }
        LlamaServer.terminateNow()
    }

    /// Как только нужная модель установлена, дообрабатываем встречи, которые её ждали.
    private func modelsChanged() {
        let hasWhisper = models.whisper == .installed
        let hasLLM = models.llmReady
        if hasWhisper, !hadWhisper {
            for meeting in store.meetings
            where meeting.status == .failed && meeting.hasAudio && meeting.utterances.isEmpty && !pipeline.isQueued(meeting.id) {
                pipeline.enqueue(meeting.id, mode: .resume)
            }
        }
        if hasLLM, !hadLLM {
            for meeting in store.meetings
            where meeting.status == .ready && meeting.summary.isEmpty && !meeting.utterances.isEmpty
                && !meeting.awaitingParticipants && !pipeline.isQueued(meeting.id) {
                pipeline.enqueue(meeting.id, mode: .summaryOnly)
            }
        }
        hadWhisper = hasWhisper
        hadLLM = hasLLM
    }

    /// Встречи, запись или обработка которых прервалась (сбой, выход из приложения), возвращаются в очередь.
    private func recoverInterruptedMeetings() {
        for meeting in store.meetings {
            switch meeting.status {
            case .recording:
                let mic = store.micURL(meeting.id), system = store.systemURL(meeting.id)
                WAVWriter.repair(url: mic)
                WAVWriter.repair(url: system)
                let seconds = Double(max(WAVReader.sampleCount(mic), WAVReader.sampleCount(system))) / 16_000
                if seconds < 1 {
                    store.delete(meeting.id)
                } else {
                    store.update(meeting.id) { $0.duration = seconds }
                    pipeline.enqueue(meeting.id, mode: .full)
                }
            case .queued, .transcribing, .diarizing:
                pipeline.enqueue(meeting.id, mode: .resume)
            case .summarizing:
                pipeline.enqueue(meeting.id, mode: .summaryOnly)
            case .ready, .failed:
                break
            }
        }
    }

    private func applyAudioRetention() {
        let days = settings.audioRetentionDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for meeting in store.meetings where meeting.hasAudio && meeting.status == .ready && meeting.startedAt < cutoff {
            store.deleteAudio(meeting.id)
        }
    }

    private static func snapshotMainWindow(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        var info = "window \(window.frame) content \(window.contentView?.frame ?? .zero) layoutRect \(window.contentLayoutRect)\n"
        func dump(_ v: NSView, _ depth: Int) {
            guard depth < 14 else { return }
            let f = v.convert(v.bounds, to: nil)
            info += String(repeating: "  ", count: depth) + "\(type(of: v)) x=\(Int(f.minX)) y=\(Int(f.minY)) w=\(Int(f.width)) h=\(Int(f.height))\(v.isHidden ? " HIDDEN" : "")\n"
            for sub in v.subviews { dump(sub, depth + 1) }
        }
        dump(view, 0)
        try? info.write(toFile: path + ".txt", atomically: true, encoding: .utf8)
    }

    // MARK: Импорт файлов

    func chooseFilesToImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = AudioImporter.allowedTypes
        panel.message = "Аудио- или видеозапись встречи"
        panel.prompt = "Импортировать"
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    /// Превращает готовые аудио- и видеофайлы во встречи и ставит их в очередь обработки.
    func importFiles(_ urls: [URL]) {
        for url in urls {
            importsInProgress += 1
            Task {
                defer { importsInProgress -= 1 }
                let values = try? url.resourceValues(forKeys: [.creationDateKey])
                var meeting = Meeting(title: url.deletingPathExtension().lastPathComponent,
                                      startedAt: values?.creationDate ?? Date())
                meeting.titleIsCustom = false
                meeting.imported = true
                meeting.status = .queued
                let folder = store.dir(meeting.id)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    // Импортированная запись — одна общая дорожка; участников разделяет диаризация.
                    let destination = store.systemURL(meeting.id)
                    meeting.duration = try await Task.detached { try await AudioImporter.convert(url, to: destination) }.value
                    store.add(meeting)
                    linkCalendarEvents()
                    pipeline.enqueue(meeting.id, mode: .full)
                    selection = .meeting(meeting.id)
                } catch {
                    try? FileManager.default.removeItem(at: folder)
                    importError = error.localizedDescription
                }
            }
        }
    }

    // MARK: Запись

    func startRecording() {
        let source = startSuggestion
        startSuggestion = nil
        notifier.clearSuggestions()
        Task {
            await recorder.start(sourceApp: source)
            if let id = recorder.meetingID { selection = .meeting(id) }
            if recorder.errorMessage != nil { showMainWindow() }
        }
    }

    func stopRecording() {
        recorder.stop()
    }

    func dismissSuggestions() {
        startSuggestion = nil
        stopSuggestion = false
        notifier.clearSuggestions()
    }

    /// Звонок сменился во время записи: запоминаем отметку и предлагаем разделить запись на две встречи.
    private func callSwitched(at moment: Date) {
        guard recorder.state == .recording, let id = recorder.meetingID else { return }
        let time = recorder.currentElapsed - Date().timeIntervalSince(moment)
        guard time > 60, let meeting = store.meeting(id),
              !meeting.splitMarks.contains(where: { abs($0.time - time) < 60 }) else { return }
        let mark = SplitMark(time: time)
        store.update(id) { $0.splitMarks.append(mark) }
        stopSuggestion = false
        guard settings.suggestStop else { return }
        splitSuggestion = mark
        notifier.suggestSplit(at: time)
    }

    /// «Это другая встреча»: после остановки запись будет разделена на этой отметке.
    func confirmSplit() {
        guard let mark = splitSuggestion, let id = recorder.meetingID else { return }
        store.update(id) { meeting in
            if let index = meeting.splitMarks.firstIndex(of: mark) { meeting.splitMarks[index].confirmed = true }
        }
        splitSuggestion = nil
        notifier.clearSuggestions()
    }

    /// «Это та же встреча»: отметку убираем.
    func rejectSplit() {
        if let mark = splitSuggestion, let id = recorder.meetingID { dismissSplitMark(id, mark) }
        splitSuggestion = nil
        notifier.clearSuggestions()
    }

    /// Больше не предлагать запись, когда это приложение использует микрофон.
    func ignoreSuggestedApp() {
        if let call = suggestedCall { settings.ignoredApps[call.bundleID] = call.name }
        suggestedCall = nil
        dismissSuggestions()
    }

    var canIgnoreSuggestedApp: Bool { suggestedCall != nil }

    private func suggestStop(_ reason: String) {
        stopReason = reason
        stopSuggestion = true
        notifier.suggestStop(reason: reason)
    }

    /// Собеседники звучали, а теперь давно молчат — вероятно, встреча закончилась, а запись забыли остановить.
    private func checkSilence() {
        guard recorder.state == .recording, settings.suggestStop, let silence = recorder.systemSilence else {
            silenceSuggested = false
            return
        }
        if silence < silenceLimit {
            silenceSuggested = false
        } else if !silenceSuggested, !stopSuggestion {
            silenceSuggested = true
            suggestStop("Собеседников не слышно уже \(Int(silenceLimit / 60)) минуты.")
        }
    }

    func showMainWindow() {
        openMainWindow?()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSettings() {
        selection = .settings
        showMainWindow()
    }

    // MARK: Правки встречи

    /// Дорожка, на которой звучит реплика. Вторую дорожку не подмешиваем: иначе вместе с репликой
    /// слышно всё, что в это же время говорили остальные.
    func audioURLs(_ id: UUID, track: Track) -> [URL] {
        switch track {
        case .system: return [store.systemURL(id)]
        case .mic:
            let clean = store.cleanMicURL(id)
            return [FileManager.default.fileExists(atPath: clean.path) ? clean : store.micURL(id)]
        }
    }

    /// Участники или авторство реплик изменились. Саммари, которое сейчас генерируется, уже устарело —
    /// прерываем его и формируем заново, когда все участники названы.
    private func participantsChanged(_ id: UUID) {
        if pipeline.isSummaryPending(id) {
            pipeline.cancelSummary(id)
            store.update(id) { $0.awaitingParticipants = true }
        }
        guard store.meeting(id)?.awaitingParticipants == true else { return }
        summaryWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.summaryWork[id] = nil
            guard let meeting = self.store.meeting(id), meeting.awaitingParticipants,
                  meeting.unnamedSpeakers.isEmpty, !self.pipeline.isQueued(id) else { return }
            self.generateSummary(id)
        }
        summaryWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + summarySettleDelay, execute: work)
        scheduleSummaryFallback(id)
    }

    private func awaitingParticipants(_ id: UUID) {
        scheduleSummaryFallback(id)
        let count = store.meeting(id)?.unnamedSpeakers.count ?? 0
        notifier.info(title: "Встреча распознана",
                      body: "Назовите участников (\(count)) — после этого будет сформировано саммари.")
    }

    private func scheduleSummaryFallback(_ id: UUID) {
        summaryFallback[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.summaryFallback[id] = nil
            guard let meeting = self.store.meeting(id), meeting.awaitingParticipants, !self.pipeline.isQueued(id) else { return }
            self.generateSummary(id)
        }
        summaryFallback[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + summaryFallbackDelay, execute: work)
    }

    /// Формирует саммари сейчас (заново, если оно как раз генерируется).
    func generateSummary(_ id: UUID) {
        summaryWork[id]?.cancel()
        summaryWork[id] = nil
        summaryFallback[id]?.cancel()
        summaryFallback[id] = nil
        store.update(id) { $0.awaitingParticipants = false }
        pipeline.requestSummary(id)
    }

    /// Замечание к саммари: сохраняется как дополнительное указание модели, саммари формируется заново.
    func submitSummaryFeedback(_ id: UUID, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.update(id) { $0.summaryFeedback.append(trimmed) }
        generateSummary(id)
    }

    func removeSummaryFeedback(_ id: UUID, at index: Int) {
        store.update(id) { meeting in
            guard meeting.summaryFeedback.indices.contains(index) else { return }
            meeting.summaryFeedback.remove(at: index)
            if !meeting.summary.isEmpty { meeting.summaryStale = true }
        }
    }

    /// Заново разделить голоса, считая, что на встрече было `count` человек вместе с владельцем записи (nil — определить автоматически).
    func rediarize(_ id: UUID, speakers count: Int?) {
        guard !pipeline.isQueued(id) else { return }
        player.stop()
        store.update(id) { $0.speakerCountHint = count }
        pipeline.enqueue(id, mode: .rediarize)
    }

    /// Делит реплику на две перед фразой с номером `sentence` (вторая часть остаётся за тем же спикером,
    /// после чего её автора можно сменить). Время делится пропорционально длине текста.
    func splitUtterance(_ meetingID: UUID, _ utteranceID: UUID, beforeSentence sentence: Int) {
        store.update(meetingID) { meeting in
            guard let index = meeting.utterances.firstIndex(where: { $0.id == utteranceID }) else { return }
            let original = meeting.utterances[index]
            let sentences = Self.sentences(original.text)
            guard sentence > 0, sentence < sentences.count else { return }
            let head = sentences[..<sentence].joined(separator: " ")
            let tail = sentences[sentence...].joined(separator: " ")
            let share = Double(head.count) / Double(max(1, head.count + tail.count))
            let cut = original.start + (original.end - original.start) * share
            var first = original, second = original
            first.text = head
            first.end = cut
            second.id = UUID()
            second.text = tail
            second.start = cut
            meeting.utterances.replaceSubrange(index...index, with: [first, second])
        }
    }

    nonisolated static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let characters = Array(text)
        for (i, character) in characters.enumerated() {
            current.append(character)
            let next = i + 1 < characters.count ? characters[i + 1] : " "
            if ".!?…".contains(character), next == " " {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { result.append(trimmed) }
        return result
    }

    func editUtterance(_ meetingID: UUID, _ utteranceID: UUID, text: String) {
        store.update(meetingID) { meeting in
            guard let index = meeting.utterances.firstIndex(where: { $0.id == utteranceID }) else { return }
            meeting.utterances[index].text = text
            meeting.utterances[index].edited = true
            if !meeting.summary.isEmpty { meeting.summaryStale = true }
        }
    }

    func reassignUtterance(_ meetingID: UUID, _ utteranceID: UUID, to speakerID: String) {
        store.update(meetingID) { meeting in
            guard let index = meeting.utterances.firstIndex(where: { $0.id == utteranceID }) else { return }
            meeting.utterances[index].speakerID = speakerID
            if !meeting.summary.isEmpty { meeting.summaryStale = true }
        }
        participantsChanged(meetingID)
    }

    /// Создаёт нового спикера и относит к нему реплику.
    func reassignUtteranceToNewSpeaker(_ meetingID: UUID, _ utteranceID: UUID) {
        store.update(meetingID) { meeting in
            guard let index = meeting.utterances.firstIndex(where: { $0.id == utteranceID }) else { return }
            var number = meeting.speakers.count + 1
            while meeting.speakers.contains(where: { $0.id == "s\(number)" || $0.label == "Спикер \(number)" }) { number += 1 }
            let speaker = Speaker(id: "s\(number)", label: "Спикер \(number)")
            meeting.speakers.append(speaker)
            meeting.utterances[index].speakerID = speaker.id
            if !meeting.summary.isEmpty { meeting.summaryStale = true }
        }
        participantsChanged(meetingID)
    }

    func updateSpeaker(_ meetingID: UUID, _ speakerID: String, _ mutate: (inout Speaker) -> Void) {
        var updated: Speaker?
        store.update(meetingID) { meeting in
            guard let index = meeting.speakers.firstIndex(where: { $0.id == speakerID }) else { return }
            mutate(&meeting.speakers[index])
            meeting.speakers[index].autoIdentified = false
            // Спикеру дали имя другого человека (например, приложение ошиблось, узнавая голос):
            // это новый знакомый голос, а прежний переименовывать нельзя.
            if let voiceID = meeting.speakers[index].voiceID,
               let voice = voices.voices.first(where: { $0.id == voiceID }),
               VoiceLibrary.isDifferentPerson(voice.name, meeting.speakers[index].name) {
                meeting.speakers[index].voiceID = nil
                meeting.speakers[index].rejectedVoices = (meeting.speakers[index].rejectedVoices ?? []) + [voiceID]
            }
            updated = meeting.speakers[index]
            if !meeting.summary.isEmpty { meeting.summaryStale = true }
        }
        syncEmails(meetingID)
        // Запоминаем голос названного участника, чтобы узнавать его на следующих встречах.
        if let updated, let voiceID = voices.remember(updated), voiceID != updated.voiceID {
            store.update(meetingID) { meeting in
                if let index = meeting.speakers.firstIndex(where: { $0.id == speakerID }) {
                    meeting.speakers[index].voiceID = voiceID
                }
            }
        }
        participantsChanged(meetingID)
    }

    /// «Это не он»: приложение неверно узнало голос. Имя снимается, знакомый голос остаётся как был.
    func rejectIdentification(_ meetingID: UUID, _ speakerID: String) {
        store.update(meetingID) { meeting in
            guard let index = meeting.speakers.firstIndex(where: { $0.id == speakerID }) else { return }
            if let voiceID = meeting.speakers[index].voiceID {
                meeting.speakers[index].rejectedVoices = (meeting.speakers[index].rejectedVoices ?? []) + [voiceID]
            }
            meeting.speakers[index].name = ""
            meeting.speakers[index].company = ""
            meeting.speakers[index].side = .other
            meeting.speakers[index].voiceID = nil
            meeting.speakers[index].autoIdentified = false
            if !meeting.summary.isEmpty { meeting.summaryStale = true }
        }
        participantsChanged(meetingID)
    }

    /// Пользователь подтвердил, что спикер — это знакомый голос из списка похожих.
    func identify(_ meetingID: UUID, _ speakerID: String, as voice: KnownVoice) {
        updateSpeaker(meetingID, speakerID) {
            $0.name = voice.name
            $0.company = voice.company
            $0.side = voice.side
            $0.voiceID = voice.id
        }
    }

    /// Объединяет двух спикеров: все реплики `source` переходят к `target`.
    func mergeSpeaker(_ meetingID: UUID, source: String, into target: String) {
        guard source != target else { return }
        store.update(meetingID) { meeting in
            for index in meeting.utterances.indices where meeting.utterances[index].speakerID == source {
                meeting.utterances[index].speakerID = target
            }
            meeting.speakers.removeAll { $0.id == source }
            if !meeting.summary.isEmpty { meeting.summaryStale = true }
        }
        participantsChanged(meetingID)
    }

    // MARK: Follow-up

    func generateFollowUp(_ id: UUID, format: FollowUpFormat) {
        guard !followUpBusy.contains(id), let meeting = store.meeting(id) else { return }
        guard let client = models.llmClient(gpu: settings.performanceMode.usesGPU) else {
            followUpError[id] = models.llmUnavailableReason
            return
        }
        followUpBusy.insert(id)
        followUpError[id] = nil
        liveFollowUp[id] = ""
        let ai = MeetingAI(client: client, userName: settings.userDisplayName, userCompany: settings.userCompany)
        followUpTasks[id] = Task {
            do {
                let text = try await ai.followUp(meeting, format: format) { partial in
                    Task { @MainActor in
                        if self.followUpBusy.contains(id) { self.liveFollowUp[id] = partial }
                    }
                }
                store.update(id) {
                    $0.followUp = text
                    $0.followUpFormat = format
                }
            } catch is CancellationError {
            } catch {
                followUpError[id] = error.localizedDescription
            }
            followUpBusy.remove(id)
            liveFollowUp[id] = nil
            followUpTasks[id] = nil
        }
    }

    func cancelFollowUp(_ id: UUID) {
        followUpTasks[id]?.cancel()
    }

    // MARK: База знаний

    private var knowledgeBase: KnowledgeBase { KnowledgeBase(root: settings.knowledgeBaseURL) }

    private func scheduleExport(_ id: UUID) {
        // Идущая запись в базу знаний не выгружается: выгружать пока нечего.
        if store.meeting(id)?.status == .recording { return }
        exportWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.exportWork[id] = nil
            self?.export(id)
            self?.writeIndex()
        }
        exportWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func export(_ id: UUID) {
        guard let meeting = store.meeting(id), meeting.status == .ready || meeting.status == .failed,
              !meeting.utterances.isEmpty else { return }
        do {
            let path = try knowledgeBase.export(meeting)
            if path != meeting.kbPath { store.setKnowledgeBasePath(id, path) }
            knowledgeBaseError = nil
        } catch {
            knowledgeBaseError = "Не удалось записать в базу знаний: \(error.localizedDescription)"
        }
    }

    private func writeIndex() {
        do { try knowledgeBase.writeIndex(store.meetings) } catch {
            knowledgeBaseError = "Не удалось обновить индекс базы знаний: \(error.localizedDescription)"
        }
    }

    private func removeFromKnowledgeBase(_ meeting: Meeting) {
        exportWork[meeting.id]?.cancel()
        knowledgeBase.remove(meeting)
        writeIndex()
    }

    /// Полная повторная выгрузка (после смены папки базы знаний).
    func exportAll() {
        for meeting in store.meetings {
            store.setKnowledgeBasePath(meeting.id, nil)
            export(meeting.id)
        }
        writeIndex()
    }

    func revealInKnowledgeBase(_ id: UUID) {
        let root = settings.knowledgeBaseURL
        if let path = store.meeting(id)?.kbPath {
            NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(path)])
        } else {
            NSWorkspace.shared.open(root)
        }
    }
}
