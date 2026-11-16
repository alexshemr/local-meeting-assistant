import Darwin
import Foundation

/// Встроенный в приложение движок llama.cpp. Запускается как дочерний процесс,
/// слушает только 127.0.0.1 и останавливается, когда не используется.
actor LlamaServer {
    static let shared = LlamaServer()

    private var process: Process?
    private var port = 0
    private var loadedModel: String?
    private var loadedOnGPU = true
    private var idleTask: Task<Void, Never>?

    private static let processLock = NSLock()
    nonisolated(unsafe) private static var runningProcess: Process?

    static var binaryURL: URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("llama/llama-server"))
        }
        // Запуск из исходников (swift run): берём движок из папки Vendor.
        let vendor = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Vendor/llama")
        if let builds = try? fm.contentsOfDirectory(at: vendor, includingPropertiesForKeys: nil) {
            candidates += builds.map { $0.appendingPathComponent("llama-server") }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    static var logURL: URL { AppPaths.support.appendingPathComponent("llama-server.log") }

    /// Запускает сервер с указанной моделью (или переиспользует уже запущенный) и возвращает его адрес.
    /// `gpu: false` — щадящий режим: без видеоускорителя, на части ядер и с низким приоритетом.
    func ensureRunning(model: URL, gpu: Bool = true) async throws -> URL {
        idleTask?.cancel()
        if let process, process.isRunning, loadedModel == model.path, loadedOnGPU == gpu {
            return baseURL
        }
        stop()

        guard let binary = Self.binaryURL else {
            throw ProcessingError.failed("Не найден встроенный движок llama.cpp. Пересоберите приложение скриптом scripts/build-app.sh.")
        }
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw ProcessingError.modelMissing("Языковая модель")
        }

        port = Self.freePort()
        FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: Self.logURL)

        let process = Process()
        process.executableURL = binary
        process.currentDirectoryURL = binary.deletingLastPathComponent()
        process.arguments = [
            "-m", model.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "-c", "16384",
            "-np", "1",
        ] + (gpu ? ["-ngl", "99"] : ["-ngl", "0", "-t", "3", "-tb", "3"])
        process.qualityOfService = gpu ? .userInitiated : .utility
        process.standardOutput = log
        process.standardError = log
        try process.run()
        self.process = process
        loadedModel = model.path
        loadedOnGPU = gpu
        Self.processLock.withLock { Self.runningProcess = process }

        // Ждём, пока модель загрузится в память.
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            if !process.isRunning {
                let tail = Self.logTail()
                stop()
                throw ProcessingError.failed("Языковая модель не запустилась. \(tail)")
            }
            if await isHealthy() { return baseURL }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        stop()
        throw ProcessingError.failed("Языковая модель не успела загрузиться.")
    }

    /// Останавливает сервер через несколько минут простоя, чтобы освободить память.
    func scheduleIdleStop(after seconds: Double = 300) {
        idleTask?.cancel()
        idleTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self.stop() }
        }
    }

    func stop() {
        idleTask?.cancel()
        if let process, process.isRunning { process.terminate() }
        process = nil
        loadedModel = nil
        Self.processLock.withLock { Self.runningProcess = nil }
    }

    /// Синхронная остановка при выходе из приложения.
    nonisolated static func terminateNow() {
        processLock.withLock {
            if let p = runningProcess, p.isRunning { p.terminate() }
            runningProcess = nil
        }
    }

    private var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private func isHealthy() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private static func logTail() -> String {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(4).joined(separator: " ")
    }

    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 18_734 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0 else { return 18_734 }
        let named = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return named == 0 ? Int(UInt16(bigEndian: addr.sin_port)) : 18_734
    }
}

/// Клиент локального сервера (OpenAI-совместимый /v1/chat/completions, потоковая выдача).
struct LLMClient {
    enum Backend {
        /// Встроенный движок llama.cpp с файлом модели GGUF.
        case builtin(model: URL, gpu: Bool)
        case ollama(model: String)
        /// Claude Code или Codex: модель в облаке, запускается программой из терминала.
        case cli(engine: LLMEngine, binary: URL, model: String)
    }

    let backend: Backend

    /// Сколько символов транскрипции модель принимает за один проход.
    /// У облачных моделей окно контекста на порядок больше, длинную встречу не нужно дробить.
    var singlePassChars: Int {
        if case .cli = backend { return 320_000 }
        return 24_000
    }

    var isLocal: Bool {
        if case .cli = backend { return false }
        return true
    }

    func generate(prompt: String, maxTokens: Int, temperature: Double = 0.2,
                  onText: @escaping @Sendable (String) -> Void) async throws -> String {
        switch backend {
        case .builtin(let model, let gpu):
            return try await generateBuiltin(model: model, gpu: gpu, prompt: prompt, maxTokens: maxTokens,
                                             temperature: temperature, onText: onText)
        case .ollama(let model):
            return try await OllamaClient.generate(model: model, prompt: prompt, maxTokens: maxTokens,
                                                   temperature: temperature, onText: onText)
        case .cli(let engine, let binary, let model):
            // Программа отдаёт ответ целиком, без потока.
            let text = try await CLIModel.generate(engine: engine, binary: binary, model: model, prompt: prompt)
            onText(text)
            return text
        }
    }

    private func generateBuiltin(model: URL, gpu: Bool, prompt: String, maxTokens: Int, temperature: Double,
                                 onText: @escaping @Sendable (String) -> Void) async throws -> String {
        let base = try await LlamaServer.shared.ensureRunning(model: model, gpu: gpu)
        defer { Task { await LlamaServer.shared.scheduleIdleStop() } }

        var request = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 3600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "messages": [["role": "user", "content": prompt]],
            "stream": true,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ProcessingError.failed("Языковая модель вернула ошибку (HTTP \(code)).")
        }

        var text = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let piece = delta["content"] as? String, !piece.isEmpty else { continue }
            text += piece
            onText(Self.stripThinking(text))
        }
        let result = Self.stripThinking(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty { throw ProcessingError.failed("Языковая модель вернула пустой ответ.") }
        return result
    }

    static func stripThinking(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
        if let open = s.range(of: "<think>") { s = String(s[..<open.lowerBound]) }
        return s
    }
}
