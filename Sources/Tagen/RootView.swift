#if os(macOS)
import SwiftUI
import TagenCore
import TagenAgents

struct RootView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.appController) var app

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $state.tab) {
                    Text(state.t("Assistant", "어시스턴트")).tag(PanelTab.assistant)
                    Text(state.t("Agents", "에이전트")).tag(PanelTab.agents)
                    Text(state.t("History", "기록")).tag(PanelTab.history)
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
                Spacer()
                Button { app?.openSettings() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help(state.t("Settings", "설정"))
                Button(role: .destructive) { app?.emergencyStop() } label: {
                    Label(state.t("Stop", "정지"), systemImage: "stop.circle.fill")
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .help(state.t("Emergency stop (⌃⌥⌘.)", "긴급 정지 (⌃⌥⌘.)"))
                .accessibilityIdentifier("emergencyStopButton")
            }
            .padding(.horizontal, 12).padding(.top, 28).padding(.bottom, 8)

            if !state.approvals.isEmpty { ApprovalBanner().padding(.horizontal, 12) }
            if let e = state.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(e).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button { state.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .padding(8).background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 12)
            }
            Divider().padding(.top, 6)
            switch state.tab {
            case .assistant: AssistantView()
            case .agents: AgentsView()
            case .history: HistoryView()
            }
        }
        .frame(minWidth: 420, minHeight: 320)
    }
}

struct ApprovalBanner: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        if let a = state.approvals.first {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: a.request.risk >= .high ? "exclamationmark.octagon.fill" : "hand.raised.fill")
                        .foregroundStyle(a.request.risk >= .high ? .red : .orange)
                    Text(a.request.title).font(.headline)
                    Spacer()
                    Text("\(state.t("Risk", "위험도")): \(a.request.risk.description)").font(.caption).padding(4)
                        .background((a.request.risk >= .high ? Color.red : Color.orange).opacity(0.2), in: Capsule())
                }
                Text(a.request.detail).font(.system(.callout, design: .monospaced)).lineLimit(6).textSelection(.enabled)
                if !a.request.reasons.isEmpty {
                    Text(a.request.reasons.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text(a.request.source).font(.caption2).foregroundStyle(.secondary)
                    if state.approvals.count > 1 { Text("+\(state.approvals.count - 1)").font(.caption2) }
                    Spacer()
                    Button(state.t("Deny", "거부")) { state.resolveApproval(a.id, .denied(reason: "user denied")) }
                        .keyboardShortcut(.cancelAction).accessibilityIdentifier("denyButton")
                    if a.request.risk < .high {
                        Button(state.t("Allow for this task", "이 작업 동안 허용")) { state.resolveApproval(a.id, .approvedForTask) }
                    }
                    Button(state.t("Allow once", "한 번 허용")) { state.resolveApproval(a.id, .approved) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("approveButton")
                }
            }
            .padding(10)
            .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.5)))
        }
    }
}
#endif
