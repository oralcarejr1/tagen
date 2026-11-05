import Foundation
import TagenCore
import TagenAgents

public enum CodexMode: String, Codable, CaseIterable, Sendable { case appServer, exec }

/// All user settings (credentials are NOT here — they live in the Keychain).
public struct AppSettings: Codable, Equatable, Sendable {
    public var models = ModelSettings.default
    public var assistant = AssistantSettings()
    public var voice = VoiceSettings()
    public var computerUseEnabled = true
    public var computerUseAutoApproveUpTo: RiskLevel = .medium
    public var computerUseMaxSteps = 20
    public var computerUseTokenBudget = 400_000
    public var agentExecutionEnabled = false
    public var allowedProjectFolders: [String] = []
    public var agentDefaultProfile: AgentPermissionProfile = .askEveryTime
    public var codexMode: CodexMode = .appServer
    public var cliPathOverrides: [String: String] = [:]
    public var uiLanguage: LanguageCode = .korean
    public var onboardingCompleted = false
    public var keepHistory = true
    public var hotkeys: [HotkeyAction: KeyCombo] = HotkeyBindings.defaults

    public init() {}

    /// Decode tolerantly: unknown/missing keys fall back to defaults so settings survive upgrades.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ k: CodingKeys, _ cur: T) -> T {
            do { return try c.decodeIfPresent(T.self, forKey: k) ?? cur } catch { return cur }
        }
        models = d(.models, models); assistant = d(.assistant, assistant); voice = d(.voice, voice)
        computerUseEnabled = d(.computerUseEnabled, computerUseEnabled)
        computerUseAutoApproveUpTo = d(.computerUseAutoApproveUpTo, computerUseAutoApproveUpTo)
        computerUseMaxSteps = d(.computerUseMaxSteps, computerUseMaxSteps)
        computerUseTokenBudget = d(.computerUseTokenBudget, computerUseTokenBudget)
        agentExecutionEnabled = d(.agentExecutionEnabled, agentExecutionEnabled)
        allowedProjectFolders = d(.allowedProjectFolders, allowedProjectFolders)
        agentDefaultProfile = d(.agentDefaultProfile, agentDefaultProfile)
        codexMode = d(.codexMode, codexMode); cliPathOverrides = d(.cliPathOverrides, cliPathOverrides)
        uiLanguage = d(.uiLanguage, uiLanguage); onboardingCompleted = d(.onboardingCompleted, onboardingCompleted)
        keepHistory = d(.keepHistory, keepHistory)
        hotkeys = d(.hotkeys, hotkeys)
        if !HotkeyBindings.validate(hotkeys).isEmpty { hotkeys = HotkeyBindings.defaults }
    }

    public func isAllowedProjectFolder(_ path: String) -> Bool {
        allowedProjectFolders.contains { CommandRisk.isInside(path, $0) }
    }
}
