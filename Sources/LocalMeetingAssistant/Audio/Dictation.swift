import AVFoundation
import Foundation

/// Голосовой ввод короткого текста (замечания к саммари): запись с микрофона и локальное распознавание.
@MainActor
final class Dictation: ObservableObject {
    enum State { case idle, recording, transcribing }

    @Published private(set) var state: State = .idle
    @Published private(set) var seconds: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published var errorMessage: String?

    /// Дольше этого запись не идёт: замечание — не доклад.
    nonisolated static let maxSeconds: TimeInterval = 300

    private var mic: MicCapture?
    private var sink: SampleSink?
    private var timer: Timer?
    private var startedAt = Date()
    private var onLimit: (() -> Void)?

    /// Накопитель звука: вызывается из аудиопотока.
    private final class SampleSink {
        private let lock = NSLock()
        private let resampler = Resampler()
        private var samples: [Float] = []
        private var peak: Float = 0

        func append(_ buffer: AVAudioPCMBuffer) {
            lock.lock()
            defer { lock.unlock() }
            let floats = resampler.convert(buffer)
            guard !floats.isEmpty, samples.count < Int(Dictation.maxSeconds) * 16_000 else { return }
            var sum: Float = 0
            for v in floats { sum += v * v }
            peak = max(peak, (sum / Float(floats.count)).squareRoot())
            samples.append(contentsOf: floats)
        }

        func consumePeak() -> Float {
            lock.withLock {
                let value = peak
                peak = 0
                return value
            }
        }

        func take() -> [Float] { lock.withLock { samples } }
    }

    /// `onLimit` вызывается, когда запись достигла предельной длины и её пора завершать.
    func start(onLimit: @escaping () -> Void) async {
        guard state == .idle else { return }
        errorMessage = nil
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            errorMessage = "Нет доступа к микрофону."
            return
        }
        let sink = SampleSink()
        let mic = MicCapture()
        mic.onBuffer = { sink.append($0) }
        do { try mic.start() } catch {
            errorMessage = "Не удалось включить микрофон: \(error.localizedDescription)"
            return
        }
        self.sink = sink
        self.mic = mic
        self.onLimit = onLimit
        startedAt = Date()
        seconds = 0
        level = 0
        state = .recording
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard state == .recording else { return }
        seconds = Date().timeIntervalSince(startedAt)
        let peak = sink?.consumePeak() ?? 0
        let target = peak > 0.0005 ? max(0, min(1, (20 * log10(peak) + 55) / 50)) : 0
        level += (target - level) * (target > level ? 0.6 : 0.25)
        if seconds >= Self.maxSeconds { onLimit?() }
    }

    private func stopCapture() -> [Float] {
        timer?.invalidate()
        timer = nil
        mic?.stop()
        mic = nil
        onLimit = nil
        let samples = sink?.take() ?? []
        sink = nil
        level = 0
        return samples
    }

    func cancel() {
        guard state == .recording else { return }
        _ = stopCapture()
        state = .idle
    }

    /// Останавливает запись и возвращает распознанный текст (nil — если распознать не удалось).
    func finish(modelFolder: URL?, glossary: String) async -> String? {
        guard state == .recording else { return nil }
        let samples = stopCapture()
        guard samples.count > 16_000 / 2 else {
            state = .idle
            errorMessage = "Запись слишком короткая."
            return nil
        }
        guard let modelFolder else {
            state = .idle
            errorMessage = "Модель распознавания речи не установлена — скачайте её в настройках."
            return nil
        }
        state = .transcribing
        defer { state = .idle }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lma-dictation-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let text = try await Task.detached { () -> String in
                let writer = try WAVWriter(url: url)
                writer.append(samples.map { Int16(max(-1, min(1, $0)) * 32767) })
                writer.close()
                let transcriber = Transcriber()
                try await transcriber.load(modelFolder: modelFolder)
                let segments = try await transcriber.transcribe(wav: url, glossary: glossary) { _ in }
                await transcriber.unload()
                return segments.map(\.text).joined(separator: " ")
            }.value
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { errorMessage = "Речь не распознана. Попробуйте ещё раз или напишите текстом." }
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            errorMessage = "Не удалось распознать: \(error.localizedDescription)"
            return nil
        }
    }
}
