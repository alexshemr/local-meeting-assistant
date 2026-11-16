import Foundation

/// Связь встреч с событиями календаря и людьми.
extension AppState {
    /// Привязывает к встречам события календаря, во время которых они шли.
    /// Вызывается при запуске, при изменении календаря и после каждой записи.
    func linkCalendarEvents() {
        guard calendar.authorized, settings.calendarEnabled else { return }
        for meeting in store.meetings where meeting.calendar == nil && !meeting.calendarDetached && meeting.status != .recording {
            guard let event = calendar.bestEvent(start: meeting.startedAt, duration: meeting.duration) else { continue }
            attach(event, to: meeting.id)
        }
        // Состав приглашённых и тема могли измениться в календаре.
        for meeting in store.meetings {
            guard let linked = meeting.calendar, let fresh = calendar.event(linked.id), fresh != linked else { continue }
            store.update(meeting.id) {
                $0.calendar = fresh
                if !$0.titleIsCustom, $0.title == linked.title { $0.title = fresh.title }
            }
        }
    }

    func attach(_ event: CalendarEvent, to meetingID: UUID) {
        store.update(meetingID) {
            $0.calendar = event
            $0.calendarDetached = false
            if !$0.titleIsCustom { $0.title = event.title }
        }
        syncEmails(meetingID)
    }

    func detachCalendar(_ meetingID: UUID) {
        store.update(meetingID) {
            $0.calendar = nil
            $0.calendarDetached = true
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
            if case .event = selection { return }
            if case .meeting = selection { return }
            selection = nil
        }
    }
}
