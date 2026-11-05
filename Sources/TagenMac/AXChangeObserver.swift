#if os(macOS)
import Foundation
@preconcurrency import ApplicationServices

/// Wraps an AXObserver that fires on element move/resize/destroy (and window move/resize) for one process.
/// Callbacks arrive on the main run loop. Call `invalidate()` (or release the object) to stop.
public final class AXChangeObserver: @unchecked Sendable {
    private var observer: AXObserver?
    private var registrations: [(AXElement, String)] = []
    private let onChange: @Sendable () -> Void
    public private(set) var registeredCount = 0

    static let elementNotifications = [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification] as [String]
    static let windowNotifications = [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification,
                                      kAXWindowMiniaturizedNotification] as [String]

    public init?(pid: pid_t, elements: [AXElement], window: AXElement?, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<AXChangeObserver>.fromOpaque(refcon).takeUnretainedValue().onChange()
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return nil }
        observer = obs
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        func add(_ el: AXElement, _ names: [String]) {
            for n in names where AXObserverAddNotification(obs, el.ref, n as CFString, refcon) == .success {
                registrations.append((el, n)); registeredCount += 1
            }
        }
        for e in elements { add(e, Self.elementNotifications) }
        if let w = window { add(w, Self.windowNotifications) }
        guard registeredCount > 0 else { observer = nil; return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }

    public func invalidate() {
        guard let obs = observer else { return }
        for (el, n) in registrations { AXObserverRemoveNotification(obs, el.ref, n as CFString) }
        registrations.removeAll()
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = nil
    }

    deinit { invalidate() }
}
#endif
