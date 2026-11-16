import Foundation

/// Деление и обрезка встреч, карточки людей.
extension AppState {
    // MARK: Деление и обрезка

    /// Встречу можно резать, когда она не записывается и не обрабатывается.
    func canCut(_ id: UUID) -> Bool {
        guard let meeting = store.meeting(id) else { return false }
        return meeting.status != .recording && !pipeline.isQueued(id) && !cutInProgress.contains(id)
    }

    /// Делит встречу на две в момент `time` (секунды от начала). Первая часть остаётся этой же встречей,
    /// вторая становится новой. Возвращает идентификатор новой встречи.
    /// `process` — встреча ещё не распознана (деление сразу после записи): саммари не трогаем.
    @discardableResult
    func splitMeeting(_ id: UUID, at time: Double, process: Bool = false) async -> UUID? {
        guard let meeting = store.meeting(id), canCut(id),
              time > 3, time < meeting.duration - 3 else { return nil }
        player.stop()
        cutInProgress.insert(id)
        defer { cutInProgress.remove(id) }

        var second = Meeting(title: Meeting.defaultTitle(for: meeting.startedAt.addingTimeInterval(time)),
                             startedAt: meeting.startedAt.addingTimeInterval(time))
        second.duration = meeting.duration - time
        second.status = process ? .queued : .ready
        second.sourceApp = meeting.sourceApp
        second.imported = meeting.imported
        second.echoCancelled = meeting.echoCancelled
        second.hasAudio = meeting.hasAudio
        second.speakers = meeting.speakers
        second.utterances = meeting.utterances.filter { $0.start >= time }.map {
            var moved = $0
            moved.start -= time
            moved.end -= time
            return moved
        }
        second.splitMarks = meeting.splitMarks.filter { $0.time > time + 5 }.map {
            SplitMark(time: $0.time - time, confirmed: $0.confirmed)
        }

        let names = ["mic.wav", "system.wav", "mic.aec.wav"]
        let firstDir = store.dir(id), secondDir = store.dir(second.id)
        let cut = Int(time * 16_000)
        do {
            try await Task.detached {
                let fm = FileManager.default
                try fm.createDirectory(at: secondDir, withIntermediateDirectories: true)
                for name in names {
                    let source = firstDir.appendingPathComponent(name)
                    guard fm.fileExists(atPath: source.path) else { continue }
                    try WAVFile.copy(source, to: secondDir.appendingPathComponent(name), from: cut, to: .max)
                    let head = firstDir.appendingPathComponent(name + ".cut")
                    try WAVFile.copy(source, to: head, from: 0, to: cut)
                    _ = try fm.replaceItemAt(source, withItemAt: head)
                }
                // Промежуточные результаты распознавания относились к целой записи.
                for name in ["raw.json", "diar.json"] {
                    try? fm.removeItem(at: firstDir.appendingPathComponent(name))
                }
            }.value
        } catch {
            try? FileManager.default.removeItem(at: secondDir)
            cutError = "Не удалось разделить встречу: \(error.localizedDescription)"
            return nil
        }

        store.update(id) {
            $0.duration = time
            $0.utterances = $0.utterances.filter { $0.start < time }.map {
                var kept = $0
                kept.end = min(kept.end, time)
                return kept
            }
            $0.splitMarks = $0.splitMarks.filter { $0.time < time - 5 }
            $0.summary = ""
            $0.summaryGeneratedAt = nil
            $0.summaryStale = false
            $0.followUp = ""
            if !$0.titleIsCustom { $0.title = Meeting.defaultTitle(for: $0.startedAt) }
        }
        store.add(second)
        // Событие календаря относилось к целой записи: подбираем его для каждой части заново.
        if meeting.calendar != nil { store.update(id) { $0.calendar = nil } }
        linkCalendarEvents()

        // Нераспознанные части ставит в обработку вызывающий — когда все деления закончены.
        if !process {
            refreshSummaryAfterCut(id)
            refreshSummaryAfterCut(second.id)
        }
        return second.id
    }

    /// Оставляет от встречи только отрезок `from…to` (секунды от начала), остальное удаляет.
    func trimMeeting(_ id: UUID, from: Double, to: Double) async {
        guard let meeting = store.meeting(id), canCut(id) else { return }
        let lower = max(0, from), upper = min(meeting.duration, to)
        guard upper - lower > 3, lower > 0 || upper < meeting.duration else { return }
        player.stop()
        cutInProgress.insert(id)
        defer { cutInProgress.remove(id) }

        let dir = store.dir(id)
        do {
            try await Task.detached {
                let fm = FileManager.default
                for name in ["mic.wav", "system.wav", "mic.aec.wav"] {
                    let source = dir.appendingPathComponent(name)
                    guard fm.fileExists(atPath: source.path) else { continue }
                    let part = dir.appendingPathComponent(name + ".cut")
                    try WAVFile.copy(source, to: part, from: Int(lower * 16_000), to: Int(upper * 16_000))
                    _ = try fm.replaceItemAt(source, withItemAt: part)
                }
                for name in ["raw.json", "diar.json"] { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
            }.value
        } catch {
            cutError = "Не удалось обрезать встречу: \(error.localizedDescription)"
            return
        }

        store.update(id) {
            $0.startedAt = $0.startedAt.addingTimeInterval(lower)
            $0.duration = upper - lower
            $0.utterances = $0.utterances.filter { $0.start >= lower && $0.start < upper }.map {
                var kept = $0
                kept.start -= lower
                kept.end = min(kept.end, upper) - lower
                return kept
            }
            $0.splitMarks = $0.splitMarks.filter { $0.time > lower + 5 && $0.time < upper - 5 }.map {
                SplitMark(time: $0.time - lower, confirmed: $0.confirmed)
            }
            $0.summary = ""
            $0.summaryGeneratedAt = nil
            $0.summaryStale = false
            $0.followUp = ""
        }
        refreshSummaryAfterCut(id)
    }

    /// После деления или обрезки прежнее саммари не годится: формируем заново (или ждём имён участников).
    private func refreshSummaryAfterCut(_ id: UUID) {
        guard let meeting = store.meeting(id), !meeting.utterances.isEmpty else { return }
        if settings.summaryTiming == .afterParticipants, !meeting.unnamedSpeakers.isEmpty {
            store.update(id) { $0.awaitingParticipants = true }
        } else {
            generateSummary(id)
        }
    }

    /// «Это одна встреча»: убрать замеченную границу.
    func dismissSplitMark(_ id: UUID, _ mark: SplitMark) {
        store.update(id) { $0.splitMarks.removeAll { $0 == mark } }
    }

    // MARK: Люди

    /// Встречи, в которых участвовал человек со знакомым голосом (от новых к старым).
    func meetings(with voice: KnownVoice) -> [Meeting] {
        store.meetings.filter { meeting in
            meeting.activeSpeakers.contains { speaker in
                speaker.voiceID == voice.id
                    || (speaker.voiceID == nil && !speaker.isUser
                        && speaker.name.caseInsensitiveCompare(voice.name) == .orderedSame)
            }
        }
    }

    /// Правка данных человека. Имя, компания и сторона обновляются и во всех встречах с ним.
    func updateVoice(_ id: UUID, name: String, company: String, side: Side, email: String) {
        let name = name.trimmingCharacters(in: .whitespaces), company = company.trimmingCharacters(in: .whitespaces)
        let email = email.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let old = voices.voice(id),
              old.name != name || old.company != company || old.side != side || (old.email ?? "") != email else { return }
        let affected = meetings(with: old).map(\.id)
        voices.update(id) {
            $0.name = name
            $0.company = company
            $0.side = side
            $0.email = email.isEmpty ? nil : email
        }
        for meetingID in affected {
            store.update(meetingID) { meeting in
                for index in meeting.speakers.indices where !meeting.speakers[index].isUser
                    && (meeting.speakers[index].voiceID == id
                        || (meeting.speakers[index].voiceID == nil
                            && meeting.speakers[index].name.caseInsensitiveCompare(old.name) == .orderedSame)) {
                    meeting.speakers[index].name = name
                    meeting.speakers[index].company = company
                    meeting.speakers[index].side = side
                    meeting.speakers[index].email = email.isEmpty ? nil : email
                }
            }
        }
    }

    /// Сводка по человеку: когда встречались и о чём договаривались — по саммари всех встреч с ним.
    func generateDigest(_ voiceID: UUID) {
        guard !digestBusy.contains(voiceID), let voice = voices.voice(voiceID) else { return }
        guard let client = models.llmClient(gpu: settings.performanceMode.usesGPU) else {
            digestError[voiceID] = models.llmUnavailableReason
            return
        }
        let related = meetings(with: voice).filter { !$0.summary.isEmpty || !$0.utterances.isEmpty }
        guard !related.isEmpty else {
            digestError[voiceID] = "Встреч с этим человеком пока нет."
            return
        }
        digestBusy.insert(voiceID)
        digestError[voiceID] = nil
        liveDigest[voiceID] = ""
        let ai = MeetingAI(client: client, userName: settings.userDisplayName, userCompany: settings.userCompany)
        digestTasks[voiceID] = Task {
            do {
                let text = try await ai.personDigest(voice, meetings: related) { partial in
                    Task { @MainActor in
                        if self.digestBusy.contains(voiceID) { self.liveDigest[voiceID] = partial }
                    }
                }
                voices.update(voiceID) {
                    $0.digest = text
                    $0.digestAt = Date()
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { digestError[voiceID] = error.localizedDescription }
            }
            digestBusy.remove(voiceID)
            liveDigest[voiceID] = nil
            digestTasks[voiceID] = nil
        }
    }

    func cancelDigest(_ voiceID: UUID) {
        digestTasks[voiceID]?.cancel()
    }
}
