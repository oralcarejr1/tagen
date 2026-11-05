#if os(macOS)
import SwiftUI
import AppKit
import TagenCore
import TagenAgents

struct AgentsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.appController) var app
    @State private var provider: AgentProvider = .claudeCode
    @State private var folder = ""
    @State private var prompt = ""
    @State private var profile: AgentPermissionProfile = .askEveryTime
    @State private var model = ""
    @State private var followUp = ""

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                Picker(state.t("Agent", "에이전트"), selection: $provider) {
                    ForEach(AgentProvider.allCases) { p in Text(p.displayName).tag(p) }
                }
                authRow
                HStack {
                    TextField(state.t("Project folder", "프로젝트 폴더"), text: $folder).textFieldStyle(.roundedBorder)
                    Button(state.t("Choose…", "선택…")) { chooseFolder() }
                }
                Picker(state.t("Permissions", "권한"), selection: $profile) {
                    ForEach(AgentPermissionProfile.allCases, id: \.self) { p in Text(p.displayName(state.lang)).tag(p) }
                }
                TextField(state.t("Model (optional)", "모델 (선택)"), text: $model).textFieldStyle(.roundedBorder)
                TextEditor(text: $prompt).font(.body).frame(minHeight: 80).border(.quaternary)
                HStack {
                    Button(state.t("Start task", "작업 시작")) {
                        app?.startAgent(provider: provider, folder: folder, prompt: prompt, profile: profile, model: model.isEmpty ? nil : model)
                    }
                    .buttonStyle(.borderedProminent).disabled(prompt.isEmpty || folder.isEmpty)
                    if !state.settings.agentExecutionEnabled {
                        Button { app?.openSettings(tab: .agents) } label: {
                            Label(state.t("Agents are off · Turn on…", "실행 꺼짐 · 켜기…"), systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .controlSize(.small).fixedSize()
                        .help(state.t("Agent execution is off. Opens Settings › Agents.", "에이전트 실행이 꺼져 있습니다. 설정 › 에이전트를 엽니다."))
                    }
                }
                Divider()
                List(selection: $state.selectedAgentTask) {
                    ForEach(state.agentTasks.values.sorted { $0.id.uuidString < $1.id.uuidString }) { t in
                        HStack {
                            statusIcon(t.status)
                            VStack(alignment: .leading) {
                                Text(t.spec.prompt).lineLimit(1)
                                Text("\(t.spec.provider.displayName) · \(t.status.displayName(state.lang))").font(.caption2).foregroundStyle(.secondary)
                            }
                        }.tag(t.id)
                    }
                }
            }
            .padding(10).frame(minWidth: 240)

            VStack(alignment: .leading, spacing: 6) {
                if let id = state.selectedAgentTask, let t = state.agentTasks[id] {
                    HStack {
                        Text(t.spec.provider.displayName).font(.headline)
                        Label(t.status.displayName(state.lang), systemImage: t.status.icon)
                            .font(.caption).foregroundStyle(t.status.color)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(t.status.color.opacity(0.15), in: Capsule())
                        Spacer()
                        if t.status == .running || t.status == .awaitingApproval || t.status == .recovering {
                            Button(state.t("Cancel", "취소"), role: .destructive) { app?.cancelAgent(id) }
                        }
                    }
                    if let s = t.sessionID { Text("session: \(s)").font(.caption2).textSelection(.enabled).foregroundStyle(.secondary) }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(t.activity.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let r = t.result {
                        MarkdownText(r.finalText).textSelection(.enabled).padding(6).background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        if !r.changedFiles.isEmpty { Text("files: " + r.changedFiles.joined(separator: ", ")).font(.caption) }
                        if !r.permissionDenials.isEmpty { Text("denied: " + r.permissionDenials.joined(separator: ", ")).font(.caption).foregroundStyle(.orange) }
                    }
                    if let f = t.failure {
                        Text(f.description).foregroundStyle(.red).font(.callout)
                        if let rem = f.remedy { Text(rem).font(.caption) }
                    }
                    if t.sessionID != nil && t.status != .running {
                        HStack {
                            TextField(state.t("Follow-up / resume prompt", "후속 / 재개 프롬프트"), text: $followUp).textFieldStyle(.roundedBorder)
                            Button(state.t("Resume", "재개")) { app?.resumeAgent(id, prompt: followUp); followUp = "" }.disabled(followUp.isEmpty)
                        }
                    }
                } else {
                    Text(state.t("Select a task", "작업을 선택하세요")).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(10).frame(minWidth: 260)
        }
        .onAppear { if folder.isEmpty { folder = state.settings.allowedProjectFolders.first ?? "" }; profile = state.settings.agentDefaultProfile }
    }

    var authRow: some View {
        HStack {
            switch state.agentAuth[provider] {
            case .signedIn(let m)?: Label(state.t("Signed in", "로그인됨") + " (\(m))", systemImage: "checkmark.seal").foregroundStyle(.green).font(.caption)
            case .signedOut(let hint)?: Label(hint, systemImage: "person.crop.circle.badge.exclamationmark").font(.caption).foregroundStyle(.orange)
            case .notInstalled?: Label(state.t("CLI not found on this Mac", "이 Mac에서 CLI를 찾을 수 없음"), systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
            case .unknown(let m)?: Text(m).font(.caption)
            case nil: ProgressView().controlSize(.small)
            }
            Spacer()
            Button(state.t("Sign in…", "로그인…")) { app?.openLogin(provider) }.controlSize(.small)
            Button { app?.refreshAgentAuth() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
        }
    }

    func statusIcon(_ s: AgentTaskSnapshot.Status) -> some View {
        Image(systemName: s.icon).foregroundStyle(s.color).help(s.displayName(state.lang))
    }

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.message = state.t("Choose a project folder the agent may work in", "에이전트가 작업할 프로젝트 폴더를 선택하세요")
        if p.runModal() == .OK, let url = p.url {
            folder = url.path
            var s = state.settings
            if !s.allowedProjectFolders.contains(url.path) { s.allowedProjectFolders.append(url.path); app?.saveSettings(s) }
        }
    }
}

extension AgentTaskSnapshot.Status {
    func displayName(_ lang: LanguageCode) -> String {
        let ko = lang == .korean
        switch self {
        case .running: return ko ? "실행 중" : "Running"
        case .awaitingApproval: return ko ? "승인 대기" : "Needs approval"
        case .completed: return ko ? "완료" : "Done"
        case .failed: return ko ? "실패" : "Failed"
        case .cancelled: return ko ? "취소됨" : "Cancelled"
        case .recovering: return ko ? "복구 중" : "Recovering"
        }
    }
    var icon: String {
        switch self {
        case .running: return "circle.dotted"
        case .awaitingApproval: return "hand.raised.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "stop.circle"
        case .recovering: return "arrow.triangle.2.circlepath"
        }
    }
    var color: Color {
        switch self {
        case .running: return .blue
        case .awaitingApproval, .recovering: return .orange
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.appController) var app
    @State private var selected: UUID?
    @State private var confirmDelete = false
    var body: some View {
        HSplitView {
            List(selection: $selected) {
                ForEach(state.history) { c in
                    VStack(alignment: .leading) {
                        Text(c.title).lineLimit(1)
                        Text(c.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                    }.tag(c.id)
                }
            }
            .frame(minWidth: 180)
            .onChange(of: selected) { _, id in if let id { app?.openConversation(id) } }
            VStack(alignment: .leading) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(state.historyMessages) { m in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.role == .user ? state.t("You", "나") : "Tagen").font(.caption).bold()
                                Text(m.text).textSelection(.enabled)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                HStack {
                    // Destructive action sits apart from "Continue" and always asks first.
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label(state.t("Delete all…", "모두 삭제…"), systemImage: "trash")
                    }
                    .buttonStyle(.borderless).foregroundStyle(.red).disabled(state.history.isEmpty)
                    .accessibilityIdentifier("deleteAllHistoryButton")
                    Text(state.t("Screenshots and audio are never stored.", "스크린샷과 음성은 저장하지 않습니다.")).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if let id = selected {
                        Button(state.t("Continue this conversation", "이 대화 이어가기")) { app?.continueConversation(id) }
                            .buttonStyle(.borderedProminent)
                    }
                }.padding(8)
            }
        }
        .onAppear { app?.loadHistory() }
        .confirmationDialog(state.t("Delete all history?", "모든 기록을 삭제할까요?"), isPresented: $confirmDelete) {
            Button(state.t("Delete \(state.history.count) conversations", "대화 \(state.history.count)개 삭제"), role: .destructive) {
                app?.deleteAllHistory(); selected = nil
            }
            Button(state.t("Cancel", "취소"), role: .cancel) {}
        } message: {
            Text(state.t("This can't be undone.", "삭제하면 되돌릴 수 없습니다."))
        }
    }
}
#endif
