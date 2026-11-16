import Combine
import CryptoKit
import Foundation
import WhisperKit

enum ModelStatus: Equatable {
    case missing
    case downloading(Double?)
    case preparing
    case installed
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .downloading, .preparing: return true
        default: return false
        }
    }
}

/// Управление локальными моделями: распознавание речи, определение участников, языковая модель.
/// Интернет нужен только здесь — для первоначального скачивания.
@MainActor
final class ModelManager: ObservableObject {
    @Published private(set) var whisper: ModelStatus = .missing
    @Published private(set) var diarizer: ModelStatus = .missing
    @Published private(set) var llm: [String: ModelStatus] = [:]

    private let settings: AppSettings
    private let defaults = UserDefaults.standard
    private var llmDownloads: [String: FileDownloader] = [:]

    private var enginesObserver: AnyCancellable?

    init(settings: AppSettings) {
        self.settings = settings
        // Готовность внешних движков влияет на кнопки генерации — пробрасываем их изменения.
        enginesObserver = engines.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        refresh()
    }

    // MARK: Состояние

    func refresh() {
        if !whisper.isBusy { whisper = whisperFolder(settings.whisperVariant) != nil ? .installed : .missing }
        if !diarizer.isBusy { diarizer = SpeakerDiarizer.isInstalled ? .installed : .missing }
        for model in LLMCatalog.all where !(llm[model.id]?.isBusy ?? false) {
            llm[model.id] = FileManager.default.fileExists(atPath: model.localURL.path) ? .installed : .missing
        }
    }

    func whisperFolder(_ variant: String) -> URL? {
        guard let path = defaults.string(forKey: "whisperFolder.\(variant)"),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    var currentWhisperFolder: URL? { whisperFolder(settings.whisperVariant) }

    /// Файл выбранной языковой модели, если она установлена.
    var currentLLM: URL? {
        if settings.llmModelID == LLMCatalog.customID {
            let path = settings.customLLMPath
            return FileManager.default.fileExists(atPath: path) && !path.isEmpty ? URL(fileURLWithPath: path) : nil
        }
        guard let model = LLMCatalog.model(settings.llmModelID),
              FileManager.default.fileExists(atPath: model.localURL.path),
              llm[model.id] == .installed else { return nil }
        return model.localURL
    }

    let engines = EngineDiscovery()

    /// Клиент выбранного в настройках движка; nil — движок сейчас не готов к работе.
    func llmClient(gpu: Bool) -> LLMClient? {
        switch settings.llmEngine {
        case .builtin:
            return currentLLM.map { LLMClient(backend: .builtin(model: $0, gpu: gpu)) }
        case .ollama:
            let info = engines.info(.ollama)
            let chosen = settings.engineModels[LLMEngine.ollama.rawValue] ?? ""
            guard info.available, let model = info.models.first(where: { $0.id == chosen })?.id ?? info.models.first?.id
            else { return nil }
            return LLMClient(backend: .ollama(model: model))
        case .claude, .codex:
            let engine = settings.llmEngine
            guard let binary = engines.info(engine).binary else { return nil }
            return LLMClient(backend: .cli(engine: engine, binary: binary, model: settings.engineModels[engine.rawValue] ?? ""))
        }
    }

    /// Саммари и письма сейчас можно готовить.
    var llmReady: Bool { llmClient(gpu: true) != nil }

    /// Почему языковая модель недоступна — для подсказок в интерфейсе.
    var llmUnavailableReason: String {
        switch settings.llmEngine {
        case .builtin: return "Языковая модель не установлена — скачайте её в настройках"
        case .ollama, .claude, .codex:
            let note = engines.info(settings.llmEngine).note
            return note.isEmpty ? "Выбранная модель недоступна — проверьте настройки" : note
        }
    }

    var selectedLLMStatus: ModelStatus {
        if settings.llmModelID == LLMCatalog.customID { return currentLLM != nil ? .installed : .missing }
        return llm[settings.llmModelID] ?? .missing
    }

    var allInstalled: Bool {
        whisper == .installed && diarizer == .installed && (settings.llmEngine != .builtin || currentLLM != nil)
    }
    var anyBusy: Bool { whisper.isBusy || diarizer.isBusy || llm.values.contains { $0.isBusy } }

    // MARK: Установка

    func installAllMissing() async {
        if whisper != .installed { await installWhisper() }
        if diarizer != .installed { await installDiarizer() }
        if settings.llmEngine == .builtin, settings.llmModelID != LLMCatalog.customID, selectedLLMStatus != .installed {
            await installLLM(settings.llmModelID)
        }
    }

    func installWhisper() async {
        guard !whisper.isBusy else { return }
        let variant = settings.whisperVariant
        whisper = .downloading(0)
        do {
            let folder = try await WhisperKit.download(variant: variant, downloadBase: AppPaths.whisperModels) { progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    if case .downloading = self.whisper { self.whisper = .downloading(fraction) }
                }
            }
            // Первая загрузка: система оптимизирует модель под этот Mac (несколько минут).
            whisper = .preparing
            let transcriber = Transcriber()
            try await transcriber.load(modelFolder: folder)
            await transcriber.unload()
            defaults.set(folder.path, forKey: "whisperFolder.\(variant)")
            whisper = .installed
        } catch {
            whisper = .failed(error.localizedDescription)
        }
    }

    func installDiarizer() async {
        guard !diarizer.isBusy else { return }
        diarizer = .downloading(nil)
        do {
            let diarizer = SpeakerDiarizer()
            try await diarizer.prepare()
            diarizer.unload()
            self.diarizer = .installed
        } catch {
            diarizer = .failed(error.localizedDescription)
        }
    }

    func installLLM(_ id: String) async {
        guard let model = LLMCatalog.model(id), !(llm[id]?.isBusy ?? false) else { return }
        llm[id] = .downloading(0)
        let partial = model.localURL.appendingPathExtension("part")
        let downloader = FileDownloader(destination: partial) { fraction in
            Task { @MainActor in
                if case .downloading = self.llm[id] { self.llm[id] = .downloading(fraction) }
            }
        }
        llmDownloads[id] = downloader
        defer { llmDownloads[id] = nil }
        do {
            try await downloader.run(from: model.url)
            llm[id] = .preparing
            let digest = try await Task.detached { try Self.sha256(of: partial) }.value
            guard digest == model.sha256 else {
                try? FileManager.default.removeItem(at: partial)
                throw ProcessingError.failed("Файл модели повреждён при скачивании. Попробуйте ещё раз.")
            }
            try? FileManager.default.removeItem(at: model.localURL)
            try FileManager.default.moveItem(at: partial, to: model.localURL)
            llm[id] = .installed
        } catch {
            // Недокачанный файл остаётся на диске: следующая попытка продолжит с места обрыва.
            llm[id] = (error as? URLError)?.code == .cancelled ? .missing : .failed(error.localizedDescription)
        }
    }

    func cancelLLMDownload(_ id: String) {
        llmDownloads[id]?.cancel()
    }

    // MARK: Удаление

    func deleteWhisper() {
        let variant = settings.whisperVariant
        if let folder = whisperFolder(variant) { try? FileManager.default.removeItem(at: folder) }
        defaults.removeObject(forKey: "whisperFolder.\(variant)")
        whisper = .missing
    }

    func deleteDiarizer() {
        let dir = AppPaths.diarizerModels
        for item in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                                  options: [])) ?? [] {
            try? FileManager.default.removeItem(at: item)
        }
        diarizer = .missing
    }

    func deleteLLM(_ id: String) {
        guard let model = LLMCatalog.model(id) else { return }
        Task { await LlamaServer.shared.stop() }
        try? FileManager.default.removeItem(at: model.localURL)
        try? FileManager.default.removeItem(at: model.localURL.appendingPathExtension("part"))
        llm[id] = .missing
    }

    var modelsDiskUsage: Int64 {
        guard let enumerator = FileManager.default.enumerator(at: AppPaths.models, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 4 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Скачивание большого файла с отображением прогресса и докачкой:
/// данные пишутся сразу в файл назначения, а при повторном запуске загрузка продолжается с места обрыва.
final class FileDownloader: NSObject, URLSessionDataDelegate {
    private let destination: URL
    private let onProgress: (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var total: Int64 = 0
    private var failure: Error?
    private var lastReport = Date.distantPast

    init(destination: URL, onProgress: @escaping (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func run(from url: URL) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destination.path) { fm.createFile(atPath: destination.path, contents: nil) }
        let existing = ((try? fm.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber)?.int64Value ?? 0

        var request = URLRequest(url: url)
        if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        received = existing

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            let task = session.dataTask(with: request)
            self.task = task
            task.resume()
        }
    }

    func cancel() {
        task?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            let handle = try FileHandle(forWritingTo: destination)
            switch status {
            case 206:
                // Сервер продолжает с запрошенного места.
                try handle.seekToEnd()
                total = received + max(0, response.expectedContentLength)
            case 200:
                // Сервер отдаёт файл целиком — начинаем заново.
                try handle.truncate(atOffset: 0)
                received = 0
                total = max(0, response.expectedContentLength)
            case 416:
                // Файл уже скачан полностью.
                try handle.close()
                completionHandler(.cancel)
                failure = nil
                total = received
                return
            default:
                try handle.close()
                failure = ProcessingError.failed("Сервер вернул ошибку \(status) при скачивании модели.")
                completionHandler(.cancel)
                return
            }
            self.handle = handle
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            received += Int64(data.count)
            if total > 0, Date().timeIntervalSince(lastReport) > 0.5 {
                lastReport = Date()
                onProgress(Double(received) / Double(total))
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        let finished = total > 0 && received >= total
        if let failure {
            continuation?.resume(throwing: failure)
        } else if finished {
            continuation?.resume()
        } else if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(throwing: ProcessingError.failed("Скачивание модели прервалось. Нажмите «Повторить» — загрузка продолжится с места обрыва."))
        }
        continuation = nil
    }
}
