import AppKit
import SwiftUI

enum MeetingTab: String, CaseIterable, Identifiable {
    case transcript = "Транскрипция"
    case participants = "Участники"
    case summary = "Саммари"
    case followUp = "Follow-up"
    var id: String { rawValue }

    /// Отладка вёрстки: `--tab participants` открывает карточку встречи на нужной вкладке.
    static var initial: MeetingTab {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--tab"), i + 1 < args.count else { return .summary }
        switch args[i + 1] {
        case "transcript": return .transcript
        case "participants": return .participants
        case "followup": return .followUp
        default: return .summary
        }
    }
}

struct MeetingDetailView: View {
    let meetingID: UUID

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var pipeline: ProcessingPipeline
    @EnvironmentObject private var player: SegmentPlayer
    @EnvironmentObject private var governor: LoadGovernor
    @EnvironmentObject private var calendar: CalendarService

    @ViewState private var tab: MeetingTab = .initial
    @ViewState private var title = ""
    @FocusState private var titleFocused: Bool
    @ViewState private var confirmDelete = false
    @ViewState private var confirmReprocess = false
    @ViewState private var confirmDeleteAudio = false

    var body: some View {
        if let meeting = store.meeting(meetingID) {
            content(meeting)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        header(meeting)
                        Divider()
                    }
                    .background(.bar)
                }
            .onAppear {
                title = meeting.title
                if meeting.awaitingParticipants { tab = .participants }
            }
            // Запись распознана и ждёт имён участников — сразу показываем их.
            .onChange(of: meeting.awaitingParticipants) { _, awaiting in
                if awaiting, !meeting.unnamedSpeakers.isEmpty { tab = .participants }
            }
            .onChange(of: meeting.title) { _, new in if !titleFocused { title = new } }
            .onDisappear { player.stop() }
            .alert("Не получилось", isPresented: Binding(
                get: { state.cutError != nil }, set: { if !$0 { state.cutError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(state.cutError ?? "")
            }
            .confirmationDialog("Удалить встречу?", isPresented: $confirmDelete) {
                Button("Удалить", role: .destructive) {
                    player.stop()
                    store.delete(meetingID)
                    state.selection = store.meetings.first.map { .meeting($0.id) }
                }
            } message: {
                Text("Будут удалены запись, транскрипция, саммари и документы этой встречи в базе знаний. Отменить это нельзя.")
            }
            .confirmationDialog("Обработать встречу заново?", isPresented: $confirmReprocess) {
                Button("Обработать заново", role: .destructive) { pipeline.enqueue(meetingID, mode: .full) }
            } message: {
                Text("Запись будет распознана заново. Ручные правки транскрипции и участников этой встречи будут заменены.")
            }
            .confirmationDialog("Удалить аудиозапись?", isPresented: $confirmDeleteAudio) {
                Button("Удалить аудио", role: .destructive) {
                    player.stop()
                    store.deleteAudio(meetingID)
                }
            } message: {
                Text("Транскрипция и саммари сохранятся, но прослушать реплики и распознать запись заново будет нельзя.")
            }
        }
    }

    // MARK: Заголовок

    @ViewBuilder
    private func header(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Название встречи", text: $title)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .focused($titleFocused)
                    .onSubmit { commitTitle() }
                    .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }

                Menu {
                    Button("Показать в базе знаний") { state.revealInKnowledgeBase(meetingID) }
                    if calendar.authorized {
                        Menu("Событие календаря") {
                            let sameDay = calendar.events.filter { Calendar.current.isDate($0.start, inSameDayAs: meeting.startedAt) }
                                .sorted { $0.start < $1.start }
                            ForEach(sameDay) { event in
                                Button {
                                    state.attach(event, to: meetingID)
                                } label: {
                                    let label = "\(Fmt.hm.string(from: event.start)) — \(event.title)"
                                    if meeting.calendar?.id == event.id { Label(label, systemImage: "checkmark") } else { Text(label) }
                                }
                            }
                            if sameDay.isEmpty { Text("В этот день событий нет") }
                            if meeting.calendar != nil {
                                Divider()
                                Button("Отвязать событие") { state.detachCalendar(meetingID) }
                            }
                        }
                    }
                    Divider()
                    Button("Обработать заново…") { confirmReprocess = true }
                        .disabled(!meeting.hasAudio || meeting.status == .recording || pipeline.isQueued(meetingID))
                    Button("Удалить аудиозапись…") { confirmDeleteAudio = true }
                        .disabled(!meeting.hasAudio || meeting.status == .recording || pipeline.isQueued(meetingID))
                    Divider()
                    Button("Удалить встречу…", role: .destructive) { confirmDelete = true }
                        .disabled(meeting.status == .recording)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            Text(subtitle(meeting))
                .font(.callout)
                .foregroundStyle(.secondary)

            if let progress = pipeline.progress[meetingID] {
                HStack(spacing: 10) {
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction).frame(maxWidth: 260)
                        Text("\(progress.stage) · \(Int(fraction * 100))%")
                    } else {
                        if !pipeline.paused.contains(meetingID) { ProgressView().controlSize(.small) } else { Image(systemName: "pause.circle") }
                        Text(progress.stage)
                    }
                    if pipeline.paused.contains(meetingID) {
                        Button("Обработать сейчас") { governor.resumeNow() }
                            .controlSize(.small)
                            .help("Продолжить, не дожидаясь конца звонка. Компьютер может тормозить")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            if let message = meeting.errorMessage, meeting.status == .failed || meeting.status == .ready {
                HStack(alignment: .firstTextBaseline) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if meeting.status == .failed, !pipeline.isQueued(meetingID) {
                        Button("Повторить") { pipeline.enqueue(meetingID, mode: .resume) }
                    }
                }
                .font(.callout)
            }

            if meeting.status == .ready || meeting.status == .failed, !pipeline.isQueued(meetingID) {
                ForEach(meeting.splitMarks, id: \.self) { mark in
                    HStack(spacing: 10) {
                        Label("Во время записи звонок сменился на отметке \(Fmt.clock(mark.time)). Похоже, это две разные встречи.",
                              systemImage: "scissors")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Разделить") { Task { await state.splitMeeting(meetingID, at: mark.time) } }
                            .disabled(!state.canCut(meetingID))
                        Button("Это одна встреча") { state.dismissSplitMark(meetingID, mark) }
                    }
                    .font(.callout)
                    .controlSize(.small)
                    .padding(8)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            if state.cutInProgress.contains(meetingID) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Запись разделяется…")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Picker("", selection: $tab) {
                ForEach(MeetingTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 520)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func subtitle(_ meeting: Meeting) -> String {
        var parts = [
            Fmt.dayLong.string(from: meeting.startedAt),
            "\(Fmt.hm.string(from: meeting.startedAt))–\(Fmt.hm.string(from: meeting.endedAt))",
            Fmt.duration(meeting.duration),
        ]
        let people = meeting.activeSpeakers.count
        if people > 0 { parts.append("участников: \(people)") }
        if let event = meeting.calendar { parts.append("приглашено: \(event.attendees.count)") }
        if !meeting.hasAudio { parts.append("аудио удалено") }
        return parts.joined(separator: " · ")
    }

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let meeting = store.meeting(meetingID), !trimmed.isEmpty, trimmed != meeting.title else {
            title = store.meeting(meetingID)?.title ?? title
            return
        }
        store.update(meetingID) {
            $0.title = trimmed
            $0.titleIsCustom = true
        }
    }

    // MARK: Содержимое

    @ViewBuilder
    private func content(_ meeting: Meeting) -> some View {
        if meeting.status == .recording {
            RecordingPanel()
        } else {
            switch tab {
            case .transcript: TranscriptTab(meeting: meeting)
            case .participants: ParticipantsTab(meeting: meeting)
            case .summary: SummaryTab(meeting: meeting, showParticipants: { tab = .participants })
            case .followUp: FollowUpTab(meeting: meeting)
            }
        }
    }
}

/// Схематичный индикатор и таймер в карточке встречи, пока идёт запись. Без анимации:
/// непрерывная перерисовка окна заметно нагружала компьютер во время звонков и демонстрации экрана.
struct RecordingPanel: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var recorder: RecordingController

    var body: some View {
        let recording = recorder.state == .recording
        VStack(spacing: 18) {
            HStack(spacing: 8) {
                Circle()
                    .fill(recording ? Color.red : Color.orange)
                    .frame(width: 10, height: 10)
                Text(recording ? "Идёт запись" : "Пауза")
                    .font(.title3.weight(.medium))
            }
            Text(Fmt.clock(recorder.elapsed))
                .font(.system(size: 44, weight: .light).monospacedDigit())

            Image(systemName: recording ? "waveform" : "pause")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(recording ? Color.red : Color.orange)
                .frame(height: 90)
                .accessibilityHidden(true)

            HStack(spacing: 12) {
                if recording {
                    Button { recorder.pause() } label: { Label("Пауза", systemImage: "pause.fill") }
                } else {
                    Button { recorder.resume() } label: { Label("Продолжить", systemImage: "play.fill") }
                }
                Button { state.stopRecording() } label: { Label("Завершить запись", systemImage: "stop.fill") }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            .controlSize(.large)

            Text("Транскрипция и саммари появятся после завершения встречи.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

func placeholder(_ icon: String, _ title: String, _ text: String) -> some View {
    VStack(spacing: 8) {
        Image(systemName: icon)
            .font(.system(size: 36))
            .foregroundStyle(.tertiary)
        Text(title).font(.title3).foregroundStyle(.secondary)
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
}

enum SpeakerPalette {
    private static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo, .mint, .red]

    static func color(for speakerID: String, in meeting: Meeting) -> Color {
        let index = meeting.speakers.firstIndex { $0.id == speakerID } ?? 0
        return colors[index % colors.count]
    }
}

// MARK: - Транскрипция

/// Что сделать со встречей относительно выбранной реплики.
enum CutAction: Identifiable {
    case split(Utterance), dropBefore(Utterance), dropAfter(Utterance)
    var id: String {
        switch self {
        case .split(let u): return "split-\(u.id)"
        case .dropBefore(let u): return "before-\(u.id)"
        case .dropAfter(let u): return "after-\(u.id)"
        }
    }
}

struct TranscriptTab: View {
    let meeting: Meeting
    @EnvironmentObject private var state: AppState
    @ViewState private var filter = ""
    @ViewState private var pendingCut: CutAction?

    /// Граница проходит чуть раньше начала реплики, чтобы не срезать её первый слог.
    private func boundary(_ utterance: Utterance) -> Double { max(0, utterance.start - 0.3) }

    private var cutTitle: String {
        switch pendingCut {
        case .split(let u): return "Разделить встречу на отметке \(Fmt.clock(u.start))?"
        case .dropBefore(let u): return "Удалить всё до отметки \(Fmt.clock(u.start))?"
        case .dropAfter(let u): return "Удалить всё начиная с отметки \(Fmt.clock(u.start))?"
        case nil: return ""
        }
    }

    private var cutMessage: String {
        switch pendingCut {
        case .split: return "Всё до этой реплики останется в этой встрече, а эта реплика и всё после неё станут новой встречей. Саммари обеих частей будут сформированы заново."
        case .dropBefore, .dropAfter: return "Удалённая часть записи и транскрипции не восстанавливается. Саммари будет сформировано заново."
        case nil: return ""
        }
    }

    private func perform(_ action: CutAction) {
        Task {
            switch action {
            case .split(let u): await state.splitMeeting(meeting.id, at: boundary(u))
            case .dropBefore(let u): await state.trimMeeting(meeting.id, from: boundary(u), to: meeting.duration)
            case .dropAfter(let u): await state.trimMeeting(meeting.id, from: 0, to: boundary(u))
            }
        }
    }

    private var shown: [Utterance] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return meeting.utterances }
        return meeting.utterances.filter { $0.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    var body: some View {
        if meeting.utterances.isEmpty {
            placeholder("text.quote", meeting.status.isProcessing ? "Запись обрабатывается" : "Транскрипции нет",
                        meeting.status.isProcessing ? "Текст появится после распознавания речи." : "В записи не найдено речи.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(shown) { utterance in
                        UtteranceRow(meeting: meeting, utterance: utterance, onCut: { pendingCut = $0 })
                    }
                }
                .padding(20)
            }
            .confirmationDialog(cutTitle, isPresented: Binding(get: { pendingCut != nil }, set: { if !$0 { pendingCut = nil } }),
                                presenting: pendingCut) { action in
                switch action {
                case .split: Button("Разделить") { perform(action) }
                case .dropBefore, .dropAfter: Button("Удалить", role: .destructive) { perform(action) }
                }
            } message: { _ in
                Text(cutMessage)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if meeting.hasAudio {
                        FullAudioBar(meeting: meeting)
                        Divider()
                    }
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Поиск по транскрипции", text: $filter)
                            .textFieldStyle(.plain)
                        Text("Реплик: \(shown.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    Divider()
                }
                .background(.bar)
            }
        }
    }
}

struct UtteranceRow: View {
    let meeting: Meeting
    let utterance: Utterance
    var onCut: (CutAction) -> Void = { _ in }

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var player: SegmentPlayer
    @ViewState private var text: String
    @FocusState private var focused: Bool

    init(meeting: Meeting, utterance: Utterance, onCut: @escaping (CutAction) -> Void = { _ in }) {
        self.meeting = meeting
        self.utterance = utterance
        self.onCut = onCut
        _text = State(initialValue: utterance.text)
    }

    private var key: String { "u-\(utterance.id.uuidString)" }

    var body: some View {
        let speaker = meeting.speaker(utterance.speakerID)
        HStack(alignment: .top, spacing: 10) {
            Button {
                player.toggle(key: key, urls: state.audioURLs(meeting.id, track: utterance.track),
                              start: utterance.start, end: utterance.end)
            } label: {
                Image(systemName: player.playingKey == key ? "stop.circle.fill" : "play.circle")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(meeting.hasAudio ? Color.accentColor : Color.secondary)
            .disabled(!meeting.hasAudio)
            .help(meeting.hasAudio ? "Прослушать реплику" : "Аудио удалено")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(meeting.speakers) { candidate in
                            Button {
                                state.reassignUtterance(meeting.id, utterance.id, to: candidate.id)
                            } label: {
                                if candidate.id == utterance.speakerID {
                                    Label(candidate.displayName, systemImage: "checkmark")
                                } else {
                                    Text(candidate.displayName)
                                }
                            }
                        }
                        Divider()
                        Button("Новый спикер") { state.reassignUtteranceToNewSpeaker(meeting.id, utterance.id) }
                        // В реплику попали слова двух человек: делим её и меняем автора у нужной части.
                        let sentences = AppState.sentences(utterance.text)
                        if sentences.count > 1 {
                            Divider()
                            Menu("Разделить реплику перед фразой…") {
                                ForEach(1..<sentences.count, id: \.self) { index in
                                    Button("«\(String(sentences[index].prefix(48)))\(sentences[index].count > 48 ? "…" : "")»") {
                                        commit()
                                        state.splitUtterance(meeting.id, utterance.id, beforeSentence: index)
                                    }
                                }
                            }
                        }
                    } label: {
                        Text(speaker?.displayName ?? "Спикер")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(SpeakerPalette.color(for: utterance.speakerID, in: meeting))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Изменить автора реплики или разделить её")

                    Text(Fmt.clock(utterance.start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if utterance.edited {
                        Text("изменено")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Menu {
                        Button("Разделить встречу с этой реплики…") { onCut(.split(utterance)) }
                        Divider()
                        Button("Удалить всё до этой реплики…") { onCut(.dropBefore(utterance)) }
                        Button("Удалить эту реплику и всё после…") { onCut(.dropAfter(utterance)) }
                    } label: {
                        Image(systemName: "scissors")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(!state.canCut(meeting.id))
                    .help("Разделить или обрезать встречу в этом месте")
                }
                TextField("", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineSpacing(3)
                    .focused($focused)
                    .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                    .onChange(of: utterance.text) { _, new in if !focused { text = new } }
                    .onDisappear { commit() }
            }
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != utterance.text else { return }
        state.editUtterance(meeting.id, utterance.id, text: trimmed)
    }
}

// MARK: - Участники

extension ParticipantsTab {
    /// Саммари ждёт имён участников.
    @ViewBuilder
    fileprivate var summaryNotice: some View {
        if meeting.awaitingParticipants {
            let left = meeting.unnamedSpeakers.count
            HStack(spacing: 10) {
                Image(systemName: left == 0 ? "sparkles" : "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.secondary)
                Text(left == 0 ? "Все участники названы — саммари сейчас начнёт формироваться."
                     : "Саммари будет сформировано, когда вы назовёте участников (осталось: \(left)). Так его не придётся переделывать.")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if left > 0 {
                    Button("Сформировать сейчас") { state.generateSummary(meeting.id) }
                        .disabled(!models.llmReady)
                }
            }
            .font(.callout)
            .padding(10)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Состав встречи по календарю: кто из приглашённых говорил, а кого в записи не слышно.
    @ViewBuilder
    fileprivate var invited: some View {
        if let event = meeting.calendar, !event.attendees.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("По календарю: «\(event.title)»")
                    .font(.headline)
                ForEach(event.attendees) { attendee in
                    AttendeeRow(attendee: attendee, meeting: meeting)
                }
                Text("«Не говорил» значит, что голоса этого человека нет среди названных спикеров: он молчал, не пришёл или его спикер ещё не назван.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 6)
        }
    }

    /// Голоса разделены неверно (двое слились в одного или один разбит на нескольких).
    @ViewBuilder
    fileprivate var recount: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Голоса разделены неверно?")
                .font(.headline)
            Text("Если приложение нашло лишних спикеров или объединило двух человек в одного, укажите, сколько человек было на встрече\(meeting.imported ? "" : " (считая вас)"), — голоса будут разделены заново.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Picker(meeting.imported ? "Человек в записи" : "Участников, считая вас", selection: $speakerCount) {
                    Text("Определить автоматически").tag(0)
                    ForEach(1...10, id: \.self) { Text("\($0)").tag($0) }
                }
                .fixedSize()
                Button("Разделить голоса заново…") { confirmRediarize = true }
                    .disabled(!meeting.hasAudio || pipeline.isQueued(meeting.id))
            }
            Text("Отдельную реплику можно отдать другому или новому спикеру на вкладке «Транскрипция»: нажмите на имя автора. Там же реплику можно разделить, если в неё попали слова двух человек.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        .padding(.top, 8)
        .onAppear { speakerCount = meeting.speakerCountHint ?? 0 }
        .confirmationDialog("Разделить голоса заново?", isPresented: $confirmRediarize) {
            Button("Разделить заново") { state.rediarize(meeting.id, speakers: speakerCount == 0 ? nil : speakerCount) }
        } message: {
            Text("Текст распознаваться заново не будет, но реплики будут распределены между спикерами по-новому. Уже названные участники сохранят имена; ручные правки текста и авторства реплик будут заменены.")
        }
    }
}

/// Плеер полной записи встречи: обе дорожки вместе.
struct FullAudioBar: View {
    let meeting: Meeting
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var player: SegmentPlayer

    private var key: String { "full-\(meeting.id.uuidString)" }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                player.toggleFull(key: key, urls: state.audioURLs(meeting.id, track: .system) + state.audioURLs(meeting.id, track: .mic))
            } label: {
                Image(systemName: player.playingKey == key && !player.paused ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .help("Прослушать запись целиком")
            FullAudioSlider(clock: player.clock, total: meeting.duration) { player.seekFull(key: key, to: $0) }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .onAppear { if player.playingKey != key { player.resetClock(duration: meeting.duration) } }
        .onChange(of: meeting.id) { _, _ in player.resetClock(duration: meeting.duration) }
    }
}

private struct FullAudioSlider: View {
    @ObservedObject var clock: PlaybackClock
    let total: Double
    let seek: (Double) -> Void
    @ViewState private var dragged: Double?

    var body: some View {
        let length = max(1, clock.duration > 0 ? clock.duration : total)
        HStack(spacing: 10) {
            Text(Fmt.clock(dragged ?? clock.position))
                .monospacedDigit()
            Slider(value: Binding(get: { min(dragged ?? clock.position, length) }, set: { dragged = $0 }), in: 0...length) { editing in
                if !editing, let target = dragged {
                    seek(target)
                    dragged = nil
                }
            }
            .controlSize(.small)
            Text(Fmt.clock(length))
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct ParticipantsTab: View {
    let meeting: Meeting

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var pipeline: ProcessingPipeline
    @EnvironmentObject private var models: ModelManager
    @ViewState private var speakerCount = 0
    @ViewState private var confirmRediarize = false

    var body: some View {
        let speakers = meeting.activeSpeakers
        if speakers.isEmpty {
            placeholder("person.2", meeting.status.isProcessing ? "Запись обрабатывается" : "Участники не определены",
                        "Участники появятся после распознавания записи.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Назовите участников — имена, компании и стороны попадут в саммари, follow-up и базу знаний. Названные голоса приложение будет узнавать на следующих встречах.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    summaryNotice
                    invited
                    ForEach(speakers) { speaker in
                        SpeakerCard(meeting: meeting, speaker: speaker)
                            .id(speaker.id)
                    }
                    recount
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SpeakerCard: View {
    let meeting: Meeting
    let speaker: Speaker

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var player: SegmentPlayer
    @EnvironmentObject private var voices: VoiceLibrary
    @ViewState private var name: String
    @ViewState private var company: String
    @FocusState private var focus: Field?

    private enum Field { case name, company }

    init(meeting: Meeting, speaker: Speaker) {
        self.meeting = meeting
        self.speaker = speaker
        _name = State(initialValue: speaker.name)
        _company = State(initialValue: speaker.company)
    }

    private var own: [Utterance] { meeting.utterances.filter { $0.speakerID == speaker.id } }
    private var key: String { "s-\(speaker.id)" }

    var body: some View {
        let color = SpeakerPalette.color(for: speaker.id, in: meeting)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(speaker.label)
                    .font(.headline)
                if speaker.isUser {
                    badge("это вы", .blue)
                } else if speaker.autoIdentified {
                    badge("узнан по голосу", .green)
                    Button("Не тот человек") {
                        state.rejectIdentification(meeting.id, speaker.id)
                        name = ""
                        company = ""
                    }
                    .controlSize(.small)
                    .help("Приложение ошиблось: снять имя. Сохранённый голос этого человека не изменится")
                }
                Spacer()
                Text("Реплик: \(own.count) · \(Fmt.duration(own.reduce(0) { $0 + ($1.end - $1.start) }))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                TextField("Имя", text: $name)
                    .focused($focus, equals: .name)
                TextField("Компания", text: $company)
                    .focused($focus, equals: .company)
                Picker("Сторона", selection: Binding(
                    get: { speaker.side },
                    set: { side in state.updateSpeaker(meeting.id, speaker.id) { $0.side = side } }
                )) {
                    ForEach(Side.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit { commit() }
            .onChange(of: focus) { _, new in if new == nil { commit() } }
            .onChange(of: speaker.name) { _, new in if focus != .name { name = new } }
            .onChange(of: speaker.company) { _, new in if focus != .company { company = new } }

            // Человек с таким именем уже есть — предлагаем выбрать его, а не заводить заново.
            if !speaker.isUser, focus == .name {
                let found = matches
                if !found.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(found) { person in
                            Button {
                                name = person.name
                                company = person.company
                                state.identify(meeting.id, speaker.id, as: person)
                                focus = nil
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "person.crop.circle")
                                    Text(person.name)
                                    if !person.company.isEmpty { Text(person.company).foregroundStyle(.secondary) }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 3)
                        }
                    }
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                }
            }

            // Подсказки из календаря: приглашённые, которым ещё не сопоставлен спикер.
            if !speaker.isUser, speaker.name.isEmpty {
                let invitees = state.unassignedInvitees(meeting).prefix(6)
                if !invitees.isEmpty {
                    HStack(spacing: 8) {
                        Text("Из календаря:")
                            .foregroundStyle(.secondary)
                        ForEach(Array(invitees)) { attendee in
                            Button(attendee.name) { state.identify(meeting.id, speaker.id, as: attendee) }
                        }
                    }
                    .font(.callout)
                    .controlSize(.small)
                }
            }

            // Имя не подставлено само (голос не узнан уверенно или похож сразу на нескольких знакомых) —
            // предлагаем варианты на выбор.
            if !speaker.isUser, speaker.name.isEmpty, let embedding = speaker.embedding {
                let similar = VoiceLibrary.candidates(embedding, in: voices.voices, excluding: speaker.rejectedVoices ?? []).prefix(3)
                if !similar.isEmpty {
                    HStack(spacing: 8) {
                        Text("Похож на:")
                            .foregroundStyle(.secondary)
                        ForEach(Array(similar), id: \.voice.id) { candidate in
                            Button(candidate.voice.name) { state.identify(meeting.id, speaker.id, as: candidate.voice) }
                        }
                    }
                    .font(.callout)
                    .controlSize(.small)
                }
            }

            HStack(spacing: 12) {
                Button {
                    if let sample = meeting.voiceSample(for: speaker.id) {
                        player.toggle(key: key, urls: state.audioURLs(meeting.id, track: sample.track),
                                      start: sample.start, end: sample.end)
                    }
                } label: {
                    Label(player.playingKey == key ? "Остановить" : "Прослушать образец голоса",
                          systemImage: player.playingKey == key ? "stop.fill" : "play.fill")
                }
                .disabled(!meeting.hasAudio || own.isEmpty)

                let others = meeting.activeSpeakers.filter { $0.id != speaker.id }
                if !others.isEmpty {
                    Menu("Объединить с…") {
                        ForEach(others) { other in
                            Button(other.displayName) {
                                commit()
                                state.mergeSpeaker(meeting.id, source: speaker.id, into: other.id)
                            }
                        }
                    }
                    .fixedSize()
                    .help("Если один человек определён как несколько спикеров, объедините их")
                }
                if let voiceID = speaker.voiceID, voices.voice(voiceID) != nil {
                    Button("Карточка человека") { state.selection = .person(voiceID) }
                        .help("Все встречи с этим человеком и сводка договорённостей")
                }
                Spacer()
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .onDisappear { commit() }
    }

    /// Знакомые люди, подходящие под набираемое имя: каждое набранное слово — начало слова в имени или компании.
    private var matches: [KnownVoice] {
        let words = Self.words(name)
        guard !words.isEmpty else { return [] }
        let taken = Set(meeting.speakers.filter { $0.id != speaker.id }.compactMap(\.voiceID))
        return voices.voices.filter { person in
            guard !taken.contains(person.id), !(speaker.rejectedVoices ?? []).contains(person.id) else { return false }
            // Этот человек уже выбран и имя набрано полностью — подсказывать нечего.
            if person.id == speaker.voiceID, person.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame { return false }
            let target = Self.words(person.name + " " + person.company)
            return words.allSatisfy { word in target.contains { $0.hasPrefix(word) } }
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        .prefix(6).map { $0 }
    }

    private static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).replacingOccurrences(of: "ё", with: "е")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
    }

    private func commit() {
        let newName = name.trimmingCharacters(in: .whitespaces)
        let newCompany = company.trimmingCharacters(in: .whitespaces)
        guard newName != speaker.name || newCompany != speaker.company else { return }
        state.updateSpeaker(meeting.id, speaker.id) {
            $0.name = newName
            $0.company = newCompany
        }
    }
}
