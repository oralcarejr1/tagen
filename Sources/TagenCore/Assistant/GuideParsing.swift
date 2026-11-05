import Foundation

public struct GuideReply: Sendable, Equatable {
    public var answer: String
    public var annotations: [Annotation]
    public var rejected: [String]   // reasons for dropped annotation proposals
}

public enum GuideParser {
    /// Extract the first top-level JSON object from model text (handles ```json fences and
    /// surrounding prose).
    public static func extractJSONObject(_ text: String) -> JSONValue? {
        if let v = try? JSONValue.parse(text.trimmingCharacters(in: .whitespacesAndNewlines)), v.objectValue != nil { return v }
        let chars = Array(text)
        var start: Int?
        var depth = 0
        var inString = false
        var escape = false
        for (i, c) in chars.enumerated() {
            if inString {
                if escape { escape = false } else if c == "\\" { escape = true } else if c == "\"" { inString = false }
                continue
            }
            if c == "\"" { inString = start != nil; continue }
            if c == "{" { if depth == 0 { start = i }; depth += 1 }
            else if c == "}" && depth > 0 {
                depth -= 1
                if depth == 0, let s = start {
                    if let v = try? JSONValue.parse(String(chars[s...i])), v.objectValue != nil { return v }
                    start = nil
                }
            }
        }
        return nil
    }

    /// Validate and convert the model's guide JSON into anchored annotations. Element ids
    /// must exist in the context; boxes must lie within the screenshot.
    public static func parse(_ text: String, context: ScreenContext, now: Date = Date(), ttl: Double = 30) -> GuideReply {
        guard let json = extractJSONObject(text) else {
            return GuideReply(answer: text.trimmingCharacters(in: .whitespacesAndNewlines), annotations: [], rejected: ["no JSON object in reply"])
        }
        let answer = json["answer"]?.stringValue ?? ""
        var anns: [Annotation] = []
        var rejected: [String] = []
        for (i, a) in (json["annotations"]?.arrayValue ?? []).prefix(6).enumerated() {
            let kind = AnnotationKind(rawValue: a["type"]?.stringValue ?? "highlight") ?? .highlight
            let label = a["label"]?.stringValue
            if let eid = a["element_id"]?.stringValue, !eid.isEmpty {
                guard let el = context.element(id: eid) else { rejected.append("annotation \(i): unknown element id \(eid)"); continue }
                guard let frame = el.frame, !frame.isEmpty else { rejected.append("annotation \(i): element \(eid) has no frame"); continue }
                let identity = ElementIdentity(element: el, pid: context.app?.pid)
                anns.append(Annotation(kind: kind, target: .element(identity, frame: frame), label: label, createdAt: now, ttl: ttl,
                                       windowFrame: context.window?.frame))
            } else if let box = a["box"]?.arrayValue, box.count == 4, let img = context.image {
                let vals = box.compactMap(\.doubleValue)
                guard vals.count == 4, vals[2] > 0, vals[3] > 0 else { rejected.append("annotation \(i): malformed box"); continue }
                let r = Rect(x: vals[0], y: vals[1], width: vals[2], height: vals[3])
                let bounds = Rect(origin: .zero, size: img.geometry.imageSize)
                guard bounds.insetBy(dx: -2, dy: -2).contains(r) else { rejected.append("annotation \(i): box outside screenshot"); continue }
                let global = img.geometry.globalRect(fromImagePixel: r)
                anns.append(Annotation(kind: kind, target: .screen(global), label: label, createdAt: now, ttl: ttl,
                                       windowFrame: context.window?.frame))
            } else {
                rejected.append("annotation \(i): no element_id or usable box")
            }
        }
        return GuideReply(answer: answer, annotations: anns, rejected: rejected)
    }
}
