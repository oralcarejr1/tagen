#if os(macOS)
import SwiftUI
import TagenCore
import TagenAgents

enum SettingsTab: String, CaseIterable { case general, permissions, models, privacy, voice, agents, computerUse }

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.appController) var app
    @State var initialTab: SettingsTab
    @State private var draft = AppSettings()
    @State private var anthropicKey = ""
    @State private var openAIKey = ""
    @State private var claudeToken = ""
    @State private var codexKey = ""

    var body: some View {
        TabView(selection: $initialTab) {
            general.tabItem { Text(state.t("General", "일반")) }.tag(SettingsTab.general)
            PermissionsView().tabItem { Text(state.t("Permissions", "권한")) }.tag(SettingsTab.permissions)
            models.tabItem { Text(state.t("Models", "모델")) }.tag(SettingsTab.models)
            privacy.tabItem { Text(state.t("Privacy", "개인정보")) }.tag(SettingsTab.privacy)
            voice.tabItem { Text(state.t("Voice", "음성")) }.tag(SettingsTab.voice)
            agents.tabItem { Text(state.t("Agents", "에이전트")) }.tag(SettingsTab.agents)
            computerUse.tabItem { Text(state.t("Computer Use", "컴퓨터 사용")) }.tag(SettingsTab.computerUse)
        }
        .padding()
        .frame(minWidth: 600, minHeight: 500)
        .onAppear { draft = state.settings }
    }

    func save() { app?.saveSettings(draft) }

    var general: some View {
        Form {
            Picker(state.t("Interface language", "인터페이스 언어"), selection: $draft.uiLanguage) {
                Text("한국어").tag(LanguageCode.korean); Text("English").tag(LanguageCode.english)
            }
            Picker(state.t("Answer language", "답변 언어"), selection: $draft.assistant.responseLanguage) {
                Text(state.t("Same as my input", "입력과 같은 언어")).tag(ResponseLanguagePreference.auto)
                Text("한국어").tag(ResponseLanguagePreference.korean); Text("English").tag(ResponseLanguagePreference.english)
            }
            Section(state.t("Shortcuts", "단축키")) {
                Text("⌥Space — " + state.t("toggle assistant", "어시스턴트 열기/닫기"))
                Text("⌃⌥Space (hold) — " + state.t("push-to-talk", "누른 채 말하기"))
                Text("⌥⇧S — " + state.t("explain selection", "선택 텍스트 설명"))
                Text("⌥⇧G — " + state.t("guide mode", "가이드 모드"))
                Text("⌥⇧R — " + state.t("ask about a screen region", "화면 영역 질문"))
                Text("⌃⌥⌘. — " + state.t("emergency stop", "긴급 정지"))
            }
            if let lat = state.panelLatenciesMs.sorted().dropFirst(state.panelLatenciesMs.count / 2).first {
                Text(state.t("Panel open latency (median, this session): ", "패널 열림 지연 (중앙값, 이번 세션): ") + String(format: "%.1f ms", lat)).font(.caption)
            }
            Button(state.t("Save", "저장")) { draft.onboardingCompleted = true; save() }.buttonStyle(.borderedProminent)
        }
        .formStyle(.grouped)
    }

    var models: some View {
        Form {
            Section("Anthropic (Claude)") {
                SecureField(state.hasAnthropicKey ? state.t("Key stored in Keychain — enter to replace", "키체인에 저장됨 — 바꾸려면 입력") : "API key", text: $anthropicKey)
                HStack {
                    Button(state.t("Save key to Keychain", "키체인에 저장")) { app?.setSecret(SecretKey.anthropicAPIKey, anthropicKey); anthropicKey = "" }.disabled(anthropicKey.isEmpty)
                    if state.hasAnthropicKey { Button(state.t("Remove key", "키 삭제"), role: .destructive) { app?.setSecret(SecretKey.anthropicAPIKey, "") } }
                }
                Toggle(state.t("Server-side refusal fallback (recommended)", "서버 측 거절 대체 (권장)"), isOn: $draft.models.enableRefusalFallback)
            }
            Section(state.t("Model per task", "작업별 모델")) {
                ForEach(ModelPurpose.allCases, id: \.self) { p in
                    HStack {
                        Text(p.displayName(state.lang)).frame(width: 170, alignment: .leading)
                        Picker("", selection: routeBinding(p).provider) {
                            Text("Anthropic").tag(ProviderKind.anthropic); Text(state.t("OpenAI-compatible", "OpenAI 호환")).tag(ProviderKind.openAICompatible)
                        }.labelsHidden().frame(width: 150)
                        TextField("model", text: routeBinding(p).model).textFieldStyle(.roundedBorder).labelsHidden()
                    }
                }
            }
            Section(state.t("OpenAI-compatible / local endpoint", "OpenAI 호환 / 로컬 엔드포인트")) {
                TextField("Base URL", text: $draft.models.openAIBaseURL)
                SecureField("API key (optional for local servers)", text: $openAIKey)
                Button(state.t("Save key", "키 저장")) { app?.setSecret(SecretKey.openAIAPIKey, openAIKey); openAIKey = "" }.disabled(openAIKey.isEmpty)
            }
            Button(state.t("Save", "저장")) { save() }.buttonStyle(.borderedProminent)
        }
        .formStyle(.grouped)
    }

    func routeBinding(_ p: ModelPurpose) -> Binding<ModelSettings.Route> {
        Binding(get: { draft.models.routes[p] ?? ModelSettings.default.routes[p]! }, set: { draft.models.routes[p] = $0 })
    }

    var privacy: some View {
        Form {
            Picker(state.t("Screenshots", "스크린샷"), selection: $draft.assistant.screenshotPolicy) {
                Text(state.t("Only when accessibility text is not enough", "접근성 텍스트가 부족할 때만")).tag(ContextRequest.ScreenshotPolicy.ifNeeded)
                Text(state.t("Always", "항상")).tag(ContextRequest.ScreenshotPolicy.always)
                Text(state.t("Never", "사용 안 함")).tag(ContextRequest.ScreenshotPolicy.never)
            }
            Toggle(state.t("Allow sending screenshots to the model provider", "스크린샷을 모델 제공자에게 전송 허용"), isOn: $draft.assistant.allowScreenshotsToModel)
            Toggle(state.t("Keep conversation history (text only)", "대화 기록 보관 (텍스트만)"), isOn: $draft.keepHistory)
            Text(state.t("Screenshots and audio are processed in memory and never saved. Secrets are redacted from history and logs.",
                         "스크린샷과 음성은 메모리에서만 처리되고 저장되지 않습니다. 비밀 정보는 기록과 로그에서 가려집니다.")).font(.caption)
            Button(state.t("Save", "저장")) { save() }.buttonStyle(.borderedProminent)
        }
        .formStyle(.grouped)
    }

    var voice: some View {
        Form {
            Picker(state.t("Recognition language", "인식 언어"), selection: $draft.voice.recognitionLanguage) {
                Text("한국어 (ko-KR)").tag(LanguageCode.korean); Text("English (en-US)").tag(LanguageCode.english)
            }
            Toggle(state.t("Prefer on-device recognition", "기기 내 인식 우선"), isOn: $draft.voice.preferOnDevice)
            Toggle(state.t("Speak answers aloud", "답변 소리 내어 읽기"), isOn: $draft.voice.speakResponses)
            Text(state.t("The microphone is only active while the talk key is held.", "마이크는 말하기 키를 누르고 있는 동안에만 켜집니다.")).font(.caption)
            Button(state.t("Save", "저장")) { save() }.buttonStyle(.borderedProminent)
        }
        .formStyle(.grouped)
    }

    var agents: some View {
        Form {
            Toggle(state.t("Allow Tagen to start coding agents (Codex / Claude Code)", "Tagen이 코딩 에이전트(Codex / Claude Code) 실행 허용"), isOn: $draft.agentExecutionEnabled)
            Picker(state.t("Default permissions", "기본 권한"), selection: $draft.agentDefaultProfile) {
                ForEach(AgentPermissionProfile.allCases, id: \.self) { Text($0.displayName(state.lang)).tag($0) }
            }
            Picker("Codex", selection: $draft.codexMode) {
                Text("app-server (approvals in Tagen)").tag(CodexMode.appServer); Text("exec --json (sandbox only)").tag(CodexMode.exec)
            }
            Section(state.t("Allowed project folders", "허용된 프로젝트 폴더")) {
                ForEach(draft.allowedProjectFolders, id: \.self) { f in
                    HStack { Text(f).font(.caption); Spacer(); Button(state.t("Remove", "제거")) { draft.allowedProjectFolders.removeAll { $0 == f } } }
                }
            }
            Section(state.t("CLI paths (optional overrides)", "CLI 경로 (선택)")) {
                TextField("claude", text: Binding(get: { draft.cliPathOverrides["claude"] ?? "" }, set: { draft.cliPathOverrides["claude"] = $0.isEmpty ? nil : $0 }))
                TextField("codex", text: Binding(get: { draft.cliPathOverrides["codex"] ?? "" }, set: { draft.cliPathOverrides["codex"] = $0.isEmpty ? nil : $0 }))
            }
            Section(state.t("Authentication on this Mac", "이 Mac에서의 인증")) {
                Text(state.t("Sign in with each CLI's own login (opens Terminal), or store a token below. Credentials from other machines are never assumed.",
                             "각 CLI의 로그인을 사용하거나(터미널이 열림) 아래에 토큰을 저장하세요. 다른 컴퓨터의 자격 증명은 사용하지 않습니다.")).font(.caption)
                HStack {
                    Button("Claude Code: sign in…") { app?.openLogin(.claudeCode) }
                    Button("Codex: sign in…") { app?.openLogin(.codex) }
                }
                SecureField("CLAUDE_CODE_OAUTH_TOKEN (from `claude setup-token`)", text: $claudeToken)
                Button(state.t("Save token", "토큰 저장")) { app?.setSecret(SecretKey.claudeCodeOAuthToken, claudeToken); claudeToken = "" }.disabled(claudeToken.isEmpty)
                SecureField("Codex / OpenAI API key", text: $codexKey)
                Button(state.t("Save key", "키 저장")) { app?.setSecret(SecretKey.codexAPIKey, codexKey); codexKey = "" }.disabled(codexKey.isEmpty)
            }
            Button(state.t("Save", "저장")) { save() }.buttonStyle(.borderedProminent)
        }
        .formStyle(.grouped)
    }

    var computerUse: some View {
        Form {
            Toggle(state.t("Enable Act mode (GUI automation)", "Act 모드(GUI 자동화) 사용"), isOn: $draft.computerUseEnabled)
            Picker(state.t("Run without asking up to", "묻지 않고 실행할 최대 위험도"), selection: $draft.computerUseAutoApproveUpTo) {
                Text(state.t("Nothing (ask for every step)", "없음 (모든 단계 확인)")).tag(RiskLevel.low)
                Text(state.t("Medium (typing, menus, shortcuts)", "중간 (입력, 메뉴, 단축키)")).tag(RiskLevel.medium)
            }
            Stepper(state.t("Max steps per task: ", "작업당 최대 단계: ") + "\(draft.computerUseMaxSteps)", value: $draft.computerUseMaxSteps, in: 3...50)
            Text(state.t("High-risk steps (delete, purchase, send, security settings, secrets, terminal) always ask. Password managers and privacy settings are never automated.",
                         "삭제·구매·전송·보안 설정·비밀 정보·터미널 같은 고위험 단계는 항상 확인합니다. 암호 관리자와 개인정보 설정은 자동화하지 않습니다.")).font(.caption)
            Button(state.t("Save", "저장")) { save() }.buttonStyle(.borderedProminent)
        }
        .formStyle(.grouped)
    }
}

struct PermissionsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.appController) var app
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.t("Tagen asks for each permission separately. Features degrade gracefully when one is missing.",
                         "Tagen은 권한을 하나씩 따로 요청합니다. 권한이 없으면 해당 기능만 제한됩니다.")).font(.callout)
            ForEach(PermissionKind.allCases) { k in
                HStack(alignment: .top) {
                    Image(systemName: icon(state.permissions[k])).foregroundStyle(color(state.permissions[k])).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.lang == .korean ? k.title.ko : k.title.en).bold()
                        Text(k.purpose(state.lang)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(state.permissions[k]?.displayName(state.lang) ?? "…").font(.caption)
                    if k.isSystemManaged {
                        Button(state.t("Request", "요청")) { app?.requestPermission(k) }.disabled(state.permissions[k] == .granted)
                        Button(state.t("Open Settings", "설정 열기")) { app?.openPermissionSettings(k) }
                    } else {
                        Text(state.t("Change in the Agents tab", "에이전트 탭에서 변경")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Divider()
            }
            HStack {
                Button(state.t("Refresh", "새로 고침")) { app?.refreshPermissions() }
                Spacer()
                Text(state.t("Development builds are ad-hoc signed: macOS may ask again after each update.", "개발 빌드는 임시 서명이므로 업데이트 후 다시 허용해야 할 수 있습니다.")).font(.caption2)
            }
        }
        .padding()
        .onAppear { app?.refreshPermissions() }
    }
    func icon(_ s: PermissionState?) -> String { s == .granted ? "checkmark.circle.fill" : s == .denied ? "xmark.circle.fill" : "questionmark.circle" }
    func color(_ s: PermissionState?) -> Color { s == .granted ? .green : s == .denied ? .red : .orange }
}
#endif
