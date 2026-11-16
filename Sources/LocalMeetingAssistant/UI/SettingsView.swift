import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var models: ModelManager
    @EnvironmentObject private var voices: VoiceLibrary

    @ViewState private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @ViewState private var confirmDeleteAudio = false
    @ViewState private var audioBytes: Int64 = 0
    @ViewState private var modelBytes: Int64 = 0

    var body: some View {
        Form {
            Section("Профиль") {
                TextField("Ваше имя", text: $settings.userName, prompt: Text("Например, Алексей Иванов"))
                TextField("Ваша компания", text: $settings.userCompany)
                TextField("Ваш e-mail", text: $settings.userEmails, prompt: Text("Несколько адресов — через запятую"))
                    .onChange(of: settings.userEmails) { _, _ in state.ownEmailsChanged() }
                Text("Имя и компания подписывают ваши реплики и follow-up. По e-mail приложение узнаёт вас среди приглашённых в календаре.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("База знаний для AI-агентов") {
                LabeledContent("Папка") {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(settings.knowledgeBasePath)
                            .font(.callout)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        HStack {
                            Button("Выбрать…") { chooseKnowledgeBase() }
                            Button("Показать в Finder") {
                                try? FileManager.default.createDirectory(at: settings.knowledgeBaseURL, withIntermediateDirectories: true)
                                NSWorkspace.shared.open(settings.knowledgeBaseURL)
                            }
                            Button("Выгрузить всё заново") { state.exportAll() }
                        }
                    }
                }
                Text("Сюда автоматически сохраняются транскрипции и саммари (Markdown и JSON). Подключите эту папку к AI-агенту — он сможет находить встречи по дате, участникам, компаниям и содержанию. Follow-up в папку не попадает.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = state.knowledgeBaseError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            CalendarSettings(calendar: state.calendar)

            Section("Запись") {
                Toggle("Предлагать начать запись, когда начался звонок", isOn: $settings.suggestStart)
                Toggle("Предлагать завершить запись, когда встреча закончилась", isOn: $settings.suggestStop)
                Text("Звонком считается приложение, которое одновременно слушает микрофон и воспроизводит звук собеседников. Диктовка, голосовые сообщения и диктофон предложения не вызывают. Конец встречи определяется по завершению звонка или по долгой тишине собеседников.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !settings.ignoredApps.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Не предлагать запись для приложений")
                        ForEach(settings.ignoredApps.sorted { $0.value < $1.value }, id: \.key) { bundleID, name in
                            HStack {
                                Text(name).foregroundStyle(.secondary)
                                Spacer()
                                Button("Убрать") { settings.ignoredApps[bundleID] = nil }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                Toggle("Запускать при входе в систему", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Text("Запись никогда не начинается сама — только после вашего подтверждения.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Локальные модели") {
                Picker("Распознавание речи", selection: $settings.whisperVariant) {
                    ForEach(WhisperCatalog.all) { Text("\($0.title) (\($0.size))").tag($0.id) }
                }
                .onChange(of: settings.whisperVariant) { _, _ in models.refresh() }
                ModelRow(title: "Модель распознавания речи", status: models.whisper,
                         install: { Task { await models.installWhisper() } },
                         delete: { models.deleteWhisper() })

                ModelRow(title: "Определение участников по голосу", detail: "≈0,1 ГБ", status: models.diarizer,
                         install: { Task { await models.installDiarizer() } },
                         delete: { models.deleteDiarizer() })

                EngineSection(engines: models.engines)

                if settings.llmEngine == .builtin {
                    Picker("Встроенная модель", selection: $settings.llmModelID) {
                        ForEach(LLMCatalog.all) { Text("\($0.title) (\(Fmt.bytes($0.bytes)))").tag($0.id) }
                        Text("Свой файл GGUF").tag(LLMCatalog.customID)
                    }
                    .onChange(of: settings.llmModelID) { _, _ in models.refresh() }
                }

                if settings.llmEngine != .builtin {
                    EmptyView()
                } else if settings.llmModelID == LLMCatalog.customID {
                    LabeledContent("Файл модели") {
                        HStack {
                            Text(settings.customLLMPath.isEmpty ? "не выбран" : (settings.customLLMPath as NSString).lastPathComponent)
                                .foregroundStyle(.secondary)
                            Button("Выбрать…") { chooseCustomModel() }
                        }
                    }
                } else {
                    ModelRow(title: "Языковая модель", status: models.selectedLLMStatus,
                             install: { Task { await models.installLLM(settings.llmModelID) } },
                             delete: { models.deleteLLM(settings.llmModelID) },
                             cancel: { models.cancelLLMDownload(settings.llmModelID) })
                }

                HStack {
                    Button("Скачать всё необходимое") { Task { await models.installAllMissing() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(models.allInstalled || models.anyBusy)
                    Spacer()
                    Text("Модели занимают \(Fmt.bytes(modelBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Распознавание речи и определение участников всегда работают на этом Mac. Интернет нужен для скачивания моделей и — если для саммари выбрана облачная модель — для её работы.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Нагрузка на компьютер") {
                Picker("Режим обработки", selection: $settings.performanceMode) {
                    ForEach(PerformanceMode.allCases) { Text($0.title).tag($0) }
                }
                Text(settings.performanceMode.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Саммари и follow-up") {
                Picker("Формировать саммари", selection: $settings.summaryTiming) {
                    ForEach(SummaryTiming.allCases) { Text($0.title).tag($0) }
                }
                Text("Саммари с безымянными «Спикер 1», «Спикер 2» приходится переделывать, поэтому по умолчанию приложение ждёт, пока вы назовёте участников. Если все голоса узнаны автоматически или вы не назвали участников за 10 минут, саммари формируется само.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Формат саммари", selection: $settings.summaryStyle) {
                    ForEach(SummaryStyle.allCases) { Text($0.title).tag($0) }
                }
                Picker("Формат follow-up по умолчанию", selection: $settings.followUpFormat) {
                    ForEach(FollowUpFormat.allCases) { Text($0.title).tag($0) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Словарь терминов")
                    TextEditor(text: $settings.glossary)
                        .font(.callout)
                        .frame(height: 60)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    Text("Названия продуктов, компаний и технические термины через запятую — подсказка для распознавания речи. Например: API, webhook, Kubernetes, Телемост.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Эхо") {
                Picker("Эхоподавление", selection: $settings.echoMode) {
                    ForEach(EchoMode.allCases) { Text($0.title).tag($0) }
                }
                Text("Когда встреча идёт через колонки, голоса собеседников попадают в микрофон и реплики двоятся. Приложение замечает это и очищает дорожку микрофона перед распознаванием. В наушниках эхо не возникает.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Аудиозаписи") {
                Picker("Хранить аудио", selection: $settings.audioRetentionDays) {
                    Text("Всегда").tag(0)
                    Text("7 дней").tag(7)
                    Text("30 дней").tag(30)
                    Text("90 дней").tag(90)
                }
                LabeledContent("Занято аудиозаписями", value: Fmt.bytes(audioBytes))
                Button("Удалить аудио всех обработанных встреч…", role: .destructive) { confirmDeleteAudio = true }
                    .disabled(audioBytes == 0)
                Text("Транскрипции и саммари при удалении аудио сохраняются. Старые записи удаляются при запуске приложения.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .navigationTitle("Настройки")
        .onAppear { refreshSizes() }
        .onChange(of: models.anyBusy) { _, _ in refreshSizes() }
        .confirmationDialog("Удалить аудио всех обработанных встреч?", isPresented: $confirmDeleteAudio) {
            Button("Удалить аудио", role: .destructive) {
                state.player.stop()
                for meeting in store.meetings where meeting.hasAudio && meeting.status == .ready {
                    store.deleteAudio(meeting.id)
                }
                refreshSizes()
            }
        } message: {
            Text("Транскрипции и саммари сохранятся, но прослушать реплики и распознать записи заново будет нельзя.")
        }
    }

    private func refreshSizes() {
        audioBytes = store.totalAudioBytes
        modelBytes = models.modelsDiskUsage
    }

    private func chooseKnowledgeBase() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        panel.message = "Папка, в которую будут сохраняться транскрипции и саммари"
        if panel.runModal() == .OK, let url = panel.url {
            settings.knowledgeBasePath = url.path
            state.exportAll()
        }
    }

    private func chooseCustomModel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        panel.message = "Файл языковой модели в формате GGUF"
        if panel.runModal() == .OK, let url = panel.url {
            settings.customLLMPath = url.path
            models.refresh()
        }
    }
}

/// Выбор движка для саммари, follow-up и сводок. Движки и их модели приложение находит само.
struct EngineSection: View {
    @ObservedObject var engines: EngineDiscovery
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Picker("Саммари и follow-up готовит", selection: $settings.llmEngine) {
            ForEach(LLMEngine.allCases) { engine in
                let found = engine == .builtin || engines.info(engine).available
                Text(engine.title + (found ? "" : " — не найден")).tag(engine)
            }
        }
        .onAppear { engines.refresh() }

        let engine = settings.llmEngine
        if engine != .builtin {
            let info = engines.info(engine)
            if info.available, !info.models.isEmpty {
                Picker("Модель", selection: Binding(
                    get: {
                        let chosen = settings.engineModels[engine.rawValue] ?? ""
                        return info.models.contains { $0.id == chosen } ? chosen : info.models[0].id
                    },
                    set: { settings.engineModels[engine.rawValue] = $0 }
                )) {
                    ForEach(info.models) { Text($0.title).tag($0.id) }
                }
            }
            if !info.note.isEmpty {
                Label(info.note, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                if let binary = info.binary {
                    Text(binary.path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(engines.scanning ? "Поиск…" : "Найти заново") { engines.refresh() }
                    .controlSize(.small)
                    .disabled(engines.scanning)
            }
            Text(engine.isLocal
                 ? "Модель работает на этом Mac, текст встречи никуда не передаётся. Память и видеоускоритель она занимает так же, как встроенная."
                 : "Внимание: транскрипция встречи отправляется в облако \(engine == .claude ? "Anthropic" : "OpenAI") через программу \(engine == .claude ? "Claude Code" : "Codex") и ваш вход в ней. Зато память этого Mac не занята, а длинные встречи обрабатываются за один проход. Ответ появляется целиком, а не по словам.")
                .font(.caption)
                .foregroundStyle(engine.isLocal ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Подключение календаря.
struct CalendarSettings: View {
    @ObservedObject var calendar: CalendarService
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var state: AppState

    var body: some View {
        Section("Календарь") {
            if calendar.authorized {
                Toggle("Использовать события календаря", isOn: $settings.calendarEnabled)
                    .onChange(of: settings.calendarEnabled) { _, _ in calendar.reload() }
                if settings.calendarEnabled {
                    ForEach(calendar.sources) { source in
                        Toggle(isOn: Binding(
                            get: { !settings.disabledCalendars.contains(source.id) },
                            set: { on in
                                if on { settings.disabledCalendars.removeAll { $0 == source.id } }
                                else { settings.disabledCalendars.append(source.id) }
                                calendar.reload()
                            }
                        )) {
                            Text(source.title) + Text(source.account.isEmpty ? "" : "  ·  \(source.account)").foregroundStyle(.secondary)
                        }
                    }
                    if calendar.sources.isEmpty {
                        Text("В календарях macOS пока ничего нет.").foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack {
                    Text(calendar.denied ? "Доступ к календарям запрещён" : "Календарь не подключён")
                    Spacer()
                    if calendar.denied {
                        Button("Открыть настройки доступа") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    } else {
                        Button("Подключить календарь") { Task { await calendar.connect() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            Text("Приложение читает календари macOS — те же, что видны в программе «Календарь». Чтобы подключить Google Календарь, добавьте аккаунт Google в «Системные настройки → Учётные записи интернета» и включите для него «Календари». Отдельный вход в Google приложению не нужен, события читаются на этом Mac. По календарю встреча получает тему и список приглашённых — видно, кто из них говорил, а кто нет.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if calendar.authorized, !calendar.denied {
                Button("Открыть «Учётные записи интернета»") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
    }
}

struct ModelRow: View {
    let title: String
    var detail: String?
    let status: ModelStatus
    let install: () -> Void
    let delete: () -> Void
    var cancel: (() -> Void)?

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                switch status {
                case .missing:
                    Button("Скачать", action: install)
                case .downloading(let fraction):
                    if let fraction {
                        ProgressView(value: fraction).frame(width: 120)
                        Text("\(Int(fraction * 100))%").monospacedDigit()
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Скачивание…")
                    }
                    if let cancel { Button("Отмена", action: cancel) }
                case .preparing:
                    ProgressView().controlSize(.small)
                    Text("Подготовка…")
                case .installed:
                    Label("Установлена", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Удалить", action: delete)
                case .failed:
                    Button("Повторить", action: install)
                }
            }
            .controlSize(.small)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if case .failed(let message) = status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if case .preparing = status {
                    Text("Первая подготовка модели под этот Mac может занять несколько минут.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
