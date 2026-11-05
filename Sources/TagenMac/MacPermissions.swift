#if os(macOS)
import AppKit
@preconcurrency import AVFoundation
@preconcurrency import Speech
@preconcurrency import ApplicationServices
import TagenCore

/// Checks/requests macOS permissions using only the standard system prompts and the
/// System Settings privacy panes. Never modifies the TCC database.
public final class MacPermissionChecker: PermissionChecker, @unchecked Sendable {
    let appSwitches: @Sendable (PermissionKind) -> Bool

    public init(appSwitches: @escaping @Sendable (PermissionKind) -> Bool) { self.appSwitches = appSwitches }

    public func status(_ kind: PermissionKind) async -> PermissionState {
        switch kind {
        case .accessibility: return AXIsProcessTrusted() ? .granted : .denied
        case .screenCapture: return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            default: return .notDetermined
            }
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            default: return .notDetermined
            }
        case .appAutomation: return .unknown   // granted per target app when first used
        case .fileAccess, .agentExecution: return appSwitches(kind) ? .granted : .denied
        }
    }

    public func request(_ kind: PermissionKind) async -> PermissionState {
        switch kind {
        case .accessibility:
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        case .screenCapture:
            _ = CGRequestScreenCaptureAccess()
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .speechRecognition:
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in SFSpeechRecognizer.requestAuthorization { _ in c.resume() } }
        case .appAutomation, .fileAccess, .agentExecution:
            await openSystemSettings(for: kind)
        }
        return await status(kind)
    }

    public func openSystemSettings(for kind: PermissionKind) async {
        let anchor: String
        switch kind {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .screenCapture: anchor = "Privacy_ScreenCapture"
        case .microphone: anchor = "Privacy_Microphone"
        case .speechRecognition: anchor = "Privacy_SpeechRecognition"
        case .appAutomation: anchor = "Privacy_Automation"
        case .fileAccess: anchor = "Privacy_FilesAndFolders"
        case .agentExecution: return
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            _ = await MainActor.run { NSWorkspace.shared.open(url) }
        }
    }
}
#endif
