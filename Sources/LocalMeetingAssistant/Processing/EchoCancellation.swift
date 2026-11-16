import CLocalVQE
import Foundation

// Обнаружение и подавление эха: когда встреча идёт через колонки, голоса собеседников
// попадают и в микрофон, из-за чего одна и та же речь оказывается на обеих дорожках.
//
// Подход и пороги перенесены из проекта pasrom/meeting-transcriber (MIT):
// детектор по корреляции огибающих и нейросетевой эхоподавитель LocalVQE (Apache-2.0).

/// Определяет, слышно ли системный звук в дорожке микрофона.
enum EchoBleedDetector {
    /// Сравниваются огибающие, а не сами сигналы: тракты записи микрофона и системного звука
    /// всегда отличаются усилением и частотной характеристикой.
    static let frameSeconds = 0.010
    static let windowSeconds = 10.0
    static let maxLagSeconds = 0.2
    /// Окно считается «с эхом», если корреляция огибающих в нём выше этого значения.
    static let correlationThreshold = 0.7
    /// Запись считается затронутой, если эхо есть хотя бы в такой доле окон.
    /// Доля окон, а не корреляция по всему файлу: частичное эхо на длинной записи иначе «размывается».
    static let affectedShareThreshold = 0.15
    static let minScoredWindows = 3
    static let minAffectedWindows = 2
    static let minAffectedWindowsRegardlessOfShare = 4
    static let silenceFloor: Float = 0.0003   // ≈ −70 дБFS

    struct Result {
        var scoredWindows: Int
        var affectedWindows: Int
        var share: Double { scoredWindows > 0 ? Double(affectedWindows) / Double(scoredWindows) : 0 }
        /// Эхо есть либо в заметной доле окон, либо хотя бы в нескольких: если собеседник говорил мало,
        /// доля окон с эхом мала даже тогда, когда каждая его реплика слышна в микрофон.
        var affected: Bool {
            scoredWindows >= minScoredWindows && affectedWindows >= minAffectedWindows
                && (share >= affectedShareThreshold || affectedWindows >= minAffectedWindowsRegardlessOfShare)
        }
    }

    /// nil — измерить не удалось (дорожки слишком короткие или одна из них тишина).
    static func analyse(system: URL, mic: URL, sampleRate: Int = 16_000) -> Result? {
        let samplesPerFrame = Int(Double(sampleRate) * frameSeconds)
        let framesPerWindow = Int(windowSeconds / frameSeconds)
        let total = min(WAVReader.sampleCount(system), WAVReader.sampleCount(mic))
        guard total >= samplesPerFrame * framesPerWindow,
              let systemEnvelope = envelope(system, samples: total, samplesPerFrame: samplesPerFrame),
              let micEnvelope = envelope(mic, samples: total, samplesPerFrame: samplesPerFrame) else { return nil }

        let windows = min(systemEnvelope.count, micEnvelope.count) / framesPerWindow
        let maxLag = Int(maxLagSeconds / frameSeconds)
        var scored = 0, affected = 0
        for window in 0..<windows {
            let range = (window * framesPerWindow)..<((window + 1) * framesPerWindow)
            guard let peak = peakCorrelation(systemEnvelope[range], micEnvelope[range], maxLag: maxLag) else { continue }
            scored += 1
            if peak > correlationThreshold { affected += 1 }
        }
        return scored > 0 ? Result(scoredWindows: scored, affectedWindows: affected) : nil
    }

    private static func envelope(_ url: URL, samples: Int, samplesPerFrame: Int) -> [Double]? {
        let chunk = samplesPerFrame * 6_000   // минута звука за раз
        var out: [Double] = []
        out.reserveCapacity(samples / samplesPerFrame)
        var loudest: Double = 0
        var position = 0
        while position < samples {
            guard let data = try? WAVReader.read(url, from: position, count: min(chunk, samples - position)),
                  !data.isEmpty else { break }
            var frame = 0
            while (frame + 1) * samplesPerFrame <= data.count {
                var acc = 0.0
                for i in (frame * samplesPerFrame)..<((frame + 1) * samplesPerFrame) { acc += Double(data[i]) * Double(data[i]) }
                let rms = (acc / Double(samplesPerFrame)).squareRoot()
                loudest = max(loudest, rms)
                out.append(rms)
                frame += 1
            }
            position += data.count
        }
        return loudest > Double(silenceFloor) ? out : nil
    }

    /// Максимум нормированной корреляции по диапазону сдвигов; nil, если в окне одна из дорожек «плоская».
    private static func peakCorrelation(_ a: ArraySlice<Double>, _ b: ArraySlice<Double>, maxLag: Int) -> Double? {
        var best: Double?
        for lag in -maxLag...maxLag {
            let overlap = a.count - abs(lag)
            guard overlap > 1 else { continue }
            let aStart = a.startIndex + max(0, -lag)
            let bStart = b.startIndex + max(0, lag)
            guard let r = correlation(a[aStart..<(aStart + overlap)], b[bStart..<(bStart + overlap)]) else { continue }
            if r > (best ?? -.infinity) { best = r }
        }
        return best
    }

    private static func correlation(_ x: ArraySlice<Double>, _ y: ArraySlice<Double>) -> Double? {
        let n = Double(x.count)
        guard n > 1 else { return nil }
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var num = 0.0, dx = 0.0, dy = 0.0
        for (xi, yi) in zip(x, y) {
            let a = xi - mx, b = yi - my
            num += a * b
            dx += a * a
            dy += b * b
        }
        guard dx > 0, dy > 0 else { return nil }
        return num / (dx * dy).squareRoot()
    }
}

/// Нейросетевое акустическое эхоподавление: убирает из дорожки микрофона то, что звучало в системном звуке.
enum EchoCanceller {
    /// Модель лежит внутри приложения (2,9 МБ), при запуске из исходников — в Vendor/localvqe.
    static var modelURL: URL? {
        let fm = FileManager.default
        var folders: [URL] = []
        if let resources = Bundle.main.resourceURL { folders.append(resources) }
        folders.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Vendor/localvqe"))
        for folder in folders {
            let models = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("localvqe-") && $0.pathExtension == "gguf" }
                .sorted { $0.path < $1.path }
            if let model = models.first { return model }
        }
        return nil
    }

    /// Обрабатывает запись поблочно (память не зависит от длины встречи) и пишет результат в `output`.
    static func cancel(mic: URL, reference: URL, output: URL, model: URL,
                       onProgress: @escaping @Sendable (Double) -> Void) throws {
        let ctx = localvqe_new(model.path)
        guard ctx != 0 else { throw ProcessingError.failed("Не удалось загрузить модель эхоподавления. \(lastError(0))") }
        defer { localvqe_free(ctx) }

        let hop = Int(localvqe_hop_length(ctx))
        guard hop > 0 else { throw ProcessingError.failed("Модель эхоподавления вернула некорректный размер кадра.") }

        let total = WAVReader.sampleCount(mic)
        let staging = output.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: staging)
        let writer = try WAVWriter(url: staging)

        var micHop = [Float](repeating: 0, count: hop)
        var refHop = [Float](repeating: 0, count: hop)
        var outHop = [Float](repeating: 0, count: hop)
        let block = hop * 256
        var position = 0

        do {
            while position < total {
                try Task.checkCancellation()
                let micBlock = try WAVReader.read(mic, from: position, count: min(block, total - position))
                if micBlock.isEmpty { break }
                // Системная дорожка короче микрофона — недостающее считается тишиной.
                let refBlock = (try? WAVReader.read(reference, from: position, count: micBlock.count)) ?? []
                var samples = [Int16]()
                samples.reserveCapacity(micBlock.count)

                var start = 0
                while start < micBlock.count {
                    let valid = min(hop, micBlock.count - start)
                    for i in 0..<hop {
                        micHop[i] = i < valid ? micBlock[start + i] : 0
                        refHop[i] = start + i < refBlock.count ? refBlock[start + i] : 0
                    }
                    let code = localvqe_process_frame_f32(ctx, micHop, refHop, Int32(hop), &outHop)
                    guard code == 0 else {
                        throw ProcessingError.failed("Ошибка эхоподавления (код \(code)). \(lastError(ctx))")
                    }
                    for i in 0..<valid { samples.append(Int16(max(-1, min(1, outHop[i])) * 32767)) }
                    start += hop
                }
                writer.append(samples)
                position += micBlock.count
                onProgress(Double(position) / Double(max(1, total)))
            }
            writer.close()
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: staging, to: output)
        } catch {
            writer.close()
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private static func lastError(_ ctx: localvqe_ctx_t) -> String {
        guard let message = localvqe_last_error(ctx) else { return "" }
        return String(cString: message)
    }
}
