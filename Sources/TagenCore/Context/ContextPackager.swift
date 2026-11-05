import Foundation

/// Turns a ScreenContext into model input: a compact text rendering of the accessibility
/// tree (with element ids the model can refer to), the selection, OCR text and, only when
/// needed, the screenshot. Screen content is always wrapped as untrusted data.
public struct ContextPackager: Sendable {
    public struct Options: Sendable, Equatable {
        public var maxElements: Int = 400
        public var maxCharacters: Int = 24_000
        public var maxValueLength: Int = 300
        public var includeFrames: Bool = true
        /// Minimum AX text volume considered "sufficient" to skip the screenshot.
        public var sufficientTextVolume: Int = 200
        public var redactSecrets: Bool = true
        public init() {}
    }

    public struct Package: Sendable, Equatable {
        public var text: String
        public var image: CapturedImage?
        public var includedElementIDs: [String]
        public var usedImageReason: String?
        public var truncated: Bool
    }

    public let options: Options
    private let redactor = Redactor()

    public init(options: Options = Options()) { self.options = options }

    static let visualKeywords: [String] = [
        "look like", "looks like", "color", "colour", "image", "picture", "photo", "chart", "graph", "diagram",
        "icon", "logo", "design", "layout", "screenshot", "visible", "see on", "on screen", "plot", "figure",
        "보이", "색", "그림", "사진", "이미지", "차트", "그래프", "도표", "아이콘", "디자인", "레이아웃", "화면에", "생김",
    ]

    /// Decide whether a screenshot is needed. Prefers accessibility text when sufficient.
    public func screenshotDecision(question: String, context: ScreenContext, policy: ContextRequest.ScreenshotPolicy) -> (Bool, String?) {
        switch policy {
        case .never: return (false, nil)
        case .always: return (true, "screenshot always enabled")
        case .ifNeeded:
            let q = question.lowercased()
            if Self.visualKeywords.contains(where: { q.contains($0) }) { return (true, "question refers to visual content") }
            if context.axRoot == nil { return (true, "accessibility tree unavailable") }
            if context.accessibilityTextVolume < options.sufficientTextVolume && context.ocr.isEmpty {
                return (true, "accessibility text insufficient")
            }
            if let bid = context.app?.bundleID, Self.canvasApps.contains(bid) { return (true, "canvas-style application") }
            return (false, nil)
        }
    }

    /// Apps whose content is mostly not exposed via accessibility.
    public static let canvasApps: Set<String> = [
        "com.figma.Desktop", "com.adobe.Photoshop", "com.apple.Preview", "com.apple.QuickTimePlayerX",
        "com.adobe.illustrator", "com.microsoft.VSCode.canvas", "org.blenderfoundation.blender",
    ]

    public func package(_ ctx: ScreenContext, question: String, policy: ContextRequest.ScreenshotPolicy) -> Package {
        var lines: [String] = []
        if let app = ctx.app { lines.append("Application: \(app.name)\(app.bundleID.map { " (\($0))" } ?? "")") }
        if let w = ctx.window {
            lines.append("Window: \(sanitize(w.title ?? "(untitled)"))\(w.isFullScreen ? " [full screen]" : "") frame=\(w.frame)")
        }
        if let url = ctx.url { lines.append("URL: \(sanitize(url))") }
        if let sel = ctx.selection, !sel.text.isEmpty {
            lines.append("Selected text (\(sel.source.rawValue)):")
            lines.append(indent(clip(sanitize(sel.text), 4000)))
        }
        if let f = ctx.focusedElementID, let e = ctx.element(id: f) {
            lines.append("Focused element: [\(e.id)] \(describe(e))")
        }

        var included: [String] = []
        var truncated = false
        if let root = ctx.axRoot {
            lines.append("Accessibility tree (ids in brackets; frames are global screen points x,y,w×h):")
            var count = 0
            var budget = options.maxCharacters
            func walk(_ e: AXElementSnapshot, depth: Int) {
                if count >= options.maxElements || budget <= 0 { truncated = true; return }
                let relevant = isRelevant(e)
                var nextDepth = depth
                if relevant {
                    let line = String(repeating: "  ", count: min(depth, 12)) + "[\(e.id)] " + describe(e)
                    budget -= line.count
                    lines.append(line)
                    included.append(e.id)
                    count += 1
                    nextDepth += 1
                }
                for c in e.children { walk(c, depth: nextDepth) }
            }
            walk(root, depth: 0)
            if truncated { lines.append("… (accessibility tree truncated)") }
        }

        if !ctx.ocr.isEmpty {
            lines.append("OCR text (top-to-bottom):")
            let sorted = ctx.ocr.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
            var chars = 0
            for l in sorted {
                if chars > 8000 { lines.append("… (OCR truncated)"); break }
                let t = sanitize(l.text)
                chars += t.count
                lines.append("  \(t)  @\(l.frame)")
            }
        }
        if !ctx.limitations.isEmpty { lines.append("Collection limits: " + ctx.limitations.joined(separator: "; ")) }

        let (needImage, reason) = screenshotDecision(question: question, context: ctx, policy: policy)
        let image = needImage ? ctx.image : nil
        if let img = image {
            lines.append("A screenshot is attached. It covers global rect \(img.geometry.captureRect) at \(Int(img.geometry.imageSize.width))×\(Int(img.geometry.imageSize.height)) px.")
        }

        let body = lines.joined(separator: "\n")
        let wrapped = PromptLibrary.wrapUntrusted(body, kind: "screen_context")
        return Package(text: wrapped, image: image, includedElementIDs: included, usedImageReason: image != nil ? reason : nil, truncated: truncated)
    }

    func isRelevant(_ e: AXElementSnapshot) -> Bool {
        if e.isInteractive { return true }
        if e.displayName != nil { return true }
        if let v = e.value, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return ["AXWindow", "AXSheet", "AXDialog", "AXWebArea", "AXHeading", "AXStaticText", "AXImage", "AXTable", "AXList"].contains(e.role)
            && (e.displayName != nil || e.value != nil)
    }

    func describe(_ e: AXElementSnapshot) -> String {
        var parts: [String] = [e.role.replacingOccurrences(of: "AX", with: "")]
        if let s = e.subrole { parts[0] += "/" + s.replacingOccurrences(of: "AX", with: "") }
        if let n = e.displayName { parts.append("\"\(clip(sanitize(n), 120))\"") }
        if e.isSecure {
            if let v = e.value, !v.isEmpty { parts.append("value=\"•••\"") }
        } else if let v = e.value, !v.isEmpty, v != e.displayName {
            parts.append("value=\"\(clip(sanitize(v), options.maxValueLength))\"")
        }
        if let i = e.identifier { parts.append("id=\(i)") }
        if !e.isEnabled { parts.append("disabled") }
        if e.isFocused { parts.append("focused") }
        if e.isSelected { parts.append("selected") }
        if options.includeFrames, let f = e.frame { parts.append("@\(f)") }
        return parts.joined(separator: " ")
    }

    func sanitize(_ s: String) -> String {
        let r = options.redactSecrets ? redactor.redact(s) : s
        // Neutralize attempts to close our untrusted-content wrapper.
        return r.replacingOccurrences(of: "</untrusted", with: "<\\/untrusted")
            .replacingOccurrences(of: "<untrusted", with: "<\\untrusted")
    }

    func clip(_ s: String, _ n: Int) -> String { s.count <= n ? s : String(s.prefix(n)) + "…" }
    func indent(_ s: String) -> String { s.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n") }
}
