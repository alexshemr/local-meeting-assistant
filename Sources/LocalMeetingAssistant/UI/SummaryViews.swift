import AppKit
import SwiftUI

func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: - Простой рендер Markdown (заголовки, списки, абзацы)

struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                line(raw)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func line(_ raw: String) -> some View {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let indent = CGFloat(raw.prefix { $0 == " " }.count / 2) * 16
        if trimmed.isEmpty {
            Spacer().frame(height: 2)
        } else if trimmed.hasPrefix("### ") {
            Text(inline(String(trimmed.dropFirst(4)))).font(.headline).padding(.top, 4)
        } else if trimmed.hasPrefix("## ") {
            Text(inline(String(trimmed.dropFirst(3)))).font(.title3.weight(.semibold)).padding(.top, 10)
        } else if trimmed.hasPrefix("# ") {
            Text(inline(String(trimmed.dropFirst(2)))).font(.title2.weight(.semibold)).padding(.top, 10)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(String(trimmed.dropFirst(2)))).lineSpacing(3)
            }
            .padding(.leading, indent)
        } else {
            Text(inline(trimmed)).lineSpacing(3).padding(.leading, indent)
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

// MARK: - Саммари

struct SummaryTab: View {
    let meeting: Meeting
    var showParticipants: () -> Void = {}

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var pipeline: ProcessingPipeline
    @EnvironmentObject private var models: ModelManager
    @EnvironmentObject private var settings: AppSettings
    @ViewState private var editing = false
    @ViewState private var draft = ""

    private var busy: Bool { pipeline.isQueued(meeting.id) }

    var body: some View {
        ScrollView {
            Group {
                VStack(alignment: .leading, spacing: 14) {
                    if meeting.summaryStale, !busy, !meeting.summary.isEmpty, !meeting.awaitingParticipants {
                        HStack {
                            Label("Транскрипция или участники изменились после создания саммари.", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            Button("Обновить саммари") { regenerate() }
                        }
                        .font(.callout)
                        .padding(10)
                        .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    }

                    if meeting.awaitingParticipants, !busy {
                        let left = meeting.unnamedSpeakers.count
                        HStack(spacing: 10) {
                            Label(left == 0 ? "Все участники названы — саммари сейчас начнёт формироваться."
                                  : "Саммари будет сформировано, когда вы назовёте участников (осталось: \(left)).",
                                  systemImage: "person.crop.circle.badge.questionmark")
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            if left > 0 {
                                Button("Назвать участников") { showParticipants() }
                                Button("Сформировать сейчас") { regenerate() }
                                    .disabled(!models.llmReady)
                            }
                        }
                        .font(.callout)
                        .padding(10)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }

                    MarkdownView(text: KnowledgeBase.generalInfo(meeting))

                    if let live = pipeline.liveSummary[meeting.id], !live.isEmpty {
                        MarkdownView(text: live)
                    } else if editing {
                        TextEditor(text: $draft)
                            .font(.body.monospaced())
                            .frame(minHeight: 420)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    } else if !meeting.summary.isEmpty {
                        MarkdownView(text: meeting.summary)
                    } else if busy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Саммари появится после обработки записи.")
                        }
                        .foregroundStyle(.secondary)
                    } else {
                        Text(meeting.utterances.isEmpty ? "Саммари формировать не из чего: в записи нет речи."
                             : "Саммари ещё не сформировано.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                .frame(maxWidth: 820, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                Divider()
            }
            .background(.bar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !meeting.utterances.isEmpty, !editing {
                VStack(spacing: 0) {
                    Divider()
                    SummaryFeedbackBar(meeting: meeting, dictation: state.dictation)
                }
                // Непрозрачный фон: текст саммари не должен просвечивать под полем ввода.
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if editing {
                Button("Сохранить") {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.update(meeting.id) { $0.summary = text }
                    editing = false
                }
                .buttonStyle(.borderedProminent)
                Button("Отмена") { editing = false }
            } else {
                Button {
                    draft = meeting.summary
                    editing = true
                } label: { Label("Редактировать", systemImage: "pencil") }
                    .disabled(busy)
                Button { regenerate() } label: {
                    Label(meeting.summary.isEmpty ? "Сгенерировать" : "Сгенерировать заново", systemImage: "sparkles")
                }
                .disabled(busy || meeting.utterances.isEmpty || !models.llmReady)
                .help(!models.llmReady ? models.llmUnavailableReason : "Сформировать саммари по текущей транскрипции")

                Picker("Формат", selection: $settings.summaryStyle) {
                    ForEach(SummaryStyle.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Формат саммари")
            }
            Spacer()
            Button {
                copyToClipboard(KnowledgeBase.generalInfo(meeting) + "\n" + meeting.summary)
            } label: { Label("Копировать", systemImage: "doc.on.doc") }
                .disabled(meeting.summary.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func regenerate() {
        state.generateSummary(meeting.id)
    }
}

/// Замечания к саммари: текстом или голосом. После отправки саммари формируется заново с их учётом.
struct SummaryFeedbackBar: View {
    let meeting: Meeting
    @ObservedObject var dictation: Dictation

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var models: ModelManager
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var recorder: RecordingController
    @ViewState private var text = ""
    @FocusState private var focused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && models.llmReady && dictation.state == .idle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !meeting.summaryFeedback.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Замечания, которые учитываются при генерации")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(meeting.summaryFeedback.enumerated()), id: \.offset) { index, remark in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(remark)
                                .font(.callout)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Button {
                                state.removeSummaryFeedback(meeting.id, at: index)
                            } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Убрать замечание")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                Group {
                    switch dictation.state {
                    case .recording:
                        HStack(spacing: 8) {
                            Circle().fill(.red).frame(width: 8, height: 8)
                            Text("Говорите… \(Fmt.clock(dictation.seconds))").monospacedDigit()
                            ProgressView(value: Double(dictation.level))
                                .frame(width: 90)
                            Spacer()
                            Button("Отмена") { dictation.cancel() }
                                .controlSize(.small)
                        }
                    case .transcribing:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Распознаю сказанное…").foregroundStyle(.secondary)
                            Spacer()
                        }
                    case .idle:
                        TextField("Что переделать в саммари? Например: «добавь договорённость о сроках интеграции»",
                                  text: $text, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...6)
                            .focused($focused)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

                Button {
                    toggleDictation()
                } label: {
                    Image(systemName: dictation.state == .recording ? "stop.fill" : "mic.fill")
                        .frame(width: 18, height: 18)
                }
                .controlSize(.large)
                .tint(dictation.state == .recording ? .red : nil)
                .disabled(dictation.state == .transcribing || recorder.isActive || models.currentWhisperFolder == nil)
                .help(recorder.isActive ? "Недоступно, пока идёт запись встречи"
                      : dictation.state == .recording ? "Закончить и распознать" : "Надиктовать замечание голосом")

                Button("Отправить") { send() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canSend)
                    .help("Сформировать саммари заново с учётом замечания")
            }

            if let error = dictation.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: 860, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear { dictation.cancel() }
    }

    private func toggleDictation() {
        switch dictation.state {
        case .idle:
            Task { await dictation.start(onLimit: { finishDictation() }) }
        case .recording:
            finishDictation()
        case .transcribing:
            break
        }
    }

    /// Распознанный текст попадает в поле ввода: его можно поправить перед отправкой.
    private func finishDictation() {
        Task {
            guard let spoken = await dictation.finish(modelFolder: models.currentWhisperFolder, glossary: settings.glossary) else { return }
            let existing = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = existing.isEmpty ? spoken : existing + " " + spoken
            focused = true
        }
    }

    private func send() {
        state.submitSummaryFeedback(meeting.id, text)
        text = ""
    }
}

// MARK: - Follow-up

struct FollowUpTab: View {
    let meeting: Meeting

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var models: ModelManager
    @EnvironmentObject private var settings: AppSettings
    @ViewState private var format: FollowUpFormat = .brief
    @ViewState private var draft = ""
    @ViewState private var copied = false
    @FocusState private var focused: Bool

    private var busy: Bool { state.followUpBusy.contains(meeting.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(format.hint). Письмо составляется от вашего лица. Оно не отправляется и не попадает в базу знаний — скопируйте текст и отправьте сами.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let error = state.followUpError[meeting.id] {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                if busy {
                    let live = state.liveFollowUp[meeting.id] ?? ""
                    if live.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Модель читает материалы встречи…").foregroundStyle(.secondary)
                        }
                    } else {
                        Text(live)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if meeting.followUp.isEmpty && draft.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "envelope")
                            .font(.system(size: 36))
                            .foregroundStyle(.tertiary)
                        Text("Follow-up ещё не создан").font(.title3).foregroundStyle(.secondary)
                        Text("Выберите формат и нажмите «Сгенерировать», когда понадобится письмо по итогам встречи.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    TextField("Текст письма", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineSpacing(3)
                        .focused($focused)
                        .padding(12)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                }
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                actions
                Divider()
            }
            .background(.bar)
        }
        .onAppear {
            draft = meeting.followUp
            format = meeting.followUpFormat ?? settings.followUpFormat
        }
        .onChange(of: meeting.followUp) { _, new in if !focused { draft = new } }
        .onDisappear { commit() }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Picker("Формат", selection: $format) {
                ForEach(FollowUpFormat.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(busy)

            if busy {
                Button("Остановить") { state.cancelFollowUp(meeting.id) }
            } else {
                Button {
                    commit()
                    state.generateFollowUp(meeting.id, format: format)
                } label: {
                    Label(meeting.followUp.isEmpty ? "Сгенерировать" : "Сгенерировать заново", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(meeting.utterances.isEmpty || !models.llmReady)
                .help(!models.llmReady ? models.llmUnavailableReason : format.hint)
            }
            Spacer()
            Button {
                commit()
                copyToClipboard(draft)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Label(copied ? "Скопировано" : "Копировать", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func commit() {
        guard !busy, draft != meeting.followUp else { return }
        store.update(meeting.id) { $0.followUp = draft }
    }
}
