#if os(macOS)
import SwiftUI
import TagenCore
import TagenAgents

struct PendingApproval: Identifiable {
    let request: ApprovalRequest
    let resolve: (ApprovalDecision) -> Void
    var id: UUID { request.id }
}

struct ReplacementProposal: Equatable {
    var text: String
    var selection: SelectedText
}

enum PanelTab: String, CaseIterable { case assistant, agents, history }

/// Observable UI state. All mutation happens on the main actor.
@MainActor
final class AppState: ObservableObject {
    @Published var tab: PanelTab = .assistant
    @Published var mode: AssistantMode = .ask
    @Published var input = ""
    @Published var response = ""
    @Published var status = ""
    @Published var busy = false
    @Published var context: ContextSummary?
    @Published var guidanceNotes: [String] = []
    @Published var replacement: ReplacementProposal?
    @Published var approvals: [PendingApproval] = []
    @Published var voiceState: VoiceState = .idle
    @Published var actLog: [String] = []
    @Published var agentTasks: [UUID: AgentTaskSnapshot] = [:]
    @Published var selectedAgentTask: UUID?
    @Published var agentAuth: [AgentProvider: AgentAuthState] = [:]
    @Published var history: [ConversationRecord] = []
    @Published var historyMessages: [MessageRecord] = []
    @Published var permissions: [PermissionKind: PermissionState] = [:]
    @Published var errorMessage: String?
    @Published var settings = AppSettings()
    @Published var hasAnthropicKey = false
    @Published var panelLatenciesMs: [Double] = []

    var lang: LanguageCode { settings.uiLanguage }
    func t(_ en: String, _ ko: String) -> String { lang == .korean ? ko : en }

    func enqueueApproval(_ r: ApprovalRequest, resolve: @escaping (ApprovalDecision) -> Void) {
        approvals.append(PendingApproval(request: r, resolve: resolve))
    }

    func resolveApproval(_ id: UUID, _ d: ApprovalDecision) {
        guard let i = approvals.firstIndex(where: { $0.id == id }) else { return }
        let p = approvals.remove(at: i)
        p.resolve(d)
    }

    func cancelApproval(_ id: UUID) { resolveApproval(id, .denied(reason: "cancelled")) }

    var missingForAsk: [PermissionKind] { PermissionGate.evaluate(.askAboutScreen, states: permissions).missingRequired }
}

/// Presents approvals in the floating panel and waits for the user. Cancellation (timeout,
/// emergency stop) resolves the request as denied.
final class PanelApprovalPresenter: ApprovalPresenter, @unchecked Sendable {
    weak var state: AppState?
    let onPresent: @MainActor () -> Void

    init(state: AppState, onPresent: @escaping @MainActor () -> Void) { self.state = state; self.onPresent = onPresent }

    func present(_ request: ApprovalRequest) async -> ApprovalDecision {
        let once = Locked<CheckedContinuation<ApprovalDecision, Never>?>(nil)
        @Sendable func finish(_ d: ApprovalDecision) {
            if let c = once.withLock({ v -> CheckedContinuation<ApprovalDecision, Never>? in let c = v; v = nil; return c }) { c.resume(returning: d) }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<ApprovalDecision, Never>) in
                once.set(c)
                Task { @MainActor [weak self] in
                    guard let self, let state = self.state else { finish(.denied(reason: "UI unavailable")); return }
                    state.enqueueApproval(request) { finish($0) }
                    self.onPresent()
                }
            }
        } onCancel: { [weak self] in
            finish(.denied(reason: "cancelled"))
            Task { @MainActor in self?.state?.approvals.removeAll { $0.id == request.id } }
        }
    }
}
#endif
