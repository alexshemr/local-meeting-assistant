import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

enum CaptureError: LocalizedError {
    case coreAudio(String, OSStatus)
    case noInput
    case noOutputDevice

    var errorDescription: String? {
        switch self {
        case .coreAudio(let what, let status): return "\(what) (код \(status))"
        case .noInput: return "Микрофон недоступен"
        case .noOutputDevice: return "Не найдено устройство вывода звука"
        }
    }
}

// MARK: - Core Audio helpers

enum CA {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default value: T) -> T? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? result : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var ref: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &ref) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = list.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr ? list : []
    }

    static var defaultOutputDevice: AudioObjectID? {
        value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
              default: AudioObjectID(kAudioObjectUnknown)).flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }
}

// MARK: - Часы записи

/// Общие часы для обеих дорожек: активное время записи без учёта пауз.
final class RecordingClock {
    private let lock = NSLock()
    private var startedAt = Date()
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0

    var isPaused: Bool { lock.withLock { pausedAt != nil } }

    /// Активное время в секундах; nil, если запись на паузе.
    func activeElapsed() -> TimeInterval? {
        lock.withLock { pausedAt == nil ? Date().timeIntervalSince(startedAt) - pausedTotal : nil }
    }

    /// Активное время с учётом текущей паузы (для интерфейса и финализации).
    var elapsed: TimeInterval {
        lock.withLock { (pausedAt ?? Date()).timeIntervalSince(startedAt) - pausedTotal }
    }

    func pause() { lock.withLock { if pausedAt == nil { pausedAt = Date() } } }

    func resume() {
        lock.withLock {
            if let p = pausedAt { pausedTotal += Date().timeIntervalSince(p); pausedAt = nil }
        }
    }
}

// MARK: - Ресемплер

/// Приводит произвольный входной формат к 16 кГц моно Float32.
final class Resampler {
    static let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        if inputFormat != buffer.format || converter == nil {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: Self.outputFormat)
        }
        guard let converter else { return [] }
        let ratio = Self.outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 256
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else { return [] }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = out.floatChannelData?[0], out.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }
}

// MARK: - Дорожка

/// Пишет одну дорожку (микрофон или системный звук) в WAV, выравнивая её по общим часам:
/// пропуски во входном потоке заполняются тишиной, чтобы дорожки оставались синхронными.
final class TrackWriter {
    private let lock = NSLock()
    private let writer: WAVWriter
    private let resampler = Resampler()
    private let clock: RecordingClock
    private var closed = false
    private var _level: Float = 0
    private var _peak: Float = 0

    init(url: URL, clock: RecordingClock) throws {
        writer = try WAVWriter(url: url)
        self.clock = clock
    }

    /// Уровень сигнала последнего буфера (RMS, 0…1).
    var level: Float { lock.withLock { _level } }

    /// Максимальный уровень с прошлого вызова — для отрисовки волны без пропуска коротких всплесков.
    func consumePeak() -> Float {
        lock.withLock {
            let value = _peak
            _peak = 0
            return value
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, let elapsed = clock.activeElapsed() else {
            _level = 0
            return
        }
        let floats = resampler.convert(buffer)
        guard !floats.isEmpty else { return }

        var sum: Float = 0
        var samples = [Int16](repeating: 0, count: floats.count)
        for i in 0..<floats.count {
            let v = max(-1, min(1, floats[i]))
            sum += v * v
            samples[i] = Int16(v * 32767)
        }
        _level = (sum / Float(floats.count)).squareRoot()
        _peak = max(_peak, _level)

        let target = Int(elapsed * Double(writer.sampleRate))
        let gap = target - (writer.sampleCount + samples.count)
        if gap > writer.sampleRate / 5 { writer.appendSilence(gap) }
        writer.append(samples)
    }

    /// Дополняет дорожку тишиной до общего времени записи и закрывает файл.
    func finish(totalSeconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        let target = Int(totalSeconds * Double(writer.sampleRate))
        if target > writer.sampleCount { writer.appendSilence(target - writer.sampleCount) }
        writer.close()
    }
}

// MARK: - Микрофон

final class MicCapture {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private var running = false

    func start() throws {
        try installAndStart()
        running = true
        // Смена устройства ввода (подключили наушники и т. п.) — перезапускаем захват.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.running else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            try? self.installAndStart()
        }
    }

    private func installAndStart() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        running = false
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

// MARK: - Системный звук

/// Захват всего системного звука через Core Audio process tap (macOS 14.4+).
/// Не меняет настройки аудиоустройств и работает с любыми наушниками и сервисами.
final class SystemAudioTap {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "lma.system-audio", qos: .userInitiated)
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var running = false
    private var tapBuffers: UnsafeMutableAudioBufferListPointer?

    func start() throws {
        try build()
        running = true
        // При смене устройства вывода пересобираем tap на новом устройстве.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.running else { return }
            self.teardown()
            try? self.build()
        }
        outputListener = listener
        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, listener)
    }

    func stop() {
        running = false
        if let listener = outputListener {
            var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, listener)
            outputListener = nil
        }
        queue.sync { self.teardown() }
    }

    private func build() throws {
        guard let output = CA.defaultOutputDevice,
              let outputUID = CA.string(output, kAudioDevicePropertyDeviceUID) else { throw CaptureError.noOutputDevice }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Local Meeting Assistant"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw CaptureError.coreAudio("Не удалось подключиться к системному звуку", status) }
        tapID = tap

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Local Meeting Assistant Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var aggregateDevice = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateDevice)
        guard status == noErr else {
            teardown()
            throw CaptureError.coreAudio("Не удалось создать устройство захвата системного звука", status)
        }
        aggregateID = aggregateDevice

        guard var asbd = CA.value(tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription()),
              let format = AVAudioFormat(streamDescription: &asbd) else {
            teardown()
            throw CaptureError.coreAudio("Не удалось определить формат системного звука", -1)
        }

        var proc: AudioDeviceIOProcID?
        // Сколько буферов занимает сам tap: один для чередующегося формата, иначе по одному на канал.
        let tapBufferCount = format.isInterleaved ? 1 : Int(format.channelCount)
        let tapList = AudioBufferList.allocate(maximumBuffers: tapBufferCount)
        tapBuffers = tapList
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { [weak self] _, input, _, _, _ in
            guard let self else { return }
            // Потоки tap идут ПОСЛЕДНИМИ во входном списке. Если у устройства вывода есть собственный вход
            // (гарнитура, AirPods, виртуальные драйверы), первыми идут его буферы — то есть микрофон,
            // и чтение «с начала» записывало в дорожку собеседников искажённый голос пользователя.
            let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard all.count >= tapBufferCount else { return }
            for index in 0..<tapBufferCount { tapList[index] = all[all.count - tapBufferCount + index] }
            guard tapList[0].mData != nil,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: tapList.unsafePointer,
                                                deallocator: nil) else { return }
            self.onBuffer?(buffer)
        }
        guard status == noErr, let proc else {
            teardown()
            throw CaptureError.coreAudio("Не удалось начать захват системного звука", status)
        }
        procID = proc

        status = AudioDeviceStart(aggregateID, proc)
        guard status == noErr else {
            teardown()
            throw CaptureError.coreAudio("Не удалось запустить захват системного звука", status)
        }
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        if let tapBuffers { free(tapBuffers.unsafeMutablePointer) }
        tapBuffers = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}
