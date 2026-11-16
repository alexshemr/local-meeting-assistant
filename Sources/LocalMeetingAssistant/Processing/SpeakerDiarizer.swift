import FluidAudio
import Foundation

struct DiarSegment: Codable {
    var speaker: String
    var start: Double
    var end: Double
}

struct DiarOutput: Codable {
    var segments: [DiarSegment] = []
    var embeddings: [String: [Float]] = [:]
}

/// Локальное разделение голосов (pyannote-совместимый офлайн-пайплайн в CoreML).
final class SpeakerDiarizer {
    private var manager: OfflineDiarizerManager?

    static var readyMarker: URL { AppPaths.diarizerModels.appendingPathComponent(".ready") }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: readyMarker.path) }

    /// Скачивает (при первом запуске) и загружает модели.
    /// `speakers` — точное число голосов, если пользователь задал его вручную.
    func prepare(speakers: Int? = nil) async throws {
        if manager != nil { return }
        var config = OfflineDiarizerConfig.default
        if let speakers, speakers > 0 { config.clustering.numSpeakers = speakers }
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels(directory: AppPaths.diarizerModels)
        FileManager.default.createFile(atPath: Self.readyMarker.path, contents: Data())
        self.manager = manager
    }

    func unload() {
        manager = nil
    }

    func process(wav: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> DiarOutput {
        guard let manager else { throw ProcessingError.failed("Модель определения участников не загружена") }
        let result = try await manager.process(wav) { done, total in
            if total > 0 { onProgress(Double(done) / Double(total)) }
        }
        return DiarOutput(
            segments: result.segments.map {
                DiarSegment(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
            },
            embeddings: result.speakerDatabase ?? [:]
        )
    }
}
