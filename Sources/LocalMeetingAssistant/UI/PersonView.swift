import SwiftUI

/// Карточка человека со знакомым голосом: данные, встречи с ним и сводка договорённостей.
struct PersonView: View {
    let voiceID: UUID

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var voices: VoiceLibrary
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var models: ModelManager

    @ViewState private var name = ""
    @ViewState private var company = ""
    @ViewState private var side: Side = .other
    @ViewState private var email = ""
    @ViewState private var confirmForget = false
    @FocusState private var focus: Field?

    private enum Field { case name, company, email }

    var body: some View {
        if let voice = voices.voice(voiceID) {
            let meetings = state.meetings(with: voice)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    details(voice, meetings: meetings)
                    digest(voice, meetings: meetings)
                    history(meetings)
                }
                .padding(20)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { load(voice) }
            .onChange(of: voice) { _, new in if focus == nil { load(new) } }
            .onChange(of: focus) { _, new in if new == nil { commit() } }
            .onDisappear { commit() }
            .confirmationDialog("Удалить «\(voice.name)» из списка людей?", isPresented: $confirmForget) {
                Button("Удалить", role: .destructive) {
                    voices.remove(voiceID)
                    state.selection = nil
                    state.open(.people)
                }
            } message: {
                Text("Приложение перестанет узнавать этого человека на новых встречах. Прошлые встречи и имена в них сохранятся, сводка будет удалена.")
            }
        } else {
            placeholder("person.crop.circle.badge.questionmark", "Человек не найден", "Возможно, этот голос был удалён из знакомых.")
        }
    }

    // MARK: Данные

    @ViewBuilder
    private func details(_ voice: KnownVoice, meetings: [Meeting]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Имя", text: $name)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .focused($focus, equals: .name)
            HStack(spacing: 10) {
                TextField("Компания", text: $company)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .company)
                    .frame(maxWidth: 240)
                TextField("E-mail", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .email)
                    .frame(maxWidth: 260)
                Picker("Сторона", selection: $side) {
                    ForEach(Side.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 160)
                .onChange(of: side) { _, _ in commit() }
                Spacer()
                Button("Удалить…", role: .destructive) { confirmForget = true }
                    .controlSize(.small)
            }
            .onSubmit { commit() }
            Text(caption(meetings))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text((voice.hasVoice ? "" : "Голос этого человека ещё не записан: приложение запомнит его, когда вы назовёте этим именем спикера на встрече. ")
                 + "По адресу почты человек сопоставляется с приглашёнными из календаря. Изменения применяются и к прошлым встречам с ним.")
                .fixedSize(horizontal: false, vertical: true)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func caption(_ meetings: [Meeting]) -> String {
        guard let last = meetings.first, let first = meetings.last else { return "Встреч с этим человеком пока нет" }
        if meetings.count == 1 { return "Одна встреча — \(Fmt.dayLong.string(from: last.startedAt))" }
        return "Встреч: \(meetings.count) · первая \(Fmt.dayLong.string(from: first.startedAt)) · последняя \(Fmt.dayLong.string(from: last.startedAt))"
    }

    private func load(_ voice: KnownVoice) {
        name = voice.name
        company = voice.company
        side = voice.side
        email = voice.email ?? ""
    }

    private func commit() {
        guard voices.voice(voiceID) != nil else { return }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { name = voices.voice(voiceID)?.name ?? "" }
        state.updateVoice(voiceID, name: name, company: company, side: side, email: email)
    }

    // MARK: Сводка

    @ViewBuilder
    private func digest(_ voice: KnownVoice, meetings: [Meeting]) -> some View {
        let busy = state.digestBusy.contains(voiceID)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Сводка").font(.title3.weight(.semibold))
                Spacer()
                if busy {
                    Button("Остановить") { state.cancelDigest(voiceID) }
                } else {
                    Button {
                        commit()
                        state.generateDigest(voiceID)
                    } label: {
                        Label(voice.digest == nil ? "Составить сводку" : "Обновить сводку", systemImage: "sparkles")
                    }
                    .disabled(meetings.isEmpty || !models.llmReady)
                    .help(!models.llmReady ? models.llmUnavailableReason
                          : "Когда встречались и о чём договорились — по саммари всех встреч с этим человеком")
                    Button { copyToClipboard(voice.digest ?? "") } label: { Label("Копировать", systemImage: "doc.on.doc") }
                        .disabled(voice.digest == nil)
                }
            }
            if let error = state.digestError[voiceID] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if busy {
                let live = state.liveDigest[voiceID] ?? ""
                if live.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Модель читает материалы встреч…").foregroundStyle(.secondary)
                    }
                } else {
                    MarkdownView(text: live)
                }
            } else if let text = voice.digest, !text.isEmpty {
                if let date = voice.digestAt {
                    let newer = meetings.filter { $0.startedAt > date }.count
                    Text("Составлена \(Fmt.dayLong.string(from: date))" + (newer > 0 ? " · после этого было встреч: \(newer)" : ""))
                        .font(.caption)
                        .foregroundStyle(newer > 0 ? Color.orange : Color.secondary)
                }
                MarkdownView(text: text)
            } else {
                Text("Сводка покажет, когда вы встречались, о чём договорились, кто что обещал и какие вопросы остались открытыми. Она составляется по саммари встреч, хранится только в приложении и в базу знаний не попадает.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Встречи

    @ViewBuilder
    private func history(_ meetings: [Meeting]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Встречи").font(.title3.weight(.semibold))
            if meetings.isEmpty {
                Text("Встреч с этим человеком в истории нет.").foregroundStyle(.secondary)
            }
            ForEach(meetings) { meeting in
                Button {
                    state.selection = .meeting(meeting.id)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(Fmt.dayShort.string(from: meeting.startedAt)), \(Fmt.hm.string(from: meeting.startedAt))")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 130, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meeting.title).lineLimit(2)
                            Text(meeting.activeSpeakers.map(\.displayName).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(Fmt.duration(meeting.duration))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
