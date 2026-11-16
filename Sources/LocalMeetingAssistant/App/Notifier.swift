import Foundation
import UserNotifications

/// Системные уведомления с кнопками «Начать запись» / «Завершить запись».
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onOpen: (() -> Void)?
    /// «Не предлагать для этого приложения».
    var onNever: (() -> Void)?
    /// «Это другая встреча — разделить запись».
    var onSplit: (() -> Void)?
    var onSameMeeting: (() -> Void)?

    private var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    private var center: UNUserNotificationCenter { .current() }

    func setup() {
        guard available else { return }
        center.delegate = self
        let start = UNNotificationCategory(
            identifier: "SUGGEST_START",
            actions: [
                UNNotificationAction(identifier: "START", title: "Начать запись", options: []),
                UNNotificationAction(identifier: "SKIP", title: "Не сейчас", options: []),
                UNNotificationAction(identifier: "NEVER", title: "Не предлагать для этого приложения", options: []),
            ], intentIdentifiers: [])
        let stop = UNNotificationCategory(
            identifier: "SUGGEST_STOP",
            actions: [
                UNNotificationAction(identifier: "STOP", title: "Завершить запись", options: []),
                UNNotificationAction(identifier: "SKIP", title: "Продолжить", options: []),
            ], intentIdentifiers: [])
        let split = UNNotificationCategory(
            identifier: "SUGGEST_SPLIT",
            actions: [
                UNNotificationAction(identifier: "SPLIT", title: "Разделить на две встречи", options: []),
                UNNotificationAction(identifier: "SAME", title: "Это та же встреча", options: []),
            ], intentIdentifiers: [])
        center.setNotificationCategories([start, stop, split])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func suggestStart(app: String) {
        post(id: "suggest-start", category: "SUGGEST_START", title: "Похоже, началась встреча",
             body: "В приложении «\(app)» идёт звонок. Начать запись?")
    }

    func suggestStop(reason: String) {
        post(id: "suggest-stop", category: "SUGGEST_STOP", title: "Встреча закончилась?",
             body: "\(reason) Завершить запись?")
    }

    func suggestSplit(at time: Double) {
        post(id: "suggest-split", category: "SUGGEST_SPLIT", title: "Началась другая встреча?",
             body: "Звонок сменился на отметке \(Fmt.clock(time)). Разделить запись на две встречи?")
    }

    func info(title: String, body: String) {
        post(id: UUID().uuidString, category: nil, title: title, body: body)
    }

    func clearSuggestions() {
        guard available else { return }
        center.removeDeliveredNotifications(withIdentifiers: ["suggest-start", "suggest-stop", "suggest-split"])
    }

    private func post(id: String, category: String?, title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let category { content.categoryIdentifier = category }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        DispatchQueue.main.async { [self] in
            switch action {
            case "START": onStart?()
            case "STOP": onStop?()
            case "NEVER": onNever?()
            case "SPLIT": onSplit?()
            case "SAME": onSameMeeting?()
            case UNNotificationDefaultActionIdentifier: onOpen?()
            default: break
            }
        }
        completionHandler()
    }
}
