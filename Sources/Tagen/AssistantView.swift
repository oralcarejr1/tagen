#if os(macOS)
import SwiftUI
import TagenCore

struct AssistantView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.appController) var app
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: $state.mode) {
                    Text("Ask").tag(AssistantMode.ask)
                    Text("Guide").tag(AssistantMode.guide)
                    Text("Act").tag(AssistantMode.act)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 210)
                Spacer()
                VoiceButton()
                Button { app?.askAboutRegion() } label: { Image(systemName: "viewfinder") }
                    .help(state.t("Select a screen region (⌥⇧R)", "화면 영역 선택 (⌥⇧R)"))
                Button { app?.newConversation() } label: { Image(systemName: "square.and.pencil") }
                    .help(state.t("New conversation", "새 대화"))
            }
            if !state.missingForAsk.isEmpty {
                Label(state.t("Accessibility permission is off — Tagen can only use screenshots/OCR. Open Settings › Permissions.",
                              "손쉬운 사용 권한이 꺼져 있어 스크린샷/OCR만 사용합니다. 설정 › 권한을 확인하세요."), systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack(alignment: .bottom) {
                TextField(placeholder, text: $state.input, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...5).focused($inputFocused)
                    .onSubmit { app?.submit() }
                    .accessibilityIdentifier("assistantInput")
                if state.busy {
                    Button(state.t("Cancel", "취소")) { app?.cancelCurrent() }
                } else {
                    Button(state.t("Send", "보내기")) { app?.submit() }.buttonStyle(.borderedProminent)
                        .disabled(state.input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            SelectionActionsBar()
            if let c = state.context { ContextChip(c: c) }
            if !state.status.isEmpty { HStack { ProgressView().controlSize(.small); Text(state.status).font(.caption).foregroundStyle(.secondary) } }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !state.response.isEmpty {
                        MarkdownText(state.response).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(state.guidanceNotes, id: \.self) { n in Text("⚠︎ \(n)").font(.caption2).foregroundStyle(.secondary) }
                    if state.mode == .act && !state.actLog.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(state.actLog.enumerated()), id: \.offset) { _, l in Text(l).font(.system(.caption, design: .monospaced)) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            if !state.response.isEmpty {
                HStack {
                    Button { app?.copyResponse(state.response) } label: { Label(state.t("Copy", "복사"), systemImage: "doc.on.doc") }
                    if let r = state.replacement {
                        Button { app?.applyReplacement() } label: { Label(state.t("Replace selection…", "선택 영역 바꾸기…"), systemImage: "arrow.left.arrow.right") }
                            .help(String(r.text.prefix(200)))
                    }
                    Spacer()
                }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(12)
        .onAppear { inputFocused = true }
    }

    var placeholder: String {
        switch state.mode {
        case .ask: return state.t("Ask about your screen…", "화면에 대해 질문하세요…")
        case .guide: return state.t("What are you looking for? (e.g. where is Export?)", "무엇을 찾나요? (예: 내보내기 버튼은 어디?)")
        case .act: return state.t("Describe a task to perform (each risky step asks first)", "수행할 작업을 설명하세요 (위험한 단계는 먼저 묻습니다)")
        }
    }
}

/// Inline Markdown with Korean-friendly **bold** (see InlineMarkdown) and preserved line breaks.
struct MarkdownText: View {
    let text: String
    init(_ text: String) { self.text = text }

    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString()
        for run in InlineMarkdown.runs(text) {
            var part = (try? AttributedString(markdown: run.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(run.text)
            if run.bold {
                let ranges = part.runs.map(\.range)
                for range in ranges {
                    let existing = part[range].inlinePresentationIntent ?? []
                    part[range].inlinePresentationIntent = existing.union(.stronglyEmphasized)
                }
            }
            result.append(part)
        }
        return result
    }

    var body: some View { Text(Self.attributed(text)) }
}

struct SelectionActionsBar: View {
    @EnvironmentObject var state: AppState
    @Environment(\.appController) var app
    @State private var custom = ""
    var body: some View {
        HStack(spacing: 6) {
            Text(state.t("Selection:", "선택 텍스트:")).font(.caption).foregroundStyle(.secondary)
            Button(state.t("Explain", "설명")) { app?.runSelection(.explain) }
            Button(state.t("Summarize", "요약")) { app?.runSelection(.summarize) }
            Button(state.t("Translate", "번역")) { app?.runSelection(.translate(to: nil)) }
            Menu(state.t("Rewrite", "다시 쓰기")) {
                ForEach(RewriteStyle.allCases, id: \.self) { s in
                    Button(state.lang == .korean ? s.displayName.ko : s.displayName.en) { app?.runSelection(.rewrite(s)) }
                }
            }.frame(width: 100)
            TextField(state.t("Custom…", "직접 입력…"), text: $custom).textFieldStyle(.roundedBorder).frame(maxWidth: 140)
                .onSubmit { if !custom.isEmpty { app?.runSelection(.custom(custom)) } }
        }
        .controlSize(.small).buttonStyle(.bordered)
    }
}

struct ContextChip: View {
    let c: ContextSummary
    @EnvironmentObject var state: AppState
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: c.usedScreenshot ? "camera.viewfinder" : "accessibility")
            Text([c.appName, c.windowTitle].compactMap { $0 }.joined(separator: " — ")).lineLimit(1)
            Text("· \(c.elementCount) \(state.t("elements", "요소"))")
            if c.hasSelection { Text("· " + state.t("selection", "선택 텍스트")) }
            if c.usedScreenshot { Text("· " + state.t("screenshot", "스크린샷")).help(c.screenshotReason ?? "") }
            if c.reusedPrevious { Text("· " + state.t("unchanged", "변경 없음")) }
        }
        .font(.caption2).foregroundStyle(.secondary)
        .help(c.limitations.joined(separator: "\n"))
    }
}

struct VoiceButton: View {
    @EnvironmentObject var state: AppState
    @Environment(\.appController) var app
    @State private var pressed = false
    var body: some View {
        let (icon, color): (String, Color) = {
            switch state.voiceState {
            case .listening, .transcribing: return ("mic.fill", .red)
            case .thinking: return ("ellipsis.circle", .blue)
            case .speaking: return ("speaker.wave.2.fill", .green)
            case .error: return ("mic.slash", .orange)
            case .idle: return ("mic", .primary)
            }
        }()
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(color)
            if case .listening(let p) = state.voiceState, !p.isEmpty { Text(p).font(.caption).lineLimit(1).frame(maxWidth: 160) }
        }
        .padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !pressed { pressed = true; app?.pushToTalk(down: true) } }
            .onEnded { _ in pressed = false; app?.pushToTalk(down: false) })
        .help(state.t("Hold to talk (or hold ⌃⌥Space). Click while speaking to interrupt.", "누른 채 말하기 (또는 ⌃⌥Space 길게). 말하는 중 누르면 중단."))
        .accessibilityLabel("Push to talk")
    }
}
#endif
