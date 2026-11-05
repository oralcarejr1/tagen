#if os(macOS)
import Foundation
@preconcurrency import Vision
import TagenCore

/// Apple Vision OCR (Korean + English).
public struct TextRecognizer: Sendable {
    public var languages: [String] = ["ko-KR", "en-US"]
    public var minimumConfidence: Float = 0.3
    public init() {}

    public func recognize(_ image: CGImage, geometry: CaptureGeometry) async throws -> [OCRLine] {
        let langs = languages
        let minConf = minimumConfidence
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let supported = (try? request.supportedRecognitionLanguages()) ?? []
                request.recognitionLanguages = langs.filter { supported.contains($0) }
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                    let lines: [OCRLine] = (request.results ?? []).compactMap { obs in
                        guard let cand = obs.topCandidates(1).first, cand.confidence >= minConf else { return nil }
                        let bb = obs.boundingBox
                        let r = Rect(x: Double(bb.minX), y: Double(bb.minY), width: Double(bb.width), height: Double(bb.height))
                        return OCRLine(text: cand.string, frame: geometry.globalRect(fromVisionNormalized: r), confidence: Double(cand.confidence))
                    }
                    cont.resume(returning: lines)
                } catch { cont.resume(throwing: error) }
            }
        }
    }
}
#endif
