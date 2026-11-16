import Foundation

/// Потоковая запись 16-битного моно WAV. Заголовок периодически обновляется,
/// поэтому файл остаётся читаемым даже при аварийном завершении приложения.
final class WAVWriter {
    static let headerSize = 44

    let sampleRate: Int
    private let handle: FileHandle
    private(set) var sampleCount = 0
    private var samplesAtLastHeaderUpdate = 0

    init(url: URL, sampleRate: Int = 16_000) throws {
        self.sampleRate = sampleRate
        FileManager.default.createFile(atPath: url.path, contents: Self.header(sampleRate: sampleRate, dataBytes: 0))
        handle = try FileHandle(forUpdating: url)
        try handle.seekToEnd()
    }

    func append(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        samples.withUnsafeBufferPointer { handle.write(Data(buffer: $0)) }
        sampleCount += samples.count
        if sampleCount - samplesAtLastHeaderUpdate > sampleRate * 10 { updateHeader() }
    }

    func appendSilence(_ count: Int) {
        guard count > 0 else { return }
        var remaining = count
        while remaining > 0 {
            let n = min(remaining, sampleRate * 5)
            handle.write(Data(count: n * 2))
            remaining -= n
        }
        sampleCount += count
    }

    func close() {
        updateHeader()
        try? handle.synchronize()
        try? handle.close()
    }

    private func updateHeader() {
        samplesAtLastHeaderUpdate = sampleCount
        try? handle.seek(toOffset: 0)
        handle.write(Self.header(sampleRate: sampleRate, dataBytes: sampleCount * 2))
        _ = try? handle.seekToEnd()
    }

    static func header(sampleRate: Int, dataBytes: Int) -> Data {
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(36 + dataBytes)
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(dataBytes)
        return d
    }

    /// Восстанавливает заголовок по фактическому размеру файла (после сбоя).
    static func repair(url: URL, sampleRate: Int = 16_000) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
              size >= headerSize, let handle = try? FileHandle(forUpdating: url) else { return }
        let dataBytes = (size - headerSize) / 2 * 2
        try? handle.seek(toOffset: 0)
        handle.write(header(sampleRate: sampleRate, dataBytes: dataBytes))
        try? handle.close()
    }
}

enum WAVFile {
    /// Копирует отрезок записи [from, to) в сэмплах в новый файл. Читает порциями: записи бывают многочасовыми.
    static func copy(_ source: URL, to destination: URL, from: Int, to end: Int, sampleRate: Int = 16_000) throws {
        let total = WAVReader.sampleCount(source)
        let start = max(0, min(from, total)), stop = max(start, min(end, total))
        FileManager.default.createFile(atPath: destination.path,
                                       contents: WAVWriter.header(sampleRate: sampleRate, dataBytes: (stop - start) * 2))
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try input.seek(toOffset: UInt64(WAVWriter.headerSize + start * 2))
        try output.seekToEnd()
        var remaining = (stop - start) * 2
        while remaining > 0 {
            let chunk = input.readData(ofLength: min(remaining, 4 << 20))
            if chunk.isEmpty { break }
            output.write(chunk)
            remaining -= chunk.count
        }
    }
}

enum WAVReader {
    static func sampleCount(_ url: URL) -> Int {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        else { return 0 }
        return max(0, (size - WAVWriter.headerSize) / 2)
    }

    static func read(_ url: URL, from start: Int, count: Int) throws -> [Float] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(WAVWriter.headerSize + start * 2))
        let data = handle.readData(ofLength: count * 2)
        let n = data.count / 2
        var out = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<n { out[i] = Float(Int16(littleEndian: src[i])) / 32768.0 }
        }
        return out
    }
}
