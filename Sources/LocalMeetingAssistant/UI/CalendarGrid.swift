import SwiftUI

/// Календарные расчёты: неделя с понедельника, русские названия.
enum Cal {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "ru_RU")
        c.firstWeekday = 2
        return c
    }()

    static func startOfWeek(_ date: Date) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    static func startOfMonth(_ date: Date) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    static func days(from start: Date, count: Int) -> [Date] {
        (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// Шесть недель, покрывающих месяц, — для сетки месяца.
    static func monthGrid(_ date: Date) -> [Date] { days(from: startOfWeek(startOfMonth(date)), count: 42) }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = format
        return f
    }

    static let monthTitle = formatter("LLLL yyyy")
    static let weekday = formatter("EE")
    static let dayMonth = formatter("d MMMM")

    static func title(_ mode: CalendarMode, _ anchor: Date) -> String {
        switch mode {
        case .month: return monthTitle.string(from: anchor).capitalized
        case .week:
            let start = startOfWeek(anchor)
            let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
            let sameMonth = calendar.component(.month, from: start) == calendar.component(.month, from: end)
            let first = sameMonth ? String(calendar.component(.day, from: start)) : dayMonth.string(from: start)
            return "\(first) – \(dayMonth.string(from: end)) \(calendar.component(.year, from: end))"
        }
    }
}

/// Плашка в сетке: событие календаря или запись без события.
struct GridEntry: Identifiable {
    enum Kind { case event, recordedEvent, recording }
    var id: String
    var title: String
    var start: Date
    var end: Date
    var kind: Kind
    var selection: SidebarSelection

    var color: Color {
        switch kind {
        case .event: return .accentColor
        case .recordedEvent: return .green
        case .recording: return .orange
        }
    }
}

extension AppState {
    /// Всё, что показывается в календаре: события и записи, которым событие не нашлось.
    func gridEntries() -> [GridEntry] {
        var entries: [GridEntry] = calendar.events.map { event in
            GridEntry(id: "e-" + event.id, title: event.title, start: event.start, end: event.end,
                      kind: meetings(for: event).isEmpty ? .event : .recordedEvent, selection: .event(event.id))
        }
        for meeting in store.meetings where meeting.calendar == nil && meeting.status != .recording {
            entries.append(GridEntry(id: "m-" + meeting.id.uuidString, title: meeting.title, start: meeting.startedAt,
                                     end: meeting.endedAt, kind: .recording, selection: .meeting(meeting.id)))
        }
        return entries
    }

    func shiftCalendar(_ direction: Int) {
        let component: Calendar.Component = calendarMode == .week ? .weekOfYear : .month
        calendarAnchor = Cal.calendar.date(byAdding: component, value: direction, to: calendarAnchor) ?? calendarAnchor
    }
}

// MARK: - Боковая панель календаря

/// Навигация по календарю: вид, переход по неделям и месяцам, мини-календарь.
struct CalendarSidebar: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var calendar: CalendarService
    @EnvironmentObject private var settings: AppSettings

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        if !calendar.authorized || !settings.calendarEnabled {
            VStack(spacing: 10) {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text("Календарь не подключён").foregroundStyle(.secondary)
                Button("Подключить в настройках") { state.open(.settings) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            // Список, а не просто прокрутка: поле поиска боковой панели показывается только над списком.
            List {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Вид", selection: $state.calendarMode) {
                        ForEach(CalendarMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    HStack(spacing: 6) {
                        Button { state.shiftCalendar(-1) } label: { Image(systemName: "chevron.left") }
                        Button("Сегодня") { state.calendarAnchor = Date() }
                        Button { state.shiftCalendar(1) } label: { Image(systemName: "chevron.right") }
                        Spacer()
                    }

                    miniMonth

                    VStack(alignment: .leading, spacing: 6) {
                        legend(.accentColor, "событие календаря")
                        legend(.green, "событие с записью")
                        legend(.orange, "запись без события")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .onChange(of: state.calendarMode) { _, _ in state.selection = .calendarGrid }
            .onChange(of: state.calendarAnchor) { _, _ in state.selection = .calendarGrid }
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.7)).frame(width: 10, height: 10)
            Text(text)
        }
    }

    /// Мини-календарь месяца: нажатие на день переносит сетку к нему.
    private var miniMonth: some View {
        let anchor = state.calendarAnchor
        let month = Cal.calendar.component(.month, from: anchor)
        let week = Cal.startOfWeek(anchor)
        let busy = Set(state.gridEntries().map { Cal.calendar.startOfDay(for: $0.start) })
        return VStack(spacing: 6) {
            Text(Cal.monthTitle.string(from: anchor).capitalized)
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"], id: \.self) {
                    Text($0).font(.caption2).foregroundStyle(.tertiary)
                }
                ForEach(Cal.monthGrid(anchor), id: \.self) { day in
                    let inMonth = Cal.calendar.component(.month, from: day) == month
                    let today = Cal.calendar.isDateInToday(day)
                    let inWeek = state.calendarMode == .week && Cal.startOfWeek(day) == week
                    Button {
                        state.calendarAnchor = day
                    } label: {
                        VStack(spacing: 1) {
                            Text("\(Cal.calendar.component(.day, from: day))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(today ? Color.white : (inMonth ? Color.primary : Color.secondary.opacity(0.5)))
                                .frame(width: 22, height: 22)
                                .background(today ? Color.accentColor : .clear, in: Circle())
                            Circle()
                                .fill(busy.contains(day) ? Color.secondary : .clear)
                                .frame(width: 3, height: 3)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 1)
                        .background(inWeek ? Color.accentColor.opacity(0.12) : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Сетка

struct CalendarGridView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var calendar: CalendarService
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        if !calendar.authorized || !settings.calendarEnabled {
            placeholder("calendar", "Календарь не подключён", "Подключите календарь в настройках — здесь появится сетка событий и записанных встреч.")
        } else {
            let entries = state.gridEntries()
            VStack(spacing: 0) {
                HStack {
                    Text(Cal.title(state.calendarMode, state.calendarAnchor))
                        .font(.title2.weight(.semibold))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                Divider()
                switch state.calendarMode {
                case .week: WeekGrid(anchor: state.calendarAnchor, entries: entries)
                case .month: MonthGrid(anchor: state.calendarAnchor, entries: entries)
                }
            }
        }
    }
}

/// Неделя: семь колонок дней и шкала времени, события — плашками по своему времени.
struct WeekGrid: View {
    let anchor: Date
    let entries: [GridEntry]
    @EnvironmentObject private var state: AppState

    private let hourHeight: CGFloat = 46
    private let gutter: CGFloat = 46

    private struct Placed: Identifiable {
        var entry: GridEntry
        var top: CGFloat
        var height: CGFloat
        var column: Int
        var columns: Int
        var id: String { entry.id }
    }

    /// Раскладывает события дня; пересекающиеся по времени делят ширину колонки.
    private func layout(_ day: Date) -> [Placed] {
        let dayStart = Cal.calendar.startOfDay(for: day)
        let dayEnd = dayStart.addingTimeInterval(86_400)
        let items = entries.filter { $0.start < dayEnd && $0.end > dayStart }.sorted { $0.start < $1.start }
        var placed: [Placed] = []
        var group: [Int] = []
        var groupEnd = Date.distantPast
        var columnEnds: [Date] = []

        func closeGroup() {
            for index in group { placed[index].columns = max(1, columnEnds.count) }
            group = []
            columnEnds = []
        }
        for entry in items {
            let start = max(entry.start, dayStart), end = min(max(entry.end, entry.start.addingTimeInterval(900)), dayEnd)
            if start >= groupEnd { closeGroup() }
            let column = columnEnds.firstIndex { $0 <= start } ?? columnEnds.count
            if column == columnEnds.count { columnEnds.append(end) } else { columnEnds[column] = end }
            groupEnd = max(groupEnd, end)
            let top = CGFloat(start.timeIntervalSince(dayStart) / 3600) * hourHeight
            let height = max(18, CGFloat(end.timeIntervalSince(start) / 3600) * hourHeight - 2)
            placed.append(Placed(entry: entry, top: top, height: height, column: column, columns: 1))
            group.append(placed.count - 1)
        }
        closeGroup()
        return placed
    }

    var body: some View {
        let days = Cal.days(from: Cal.startOfWeek(anchor), count: 7)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: gutter, height: 1)
                ForEach(days, id: \.self) { day in
                    let today = Cal.calendar.isDateInToday(day)
                    VStack(spacing: 2) {
                        Text(Cal.weekday.string(from: day).uppercased())
                            .font(.caption2)
                            .foregroundStyle(today ? Color.accentColor : Color.secondary)
                        Text("\(Cal.calendar.component(.day, from: day))")
                            .font(.title3.weight(today ? .semibold : .regular))
                            .foregroundStyle(today ? Color.white : Color.primary)
                            .frame(width: 30, height: 30)
                            .background(today ? Color.accentColor : .clear, in: Circle())
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 6)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { hour in
                                Text(hour == 0 ? "" : String(format: "%02d:00", hour))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: gutter - 6, height: hourHeight, alignment: .topTrailing)
                                    .offset(y: -6)
                                    .id(hour)
                            }
                        }
                        .frame(width: gutter)
                        ForEach(days, id: \.self) { day in
                            dayColumn(day)
                        }
                    }
                    .padding(.top, 8)
                }
                .onAppear { proxy.scrollTo(8, anchor: .top) }
            }
        }
    }

    private func dayColumn(_ day: Date) -> some View {
        let placed = layout(day)
        return GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { _ in
                        Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1)
                        Spacer().frame(height: hourHeight - 1)
                    }
                }
                Rectangle().fill(Color.secondary.opacity(0.15)).frame(width: 1)
                if Cal.calendar.isDateInToday(day) {
                    let now = CGFloat(Date().timeIntervalSince(Cal.calendar.startOfDay(for: day)) / 3600) * hourHeight
                    Rectangle().fill(Color.red).frame(height: 1.5).offset(y: now)
                }
                ForEach(placed) { item in
                    let width = (geometry.size.width - 4) / CGFloat(item.columns)
                    Button {
                        state.selection = item.entry.selection
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.entry.title)
                                .font(.caption.weight(.medium))
                                .lineLimit(item.height > 34 ? 2 : 1)
                            if item.height > 30 {
                                Text("\(Fmt.hm.string(from: item.entry.start))–\(Fmt.hm.string(from: item.entry.end))")
                                    .font(.caption2)
                                    .opacity(0.8)
                            }
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .frame(width: width - 2, height: item.height, alignment: .topLeading)
                        .background(item.entry.color.opacity(0.22), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(item.entry.color).frame(width: 3)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: 2 + width * CGFloat(item.column), y: item.top)
                    .help(item.entry.title)
                }
            }
        }
        .frame(height: hourHeight * 24)
        .frame(maxWidth: .infinity)
    }
}

/// Месяц: шесть недель, в каждой клетке — события дня.
struct MonthGrid: View {
    let anchor: Date
    let entries: [GridEntry]
    @EnvironmentObject private var state: AppState

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        let month = Cal.calendar.component(.month, from: anchor)
        let byDay = Dictionary(grouping: entries) { Cal.calendar.startOfDay(for: $0.start) }
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"], id: \.self) {
                    Text($0).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 6)
            Divider()
            GeometryReader { geometry in
                let rowHeight = geometry.size.height / 6
                let visible = max(1, Int((rowHeight - 30) / 17))
                LazyVGrid(columns: columns, spacing: 0) {
                    ForEach(Cal.monthGrid(anchor), id: \.self) { day in
                        cell(day, items: (byDay[day] ?? []).sorted { $0.start < $1.start },
                             inMonth: Cal.calendar.component(.month, from: day) == month, visible: visible)
                            .frame(height: rowHeight, alignment: .top)
                    }
                }
            }
        }
    }

    private func cell(_ day: Date, items: [GridEntry], inMonth: Bool, visible: Int) -> some View {
        let today = Cal.calendar.isDateInToday(day)
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                state.calendarAnchor = day
                state.calendarMode = .week
            } label: {
                Text("\(Cal.calendar.component(.day, from: day))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(today ? Color.white : (inMonth ? Color.primary : Color.secondary.opacity(0.5)))
                    .frame(width: 24, height: 24)
                    .background(today ? Color.accentColor : .clear, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Открыть неделю")
            ForEach(items.prefix(visible)) { item in
                Button {
                    state.selection = item.selection
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(item.color).frame(width: 6, height: 6)
                        Text(Fmt.hm.string(from: item.start)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        Text(item.title).font(.caption).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.title)
            }
            if items.count > visible {
                Text("ещё \(items.count - visible)").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(alignment: .top) { Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1) }
        .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.15)).frame(width: 1) }
    }
}
