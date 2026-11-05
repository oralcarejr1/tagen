import Foundation

public enum LanguageCode: String, Sendable, Codable, CaseIterable {
    case korean = "ko"
    case english = "en"

    public var localeIdentifier: String { self == .korean ? "ko-KR" : "en-US" }
    public var displayName: String { self == .korean ? "한국어" : "English" }
    public var englishName: String { self == .korean ? "Korean" : "English" }
    public var other: LanguageCode { self == .korean ? .english : .korean }
}

public enum LanguageDetector {
    /// Ratio of Hangul letters among all letters.
    public static func hangulRatio(_ text: String) -> Double {
        var hangul = 0, letters = 0
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            letters += 1
            if isHangul(scalar) { hangul += 1 }
        }
        return letters == 0 ? 0 : Double(hangul) / Double(letters)
    }

    public static func isHangul(_ s: Unicode.Scalar) -> Bool {
        (0xAC00...0xD7A3).contains(s.value) || (0x1100...0x11FF).contains(s.value) || (0x3130...0x318F).contains(s.value)
    }

    /// Korean if at least 30% of letters are Hangul, English otherwise. `fallback` is used
    /// for text without letters.
    public static func detect(_ text: String, fallback: LanguageCode = .english) -> LanguageCode {
        let hasLetters = text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        guard hasLetters else { return fallback }
        return hangulRatio(text) >= 0.3 ? .korean : .english
    }
}
