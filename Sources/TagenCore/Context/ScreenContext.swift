import Foundation

/// Snapshot of one accessibility element. `id` is a stable path within a single snapshot
/// (e.g. "w0.3.1") that models refer to; `frame` is in global coordinates.
public struct AXElementSnapshot: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var role: String
    public var subrole: String?
    public var title: String?
    public var value: String?
    public var label: String?          // AXDescription
    public var help: String?
    public var identifier: String?     // AXIdentifier (developer-provided, most stable)
    public var placeholder: String?
    public var frame: Rect?
    public var isEnabled: Bool
    public var isFocused: Bool
    public var isSelected: Bool
    public var isSecure: Bool
    public var actions: [String]
    public var children: [AXElementSnapshot]

    public init(
        id: String, role: String, subrole: String? = nil, title: String? = nil, value: String? = nil,
        label: String? = nil, help: String? = nil, identifier: String? = nil, placeholder: String? = nil,
        frame: Rect? = nil, isEnabled: Bool = true, isFocused: Bool = false, isSelected: Bool = false,
        isSecure: Bool = false, actions: [String] = [], children: [AXElementSnapshot] = []
    ) {
        self.id = id; self.role = role; self.subrole = subrole; self.title = title; self.value = value
        self.label = label; self.help = help; self.identifier = identifier; self.placeholder = placeholder
        self.frame = frame; self.isEnabled = isEnabled; self.isFocused = isFocused; self.isSelected = isSelected
        self.isSecure = isSecure || role == "AXSecureTextField" || subrole == "AXSecureTextField"
        self.actions = actions; self.children = children
    }

    /// Human-readable name: title, then label, then placeholder, then identifier.
    public var displayName: String? {
        for c in [title, label, placeholder, help] { if let c, !c.trimmingCharacters(in: .whitespaces).isEmpty { return c } }
        return nil
    }

    public var isInteractive: Bool {
        Self.interactiveRoles.contains(role) || actions.contains("AXPress") || actions.contains("AXShowMenu")
    }

    public static let interactiveRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem",
        "AXMenuBarItem", "AXTextField", "AXTextArea", "AXSecureTextField", "AXComboBox", "AXSlider",
        "AXLink", "AXTab", "AXDisclosureTriangle", "AXIncrementor", "AXSearchField", "AXCell", "AXRow",
        "AXSegmentedControl", "AXStepper", "AXColorWell", "AXSwitch", "AXToggle",
    ]

    public static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXSecureTextField"]

    /// Depth-first traversal.
    public func flattened() -> [AXElementSnapshot] {
        var out: [AXElementSnapshot] = []
        var stack: [AXElementSnapshot] = [self]
        while let e = stack.popLast() {
            out.append(e)
            stack.append(contentsOf: e.children.reversed())
        }
        return out
    }

    public func find(id: String) -> AXElementSnapshot? { flattened().first(where: { $0.id == id }) }

    public var elementCount: Int { 1 + children.reduce(0) { $0 + $1.elementCount } }
}

public struct AppInfo: Sendable, Codable, Equatable {
    public var name: String
    public var bundleID: String?
    public var pid: Int32
    public init(name: String, bundleID: String?, pid: Int32) { self.name = name; self.bundleID = bundleID; self.pid = pid }
}

public struct WindowInfo: Sendable, Codable, Equatable {
    public var title: String?
    public var frame: Rect
    public var windowID: UInt32?
    public var isFullScreen: Bool
    public var isMinimized: Bool
    public init(title: String?, frame: Rect, windowID: UInt32? = nil, isFullScreen: Bool = false, isMinimized: Bool = false) {
        self.title = title; self.frame = frame; self.windowID = windowID
        self.isFullScreen = isFullScreen; self.isMinimized = isMinimized
    }
}

public enum SelectionSource: String, Sendable, Codable {
    case accessibility      // kAXSelectedTextAttribute
    case screenRegion       // user-drawn region, OCR'd
    case userProvided       // typed / pasted into the assistant
}

public struct SelectedText: Sendable, Codable, Equatable {
    public var text: String
    public var source: SelectionSource
    /// Element that owns the selection (for approved replacement).
    public var elementID: String?
    public var isEditable: Bool
    public var frame: Rect?
    public init(text: String, source: SelectionSource, elementID: String? = nil, isEditable: Bool = false, frame: Rect? = nil) {
        self.text = text; self.source = source; self.elementID = elementID; self.isEditable = isEditable; self.frame = frame
    }
}

public struct OCRLine: Sendable, Codable, Equatable {
    public var text: String
    public var frame: Rect      // global coordinates
    public var confidence: Double
    public init(text: String, frame: Rect, confidence: Double) { self.text = text; self.frame = frame; self.confidence = confidence }
}

/// A captured image kept in memory only (never persisted by default).
public struct CapturedImage: Sendable, Equatable {
    public var data: Data
    public var mediaType: String   // "image/png" or "image/jpeg"
    public var geometry: CaptureGeometry
    public init(data: Data, mediaType: String, geometry: CaptureGeometry) {
        self.data = data; self.mediaType = mediaType; self.geometry = geometry
    }
}

/// Everything observed about the current screen at one instant.
public struct ScreenContext: Sendable, Equatable {
    public var id: UUID
    public var capturedAt: Date
    public var app: AppInfo?
    public var window: WindowInfo?
    public var url: String?
    public var axRoot: AXElementSnapshot?
    public var focusedElementID: String?
    public var selection: SelectedText?
    public var ocr: [OCRLine]
    public var image: CapturedImage?
    public var layout: DisplayLayout
    /// Notes about what could not be collected (e.g. missing permission).
    public var limitations: [String]

    public init(
        id: UUID = UUID(), capturedAt: Date = Date(), app: AppInfo? = nil, window: WindowInfo? = nil, url: String? = nil,
        axRoot: AXElementSnapshot? = nil, focusedElementID: String? = nil, selection: SelectedText? = nil,
        ocr: [OCRLine] = [], image: CapturedImage? = nil, layout: DisplayLayout = DisplayLayout(displays: []),
        limitations: [String] = []
    ) {
        self.id = id; self.capturedAt = capturedAt; self.app = app; self.window = window; self.url = url
        self.axRoot = axRoot; self.focusedElementID = focusedElementID; self.selection = selection; self.ocr = ocr
        self.image = image; self.layout = layout; self.limitations = limitations
    }

    public func element(id: String) -> AXElementSnapshot? { axRoot?.find(id: id) }

    /// Total characters of human-readable text available from accessibility.
    public var accessibilityTextVolume: Int {
        guard let root = axRoot else { return 0 }
        return root.flattened().reduce(0) { acc, e in
            acc + (e.isSecure ? 0 : (e.value?.count ?? 0)) + (e.displayName?.count ?? 0)
        }
    }
}

/// What to capture for a request.
public struct ContextRequest: Sendable, Equatable {
    public var includeAccessibility: Bool
    public var includeSelection: Bool
    public var includeScreenshot: ScreenshotPolicy
    public var region: Rect?                // explicit user-selected region (global)
    public var maxAXDepth: Int
    public var maxAXElements: Int

    public enum ScreenshotPolicy: String, Sendable, Codable { case never, ifNeeded, always }

    public init(includeAccessibility: Bool = true, includeSelection: Bool = true, includeScreenshot: ScreenshotPolicy = .ifNeeded,
                region: Rect? = nil, maxAXDepth: Int = 25, maxAXElements: Int = 1500) {
        self.includeAccessibility = includeAccessibility; self.includeSelection = includeSelection
        self.includeScreenshot = includeScreenshot; self.region = region
        self.maxAXDepth = maxAXDepth; self.maxAXElements = maxAXElements
    }
}

/// OS boundary: collects ScreenContext. Implemented by TagenMac.MacContextProvider.
public protocol ScreenContextProvider: Sendable {
    func capture(_ request: ContextRequest) async throws -> ScreenContext
    /// Re-read one element's current frame (for annotation anchoring / verification).
    func currentFrame(ofElementWithIdentity identity: ElementIdentity) async -> Rect?
}

/// Durable description of an element that survives re-snapshotting (snapshot ids do not).
public struct ElementIdentity: Sendable, Codable, Equatable, Hashable {
    public var pid: Int32?
    public var role: String
    public var identifier: String?
    public var title: String?
    public var label: String?
    public var path: String          // snapshot id at time of capture, used as tie-breaker
    public var lastFrame: Rect?

    public init(pid: Int32?, role: String, identifier: String?, title: String?, label: String?, path: String, lastFrame: Rect?) {
        self.pid = pid; self.role = role; self.identifier = identifier; self.title = title; self.label = label
        self.path = path; self.lastFrame = lastFrame
    }

    public init(element e: AXElementSnapshot, pid: Int32?) {
        self.init(pid: pid, role: e.role, identifier: e.identifier, title: e.title, label: e.label, path: e.id, lastFrame: e.frame)
    }

    /// Score how well a fresh snapshot element matches this identity (higher is better,
    /// 0 = not a match). Used to re-find elements after the UI changes.
    public func matchScore(_ e: AXElementSnapshot) -> Int {
        guard e.role == role else { return 0 }
        var s = 1
        if let i = identifier, !i.isEmpty { if e.identifier == i { s += 100 } else { return 0 } }
        if let t = title, !t.isEmpty { if e.title == t { s += 20 } else if identifier == nil { return 0 } }
        if let l = label, !l.isEmpty, e.label == l { s += 10 }
        if e.id == path { s += 5 }
        if let f = lastFrame, let ef = e.frame, f.centerDistance(to: ef) < 40 { s += 3 }
        return s
    }

    /// Best match in a snapshot tree, or nil.
    public func resolve(in root: AXElementSnapshot) -> AXElementSnapshot? {
        var best: (AXElementSnapshot, Int)?
        var ambiguous = false
        for e in root.flattened() {
            let sc = matchScore(e)
            guard sc > 0 else { continue }
            if let b = best {
                if sc > b.1 { best = (e, sc); ambiguous = false } else if sc == b.1 { ambiguous = true }
            } else { best = (e, sc) }
        }
        // An ambiguous weak match is not trusted (prevents acting on the wrong control).
        if ambiguous, let b = best, b.1 < 20 { return nil }
        return best?.0
    }
}
