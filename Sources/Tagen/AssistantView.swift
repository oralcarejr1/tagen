#if os(macOS)
import SwiftUI
import AppKit
import TagenCore
import TagenMac

struct AssistantView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.appController) var app
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Wide panels show labelled tools; narrow ones fall back to icons (tooltips keep the names).
            ViewThatFits(in: .horizontal) {
                toolbar(labelled: true)
                toolbar(labelled: false)
            }
            Label(state.mode.blurb(state.lang), systemImage: state.mode.icon)
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("modeDescription")
            if !state.missingForAsk.isEmpty {
                HStack(spacing: 6) {
                    Label(state.t("Accessibility permission is off — Tagen can only use screenshots/OCR.",
                                  "손쉬운 사용 권한이 꺼져 있어 스크린샷/OCR만 사용합니다."), systemImage: "lock.trianglebadge.exclamationmark")
                        .font(.caption).foregroundStyle(.orange)
                    Spacer(minLength: 4)
                    Button(state.t("Open Permissions", "권한 열기")) { app?.openSettings(tab: .permissions) }
                        .controlSize(.small)
                }
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

    func toolbar(labelled: Bool) -> some View {
        HStack {
            Picker("", selection: $state.mode) {
                ForEach(AssistantMode.allCases, id: \.self) { m in Text(m.title(state.lang)).tag(m) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            .accessibilityIdentifier("modePicker")
            Spacer(minLength: 8)
            VoiceButton(labelled: labelled)
            Button { app?.askAboutRegion() } label: {
                toolLabel(state.t("Region", "영역"), "viewfinder", labelled)
            }
            .help(state.t("Select a screen region and ask about it (⌥⇧R)", "화면 영역을 골라 질문 (⌥⇧R)"))
            Button { app?.newConversation() } label: {
                toolLabel(state.t("New", "새 대화"), "square.and.pencil", labelled)
            }
            .help(state.t("New conversation", "새 대화"))
        }
        .fixedSize(horizontal: labelled, vertical: false)
    }

    @ViewBuilder func toolLabel(_ title: String, _ icon: String, _ labelled: Bool) -> some View {
        if labelled { Label(title, systemImage: icon).labelStyle(.titleAndIcon) } else { Image(systemName: icon) }
    }

    var placeholder: String {
        switch state.mode {
        case .ask: return state.t("Ask about your screen…", "화면에 대해 질문하세요…")
        case .guide: return state.t("What are you looking for? (e.g. where is Export?)", "무엇을 찾나요? (예: 내보내기 버튼은 어디?)")
        case .act: return state.t("Describe a task to perform", "수행할 작업을 설명하세요")
        }
    }
}

extension AssistantMode {
    func title(_ lang: LanguageCode) -> String {
        switch self {
        case .ask: return lang == .korean ? "질문" : "Ask"
        case .guide: return lang == .korean ? "안내" : "Guide"
        case .act: return lang == .korean ? "실행" : "Act"
        }
    }
    var icon: String {
        switch self {
        case .ask: return "questionmark.bubble"
        case .guide: return "scope"
        case .act: return "hand.tap"
        }
    }
    /// One line telling the user what this mode will (and won't) do.
    func blurb(_ lang: LanguageCode) -> String {
        let ko = lang == .korean
        switch self {
        case .ask: return ko ? "화면을 읽고 답합니다. 아무것도 클릭하지 않습니다." : "Reads your screen and answers. Never clicks anything."
        case .guide: return ko ? "찾는 버튼이나 메뉴를 화면 위에 표시해 줍니다." : "Highlights the button or menu you're looking for, right on screen."
        case .act: return ko ? "작업을 대신 수행합니다. 위험한 단계는 먼저 묻습니다." : "Does the task for you. Risky steps ask first."
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
        Group {
            if let sel = state.selectionPreview {
                VStack(alignment: .leading, spacing: 4) {
                    Label { Text("“\(Self.preview(sel))”").lineLimit(1).truncationMode(.tail) } icon: { Image(systemName: "text.quote") }
                        .font(.caption).foregroundStyle(.secondary)
                        .help(String(sel.prefix(500)))
                    actions
                }
            } else {
                HStack(spacing: 4) {
                    Label(state.t("Select text in another app to explain, summarize, translate or rewrite it.",
                                  "다른 앱에서 텍스트를 선택하면 설명·요약·번역·다시 쓰기를 쓸 수 있습니다."), systemImage: "text.cursor")
                        .font(.caption2).foregroundStyle(.secondary)
                    Button { Self.refresh(state) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).controlSize(.small)
                        .help(state.t("Check the selection again", "선택 텍스트 다시 확인"))
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { n in
            if n.object is AssistantPanel { Self.refresh(state) }
        }
    }

    /// First line-ish of the selection, whitespace collapsed.
    static func preview(_ s: String) -> String {
        let flat = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > 80 ? String(flat.prefix(80)) + "…" : flat
    }

    /// Peeks at the frontmost app's selection off the main thread (AX calls can block up to 1 s).
    /// Skipped without Accessibility permission, and when Tagen itself is frontmost (its own fields).
    static func refresh(_ state: AppState) {
        guard state.permissions[.accessibility]?.isGranted == true,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { state.selectionPreview = nil; return }
        Task {
            let text = await Task.detached { AXInspector.selectedText()?.text }.value
            state.selectionPreview = text
        }
    }

    var actions: some View {
        HStack(spacing: 6) {
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
    /// Wide layout spells out what the button does and which language it listens for.
    var labelled = false
    @State private var pressed = false
    var languageText: String {
        let ko = state.settings.voice.recognitionLanguage == .korean
        return labelled ? state.t("Talk", "말하기") + " · " + (ko ? state.t("Korean", "한국어") : state.t("English", "영어")) : (ko ? "KO" : "EN")
    }
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
            Text(languageText).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !pressed { pressed = true; app?.pushToTalk(down: true) } }
            .onEnded { _ in pressed = false; app?.pushToTalk(down: false) })
        .help(state.t("Hold to talk. Press while speaking to interrupt. Right-click to choose the language.", "누른 채 말하기. 말하는 중 누르면 중단. 우클릭으로 언어 선택."))
        .contextMenu {
            Button("한국어 (ko-KR)" + (state.settings.voice.recognitionLanguage == .korean ? " ✓" : "")) { app?.setVoiceLanguage(.korean) }
            Button("English (en-US)" + (state.settings.voice.recognitionLanguage == .english ? " ✓" : "")) { app?.setVoiceLanguage(.english) }
        }
        .accessibilityLabel("Push to talk")
    }
}
#endif
