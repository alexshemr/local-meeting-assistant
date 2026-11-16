import SwiftUI

/// Нижнее меню боковой панели: люди, встречи, календарь, настройки.
struct SidebarTabBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SidebarTab.allCases) { tab in
                Button {
                    state.open(tab)
                } label: {
                    Image(systemName: tab.icon)
                        .font(.system(size: 19))
                        .foregroundStyle(state.tab == tab ? Color.accentColor : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityLabel(tab.title)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }
}

// MARK: - Люди

struct PeopleList: View {
    let query: String
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var voices: VoiceLibrary
    @EnvironmentObject private var store: MeetingStore

    private var people: [KnownVoice] {
        let q = query.trimmingCharacters(in: .whitespaces)
        func has(_ s: String?) -> Bool {
            (s ?? "").range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        return voices.voices
            .filter { q.isEmpty || has($0.name) || has($0.company) || has($0.email) || has($0.digest) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List(selection: $state.selection) {
            ForEach(people) { person in
                PersonRow(person: person, meetings: state.meetings(with: person).count)
                    .tag(SidebarSelection.person(person.id))
            }
        }
        .overlay {
            if people.isEmpty {
                Text(voices.voices.isEmpty ? "Людей пока нет.\nОни появляются, когда вы называете участников встреч."
                     : "Никого не найдено")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Button { state.addPerson() } label: {
                Label("Добавить человека", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
    }
}

struct PersonRow: View {
    let person: KnownVoice
    let meetings: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(person.name)
                .font(.body.weight(.medium))
                .lineLimit(1)
            let details = [person.company, person.email ?? ""].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if !details.isEmpty {
                Text(details.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(meetings == 0 ? "встреч нет" : "встреч: \(meetings)" + (person.hasVoice ? "" : " · голос не записан"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Календарь

/// Лента календаря: события календаря и записанные встречи, которым событие не нашлось, — одним списком.
struct CalendarList: View {
    let query: String
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var calendar: CalendarService
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var settings: AppSettings

    enum Item: Identifiable {
        case event(CalendarEvent, recorded: [Meeting])
        case meeting(Meeting)

        var id: String {
            switch self {
            case .event(let event, _): return "e-" + event.id
            case .meeting(let meeting): return "m-" + meeting.id.uuidString
            }
        }
        var date: Date {
            switch self {
            case .event(let event, _): return event.start
            case .meeting(let meeting): return meeting.startedAt
            }
        }
        var selection: SidebarSelection {
            switch self {
            case .event(let event, _): return .event(event.id)
            case .meeting(let meeting): return .meeting(meeting.id)
            }
        }
    }

    private var items: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var result: [Item] = []
        for event in calendar.events {
            let recorded = state.meetings(for: event)
            // Поиск идёт и по календарю (тема, приглашённые), и по содержанию записанной встречи.
            if q.isEmpty || event.matches(q) || recorded.contains(where: { $0.matches(q) }) {
                result.append(.event(event, recorded: recorded))
            }
        }
        let known = Set(calendar.events.map(\.id))
        for meeting in store.meetings where meeting.calendar.map({ !known.contains($0.id) }) ?? true {
            if q.isEmpty || meeting.matches(q) { result.append(.meeting(meeting)) }
        }
        return result.sorted { $0.date > $1.date }
    }

    private var days: [(day: Date, items: [Item])] {
        let grouped = Dictionary(grouping: items) { Calendar.current.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0]!.sorted { $0.date < $1.date }) }
    }

    var body: some View {
        if !calendar.authorized || !settings.calendarEnabled {
            VStack(spacing: 10) {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text("Календарь не подключён")
                    .foregroundStyle(.secondary)
                Button("Подключить в настройках") { state.open(.settings) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            List(selection: $state.selection) {
                ForEach(days, id: \.day) { day in
                    Section(dayTitle(day.day)) {
                        ForEach(day.items) { item in
                            row(item).tag(item.selection)
                        }
                    }
                }
            }
            .overlay {
                if items.isEmpty {
                    Text(query.isEmpty ? "Событий нет" : "Ничего не найдено").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        let title = Fmt.dayLong.string(from: day)
        if calendar.isDateInToday(day) { return "Сегодня, " + title }
        if calendar.isDateInTomorrow(day) { return "Завтра, " + title }
        if calendar.isDateInYesterday(day) { return "Вчера, " + title }
        return title
    }

    @ViewBuilder
    private func row(_ item: Item) -> some View {
        switch item {
        case .event(let event, let recorded):
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(Fmt.hm.string(from: event.start))–\(Fmt.hm.string(from: event.end))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if !recorded.isEmpty {
                        Label("записано", systemImage: "waveform")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(event.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                if !event.attendees.isEmpty {
                    Text(event.attendees.filter { !$0.isSelf }.map(\.name).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 3)
        case .meeting(let meeting):
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(Fmt.hm.string(from: meeting.startedAt))–\(Fmt.hm.string(from: meeting.endedAt))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Label("запись без события", systemImage: "waveform")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(meeting.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Text(meeting.activeSpeakers.map(\.displayName).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 3)
        }
    }
}

/// Карточка события календаря: кто приглашён, есть ли запись, что на ней было.
struct EventDetailView: View {
    let eventID: String
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var calendar: CalendarService
    @EnvironmentObject private var store: MeetingStore

    var body: some View {
        if let event = calendar.event(eventID) {
            let recorded = state.meetings(for: event)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Button {
                        state.calendarAnchor = event.start
                        state.selection = .calendarGrid
                    } label: { Label("Календарь", systemImage: "chevron.left") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(event.title).font(.title2.weight(.semibold))
                        Text("\(Fmt.dayLong.string(from: event.start)) · \(Fmt.hm.string(from: event.start))–\(Fmt.hm.string(from: event.end)) · календарь «\(event.calendar)»")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    attendees(event, recorded: recorded.first)
                    recordings(event, recorded: recorded)
                }
                .padding(20)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            placeholder("calendar", "Событие не найдено", "Возможно, оно удалено из календаря или вышло за пределы показываемого периода.")
        }
    }

    @ViewBuilder
    private func attendees(_ event: CalendarEvent, recorded: Meeting?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Приглашённые").font(.title3.weight(.semibold))
            if event.attendees.isEmpty {
                Text("В событии нет приглашённых.").foregroundStyle(.secondary)
            }
            ForEach(event.attendees) { attendee in
                AttendeeRow(attendee: attendee, meeting: recorded)
            }
        }
    }

    @ViewBuilder
    private func recordings(_ event: CalendarEvent, recorded: [Meeting]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Запись").font(.title3.weight(.semibold))
            if recorded.isEmpty {
                Text(event.start > Date() ? "Встреча ещё не состоялась." : "Эта встреча не записывалась.")
                    .foregroundStyle(.secondary)
                // Запись того же дня, которая не привязалась сама (например, началась заметно позже события).
                let sameDay = store.meetings.filter {
                    $0.calendar == nil && Calendar.current.isDate($0.startedAt, inSameDayAs: event.start)
                }
                if !sameDay.isEmpty {
                    Menu("Привязать запись…") {
                        ForEach(sameDay) { meeting in
                            Button("\(Fmt.hm.string(from: meeting.startedAt)) — \(meeting.title)") {
                                state.attach(event, to: meeting.id)
                            }
                        }
                    }
                    .fixedSize()
                }
            }
            ForEach(recorded) { meeting in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("\(Fmt.hm.string(from: meeting.startedAt))–\(Fmt.hm.string(from: meeting.endedAt)) · \(Fmt.duration(meeting.duration))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Открыть встречу") { state.selection = .meeting(meeting.id) }
                    }
                    if meeting.summary.isEmpty {
                        Text("Саммари ещё не сформировано.").foregroundStyle(.secondary)
                    } else {
                        MarkdownView(text: meeting.summary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

/// Приглашённый: ответ на приглашение и — если встреча записана — говорил ли он.
struct AttendeeRow: View {
    let attendee: CalendarAttendee
    let meeting: Meeting?
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            let spoke = meeting?.speaker(for: attendee) != nil
            Image(systemName: meeting == nil ? "person" : (spoke ? "person.wave.2.fill" : "person.slash"))
                .foregroundStyle(meeting == nil ? Color.secondary : (spoke ? Color.green : Color.secondary))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(attendee.name + (attendee.isSelf ? " (вы)" : "") + (attendee.isOrganizer ? " · организатор" : ""))
                Text([attendee.email, attendee.statusTitle].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if meeting != nil {
                Text(spoke ? "говорил" : "не говорил")
                    .font(.caption)
                    .foregroundStyle(spoke ? Color.green : Color.secondary)
            }
            if !attendee.isSelf {
                Button("Карточка") { state.openPerson(for: attendee) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}
