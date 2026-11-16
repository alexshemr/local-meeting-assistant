import Foundation

/// Насколько приложению можно нагружать компьютер тяжёлой обработкой (распознавание, участники, саммари).
enum PerformanceMode: String, CaseIterable, Identifiable {
    case smart, max, gentle
    var id: String { rawValue }

    var title: String {
        switch self {
        case .smart: return "Умный — не мешать звонкам"
        case .max: return "Максимальная скорость"
        case .gentle: return "Щадящий — медленно, но незаметно"
        }
    }

    var hint: String {
        switch self {
        case .smart:
            return "Обработка идёт на полной скорости, но приостанавливается, пока вы на звонке или записываете встречу, а также при нехватке памяти и перегреве. После звонка продолжается сама."
        case .max:
            return "Обработка начинается сразу и использует всё, что есть: видеоускоритель и память. Во время звонка компьютер может заметно тормозить."
        case .gentle:
            return "Саммари готовится без видеоускорителя, на части ядер процессора и с низким приоритетом — в несколько раз медленнее, зато интерфейс и демонстрация экрана остаются плавными. На время звонков обработка тоже приостанавливается."
        }
    }

    /// Запускать языковую модель на видеоускорителе.
    var usesGPU: Bool { self != .gentle }
    /// Приостанавливать обработку, пока компьютер нужен пользователю для звонка.
    var yieldsToCalls: Bool { self != .max }
}

/// Решает, можно ли сейчас выполнять тяжёлую обработку, и сообщает причину паузы.
@MainActor
final class LoadGovernor: ObservableObject {
    /// Почему обработка приостановлена; nil — можно работать.
    @Published private(set) var pauseReason: String?

    /// Обработку нужно немедленно освободить (остановить языковую модель и т. п.).
    var onPause: (() -> Void)?

    private let settings: AppSettings
    private var recording = false
    private var callApp: String?
    private var memoryCritical = false
    private var clearSince: Date?
    /// Пользователь попросил обработать сейчас, несмотря на паузу (действует, пока причина паузы не исчезнет).
    private var overridden = false
    private var memorySource: DispatchSourceMemoryPressure?

    /// Сколько секунд после окончания звонка ждать, прежде чем снова нагружать компьютер.
    private let resumeDelay: TimeInterval = 20

    init(settings: AppSettings) {
        self.settings = settings
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            let event = source.data
            Task { @MainActor in
                self?.memoryCritical = event.contains(.critical)
                self?.evaluate()
            }
        }
        source.resume()
        memorySource = source
    }

    /// Вызывается при каждом опросе состояния звука (раз в 2 секунды).
    /// `callApp` — стороннее приложение, которое сейчас использует микрофон.
    func update(recording: Bool, callApp: String?) {
        self.recording = recording
        self.callApp = callApp
        evaluate()
    }

    /// Продолжить обработку прямо сейчас, не дожидаясь конца звонка.
    func resumeNow() {
        overridden = true
        pauseReason = nil
        clearSince = nil
    }

    private var currentReason: String? {
        let reason = underlyingReason
        if reason == nil { overridden = false }
        return overridden ? nil : reason
    }

    private var underlyingReason: String? {
        guard settings.performanceMode.yieldsToCalls else { return nil }
        if recording { return "идёт запись встречи" }
        if let callApp { return "микрофон использует «\(callApp)»" }
        if memoryCritical { return "компьютеру не хватает памяти" }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return "компьютер перегрет"
        default: return nil
        }
    }

    func evaluate() {
        if let reason = currentReason {
            clearSince = nil
            let wasRunning = pauseReason == nil
            if pauseReason != reason { pauseReason = reason }
            if wasRunning { onPause?() }
        } else if pauseReason != nil {
            // Возобновляем не сразу: между звонками подряд и при коротком выключении микрофона не дёргаемся.
            let since = clearSince ?? Date()
            clearSince = since
            if !settings.performanceMode.yieldsToCalls || Date().timeIntervalSince(since) >= resumeDelay {
                pauseReason = nil
                clearSince = nil
            }
        }
    }

    /// Ждёт, пока обработку можно продолжать. Возвращается сразу, если пауза не нужна.
    func waitUntilClear() async {
        while pauseReason != nil, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}
