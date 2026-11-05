#if os(macOS)
import AppKit
import SwiftUI
import TagenCore
import TagenAgents
import TagenMac

/// `Tagen --render-ui <dir>`: renders the main UI states to PNG files (for CI visual review).
@MainActor
enum UIRender {
    static func png(_ view: NSView, to url: URL) -> Bool {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    static func settle() async { try? await Task.sleep(nanoseconds: 400_000_000) }

    static func run(dir: String) async -> Int32 {
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var written: [String] = []
        for lang in [LanguageCode.korean, .english] {
            let c = AppController(storeURL: nil, secrets: InMemorySecretStore())
            var s = c.state.settings; s.uiLanguage = lang; s.onboardingCompleted = true; c.state.settings = s
            c.state.permissions = [.accessibility: .granted, .screenCapture: .granted, .microphone: .denied, .speechRecognition: .notDetermined,
                                   .fileAccess: .granted, .appAutomation: .unknown, .agentExecution: .denied]
            let p = c.ensurePanel()
            p.setContentSize(NSSize(width: 560, height: 560))
            p.orderFrontRegardless()
            let ko = lang == .korean
            let suffix = ko ? "ko" : "en"

            // 1. Ask with a streamed answer and context chip
            c.state.mode = .ask
            c.state.input = ko ? "이 화면에서 내보내기는 어떻게 해?" : "How do I export from this screen?"
            c.state.context = ContextSummary(appName: "Keynote", windowTitle: ko ? "분기 보고서.key" : "Quarterly Report.key", elementCount: 184,
                                             hasSelection: false, usedScreenshot: false, screenshotReason: nil, reusedPrevious: false, limitations: [])
            c.state.response = ko ? "**파일 › 내보내기 › PDF…**를 선택하세요.\n\n1. 상단 메뉴에서 *파일*을 엽니다.\n2. *내보내기*에서 **PDF**를 고릅니다.\n3. 품질을 정한 뒤 **다음…**을 누릅니다."
                                  : "Choose **File › Export To › PDF…**\n\n1. Open *File* in the menu bar.\n2. Pick **PDF** under *Export To*.\n3. Choose quality and click **Next…**."
            await settle(); if png(p.contentView!, to: out.appendingPathComponent("panel-ask-\(suffix).png")) { written.append("panel-ask-\(suffix).png") }

            // 2. Approval banner (high risk) during Act
            c.state.mode = .act
            c.state.input = ko ? "받은편지함의 스팸을 정리해 줘" : "Clean up spam in my inbox"
            c.state.response = ""
            // Built by the real executor helper + policy so the screenshot shows what users will see.
            let delBtn = AXElementSnapshot(id: "w0.4.2", role: "AXButton", title: ko ? "삭제" : "Delete", frame: Rect(x: 300, y: 80, width: 60, height: 24))
            let obs = GUIObservation(app: AppInfo(name: "Mail", bundleID: "com.apple.mail", pid: 1),
                                     window: WindowInfo(title: ko ? "받은편지함" : "Inbox", frame: Rect(x: 0, y: 0, width: 900, height: 600)),
                                     root: delBtn, layout: MacDisplays.layout())
            let act = GUIAction.click(.element(id: "w0.4.2", observationID: obs.id))
            let assessment = ActionPolicy().assess(act, element: delBtn, observation: obs, scopeBundleID: "com.apple.mail")
            c.state.actLog = ["▶︎ " + (ko ? "받은편지함 정리" : "Clean inbox") + " [com.apple.mail]",
                              "→ " + act.summary(c.state.lang, targetName: act.targetName(in: obs))]
            c.state.enqueueApproval(ActionExecutor.approvalRequest(act, element: delBtn, observation: obs, assessment: assessment)) { _ in }
            await settle(); if png(p.contentView!, to: out.appendingPathComponent("panel-act-approval-\(suffix).png")) { written.append("panel-act-approval-\(suffix).png") }
            c.state.approvals = []

            // 3. Guide mode with an error banner (missing permission)
            c.state.mode = .guide
            c.state.input = ko ? "설정 버튼이 어디 있어?" : "Where is the Settings button?"
            c.state.response = ko ? "오른쪽 위의 톱니바퀴 아이콘입니다. 화면에 화살표로 표시했어요." : "It's the gear icon at the top right — highlighted on screen."
            c.state.selectionPreview = ko ? "분기 매출은 전년 대비 12% 증가했으며, 신규 고객 비중이 처음으로 40%를 넘었습니다." : "Quarterly revenue grew 12% year over year, and new customers passed 40% of the total for the first time."
            c.state.errorMessage = ko ? "음성에는 마이크와 음성 인식 권한이 필요합니다 (텍스트 입력은 계속 사용 가능)." : "Voice needs Microphone and Speech Recognition permission (text input still works)."
            await settle(); if png(p.contentView!, to: out.appendingPathComponent("panel-guide-\(suffix).png")) { written.append("panel-guide-\(suffix).png") }
            c.state.errorMessage = nil; c.state.selectionPreview = nil

            // 4. Agents tab
            c.state.tab = .agents
            c.state.agentAuth = [.claudeCode: .signedIn(method: "claude.ai"), .codex: .signedOut(hint: AgentAuthManager.loginHint(.codex))]
            await settle(); if png(p.contentView!, to: out.appendingPathComponent("panel-agents-\(suffix).png")) { written.append("panel-agents-\(suffix).png") }
            c.state.tab = .assistant
            p.orderOut(nil)

            // 5. Settings: general (shortcuts editor), permissions, models, voice, computer use
            for tab in [SettingsTab.general, .permissions, .models, .voice, .computerUse] {
                c.openSettings(tab: tab)
                await settle()
                if let v = c.settingsWindow?.contentView, png(v, to: out.appendingPathComponent("settings-\(tab.rawValue)-\(suffix).png")) {
                    written.append("settings-\(tab.rawValue)-\(suffix).png")
                }
            }
            c.settingsWindow?.orderOut(nil)
        }
        print("rendered \(written.count) screenshots: \(written.joined(separator: ", "))")
        return written.count >= 10 ? 0 : 1
    }
}
#endif
