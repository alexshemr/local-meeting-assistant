import EventKit
import Foundation

/// Приглашённый на событие календаря.
struct CalendarAttendee: Codable, Hashable, Identifiable {
    var name: String
    var email: String
    /// accepted, declined, tentative, pending
    var status: String
    var isSelf = false
    var isOrganizer = false

    var id: String { email.isEmpty ? name : email.lowercased() }

    var statusTitle: String {
        switch status {
        case "accepted": return "принял приглашение"
        case "declined": return "отклонил приглашение"
        case "tentative": return "под вопросом"
        default: return "не ответил на приглашение"
        }
    }
}

/// Событие календаря — в том виде, в каком оно сохраняется во встрече и показывается в интерфейсе.
struct CalendarEvent: Codable, Hashable, Identifiable {
    /// Идентификатор события; у повторяющихся событий дополнен датой начала.
    var id: String
    var title: String
    var start: Date
    var end: Date
    var calendar: String
    var attendees: [CalendarAttendee] = []

    func matches(_ query: String) -> Bool {
        func has(_ s: String) -> Bool { s.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return has(title) || attendees.contains { has($0.name) || has($0.email) }
    }
}

/// Доступ к календарям macOS. Google Календарь попадает сюда, когда аккаунт Google добавлен
/// в «Системные настройки → Учётные записи интернета» с включёнными календарями: приложению не нужен
/// собственный вход в Google, а данные читаются локально, как у встроенного приложения «Календарь».
@MainActor
final class CalendarService: ObservableObject {
    struct Source: Identifiable, Hashable {
        var id: String
        var title: String
        var account: String
    }

    @Published private(set) var authorized = false
    @Published private(set) var denied = false
    @Published private(set) var sources: [Source] = []
    /// События за окно «два месяца назад — три недели вперёд», от новых к старым.
    @Published private(set) var events: [CalendarEvent] = []

    private let store = EKEventStore()
    private let settings: AppSettings
    private var observer: NSObjectProtocol?
    var onChange: (() -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        updateStatus()
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        if authorized { reload() }
    }

    private func updateStatus() {
        let status = EKEventStore.authorizationStatus(for: .event)
        authorized = status == .fullAccess
        denied = status == .denied || status == .restricted
    }

    /// Спрашивает у macOS доступ к календарям.
    func connect() async {
        _ = try? await store.requestFullAccessToEvents()
        updateStatus()
        if authorized {
            settings.calendarEnabled = true
            reload()
        }
    }

    func reload() {
        guard authorized, settings.calendarEnabled else {
            events = []
            sources = []
            onChange?()
            return
        }
        let calendars = store.calendars(for: .event)
        sources = calendars.map { Source(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "") }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
        let used = calendars.filter { !settings.disabledCalendars.contains($0.calendarIdentifier) }
        guard !used.isEmpty else {
            events = []
            onChange?()
            return
        }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-60 * 86_400),
                                                 end: now.addingTimeInterval(21 * 86_400), calendars: used)
        events = store.events(matching: predicate).filter { !$0.isAllDay }.map(Self.convert).sorted { $0.start > $1.start }
        onChange?()
    }

    private static func convert(_ event: EKEvent) -> CalendarEvent {
        let organizer = event.organizer?.url
        var attendees: [CalendarAttendee] = (event.attendees ?? []).filter { $0.participantType != .room && $0.participantType != .resource }.map { person in
            let email = person.url.absoluteString.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive)
            let status: String
            switch person.participantStatus {
            case .accepted: status = "accepted"
            case .declined: status = "declined"
            case .tentative: status = "tentative"
            default: status = "pending"
            }
            var name = person.name ?? ""
            if name.isEmpty || name.contains("@") { name = email.split(separator: "@").first.map(String.init) ?? email }
            return CalendarAttendee(name: name, email: email.contains("@") ? email : "", status: status,
                                    isSelf: person.isCurrentUser, isOrganizer: person.url == organizer)
        }
        // Один и тот же человек иногда приходит дважды (как организатор и как участник).
        var seen = Set<String>()
        attendees = attendees.filter { seen.insert($0.id).inserted }
        let base = event.eventIdentifier ?? UUID().uuidString
        let id = event.hasRecurrenceRules ? "\(base)@\(Int(event.startDate.timeIntervalSince1970))" : base
        return CalendarEvent(id: id, title: (event.title ?? "").isEmpty ? "Без названия" : event.title,
                             start: event.startDate, end: event.endDate, calendar: event.calendar?.title ?? "",
                             attendees: attendees)
    }

    func event(_ id: String) -> CalendarEvent? { events.first { $0.id == id } }

    /// Событие, во время которого шла встреча: с наибольшим пересечением по времени.
    func bestEvent(start: Date, duration: Double) -> CalendarEvent? {
        let end = start.addingTimeInterval(duration)
        var best: (event: CalendarEvent, overlap: Double)?
        for event in events {
            let overlap = min(end, event.end).timeIntervalSince(max(start, event.start))
            let shorter = min(duration, event.end.timeIntervalSince(event.start))
            // Пересечение должно быть существенным: хотя бы 40% более короткого из двух отрезков и не меньше двух минут.
            guard overlap >= max(120, shorter * 0.4) || (shorter < 300 && overlap >= shorter * 0.6) else { continue }
            if overlap > (best?.overlap ?? 0) { best = (event, overlap) }
        }
        return best?.event
    }
}
