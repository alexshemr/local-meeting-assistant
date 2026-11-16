import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Импорт готовых записей: любой аудио- или видеофайл приводится к рабочему формату приложения
/// (WAV, 16 кГц, моно, 16 бит) и дальше проходит обычную обработку.
enum AudioImporter {
    /// Форматы, которые система читает сама.
    static let nativeExtensions: Set<String> = [
        "wav", "mp3", "m4a", "mp4", "mov", "m4v", "aac", "flac", "aiff", "aif", "caf", "amr", "3gp", "3g2",
    ]
    /// Форматы, для которых нужен установленный ffmpeg.
    static let ffmpegExtensions: Set<String> = ["mkv", "webm", "ogg", "opus", "oga", "wma", "avi"]

    static var allowedTypes: [UTType] {
        var types: [UTType] = [.audio, .movie]
        for ext in nativeExtensions.union(ffmpegExtensions) {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }

    static func isSupported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return nativeExtensions.contains(ext) || ffmpegExtensions.contains(ext)
    }

    static var ffmpegURL: URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Конвертирует файл и возвращает длительность в секундах.
    static func convert(_ source: URL, to destination: URL) async throws -> Double {
        do {
            try await convertWithAVFoundation(source, to: destination)
        } catch {
            // Система не справилась (MKV, WebM, OGG и т. п.) — пробуем ffmpeg, если он установлен.
            try? FileManager.default.removeItem(at: destination)
            guard let ffmpeg = ffmpegURL else {
                if ffmpegExtensions.contains(source.pathExtension.lowercased()) {
                    throw ProcessingError.failed("Для файлов .\(source.pathExtension) нужен ffmpeg. Установите его (brew install ffmpeg) или сконвертируйте файл в MP3, M4A или WAV.")
                }
                throw ProcessingError.failed("Не удалось прочитать «\(source.lastPathComponent)»: \(error.localizedDescription)")
            }
            try convertWithFFmpeg(ffmpeg, source, to: destination)
        }
        let seconds = Double(WAVReader.sampleCount(destination)) / 16_000
        guard seconds >= 0.5 else {
            try? FileManager.default.removeItem(at: destination)
            throw ProcessingError.failed("В файле «\(source.lastPathComponent)» не найдено звука.")
        }
        return seconds
    }

    private static func convertWithAVFoundation(_ source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw ProcessingError.failed("В файле нет звуковой дорожки.") }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { throw ProcessingError.failed("Формат звука не поддерживается.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ProcessingError.failed("Не удалось начать чтение файла.") }

        let writer = try WAVWriter(url: destination)
        defer { writer.close() }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length >= 2 else { continue }
            var samples = [Int16](repeating: 0, count: length / 2)
            let status = samples.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length / 2 * 2, destination: $0.baseAddress!)
            }
            if status == kCMBlockBufferNoErr { writer.append(samples) }
        }
        if reader.status == .failed { throw reader.error ?? ProcessingError.failed("Ошибка чтения файла.") }
    }

    private static func convertWithFFmpeg(_ ffmpeg: URL, _ source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-nostdin", "-y", "-loglevel", "error", "-i", source.path, "-vn",
                             "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
                             "-bitexact", "-map_metadata", "-1", "-f", "wav", destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProcessingError.failed("ffmpeg не смог прочитать «\(source.lastPathComponent)».")
        }
    }
}
