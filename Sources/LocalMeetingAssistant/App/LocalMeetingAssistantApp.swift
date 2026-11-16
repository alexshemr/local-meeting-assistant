import AppKit
import SwiftUI

@main
struct LocalMeetingAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        Window("Local Meeting Assistant", id: "main") {
            MainWindow()
                .appEnvironment(state)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuContent(state: state, menu: state.menuBar)
        } label: {
            MenuBarLabel(state: state, menu: state.menuBar)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Служебные проверки без интерфейса и без доступа к хранилищу встреч:
        //   --check-echo <mic.wav> <system.wav> [<out.wav>]   детектор эха и (если задан out) эхоподавление
        //   --check-import <файл> <out.wav>                   конвертация файла в рабочий формат
        if SelfCheck.runIfRequested() { exit(0) }
        // Один экземпляр на пользователя: два процесса с общим хранилищем встреч мешали бы друг другу.
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if let existing = others.first {
                existing.activate()
                exit(0)
            }
        }
        Task { @MainActor in
            AppState.shared.bootstrap()
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            // Если система не восстановила окно с прошлого запуска — открываем его сами.
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Self.hasVisibleMainWindow { AppState.shared.showMainWindow() }
        }
    }

    /// Повторный запуск из Finder или Launchpad при уже работающем приложении.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            if !Self.hasVisibleMainWindow { AppState.shared.showMainWindow() }
        }
        return true
    }

    @MainActor
    private static var hasVisibleMainWindow: Bool {
        NSApp.windows.contains { $0.isVisible && $0.canBecomeMain && $0.frame.width > 400 }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppState.shared.shutdown() }
    }
}

extension View {
    @MainActor
    func appEnvironment(_ state: AppState) -> some View {
        environmentObject(state)
            .environmentObject(state.settings)
            .environmentObject(state.store)
            .environmentObject(state.recorder)
            .environmentObject(state.pipeline)
            .environmentObject(state.models)
            .environmentObject(state.player)
            .environmentObject(state.voices)
            .environmentObject(state.governor)
            .environmentObject(state.calendar)
    }
}

// MARK: - Меню-бар

/// Всё, что показывает строка меню. Значок и меню подписаны только на эту модель, и она меняется
/// лишь тогда, когда меняется то, что реально видно. Подписка на запись и обработку целиком заставляла
/// систему перерисовывать значок несколько раз в секунду (уровни звука, каждое слово саммари) —
/// это заметно нагружало компьютер во время встреч.
@MainActor
final class MenuBarModel: ObservableObject {
    @Published private(set) var recording: RecordingController.State = .idle
    @Published private(set) var startSuggestion: String?
    @Published private(set) var stopSuggestion = false
    @Published private(set) var processing = false

    func update(recording: RecordingController.State, startSuggestion: String?, stopSuggestion: Bool, processing: Bool) {
        if self.recording != recording { self.recording = recording }
        if self.startSuggestion != startSuggestion { self.startSuggestion = startSuggestion }
        if self.stopSuggestion != stopSuggestion { self.stopSuggestion = stopSuggestion }
        if self.processing != processing { self.processing = processing }
    }

    var icon: String {
        switch recording {
        case .recording: return "record.circle.fill"
        case .paused: return "pause.circle.fill"
        case .idle:
            if startSuggestion != nil { return "mic.badge.plus" }
            return processing ? "waveform.circle.fill" : "waveform.circle"
        }
    }
}

struct MenuBarLabel: View {
    let state: AppState
    @ObservedObject var menu: MenuBarModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: menu.icon)
            .onAppear {
                state.openMainWindow = { openWindow(id: "main") }
            }
    }
}

struct MenuContent: View {
    let state: AppState
    @ObservedObject var menu: MenuBarModel

    private var recorder: RecordingController { state.recorder }

    var body: some View {
        Text(statusLine)

        if let app = menu.startSuggestion, menu.recording == .idle {
            Text("В приложении «\(app)» идёт звонок")
            if state.canIgnoreSuggestedApp {
                Button("Не предлагать для «\(app)»") { state.ignoreSuggestedApp() }
            }
        }
        if menu.stopSuggestion, menu.recording != .idle {
            Text("Похоже, встреча закончилась")
        }

        Divider()

        switch menu.recording {
        case .idle:
            Button("Начать запись") { state.startRecording() }
                .keyboardShortcut("r")
        case .recording:
            Button("Пауза") { recorder.pause() }
            Button("Завершить запись") { state.stopRecording() }
                .keyboardShortcut("r")
        case .paused:
            Button("Продолжить запись") { recorder.resume() }
            Button("Завершить запись") { state.stopRecording() }
                .keyboardShortcut("r")
        }

        Divider()

        Button("Импортировать запись…") {
            state.showMainWindow()
            state.chooseFilesToImport()
        }
        Button("Открыть Local Meeting Assistant") { state.showMainWindow() }
            .keyboardShortcut("o")
        Button("Настройки…") { state.showSettings() }
            .keyboardShortcut(",")

        Divider()

        Button("Выйти") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch menu.recording {
        case .recording: return "Идёт запись"
        case .paused: return "Запись на паузе"
        case .idle: return menu.processing ? "Идёт обработка встречи" : "Запись не идёт"
        }
    }
}

enum SelfCheck {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--check-echo"), i + 2 < args.count {
            let mic = URL(fileURLWithPath: args[i + 1]), system = URL(fileURLWithPath: args[i + 2])
            report("before", EchoBleedDetector.analyse(system: system, mic: mic))
            if i + 3 < args.count, !args[i + 3].hasPrefix("--") {
                let out = URL(fileURLWithPath: args[i + 3])
                guard let model = EchoCanceller.modelURL else { print("model: NOT FOUND"); return true }
                let started = Date()
                do {
                    try EchoCanceller.cancel(mic: mic, reference: system, output: out, model: model) { _ in }
                    let seconds = Double(WAVReader.sampleCount(mic)) / 16_000
                    print(String(format: "cancelled %.1f s of audio in %.2f s", seconds, Date().timeIntervalSince(started)))
                    report("after", EchoBleedDetector.analyse(system: system, mic: out))
                } catch { print("cancel FAILED: \(error.localizedDescription)") }
            }
            return true
        }
        // --check-samples: образцы голоса по сохранённым встречам (только чтение), деление на фразы, классы приложений.
        if args.contains("--check-samples") {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let dirs = (try? FileManager.default.contentsOfDirectory(at: AppPaths.meetings, includingPropertiesForKeys: nil)) ?? []
            for dir in dirs {
                guard let data = try? Data(contentsOf: dir.appendingPathComponent("meeting.json")),
                      let meeting = try? decoder.decode(Meeting.self, from: data) else { continue }
                print("== \(meeting.title)")
                for speaker in meeting.activeSpeakers {
                    guard let sample = meeting.voiceSample(for: speaker.id) else { continue }
                    let clash = meeting.utterances.filter {
                        $0.speakerID != speaker.id && $0.start < sample.end && $0.end > sample.start
                    }.count
                    print(String(format: "  %@: %@ %.1f–%.1f (%.1f s), overlapping other speakers: %d", speaker.label,
                                 sample.track.rawValue, sample.start, sample.end, sample.end - sample.start, clash))
                }
            }
            print(AppState.sentences("Да, хорошо. А что по срокам? Версия 2.5 выйдет в июне… Посмотрим"))
            for id in ["com.apple.VoiceMemos", "us.zoom.xos", "com.google.Chrome", "ru.keepcoder.Telegram",
                       "com.anthropic.claudefordesktop", "com.microsoft.teams2", "Mattermost.Desktop"] {
                print(id, MicActivityMonitor.kind(of: id))
            }
            return true
        }
        // --check-diar <wav> [<число спикеров>]: разделение голосов с заданным числом спикеров.
        if let i = args.firstIndex(of: "--check-diar"), i + 1 < args.count {
            let wav = URL(fileURLWithPath: args[i + 1])
            let count = i + 2 < args.count ? Int(args[i + 2]) : nil
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    let diarizer = SpeakerDiarizer()
                    try await diarizer.prepare(speakers: count)
                    let output = try await diarizer.process(wav: wav) { _ in }
                    var seconds: [String: Double] = [:]
                    for segment in output.segments { seconds[segment.speaker, default: 0] += segment.end - segment.start }
                    print("speakers: \(seconds.count)", seconds.sorted { $0.key < $1.key }.map { String(format: "%@=%.0fs", $0.key, $0.value) })
                } catch { print("diar FAILED: \(error.localizedDescription)") }
                done.signal()
            }
            done.wait()
            return true
        }
        // --check-llm: какие движки найдены и отвечают ли они на короткий тестовый вопрос.
        if args.contains("--check-llm") {
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                // Главный поток здесь занят ожиданием, поэтому ищем движки напрямую, без модели интерфейса.
                let found: [(LLMEngine, EngineInfo)] = [
                    (.ollama, await EngineDiscovery.findOllama()), (.claude, await EngineDiscovery.findClaude()),
                    (.codex, await EngineDiscovery.findCodex()),
                ]
                for (engine, info) in found {
                    print("\(engine.rawValue): available=\(info.available) binary=\(info.binary?.path ?? "-") models=\(info.models.map(\.id)) note=\(info.note)")
                    guard info.available else { continue }
                    let backend: LLMClient.Backend = engine == .ollama
                        ? .ollama(model: info.models.first?.id ?? "")
                        : .cli(engine: engine, binary: info.binary!, model: "")
                    let started = Date()
                    do {
                        let answer = try await LLMClient(backend: backend).generate(
                            prompt: "Ответь одним словом: столица Франции?", maxTokens: 50) { _ in }
                        print(String(format: "  answer in %.1f s: %@", Date().timeIntervalSince(started), String(answer.prefix(80))))
                    } catch { print("  FAILED: \(error.localizedDescription)") }
                }
                done.signal()
            }
            done.wait()
            return true
        }
        if let i = args.firstIndex(of: "--check-import"), i + 2 < args.count {
            let source = URL(fileURLWithPath: args[i + 1]), out = URL(fileURLWithPath: args[i + 2])
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    let seconds = try await AudioImporter.convert(source, to: out)
                    print(String(format: "import ok: %.2f s -> %@", seconds, out.lastPathComponent))
                } catch { print("import FAILED: \(error.localizedDescription)") }
                done.signal()
            }
            done.wait()
            return true
        }
        return false
    }

    private static func report(_ label: String, _ result: EchoBleedDetector.Result?) {
        guard let result else { print("\(label): not measurable"); return }
        print(String(format: "%@: affected=%@ windows=%d/%d share=%.2f", label, result.affected ? "YES" : "no",
                     result.affectedWindows, result.scoredWindows, result.share))
    }
}
