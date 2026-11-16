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
        let own = settings.ownEmails
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-180 * 86_400),
                                                 end: now.addingTimeInterval(60 * 86_400), calendars: used)
        events = store.events(matching: predicate).filter { !$0.isAllDay }.map { Self.convert($0, own: own) }.sorted { $0.start > $1.start }
        onChange?()
    }

    private static func convert(_ event: EKEvent, own: Set<String>) -> CalendarEvent {
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
                                    isSelf: person.isCurrentUser || own.contains(email.lowercased()), isOrganizer: person.url == organizer)
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

    /// Отладка вёрстки (`--demo-calendar`): вымышленные события на текущую неделю, без доступа к календарю.
    func loadDemo() {
        authorized = true
        let monday = Cal.startOfWeek(Date())
        func at(_ day: Int, _ hour: Double, _ minutes: Double, _ title: String, _ people: [String]) -> CalendarEvent {
            let start = monday.addingTimeInterval(Double(day) * 86_400 + hour * 3600)
            let attendees = people.map { CalendarAttendee(name: $0, email: "", status: "accepted") }
            return CalendarEvent(id: "demo-\(day)-\(hour)-\(title)", title: title, start: start, end: start.addingTimeInterval(minutes * 60),
                                 calendar: "Работа", attendees: attendees)
        }
        events = [
            at(0, 10, 30, "Планёрка команды", ["Анна", "Борис"]), at(0, 11, 60, "Интеграция с партнёром", ["Вера"]),
            at(0, 11.5, 45, "Созвон с подрядчиком", ["Глеб"]), at(1, 9.5, 30, "Стендап", ["Анна"]),
            at(1, 13, 60, "Обед", []), at(1, 15, 90, "Демо продукта", ["Вера", "Глеб", "Дарья"]),
            at(2, 10, 30, "Планёрка команды", ["Анна", "Борис"]), at(2, 16, 45, "Один на один", ["Борис"]),
            at(3, 12, 60, "Сверка статусов", ["Дарья"]), at(3, 12, 30, "Короткий звонок", ["Глеб"]),
            at(3, 12.5, 60, "Обсуждение договора", ["Вера"]), at(4, 11, 120, "Квартальное планирование", ["Анна", "Борис", "Вера"]),
            at(4, 17, 30, "Итоги недели", ["Анна"]),
        ].sorted { $0.start > $1.start }
    }

    func event(_ id: String) -> CalendarEvent? { events.first { $0.id == id } }

    /// События, во время которых шла запись, — от большего пересечения по времени к меньшему.
    /// Учитываются только события с приглашёнными: напоминания и личные блоки («Обед») встречами не считаются.
    func candidates(start: Date, duration: Double) -> [CalendarEvent] {
        let end = start.addingTimeInterval(duration)
        var found: [(event: CalendarEvent, overlap: Double)] = []
        for event in events where event.attendees.contains(where: { !$0.isSelf }) {
            let overlap = min(end, event.end).timeIntervalSince(max(start, event.start))
            let shorter = min(duration, event.end.timeIntervalSince(event.start))
            // Пересечение должно быть существенным: хотя бы 40% более короткого из двух отрезков и не меньше двух минут.
            guard overlap >= max(120, shorter * 0.4) || (shorter < 300 && overlap >= shorter * 0.6) else { continue }
            found.append((event, overlap))
        }
        return found.sorted { $0.overlap > $1.overlap }.map(\.event)
    }
}
