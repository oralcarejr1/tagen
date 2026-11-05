import Foundation

/// Every capability is gated separately. The first four map to macOS TCC services;
/// the rest are app-level switches the user controls in Settings.
public enum PermissionKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case screenCapture
    case accessibility
    case microphone
    case speechRecognition
    case fileAccess
    case appAutomation
    case agentExecution
    public var id: String { rawValue }

    public var isSystemManaged: Bool {
        switch self {
        case .screenCapture, .accessibility, .microphone, .speechRecognition, .appAutomation: return true
        case .fileAccess, .agentExecution: return false
        }
    }

    public var title: (en: String, ko: String) {
        switch self {
        case .screenCapture: return ("Screen Recording", "화면 기록")
        case .accessibility: return ("Accessibility", "손쉬운 사용")
        case .microphone: return ("Microphone", "마이크")
        case .speechRecognition: return ("Speech Recognition", "음성 인식")
        case .fileAccess: return ("Project Folder Access", "프로젝트 폴더 접근")
        case .appAutomation: return ("App Automation", "앱 자동화")
        case .agentExecution: return ("Coding Agent Execution", "코딩 에이전트 실행")
        }
    }

    public var purpose: String {
        switch self {
        case .screenCapture: return "Capture the active window or a selected region when accessibility text is not enough."
        case .accessibility: return "Read the active window's UI elements and selected text; perform approved GUI actions."
        case .microphone: return "Push-to-talk voice input (only while the talk key is held)."
        case .speechRecognition: return "Transcribe push-to-talk audio, on-device when available."
        case .fileAccess: return "Let coding agents work in folders you choose."
        case .appAutomation: return "Send Apple Events / menu commands to other apps for approved actions."
        case .agentExecution: return "Start Codex / Claude Code processes on your Mac."
        }
    }
}

public enum PermissionState: String, Sendable, Codable {
    case granted, denied, notDetermined, restricted, unknown
    public var isGranted: Bool { self == .granted }
}

/// OS boundary for checking/requesting permissions. Never bypasses system dialogs:
/// `request` only triggers the standard system prompt or opens System Settings.
public protocol PermissionChecker: Sendable {
    func status(_ kind: PermissionKind) async -> PermissionState
    func request(_ kind: PermissionKind) async -> PermissionState
    func openSystemSettings(for kind: PermissionKind) async
}

public enum Feature: String, Sendable, CaseIterable {
    case askAboutScreen, selectionActions, visualGuidance, voice, codingAgents, computerUse

    public var required: [PermissionKind] {
        switch self {
        case .askAboutScreen: return [.accessibility]
        case .selectionActions: return [.accessibility]
        case .visualGuidance: return [.accessibility]
        case .voice: return [.microphone, .speechRecognition]
        case .codingAgents: return [.agentExecution, .fileAccess]
        case .computerUse: return [.accessibility]
        }
    }
    /// Permissions that improve the feature but are not required (graceful degradation).
    public var optional: [PermissionKind] {
        switch self {
        case .askAboutScreen, .visualGuidance, .computerUse: return [.screenCapture]
        case .selectionActions: return [.screenCapture]
        default: return []
        }
    }
}

public struct PermissionReport: Sendable, Equatable {
    public var feature: Feature
    public var missingRequired: [PermissionKind]
    public var missingOptional: [PermissionKind]
    public var available: Bool { missingRequired.isEmpty }
    public var degraded: Bool { !missingOptional.isEmpty }
}

public enum PermissionGate {
    public static func evaluate(_ feature: Feature, states: [PermissionKind: PermissionState]) -> PermissionReport {
        PermissionReport(
            feature: feature,
            missingRequired: feature.required.filter { states[$0]?.isGranted != true },
            missingOptional: feature.optional.filter { states[$0]?.isGranted != true })
    }
}
