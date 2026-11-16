import AppKit
import CoreAudio
import Foundation

/// Приложение, в котором, похоже, идёт звонок.
struct DetectedCall: Equatable {
    var name: String
    /// Идентификатор основного приложения (для списка «не предлагать»).
    var bundleID: String
}

/// Определяет, что на компьютере идёт звонок, — чтобы предложить запись.
///
/// Сам звук не читает — только опрашивает состояние аудиопроцессов системы. Один лишь включённый
/// микрофон звонком не считается: так выглядят и диктовка, и голосовое сообщение, и диктофон.
/// Звонок — это двусторонний звук: приложение одновременно слушает микрофон и воспроизводит звук
/// собеседников, причём не пару секунд, а устойчиво. Исключение — программы, созданные именно
/// для встреч (Zoom, Teams и т. п.): для них достаточно включённого микрофона.
@MainActor
final class MicActivityMonitor {
    var onCallStarted: ((DetectedCall) -> Void)?
    /// Звонок закончился: приложение перестало и слушать, и воспроизводить.
    var onCallEnded: (() -> Void)?
    /// Приложение звонка ненадолго отпустило микрофон и заняло его снова — так выглядит переход
    /// из одной встречи в другую (в том же браузере). Параметр — момент, когда микрофон был отпущен.
    var onCallSwitched: ((Date) -> Void)?
    /// Когда закончился последний звонок (микрофон отпущен).
    private(set) var lastCallEnd: Date?
    /// Вызывается при каждом опросе (раз в 2 секунды) — для проверок, которым нужен тот же ритм.
    var onPoll: (() -> Void)?
    /// Приложения, которые пользователь попросил не учитывать (идентификатор основного приложения).
    var isIgnoredByUser: ((String) -> Bool)?

    private var timer: Timer?
    /// С какого момента приложение непрерывно выглядит как звонок.
    private var qualifiedSince: [String: Date] = [:]
    private var active: DetectedCall?
    /// Стороннее приложение, которое прямо сейчас использует микрофон (звонок, диктовка — что угодно).
    private(set) var micUser: String?
    private var lastInput = Date.distantPast
    private var lastAlive = Date.distantPast
    private var inputLostAt: Date?
    /// Микрофон должен быть отпущен хотя бы на столько секунд, чтобы это считалось сменой звонка.
    private let switchGap: TimeInterval = 3.5

    /// Сколько секунд должен продержаться двусторонний звук, чтобы считать его звонком.
    private let twoWayDelay: TimeInterval = 10
    /// Для программ, созданных для встреч, достаточно включённого микрофона на это время.
    private let meetingAppDelay: TimeInterval = 4
    private let endDelay: TimeInterval = 20
    /// Если микрофон отпущен дольше этого времени, звук из того же приложения звонком уже не считаем
    /// (например, в браузере осталась играть музыка).
    private let outputOnlyGrace: TimeInterval = 90

    /// Системные службы, которые слушают микрофон сами по себе (Siri, диктовка, голосовое управление).
    nonisolated private static let systemPrefixes = [
        "com.apple.corespeech", "com.apple.assistant", "com.apple.speechrecognitioncore", "com.apple.speech",
        "com.apple.siri", "com.apple.controlcenter", "com.apple.accessibility", "com.apple.voicecontrol",
        "com.apple.dictation", "com.apple.audio", "com.apple.coreaudio",
    ]
    /// Программы, в которых микрофон — это не встреча, даже если они сами что-то воспроизводят:
    /// диктофоны, диктовка, голосовые ассистенты, запись экрана и звука.
    nonisolated private static let neverMarkers = [
        "voicememos", "whisper", "wispr", "voiceink", "dictat", "com.openai.", "anthropic", "claude",
        "obsproject", "audacity", "garageband", "com.apple.logic", "quicktime", "screencaptureui", "loom",
        "shazam", "com.apple.photo-booth", "elevenlabs", "talon",
    ]
    /// Программы, созданные для встреч.
    nonisolated private static let meetingMarkers = [
        "us.zoom", "com.microsoft.teams", "webex", "com.apple.facetime", "skype", "telemost", "jitsi",
        "gotomeeting", "bluejeans", "whereby", "trueconf", "ktalk", "kontur.talk", "mts-link", "webinar",
        "sberjazz", "salutejazz", "com.google.meet", "pexip", "lifesize", "ringcentral", "avconferenced",
    ]

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private struct AppAudio {
        var name: String
        var input = false
        var output = false
    }

    private func poll() {
        defer { onPoll?() }
        let apps = audioApps()
        let now = Date()
        micUser = apps.first { $0.value.input && isIgnoredByUser?($0.key) != true }?.value.name

        if let call = active {
            let state = apps[call.bundleID]
            if state?.input == true {
                if let lost = inputLostAt, now.timeIntervalSince(lost) >= switchGap { onCallSwitched?(lost) }
                inputLostAt = nil
                lastInput = now
            } else if inputLostAt == nil {
                inputLostAt = now
            }
            let alive = state?.input == true
                || (state?.output == true && now.timeIntervalSince(lastInput) < outputOnlyGrace)
            if alive { lastAlive = now }
            if now.timeIntervalSince(lastAlive) >= endDelay {
                active = nil
                qualifiedSince = [:]
                lastCallEnd = inputLostAt ?? lastInput
                inputLostAt = nil
                onCallEnded?()
            }
            return
        }

        var stillQualified = Set<String>()
        for (bundleID, app) in apps where app.input {
            let kind = Self.kind(of: bundleID)
            if kind == .never || isIgnoredByUser?(bundleID) == true { continue }
            guard kind == .meeting || app.output else { continue }
            stillQualified.insert(bundleID)
            let since = qualifiedSince[bundleID] ?? now
            qualifiedSince[bundleID] = since
            if now.timeIntervalSince(since) >= (kind == .meeting ? meetingAppDelay : twoWayDelay) {
                let call = DetectedCall(name: app.name, bundleID: bundleID)
                active = call
                lastInput = now
                lastAlive = now
                onCallStarted?(call)
                break
            }
        }
        qualifiedSince = qualifiedSince.filter { stillQualified.contains($0.key) }
    }

    enum Kind { case never, meeting, other }

    nonisolated static func kind(of bundleID: String) -> Kind {
        let id = bundleID.lowercased()
        if neverMarkers.contains(where: { id.contains($0) }) { return .never }
        if meetingMarkers.contains(where: { id.contains($0) }) { return .meeting }
        return .other
    }

    /// Состояние звука сторонних приложений: вспомогательные процессы (вкладки браузера и т. п.)
    /// сведены к основному приложению.
    private func audioApps() -> [String: AppAudio] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications
        var result: [String: AppAudio] = [:]
        for process in CA.objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
            let input = (CA.value(process, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) ?? 0) != 0
            let output = (CA.value(process, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) ?? 0) != 0
            guard input || output,
                  let pid = CA.value(process, kAudioProcessPropertyPID, default: pid_t(0)), pid != ownPID else { continue }
            let bundleID = CA.string(process, kAudioProcessPropertyBundleID) ?? ""
            let lowered = bundleID.lowercased()
            if Self.systemPrefixes.contains(where: { lowered.hasPrefix($0) }) { continue }
            let owner = Self.owner(pid: pid, bundleID: bundleID, running: running)
            var app = result[owner.bundleID] ?? AppAudio(name: owner.name)
            app.input = app.input || input
            app.output = app.output || output
            result[owner.bundleID] = app
        }
        return result
    }

    private static func owner(pid: pid_t, bundleID: String, running: [NSRunningApplication]) -> (bundleID: String, name: String) {
        if let exact = running.first(where: { $0.processIdentifier == pid }), exact.activationPolicy == .regular,
           let name = exact.localizedName {
            return (exact.bundleIdentifier ?? bundleID, name)
        }
        // Вспомогательные процессы браузеров и Electron-приложений: «com.google.Chrome.helper» → Chrome.
        if !bundleID.isEmpty,
           let parent = running.first(where: {
               $0.activationPolicy == .regular && ($0.bundleIdentifier.map { bundleID.hasPrefix($0) } ?? false)
           }), let parentID = parent.bundleIdentifier, let name = parent.localizedName {
            return (parentID, name)
        }
        // Safari и другие приложения на WebKit захватывают звук в общем системном процессе.
        if bundleID.hasPrefix("com.apple.WebKit") { return ("com.apple.Safari", "Safari") }
        if bundleID == "com.apple.avconferenced" { return (bundleID, "FaceTime") }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName
        return (bundleID.isEmpty ? "pid-\(pid)" : bundleID, name ?? (bundleID.isEmpty ? "другое приложение" : bundleID))
    }
}
