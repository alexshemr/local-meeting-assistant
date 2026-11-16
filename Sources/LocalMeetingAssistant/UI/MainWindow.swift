import AppKit
import SwiftUI

struct MainWindow: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var models: ModelManager
    @ViewState private var query = ""

    private var filtered: [Meeting] { store.meetings.filter { $0.matches(query) } }

    private var searchPrompt: String {
        switch state.tab {
        case .people: return "Поиск по людям"
        case .calendar: return "Поиск по календарю и встречам"
        default: return "Поиск по встречам"
        }
    }

    private var meetingsList: some View {
            List(selection: $state.selection) {
                ForEach(filtered) { meeting in
                    MeetingRow(meeting: meeting)
                        .tag(SidebarSelection.meeting(meeting.id))
                }
            }
            .overlay {
                if filtered.isEmpty {
                    Text(store.meetings.isEmpty ? "Встреч пока нет" : "Ничего не найдено")
                        .foregroundStyle(.secondary)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url, AudioImporter.isSupported(url) else { return }
                        Task { @MainActor in state.importFiles([url]) }
                    }
                }
                return true
            }
    }

    var body: some View {
        NavigationSplitView {
            Group {
                switch state.tab {
                case .meetings: meetingsList
                case .people: PeopleList(query: query)
                case .calendar: CalendarList(query: query)
                case .settings:
                    Text("Настройки открыты справа.\nСписок встреч — второй значок внизу.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                }
            }
            .alert("Не удалось импортировать файл", isPresented: Binding(
                get: { state.importError != nil }, set: { if !$0 { state.importError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(state.importError ?? "")
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 8) {
                    StatusCard()
                    if !models.allInstalled { SetupNotice() }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    SidebarTabBar()
                }
                .background(.bar)
            }
            .searchable(text: $query, placement: .sidebar, prompt: searchPrompt)
            // Явные идеальные размеры обязательны: без них колонка сообщает окну высоту всего
            // содержимого списка, и раскладка выходит за пределы окна.
            .frame(minHeight: 300, idealHeight: 500)
            .navigationSplitViewColumnWidth(min: 270, ideal: 310, max: 420)
        } detail: {
            Group {
                switch state.selection {
                case _ where state.demoMeeting != nil:
                    RecordingPanel()
                case .meeting(let id) where store.meeting(id) != nil:
                    MeetingDetailView(meetingID: id)
                        .id(id)
                case .person(let id):
                    PersonView(voiceID: id)
                        .id(id)
                case .event(let id):
                    EventDetailView(eventID: id)
                        .id(id)
                case .settings:
                    SettingsView()
                default:
                    EmptyState()
                }
            }
            .frame(minWidth: 560, idealWidth: 820, minHeight: 300, idealHeight: 500)
        }
        .onAppear { NSApp.setActivationPolicy(.regular) }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

// MARK: - Строка встречи

struct MeetingRow: View {
    let meeting: Meeting
    @EnvironmentObject private var pipeline: ProcessingPipeline

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title)
                .font(.body.weight(.medium))
                .lineLimit(2)
            Text("\(Fmt.dayShort.string(from: meeting.startedAt)), \(Fmt.hm.string(from: meeting.startedAt)) · \(Fmt.duration(meeting.duration))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if meeting.status == .recording {
                Label("Идёт запись", systemImage: "record.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let progress = pipeline.progress[meeting.id] {
                Text(progress.stage + (progress.fraction.map { " · \(Int($0 * 100))%" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            } else if meeting.status == .failed {
                Label("Ошибка обработки", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                let people = meeting.activeSpeakers.map(\.displayName).joined(separator: ", ")
                if !people.isEmpty {
                    Text(people)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Состояние записи

struct StatusCard: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var recorder: RecordingController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch recorder.state {
            case .idle:
                if let app = state.startSuggestion {
                    Text("В приложении «\(app)» идёт звонок. Записать встречу?")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button {
                        state.startRecording()
                    } label: {
                        Label("Начать запись", systemImage: "record.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    if state.startSuggestion != nil {
                        Menu("Не сейчас") {
                            Button("Не сейчас") { state.dismissSuggestions() }
                            if let app = state.startSuggestion, state.canIgnoreSuggestedApp {
                                Button("Не предлагать для «\(app)»") { state.ignoreSuggestedApp() }
                            }
                        } primaryAction: {
                            state.dismissSuggestions()
                        }
                        .controlSize(.large)
                        .fixedSize()
                    }
                }
                Button {
                    state.chooseFilesToImport()
                } label: {
                    if state.importsInProgress > 0 {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Импорт файла…")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label("Импортировать запись…", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(state.importsInProgress > 0)
                .help("Аудио или видео: MP3, M4A, WAV, MP4, MOV и другие. Можно перетащить файл в список встреч.")

            case .recording, .paused:
                HStack(spacing: 8) {
                    Circle()
                        .fill(recorder.state == .recording ? Color.red : Color.orange)
                        .frame(width: 10, height: 10)
                    Text(recorder.state == .recording ? "Идёт запись" : "Пауза")
                        .font(.headline)
                    Spacer()
                    Text(Fmt.clock(recorder.elapsed))
                        .font(.title3.monospacedDigit())
                }
                LevelMeter(title: "Микрофон", systemImage: "mic.fill", level: recorder.micLevel)
                LevelMeter(title: "Собеседники", systemImage: "speaker.wave.2.fill", level: recorder.systemLevel)

                if let mark = state.splitSuggestion {
                    Text("Звонок сменился на отметке \(Fmt.clock(mark.time)). Это другая встреча?")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Разделить запись") { state.confirmSplit() }
                        Button("Та же встреча") { state.rejectSplit() }
                    }
                    .controlSize(.small)
                }
                if state.stopSuggestion {
                    Text("\(state.stopReason) Завершить запись?")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if recorder.state == .recording {
                        Button { recorder.pause() } label: { Label("Пауза", systemImage: "pause.fill").frame(maxWidth: .infinity) }
                    } else {
                        Button { recorder.resume() } label: { Label("Продолжить", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    }
                    Button { state.stopRecording() } label: { Label("Завершить", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
                .controlSize(.large)
            }

            if let warning = recorder.systemAudioWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = recorder.errorMessage {
                Label(error, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct LevelMeter: View {
    let title: String
    let systemImage: String
    let level: Float

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Color.green)
                        .frame(width: geo.size.width * CGFloat(normalized))
                }
            }
            .frame(height: 5)
        }
        .help(title)
        .animation(.linear(duration: 0.2), value: level)
    }

    /// Логарифмическая шкала: −60 дБ … 0 дБ.
    private var normalized: Float {
        guard level > 0.001 else { return 0 }
        return max(0, min(1, (20 * log10(level) + 60) / 60))
    }
}

// MARK: - Подсказки

struct SetupNotice: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var models: ModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(models.anyBusy ? "Модели скачиваются…" : "Нужно скачать модели", systemImage: "arrow.down.circle")
                .font(.callout.weight(.medium))
            Text("Для распознавания речи и саммари нужны локальные модели. Интернет понадобится только один раз.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if models.anyBusy {
                ProgressView(value: overallProgress)
                Text(progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("Скачать модели") { Task { await models.installAllMissing() } }
                        .buttonStyle(.borderedProminent)
                    Button("Подробнее") { state.selection = .settings }
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

extension SetupNotice {
    private var busyStatus: (String, ModelStatus)? {
        if models.whisper.isBusy { return ("Распознавание речи", models.whisper) }
        if models.diarizer.isBusy { return ("Определение участников", models.diarizer) }
        if models.selectedLLMStatus.isBusy { return ("Языковая модель", models.selectedLLMStatus) }
        return nil
    }

    fileprivate var overallProgress: Double? {
        if case .downloading(let fraction)? = busyStatus?.1 { return fraction }
        return nil
    }

    fileprivate var progressText: String {
        guard let (name, status) = busyStatus else { return "" }
        switch status {
        case .downloading(let fraction?): return "\(name): \(Int(fraction * 100))%"
        case .preparing: return "\(name): подготовка под этот Mac…"
        default: return "\(name): скачивание…"
        }
    }
}

struct EmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("Выберите встречу или начните запись")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Запись, распознавание и саммари выполняются на этом компьютере.\nДанные никуда не передаются.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
