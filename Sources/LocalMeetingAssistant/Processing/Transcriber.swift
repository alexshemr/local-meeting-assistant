import Foundation
import WhisperKit

struct RawSegment: Codable {
    var start: Double
    var end: Double
    var text: String
}

enum ProcessingError: LocalizedError {
    case modelMissing(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing(let what): return "\(what) не установлена. Скачайте её в настройках приложения."
        case .failed(let message): return message
        }
    }
}

/// Локальное распознавание речи (Whisper через CoreML).
/// Длинные записи читаются с диска окнами по ~10 минут, поэтому память не растёт с длиной встречи.
final class Transcriber {
    private var kit: WhisperKit?
    private let sampleRate = 16_000

    func load(modelFolder: URL) async throws {
        if kit != nil { return }
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            tokenizerFolder: AppPaths.whisperModels,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )
        kit = try await WhisperKit(config)
    }

    func unload() async {
        await kit?.unloadModels()
        kit = nil
    }

    /// `gate` вызывается перед каждым окном: в нём обработка может подождать, пока компьютер занят звонком.
    func transcribe(wav: URL, glossary: String, gate: (@Sendable () async -> Void)? = nil,
                    onProgress: @escaping @Sendable (Double) -> Void) async throws -> [RawSegment] {
        guard let kit else { throw ProcessingError.failed("Модель распознавания речи не загружена") }
        let total = WAVReader.sampleCount(wav)
        guard total > sampleRate / 2 else { return [] }

        var options = DecodingOptions()
        options.task = .transcribe
        options.language = "ru"
        options.detectLanguage = false
        options.skipSpecialTokens = true
        options.withoutTimestamps = false
        options.wordTimestamps = false
        options.chunkingStrategy = .vad

        let terms = glossary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !terms.isEmpty, let tokenizer = kit.tokenizer {
            let tokens = tokenizer.encode(text: " " + terms).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            if !tokens.isEmpty { options.promptTokens = Array(tokens.suffix(200)) }
        }

        // Окна по 3 минуты: память не растёт с длиной встречи, а паузу на время звонка не приходится ждать долго.
        let window = 180 * sampleRate
        var position = 0
        var output: [RawSegment] = []

        while position < total {
            try Task.checkCancellation()
            await gate?()
            var samples = try WAVReader.read(wav, from: position, count: min(window, total - position))
            if samples.isEmpty { break }
            if position + samples.count < total {
                samples.removeLast(samples.count - quietCut(samples))
            }
            let offset = Double(position) / Double(sampleRate)

            if hasSpeechEnergy(samples) {
                let results: [TranscriptionResult] = try await kit.transcribe(audioArray: samples, decodeOptions: options)
                for result in results {
                    for segment in result.segments {
                        let text = Self.clean(segment.text)
                        guard !text.isEmpty, !Self.isHallucination(text), segment.noSpeechProb < 0.8 else { continue }
                        output.append(RawSegment(start: offset + Double(segment.start),
                                                 end: offset + Double(max(segment.end, segment.start + 0.2)),
                                                 text: text))
                    }
                }
            }
            position += samples.count
            onProgress(Double(position) / Double(total))
        }
        return output.sorted { $0.start < $1.start }
    }

    /// Ищет самое тихое место в последних 30 секундах окна, чтобы не резать слово пополам.
    private func quietCut(_ samples: [Float]) -> Int {
        let frame = sampleRate / 2
        let searchStart = max(0, samples.count - 30 * sampleRate)
        var bestIndex = samples.count
        var bestEnergy = Float.greatestFiniteMagnitude
        var i = searchStart
        while i + frame <= samples.count {
            var energy: Float = 0
            for j in i..<(i + frame) { energy += samples[j] * samples[j] }
            if energy < bestEnergy {
                bestEnergy = energy
                bestIndex = i + frame / 2
            }
            i += frame / 2
        }
        return max(sampleRate, bestIndex)
    }

    /// Полностью тихие окна пропускаем: Whisper на тишине склонен выдумывать текст.
    private func hasSpeechEnergy(_ samples: [Float]) -> Bool {
        let frame = sampleRate / 10
        var i = 0
        while i + frame <= samples.count {
            var energy: Float = 0
            for j in i..<(i + frame) { energy += samples[j] * samples[j] }
            if (energy / Float(frame)).squareRoot() > 0.003 { return true }
            i += frame
        }
        return false
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{FFFD}", with: "")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let hallucinations = [
        "субтитры", "продолжение следует", "спасибо за просмотр", "dimatorzok",
        "подписывайтесь на канал", "редактор субтитров", "корректор",
    ]

    private static func isHallucination(_ text: String) -> Bool {
        guard text.count < 70 else { return false }
        let lower = text.lowercased()
        return hallucinations.contains { lower.contains($0) }
    }
}
