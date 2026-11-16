import AVFoundation
import Foundation

/// Положение воспроизведения полной записи. Отдельный объект, чтобы ежесекундные обновления
/// перерисовывали только полосу плеера, а не всю транскрипцию.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published fileprivate(set) var position: Double = 0
    @Published fileprivate(set) var duration: Double = 0
}

/// Воспроизводит фрагмент встречи: обе дорожки (микрофон и системный звук) синхронно.
@MainActor
final class SegmentPlayer: ObservableObject {
    /// Идентификатор проигрываемого элемента (реплика или образец голоса).
    @Published private(set) var playingKey: String?

    /// Полная запись поставлена на паузу.
    @Published private(set) var paused = false
    let clock = PlaybackClock()

    private var players: [AVAudioPlayer] = []
    private var stopTimer: Timer?
    private var clockTimer: Timer?

    // MARK: Полная запись

    /// Запускает полную запись встречи, ставит на паузу или продолжает.
    func toggleFull(key: String, urls: [URL]) {
        if playingKey == key {
            if paused { startAll(at: clock.position) } else { pauseAll() }
            return
        }
        // Плеер этой записи остановлен: начинаем с того места, куда передвинут ползунок.
        let from = clock.position
        stop()
        players = urls.filter { FileManager.default.fileExists(atPath: $0.path) }.compactMap { try? AVAudioPlayer(contentsOf: $0) }
        guard !players.isEmpty else { return }
        clock.duration = players.map(\.duration).max() ?? 0
        playingKey = key
        startAll(at: from < clock.duration - 1 ? from : 0)
        clockTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Перематывает полную запись. Если она не запущена, запоминает место для будущего запуска.
    func seekFull(key: String, to time: Double) {
        clock.position = max(0, time)
        guard playingKey == key else { return }
        if paused {
            for player in players { player.currentTime = min(clock.position, max(0, player.duration - 0.1)) }
        } else {
            startAll(at: clock.position)
        }
    }

    /// Плеер показывает другую встречу: положение прежней записи больше не нужно.
    func resetClock(duration: Double) {
        clock.position = 0
        clock.duration = duration
    }

    private func startAll(at time: Double) {
        players.forEach { $0.pause() }
        let deviceTime = players[0].deviceCurrentTime + 0.05
        for player in players where time < player.duration - 0.1 {
            player.currentTime = time
            player.prepareToPlay()
            player.play(atTime: deviceTime)
        }
        clock.position = time
        paused = false
    }

    private func pauseAll() {
        players.forEach { $0.pause() }
        paused = true
    }

    private func tick() {
        guard !paused, clockTimer != nil else { return }
        if let longest = players.max(by: { $0.duration < $1.duration }), longest.isPlaying {
            clock.position = longest.currentTime
        } else if !players.contains(where: \.isPlaying) {
            stop()
            clock.position = 0
        }
    }

    // MARK: Фрагменты

    func toggle(key: String, urls: [URL], start: Double, end: Double) {
        if playingKey == key {
            stop()
            return
        }
        stop()
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        players = existing.compactMap { try? AVAudioPlayer(contentsOf: $0) }
        guard !players.isEmpty else { return }

        let startTime = max(0, start - 0.15)
        let length = max(0.3, end - startTime + 0.25)
        let deviceTime = players[0].deviceCurrentTime + 0.05
        for player in players {
            player.currentTime = min(startTime, max(0, player.duration - 0.1))
            player.prepareToPlay()
            player.play(atTime: deviceTime)
        }
        playingKey = key
        stopTimer = Timer.scheduledTimer(withTimeInterval: length, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    func stop() {
        stopTimer?.invalidate()
        stopTimer = nil
        clockTimer?.invalidate()
        clockTimer = nil
        paused = false
        players.forEach { $0.stop() }
        players = []
        playingKey = nil
    }
}
