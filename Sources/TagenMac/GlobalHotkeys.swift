#if os(macOS)
import AppKit
import Carbon.HIToolbox
import TagenCore

/// System-wide hotkeys via Carbon RegisterEventHotKey (does not require Accessibility).
/// Supports press and release callbacks (for push-to-talk).
@MainActor
public final class GlobalHotkeys {
    public struct Hotkey: Sendable, Equatable {
        public var keyCode: UInt32
        public var modifiers: UInt32   // Carbon modifier flags (cmdKey, optionKey, ...)
        public init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }

        /// From a configurable binding (virtual key codes are layout-independent positions, US names).
        public init?(_ combo: KeyCombo) {
            guard let code = KeyCodes.code(for: combo.key) else { return nil }
            self.init(keyCode: UInt32(code), modifiers: HotkeyBindings.carbonModifiers(combo))
        }

        public static let optionSpace = Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
        public static let controlOptionSpace = Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))
        public static let emergencyStop = Hotkey(keyCode: UInt32(kVK_ANSI_Period), modifiers: UInt32(controlKey | optionKey | cmdKey))
        public static let selectionActions = Hotkey(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey | shiftKey))
        public static let guide = Hotkey(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(optionKey | shiftKey))
        public static let region = Hotkey(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | shiftKey))
    }

    public static let shared = GlobalHotkeys()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    fileprivate var pressHandlers: [UInt32: () -> Void] = [:]
    fileprivate var releaseHandlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var installed = false
    public var failures: [String] = []

    @discardableResult
    public func register(_ hk: Hotkey, name: String, onPress: @escaping () -> Void, onRelease: (() -> Void)? = nil) -> Bool {
        installIfNeeded()
        let id = nextID; nextID += 1
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x5447_4E31), id: id)  // 'TGN1'
        let st = RegisterEventHotKey(hk.keyCode, hk.modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        guard st == noErr, let r = ref else { failures.append("\(name): RegisterEventHotKey \(st)"); return false }
        refs[id] = r
        pressHandlers[id] = onPress
        if let onRelease { releaseHandlers[id] = onRelease }
        return true
    }

    public func unregisterAll() {
        for r in refs.values { UnregisterEventHotKey(r) }
        refs.removeAll(); pressHandlers.removeAll(); releaseHandlers.removeAll()
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            let st = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                       MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard st == noErr else { return st }
            let kind = GetEventKind(event)
            let id = hkID.id
            MainActor.assumeIsolated {
                if kind == UInt32(kEventHotKeyPressed) { GlobalHotkeys.shared.pressHandlers[id]?() }
                else if kind == UInt32(kEventHotKeyReleased) { GlobalHotkeys.shared.releaseHandlers[id]?() }
            }
            return noErr
        }, 2, &specs, nil, nil)
    }
}
#endif
