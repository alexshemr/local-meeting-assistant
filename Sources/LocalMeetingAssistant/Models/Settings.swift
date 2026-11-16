import Foundation

enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("LocalMeetingAssistant", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var meetings: URL { dir("Meetings") }
    static var models: URL { dir("Models") }
    static var whisperModels: URL { dir("Models/whisper") }
    static var diarizerModels: URL { dir("Models/diarizer") }
    static var llmModels: URL { dir("Models/llm") }
    static var voiceLibrary: URL { support.appendingPathComponent("voices.json") }

    static var defaultKnowledgeBase: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Meeting Knowledge Base", isDirectory: true)
    }

    private static func dir(_ name: String) -> URL {
        let url = support.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var userName: String { didSet { d.set(userName, forKey: "userName") } }
    @Published var userCompany: String { didSet { d.set(userCompany, forKey: "userCompany") } }
    @Published var knowledgeBasePath: String { didSet { d.set(knowledgeBasePath, forKey: "knowledgeBasePath") } }

    /// Предлагать начать запись, когда другое приложение включает микрофон.
    @Published var suggestStart: Bool { didSet { d.set(suggestStart, forKey: "suggestStart") } }
    /// Предлагать завершить запись, когда микрофон больше никем не используется.
    @Published var suggestStop: Bool { didSet { d.set(suggestStop, forKey: "suggestStop") } }

    @Published var summaryStyle: SummaryStyle { didSet { d.set(summaryStyle.rawValue, forKey: "summaryStyle") } }
    /// Когда формировать саммари: сразу после распознавания или после того, как названы участники.
    @Published var summaryTiming: SummaryTiming { didSet { d.set(summaryTiming.rawValue, forKey: "summaryTiming") } }
    /// Приложения, для которых не нужно предлагать запись: идентификатор → название.
    @Published var ignoredApps: [String: String] { didSet { d.set(ignoredApps, forKey: "ignoredApps") } }
    /// Насколько тяжёлой обработке можно нагружать компьютер.
    @Published var performanceMode: PerformanceMode { didSet { d.set(performanceMode.rawValue, forKey: "performanceMode") } }
    @Published var followUpFormat: FollowUpFormat { didSet { d.set(followUpFormat.rawValue, forKey: "followUpFormat") } }

    @Published var whisperVariant: String { didSet { d.set(whisperVariant, forKey: "whisperVariant") } }
    /// Чем готовить саммари: встроенная модель, Ollama, Claude Code или Codex.
    @Published var llmEngine: LLMEngine { didSet { d.set(llmEngine.rawValue, forKey: "llmEngine") } }
    /// Выбранная модель для каждого внешнего движка (пусто — модель по умолчанию).
    @Published var engineModels: [String: String] { didSet { d.set(engineModels, forKey: "engineModels") } }
    /// Использовать события календаря: тема встречи, состав приглашённых.
    @Published var calendarEnabled: Bool { didSet { d.set(calendarEnabled, forKey: "calendarEnabled") } }
    /// Календари, которые пользователь исключил.
    @Published var disabledCalendars: [String] { didSet { d.set(disabledCalendars, forKey: "disabledCalendars") } }
    @Published var llmModelID: String { didSet { d.set(llmModelID, forKey: "llmModelID") } }
    @Published var customLLMPath: String { didSet { d.set(customLLMPath, forKey: "customLLMPath") } }

    /// Термины и названия, которые подсказываются распознаванию речи.
    @Published var glossary: String { didSet { d.set(glossary, forKey: "glossary") } }
    /// Подавление эха, когда собеседников слышно в микрофон (встреча через колонки).
    @Published var echoMode: EchoMode { didSet { d.set(echoMode.rawValue, forKey: "echoMode") } }
    /// Через сколько дней удалять аудио обработанных встреч. 0 — хранить всегда.
    @Published var audioRetentionDays: Int { didSet { d.set(audioRetentionDays, forKey: "audioRetentionDays") } }

    private init() {
        userName = d.string(forKey: "userName") ?? ""
        userCompany = d.string(forKey: "userCompany") ?? ""
        knowledgeBasePath = d.string(forKey: "knowledgeBasePath") ?? AppPaths.defaultKnowledgeBase.path
        suggestStart = d.object(forKey: "suggestStart") as? Bool ?? true
        suggestStop = d.object(forKey: "suggestStop") as? Bool ?? true
        summaryStyle = SummaryStyle(rawValue: d.string(forKey: "summaryStyle") ?? "") ?? .standard
        summaryTiming = SummaryTiming(rawValue: d.string(forKey: "summaryTiming") ?? "") ?? .afterParticipants
        ignoredApps = d.dictionary(forKey: "ignoredApps") as? [String: String] ?? [:]
        performanceMode = PerformanceMode(rawValue: d.string(forKey: "performanceMode") ?? "") ?? .smart
        followUpFormat = FollowUpFormat(rawValue: d.string(forKey: "followUpFormat") ?? "") ?? .brief
        whisperVariant = d.string(forKey: "whisperVariant") ?? WhisperCatalog.defaultVariant
        llmEngine = LLMEngine(rawValue: d.string(forKey: "llmEngine") ?? "") ?? .builtin
        engineModels = d.dictionary(forKey: "engineModels") as? [String: String] ?? [:]
        calendarEnabled = d.bool(forKey: "calendarEnabled")
        disabledCalendars = d.stringArray(forKey: "disabledCalendars") ?? []
        llmModelID = d.string(forKey: "llmModelID") ?? LLMCatalog.defaultID
        customLLMPath = d.string(forKey: "customLLMPath") ?? ""
        glossary = d.string(forKey: "glossary") ?? ""
        echoMode = EchoMode(rawValue: d.string(forKey: "echoMode") ?? "") ?? .auto
        audioRetentionDays = d.integer(forKey: "audioRetentionDays")
    }

    var knowledgeBaseURL: URL { URL(fileURLWithPath: knowledgeBasePath, isDirectory: true) }
    var userDisplayName: String { userName.trimmingCharacters(in: .whitespaces).isEmpty ? "Я" : userName }
}

enum SummaryTiming: String, CaseIterable, Identifiable {
    case afterParticipants, immediately
    var id: String { rawValue }
    var title: String {
        switch self {
        case .afterParticipants: return "Когда названы все участники"
        case .immediately: return "Сразу после распознавания"
        }
    }
}

enum EchoMode: String, CaseIterable, Identifiable {
    case auto, always, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Автоматически, если обнаружено эхо"
        case .always: return "Всегда"
        case .off: return "Выключено"
        }
    }
}

struct WhisperModelInfo: Identifiable, Hashable {
    let id: String
    let title: String
    let size: String
}

enum WhisperCatalog {
    static let defaultVariant = "openai_whisper-large-v3-v20240930_turbo"
    static let all: [WhisperModelInfo] = [
        .init(id: "openai_whisper-large-v3-v20240930_turbo", title: "Whisper large-v3 turbo — лучшее качество", size: "≈1,6 ГБ"),
        .init(id: "openai_whisper-large-v3-v20240930_turbo_632MB", title: "Whisper large-v3 turbo, сжатая — быстрее и компактнее", size: "≈0,6 ГБ"),
    ]
}

struct LLMModelInfo: Identifiable, Hashable {
    let id: String
    let title: String
    let repo: String
    let file: String
    let bytes: Int64
    let sha256: String

    var url: URL { URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")! }
    var localURL: URL { AppPaths.llmModels.appendingPathComponent(file) }
}

enum LLMCatalog {
    static let defaultID = "gemma-4-12b"
    static let customID = "custom"
    static let all: [LLMModelInfo] = [
        .init(id: "gemma-4-12b", title: "Gemma 4 12B — лучшее качество саммари",
              repo: "unsloth/gemma-4-12b-it-GGUF", file: "gemma-4-12b-it-Q4_K_M.gguf",
              bytes: 7_120_000_000,
              sha256: "0a270ec9fe6b34f4a0d33992b6135117b484ebc4766ab76b51d4ae8c457e4c42"),
        .init(id: "gemma-4-e4b", title: "Gemma 4 E4B — быстрее, меньше памяти",
              repo: "unsloth/gemma-4-E4B-it-GGUF", file: "gemma-4-E4B-it-Q4_K_M.gguf",
              bytes: 4_980_000_000,
              sha256: "85a896a047553e842f25297ee5b031d64ff30147d9c4af17b1e4b394cd1fab87"),
    ]
    static func model(_ id: String) -> LLMModelInfo? { all.first { $0.id == id } }
}
