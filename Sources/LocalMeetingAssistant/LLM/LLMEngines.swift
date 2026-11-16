import Foundation

/// Чем готовить саммари, follow-up и сводки.
enum LLMEngine: String, CaseIterable, Identifiable {
    /// Встроенный движок llama.cpp с моделью Gemma — работает без интернета.
    case builtin
    /// Локальные модели Ollama, если она установлена на этом Mac.
    case ollama
    /// Claude Code — модель в облаке Anthropic, используется вход, выполненный в терминале.
    case claude
    /// Codex — модель в облаке OpenAI, используется вход, выполненный в терминале.
    case codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .builtin: return "Встроенная модель (на этом Mac)"
        case .ollama: return "Ollama (на этом Mac)"
        case .claude: return "Claude Code (облако Anthropic)"
        case .codex: return "Codex (облако OpenAI)"
        }
    }

    /// Текст встречи остаётся на компьютере.
    var isLocal: Bool { self == .builtin || self == .ollama }
    /// Модель грузит память и видеоускоритель этого Mac — её стоит придерживать на время звонков.
    var loadsThisMac: Bool { isLocal }
}

/// Найденный на компьютере движок и его модели.
struct EngineInfo: Equatable {
    var available = false
    /// Почему недоступен или что нужно сделать (для показа в настройках).
    var note = ""
    var binary: URL?
    /// Модели: идентификатор и название. Пустой идентификатор — «модель по умолчанию».
    var models: [EngineModel] = []
}

struct EngineModel: Equatable, Identifiable {
    var id: String
    var title: String
}

/// Сам находит установленные движки и их модели: ничего настраивать вручную не нужно.
@MainActor
final class EngineDiscovery: ObservableObject {
    @Published private(set) var engines: [LLMEngine: EngineInfo] = [:]
    @Published private(set) var scanning = false

    func info(_ engine: LLMEngine) -> EngineInfo { engines[engine] ?? EngineInfo() }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        Task {
            async let ollama = Self.findOllama()
            async let claude = Self.findClaude()
            async let codex = Self.findCodex()
            let found = await [LLMEngine.ollama: ollama, .claude: claude, .codex: codex]
            engines = found
            scanning = false
        }
    }

    // MARK: Поиск программ

    /// Программы из терминала приложению с интерфейсом не видны (у него нет PATH оболочки),
    /// поэтому ищем в привычных местах, а затем спрашиваем саму оболочку пользователя.
    nonisolated static func findBinary(_ name: String, extra: [String] = []) async -> URL? {
        let home = NSHomeDirectory()
        let places = extra + [
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/bin", "\(home)/.npm-global/bin",
            "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/.cargo/bin", "\(home)/.claude/local", "/usr/bin",
        ]
        let fm = FileManager.default
        for place in places {
            let path = place + "/" + name
            if fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let output = try? await CLIRunner.run(URL(fileURLWithPath: shell), ["-lic", "command -v \(name)"],
                                                    input: nil, timeout: 8).output else { return nil }
        let path = output.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return path.hasPrefix("/") && fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    nonisolated static func findOllama() async -> EngineInfo {
        var info = EngineInfo()
        info.binary = await findBinary("ollama", extra: ["/Applications/Ollama.app/Contents/Resources"])
        if let models = await OllamaClient.models() {
            info.models = models.map { EngineModel(id: $0, title: $0) }
            info.available = !models.isEmpty
            info.note = models.isEmpty ? "Ollama запущена, но моделей в ней нет. Скачайте модель командой «ollama pull»." : ""
        } else {
            info.note = info.binary == nil ? "Ollama не установлена." : "Ollama установлена, но не запущена. Откройте приложение Ollama."
        }
        return info
    }

    nonisolated static func findClaude() async -> EngineInfo {
        var info = EngineInfo()
        var binary = await findBinary("claude")
        if binary == nil {
            // Claude Code, установленный вместе с приложением Claude: берём самую свежую версию.
            let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Claude/claude-code")
            let fm = FileManager.default
            var candidates: [URL] = []
            for version in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                for build in (try? fm.contentsOfDirectory(at: version, includingPropertiesForKeys: nil)) ?? [] {
                    let path = build.appendingPathComponent("claude.app/Contents/MacOS/claude")
                    if fm.isExecutableFile(atPath: path.path) { candidates.append(path) }
                }
            }
            binary = candidates.max {
                $0.path.compare($1.path, options: .numeric) == .orderedAscending
            }
        }
        info.binary = binary
        info.available = binary != nil
        info.note = binary == nil ? "Claude Code не найден." : ""
        // Перечня моделей программа не выдаёт; она принимает эти обозначения и сама выбирает актуальную версию.
        info.models = [
            EngineModel(id: "", title: "По умолчанию"),
            EngineModel(id: "opus", title: "Opus — самая сильная"),
            EngineModel(id: "sonnet", title: "Sonnet — быстрее"),
            EngineModel(id: "haiku", title: "Haiku — самая быстрая"),
        ]
        return info
    }

    nonisolated static func findCodex() async -> EngineInfo {
        var info = EngineInfo()
        info.binary = await findBinary("codex")
        info.available = info.binary != nil
        info.note = info.binary == nil ? "Codex не найден." : ""
        info.models = [EngineModel(id: "", title: "По умолчанию")]
        // Список моделей Codex хранит у себя после входа.
        struct Cache: Decodable {
            struct Model: Decodable { var slug: String; var display_name: String?; var visibility: String? }
            var models: [Model]
        }
        let cache = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/models_cache.json")
        if let data = try? Data(contentsOf: cache), let decoded = try? JSONDecoder().decode(Cache.self, from: data) {
            info.models += decoded.models.filter { $0.visibility != "hide" }
                .map { EngineModel(id: $0.slug, title: $0.display_name ?? $0.slug) }
        }
        return info
    }
}

// MARK: - Запуск программ командной строки

enum CLIRunner {
    struct Result {
        var output: String
        var errors: String
        var status: Int32
    }

    /// Запускает программу, подаёт `input` на стандартный ввод и ждёт завершения.
    /// Отмена задачи или истечение времени останавливают программу.
    static func run(_ binary: URL, _ arguments: [String], input: String?, timeout: TimeInterval,
                    directory: URL? = nil) async throws -> Result {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        var environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:"
            + (environment["PATH"] ?? "")
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin

        return try await withTaskCancellationHandler {
            try process.run()
            // Читаем оба потока сразу: иначе программа, выводящая много текста, зависнет на заполненном канале.
            async let out = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }.value
            async let err = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }.value
            if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
            try? stdin.fileHandleForWriting.close()

            let killer = Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !Task.isCancelled, process.isRunning { process.terminate() }
            }
            let (outData, errData) = await (out, err)
            process.waitUntilExit()
            killer.cancel()
            try Task.checkCancellation()
            return Result(output: String(decoding: outData, as: UTF8.self),
                          errors: String(decoding: errData, as: UTF8.self), status: process.terminationStatus)
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

// MARK: - Ollama

enum OllamaClient {
    static let base = URL(string: "http://127.0.0.1:11434")!

    /// Имена установленных моделей; nil — Ollama не отвечает.
    static func models() async -> [String]? {
        var request = URLRequest(url: base.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return nil }
        return models.compactMap { $0["name"] as? String }.sorted()
    }

    static func generate(model: String, prompt: String, maxTokens: Int, temperature: Double,
                         onText: @escaping @Sendable (String) -> Void) async throws -> String {
        var request = URLRequest(url: base.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 3600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Окно контекста задаём явно: по умолчанию у Ollama оно слишком мало для транскрипции встречи.
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "stream": true,
            "options": ["num_ctx": 16384, "temperature": temperature, "num_predict": maxTokens],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ProcessingError.failed("Ollama вернула ошибку (HTTP \(code)). Проверьте, что модель «\(model)» установлена.")
        }
        var text = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let message = json["message"] as? [String: Any], let piece = message["content"] as? String, !piece.isEmpty {
                text += piece
                onText(LLMClient.stripThinking(text))
            }
            if json["done"] as? Bool == true { break }
        }
        let result = LLMClient.stripThinking(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty { throw ProcessingError.failed("Ollama вернула пустой ответ.") }
        return result
    }
}

// MARK: - Облачные модели через программы командной строки

enum CLIModel {
    /// Пустая папка для запуска: программа не должна подхватывать настройки и файлы каких-либо проектов.
    private static var sandbox: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lma-llm", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static let system = "Ты готовишь итоги рабочих встреч. Отвечай только текстом результата, без вступлений и пояснений. Инструменты не используй."

    static func generate(engine: LLMEngine, binary: URL, model: String, prompt: String) async throws -> String {
        let result: CLIRunner.Result
        var answer: String
        switch engine {
        case .claude:
            var arguments = ["-p", "--output-format", "text", "--tools", "", "--no-session-persistence",
                             "--disable-slash-commands", "--strict-mcp-config", "--system-prompt", system]
            if !model.isEmpty { arguments += ["--model", model] }
            result = try await CLIRunner.run(binary, arguments, input: prompt, timeout: 1200, directory: sandbox)
            answer = result.output
        case .codex:
            let file = sandbox.appendingPathComponent("answer-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: file) }
            var arguments = ["exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only", "--color", "never",
                             // Для пересказа встречи долгие рассуждения не нужны — так ответ приходит заметно быстрее.
                             "-c", "model_reasoning_effort=\"medium\"", "-o", file.path]
            if !model.isEmpty { arguments += ["-m", model] }
            arguments.append("-")
            result = try await CLIRunner.run(binary, arguments, input: system + "\n\n" + prompt, timeout: 1200,
                                             directory: sandbox)
            answer = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        default:
            throw ProcessingError.failed("Этот движок не запускается из командной строки.")
        }
        answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = (answer + result.errors).lowercased()
        if lowered.contains("not logged in") || lowered.contains("/login") || lowered.contains("please login")
            || lowered.contains("401") {
            let command = engine == .claude ? "claude" : "codex login"
            throw ProcessingError.failed("В \(engine == .claude ? "Claude Code" : "Codex") не выполнен вход. Откройте Терминал, запустите «\(command)» и войдите в аккаунт.")
        }
        if result.status != 0 || answer.isEmpty {
            let detail = (result.errors.isEmpty ? result.output : result.errors)
                .split(separator: "\n").suffix(3).joined(separator: " ").prefix(300)
            throw ProcessingError.failed("\(engine == .claude ? "Claude Code" : "Codex") не вернул ответ. \(detail)")
        }
        return answer
    }
}
