import Foundation

/// Связь встреч с событиями календаря и людьми.
extension AppState {
    /// Решает для каждой встречи, записана ли она во время события календаря.
    ///
    /// Одного совпадения по времени мало: в календаре стоят и обеды, и напоминания, а созвониться можно
    /// с кем угодно. Событие привязывается, только если в нём есть приглашённые и хотя бы один названный
    /// собеседник — среди них. Пока собеседники не названы, событие привязывается предварительно
    /// (чтобы подсказать имена) и снимается, если после называния никто не совпал.
    /// Вызывается при запуске, при изменении календаря и при любой правке встреч.
    func linkCalendarEvents() {
        // В режиме просмотра вёрстки (`--snapshot`) данные не меняем.
        guard calendar.authorized, settings.calendarEnabled, !linking,
              !CommandLine.arguments.contains("--snapshot") else { return }
        linking = true
        defer { linking = false }
        for meeting in store.meetings where meeting.status != .recording {
            if meeting.calendarManual {
                // Привязано вручную: только подтягиваем изменения события из календаря.
                if let linked = meeting.calendar, let fresh = calendar.event(linked.id), fresh != linked {
                    store.update(meeting.id) { $0.calendar = fresh }
                }
                continue
            }
            if meeting.calendarDetached { continue }
            let options = calendar.candidates(start: meeting.startedAt, duration: meeting.duration)
            let named = meeting.namedSpeakers
            let chosen: CalendarEvent?
            if named.isEmpty {
                // Ещё не обработана или собеседники не названы — берём событие по времени, предварительно.
                chosen = meeting.utterances.isEmpty || !meeting.unnamedSpeakers.isEmpty ? options.first : nil
            } else {
                chosen = options.first { event in
                    named.contains { speaker in
                        event.attendees.contains {
                            !$0.isSelf && NameMatch.same(speakerName: speaker.name, speakerEmail: speaker.email, attendee: $0)
                        }
                    }
                }
            }
            if let chosen {
                if meeting.calendar != chosen { attach(chosen, to: meeting.id, manual: false) }
            } else if meeting.calendar != nil {
                removeCalendar(meeting.id, byUser: false)
            }
        }
    }

    func attach(_ event: CalendarEvent, to meetingID: UUID, manual: Bool = true) {
        store.update(meetingID) {
            if $0.calendar == nil, !$0.titleIsCustom { $0.titleBeforeCalendar = $0.title }
            $0.calendar = event
            $0.calendarDetached = false
            $0.calendarManual = manual
            if !$0.titleIsCustom { $0.title = event.title }
        }
        syncEmails(meetingID)
    }

    func detachCalendar(_ meetingID: UUID) {
        removeCalendar(meetingID, byUser: true)
    }

    private func removeCalendar(_ meetingID: UUID, byUser: Bool) {
        guard let meeting = store.meeting(meetingID), let event = meeting.calendar else { return }
        var needsTitle = false
        store.update(meetingID) {
            $0.calendar = nil
            $0.calendarManual = false
            if byUser { $0.calendarDetached = true }
            // Название было темой события — возвращаем прежнее.
            if !$0.titleIsCustom, $0.title == event.title {
                if let previous = $0.titleBeforeCalendar, !previous.isEmpty {
                    $0.title = previous
                } else {
                    $0.title = Meeting.defaultTitle(for: $0.startedAt)
                    needsTitle = true
                }
            }
            $0.titleBeforeCalendar = nil
        }
        // Прежнее название не сохранилось (встреча привязана старой версией) — придумываем по саммари.
        if needsTitle { retitle(meetingID) }
    }

    /// Придумывает название встречи по её саммари — когда прежнее название утрачено.
    private func retitle(_ meetingID: UUID) {
        guard let meeting = store.meeting(meetingID), !meeting.summary.isEmpty,
              governor.pauseReason == nil || !settings.llmEngine.loadsThisMac,
              let client = models.llmClient(gpu: settings.performanceMode.usesGPU) else { return }
        let fallback = meeting.title
        let prompt = """
        Ниже — саммари рабочей встречи. Придумай короткое название встречи по её основной теме: 3–8 слов, \
        без кавычек и точки в конце. В ответе дай только название.

        \(meeting.summary.prefix(4000))
        """
        retitleQueue = Task { [previous = retitleQueue] in
            await previous?.value
            guard let raw = try? await client.generate(prompt: prompt, maxTokens: 40, onText: { _ in }) else { return }
            let title = raw.split(separator: "\n").first.map(String.init)?
                .trimmingCharacters(in: CharacterSet(charactersIn: " *«»\"#.")) ?? ""
            guard !title.isEmpty, title.count <= 90 else { return }
            store.update(meetingID) {
                if !$0.titleIsCustom, $0.calendar == nil, $0.title == fallback { $0.title = title }
            }
        }
    }

    /// Встречи, записанные во время события календаря.
    func meetings(for event: CalendarEvent) -> [Meeting] {
        store.meetings.filter { $0.calendar?.id == event.id }
    }

    /// Проставляет спикерам адреса почты из карточек людей и из события календаря — по ним
    /// приглашённые сопоставляются с теми, кто говорил.
    func syncEmails(_ meetingID: UUID) {
        guard let meeting = store.meeting(meetingID) else { return }
        var changes: [String: String] = [:]
        for speaker in meeting.speakers where !speaker.isUser && (speaker.email ?? "").isEmpty {
            if let person = voices.voice(speaker.voiceID), let email = person.email, !email.isEmpty {
                changes[speaker.id] = email
            } else if let attendee = meeting.calendar?.attendees.first(where: {
                !$0.email.isEmpty && $0.name.caseInsensitiveCompare(speaker.name) == .orderedSame
            }) {
                changes[speaker.id] = attendee.email
            }
        }
        guard !changes.isEmpty else { return }
        store.update(meetingID) { meeting in
            for index in meeting.speakers.indices {
                if let email = changes[meeting.speakers[index].id] { meeting.speakers[index].email = email }
            }
        }
    }

    /// «Этот спикер — вот этот приглашённый из календаря».
    func identify(_ meetingID: UUID, _ speakerID: String, as attendee: CalendarAttendee) {
        if let person = voices.person(email: attendee.email, name: attendee.name) {
            if (person.email ?? "").isEmpty, !attendee.email.isEmpty {
                voices.update(person.id) { $0.email = attendee.email }
            }
            identify(meetingID, speakerID, as: voices.voice(person.id) ?? person)
        } else {
            updateSpeaker(meetingID, speakerID) { $0.name = attendee.name }
        }
        // Запоминаем адрес в карточке человека и у спикера.
        if let voiceID = store.meeting(meetingID)?.speaker(speakerID)?.voiceID, !attendee.email.isEmpty {
            voices.update(voiceID) { if ($0.email ?? "").isEmpty { $0.email = attendee.email } }
        }
        store.update(meetingID) { meeting in
            if let index = meeting.speakers.firstIndex(where: { $0.id == speakerID }), !attendee.email.isEmpty {
                meeting.speakers[index].email = attendee.email
            }
        }
    }

    /// Приглашённые, которым ещё не сопоставлен ни один спикер, — подсказки для безымянных спикеров.
    func unassignedInvitees(_ meeting: Meeting) -> [CalendarAttendee] {
        meeting.silentInvitees.filter { !$0.isSelf }
    }

    /// Карточка человека для приглашённого (если такой человек уже известен).
    func person(for attendee: CalendarAttendee) -> KnownVoice? {
        voices.person(email: attendee.email, name: attendee.name)
    }

    /// Открывает карточку приглашённого, при необходимости создавая её.
    func openPerson(for attendee: CalendarAttendee) {
        let id = person(for: attendee)?.id ?? voices.add(name: attendee.name, email: attendee.email)
        selection = .person(id)
    }

    func addPerson() {
        selection = .person(voices.add(name: "Новый человек"))
    }

    /// Смена раздела в нижнем меню.
    func open(_ tab: SidebarTab) {
        self.tab = tab
        switch tab {
        case .settings:
            selection = .settings
        case .people:
            if case .person = selection { return }
            selection = voices.voices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .first.map { .person($0.id) }
        case .meetings:
            if case .meeting = selection { return }
            selection = store.meetings.first.map { .meeting($0.id) }
        case .calendar:
            selection = .calendarGrid
        }
    }
}
