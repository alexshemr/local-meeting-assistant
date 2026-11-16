import AVFoundation
import Foundation

@MainActor
final class RecordingController: ObservableObject {
    enum State { case idle, recording, paused }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var meetingID: UUID?
    @Published var errorMessage: String?
    /// Системный звук не пишется (нет разрешения или ошибка устройства) — запись идёт только с микрофона.
    @Published private(set) var systemAudioWarning: String?

    var onFinished: ((UUID) -> Void)?

    private let store: MeetingStore
    private var clock = RecordingClock()
    private var mic: MicCapture?
    private var systemTap: SystemAudioTap?
    private var micTrack: TrackWriter?
    private var systemTrack: TrackWriter?
    private var timer: Timer?
    private var lastSavedDuration: TimeInterval = 0
    /// Когда в последний раз было слышно собеседников и сколько всего они звучали (в отсчётах волны).
    private var lastSystemSound: Date?
    private var systemSoundTicks = 0

    /// Сколько секунд подряд не слышно собеседников. nil — если в этой записи их и не было слышно
    /// (очная встреча, диктовка): тогда тишина ничего не значит.
    var systemSilence: TimeInterval? {
        guard state == .recording, let last = lastSystemSound,
              Double(systemSoundTicks) * Self.tickInterval >= 20 else { return nil }
        return Date().timeIntervalSince(last)
    }
    /// Как часто обновляются таймер и индикаторы уровня. Реже — меньше перерисовок во время встречи.
    static let tickInterval: TimeInterval = 0.5

    init(store: MeetingStore) {
        self.store = store
    }

    var isActive: Bool { state != .idle }

    /// Точное время записи прямо сейчас (публикуемое `elapsed` обновляется раз в секунду).
    var currentElapsed: TimeInterval { clock.elapsed }

    func start(sourceApp: String? = nil) async {
        guard state == .idle else { return }
        errorMessage = nil
        systemAudioWarning = nil

        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            errorMessage = "Нет доступа к микрофону. Разрешите его в Системных настройках → Конфиденциальность и безопасность → Микрофон."
            return
        }

        let now = Date()
        var meeting = Meeting(title: Meeting.defaultTitle(for: now), startedAt: now)
        meeting.sourceApp = sourceApp
        store.add(meeting)

        do {
            let clock = RecordingClock()
            let micTrack = try TrackWriter(url: store.micURL(meeting.id), clock: clock)
            let systemTrack = try TrackWriter(url: store.systemURL(meeting.id), clock: clock)

            let mic = MicCapture()
            mic.onBuffer = { micTrack.append($0) }
            try mic.start()

            let tap = SystemAudioTap()
            tap.onBuffer = { systemTrack.append($0) }
            do {
                try tap.start()
            } catch {
                systemAudioWarning = "Системный звук не записывается: \(error.localizedDescription). Проверьте разрешение «Запись системного аудио»."
            }

            self.clock = clock
            self.mic = mic
            self.systemTap = tap
            self.micTrack = micTrack
            self.systemTrack = systemTrack
        } catch {
            store.delete(meeting.id)
            errorMessage = "Не удалось начать запись: \(error.localizedDescription)"
            return
        }

        meetingID = meeting.id
        elapsed = 0
        lastSavedDuration = 0
        state = .recording
        lastSystemSound = nil
        systemSoundTicks = 0
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // .common — чтобы таймер не замирал, пока открыто меню или идёт прокрутка.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func pause() {
        guard state == .recording else { return }
        clock.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        clock.resume()
        if lastSystemSound != nil { lastSystemSound = Date() }
        state = .recording
    }

    func stop() {
        guard state != .idle, let id = meetingID else { return }
        timer?.invalidate()
        timer = nil
        mic?.stop()
        systemTap?.stop()

        let total = clock.elapsed
        micTrack?.finish(totalSeconds: total)
        systemTrack?.finish(totalSeconds: total)
        mic = nil
        systemTap = nil
        micTrack = nil
        systemTrack = nil

        store.update(id) {
            $0.duration = total
            $0.status = .queued
        }
        state = .idle
        meetingID = nil
        micLevel = 0
        systemLevel = 0
        elapsed = 0
        onFinished?(id)
    }

    private func tick() {
        let systemPeak = systemTrack?.consumePeak() ?? 0
        _ = micTrack?.consumePeak()
        if state == .recording, systemPeak > 0.003 {
            lastSystemSound = Date()
            systemSoundTicks += 1
        }
        // Публикуем только заметные изменения: каждое обновление перерисовывает окно и значок в строке меню.
        let now = clock.elapsed
        if Int(now) != Int(elapsed) { elapsed = now }
        let mic = micTrack?.level ?? 0, system = systemTrack?.level ?? 0
        if abs(mic - micLevel) > 0.004 { micLevel = mic }
        if abs(system - systemLevel) > 0.004 { systemLevel = system }
        let elapsed = now
        // Периодически фиксируем длительность, чтобы после сбоя встреча осталась корректной.
        if let id = meetingID, elapsed - lastSavedDuration > 15 {
            lastSavedDuration = elapsed
            store.update(id) { $0.duration = elapsed }
        }
    }

    /// Логарифмическая шкала −55 дБ … −5 дБ → 0…1.
    private static func normalized(_ rms: Float) -> Float {
        guard rms > 0.0005 else { return 0 }
        return max(0, min(1, (20 * log10(rms) + 55) / 50))
    }

    /// Отладка вёрстки (`--demo-recording`): изображает идущую запись без захвата звука.
    func showDemoRecording() {
        state = .recording
        elapsed = 83
        micLevel = 0.08
        systemLevel = 0.03
    }
}
