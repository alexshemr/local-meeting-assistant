import AVFoundation
import Foundation

/// Воспроизводит фрагмент встречи: обе дорожки (микрофон и системный звук) синхронно.
@MainActor
final class SegmentPlayer: ObservableObject {
    /// Идентификатор проигрываемого элемента (реплика или образец голоса).
    @Published private(set) var playingKey: String?

    private var players: [AVAudioPlayer] = []
    private var stopTimer: Timer?

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
        players.forEach { $0.stop() }
        players = []
        playingKey = nil
    }
}
