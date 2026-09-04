import Foundation

public struct ControllerID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

public struct PlayerID: Codable, Hashable, Sendable, Comparable, Identifiable {
    public let rawValue: UInt8

    public init(_ rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public var id: UInt8 { rawValue }

    public static func < (lhs: PlayerID, rhs: PlayerID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct PlayerInfo: Codable, Hashable, Sendable, Identifiable {
    public let id: PlayerID
    public var displayName: String
    public let colorHex: String
    public var isConnected: Bool

    public init(id: PlayerID, displayName: String, colorHex: String, isConnected: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.colorHex = colorHex
        self.isConnected = isConnected
    }

    public var number: Int { Int(id.rawValue) + 1 }
}

public struct RGBComponents: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public enum ArcadePalette {
    public static let cyan = "#32E6FF"
    public static let magenta = "#FF4FD8"
    public static let lime = "#6DFF78"

    public static func rgb(_ value: String) -> RGBComponents? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard hex.count == 6, let number = UInt64(hex, radix: 16) else { return nil }
        return RGBComponents(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }
}

public enum PlayerPalette {
    public static let colors = [
        ArcadePalette.cyan, ArcadePalette.magenta, "#FFE44D", ArcadePalette.lime,
        "#FF7A3D", "#9F7BFF", "#F5F7FF", "#55A7FF",
    ]

    public static func color(for id: PlayerID) -> String {
        colors[Int(id.rawValue) % colors.count]
    }
}

public enum DisplayName {
    private final class ScalarMatcher: @unchecked Sendable {
        private let expression: NSRegularExpression

        init(_ pattern: String) {
            expression = try! NSRegularExpression(pattern: pattern)
        }

        func matches(_ scalar: Unicode.Scalar) -> Bool {
            let value = String(scalar)
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return expression.firstMatch(in: value, range: range) != nil
        }
    }

    private static let maximumAnalyzedScalars = 128
    private static let leftJoiningMatcher = ScalarMatcher(
        #"^[\p{Joining_Type=Left_Joining}\p{Joining_Type=Dual_Joining}]$"#
    )
    private static let rightJoiningMatcher = ScalarMatcher(
        #"^[\p{Joining_Type=Right_Joining}\p{Joining_Type=Dual_Joining}]$"#
    )
    private static let transparentJoiningMatcher = ScalarMatcher(
        #"^\p{Joining_Type=Transparent}$"#
    )
    private static let dependentVowelMatcher = ScalarMatcher(
        #"^\p{Indic_Syllabic_Category=Vowel_Dependent}$"#
    )

    public static func sanitized(_ candidate: String, fallback: String) -> String {
        let compactCandidate = compact(candidate)
        let compactFallback = compact(fallback)
        let resolved = compactCandidate.isEmpty ? compactFallback : compactCandidate
        return String((resolved.isEmpty ? "Player" : resolved).prefix(24))
    }

    private static func compact(_ value: String) -> String {
        let bounded = String(String.UnicodeScalarView(
            value.unicodeScalars.prefix(maximumAnalyzedScalars)
        ))
        let normalized = bounded.precomposedStringWithCanonicalMapping
        let scalars = Array(normalized.unicodeScalars.prefix(maximumAnalyzedScalars))
        let permittedIgnorables = permittedDefaultIgnorables(in: scalars)
        let space = Unicode.Scalar(" ")
        let safeScalars = scalars.enumerated().compactMap { index, scalar -> Unicode.Scalar? in
            if scalar.properties.isDefaultIgnorableCodePoint,
               !permittedIgnorables.contains(index) {
                return nil
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return space }
            if scalar.properties.isBidiControl || scalar.properties.generalCategory == .control { return nil }
            return scalar
        }
        guard safeScalars.contains(where: {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !$0.properties.isDefaultIgnorableCodePoint
        }) else { return "" }
        let compact = String(String.UnicodeScalarView(safeScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return compact
    }

    private static func permittedDefaultIgnorables(
        in scalars: [Unicode.Scalar]
    ) -> Set<Int> {
        var permitted: Set<Int> = []
        let registeredEmojiZWJIndices = registeredEmojiZWJIndices(in: scalars)
        var index = scalars.startIndex
        while index < scalars.endIndex {
            switch scalars[index].value {
            case 0x200C:
                if hasCursiveZWNJContext(at: index, in: scalars)
                    || hasViramaContext(before: index, in: scalars, requiresFollowingLetter: true) {
                    permitted.insert(index)
                }
            case 0x200D:
                if registeredEmojiZWJIndices.contains(index)
                    || hasViramaContext(before: index, in: scalars, requiresFollowingLetter: false) {
                    permitted.insert(index)
                }
            case 0xFE00...0xFE0F:
                if index > scalars.startIndex,
                   UnicodeSequenceData.isRegisteredVariationSequence(
                    base: scalars[index - 1],
                    selector: scalars[index]
                   ) {
                    permitted.insert(index)
                }
            case 0x1F3F4:
                if let tagEnd = emojiTagSequenceEnd(startingAt: index, in: scalars) {
                    permitted.formUnion((index + 1)...tagEnd)
                    index = tagEnd
                }
            default:
                break
            }
            index += 1
        }
        return permitted
    }

    private static func hasCursiveZWNJContext(
        at index: Int,
        in scalars: [Unicode.Scalar]
    ) -> Bool {
        guard let previous = nonTransparentScalar(before: index, in: scalars),
              let next = nonTransparentScalar(after: index, in: scalars) else { return false }
        return matches(previous, using: leftJoiningMatcher)
            && matches(next, using: rightJoiningMatcher)
    }

    private static func nonTransparentScalar(
        before index: Int,
        in scalars: [Unicode.Scalar]
    ) -> Unicode.Scalar? {
        var cursor = index - 1
        while cursor >= scalars.startIndex {
            let scalar = scalars[cursor]
            if !matches(scalar, using: transparentJoiningMatcher) { return scalar }
            cursor -= 1
        }
        return nil
    }

    private static func nonTransparentScalar(
        after index: Int,
        in scalars: [Unicode.Scalar]
    ) -> Unicode.Scalar? {
        var cursor = index + 1
        while cursor < scalars.endIndex {
            let scalar = scalars[cursor]
            if !matches(scalar, using: transparentJoiningMatcher) { return scalar }
            cursor += 1
        }
        return nil
    }

    private static func registeredEmojiZWJIndices(
        in scalars: [Unicode.Scalar]
    ) -> Set<Int> {
        var registeredIndices: Set<Int> = []
        let value = String(String.UnicodeScalarView(scalars))
        var lowerBound = scalars.startIndex
        for character in value {
            let upperBound = lowerBound + character.unicodeScalars.count
            let joinerIndices = (lowerBound..<upperBound).filter {
                scalars[$0].value == 0x200D
            }
            for sequenceStart in lowerBound..<upperBound {
                guard let firstJoiner = joinerIndices.first(where: { $0 >= sequenceStart }),
                      firstJoiner + 1 < upperBound else { break }
                // A malformed adjacent joiner can merge multiple spans into one Character.
                let firstSequenceEnd = firstJoiner + 2
                let lastSequenceEnd = min(
                    upperBound,
                    sequenceStart + UnicodeSequenceData.maximumEmojiZWJSequenceScalarCount
                )
                guard firstSequenceEnd <= lastSequenceEnd else { continue }
                for sequenceEnd in firstSequenceEnd...lastSequenceEnd {
                    let sequence = String(String.UnicodeScalarView(
                        scalars[sequenceStart..<sequenceEnd]
                    ))
                    if UnicodeSequenceData.isRegisteredEmojiZWJSequence(sequence) {
                        registeredIndices.formUnion(
                            joinerIndices.filter { (sequenceStart..<sequenceEnd).contains($0) }
                        )
                    }
                }
            }
            lowerBound = upperBound
        }
        return registeredIndices
    }

    private static func hasViramaContext(
        before index: Int,
        in scalars: [Unicode.Scalar],
        requiresFollowingLetter: Bool
    ) -> Bool {
        var cursor = index - 1
        while cursor >= scalars.startIndex,
              isNonspacingMark(scalars[cursor]),
              scalars[cursor].properties.canonicalCombiningClass != .virama {
            cursor -= 1
        }
        guard cursor >= scalars.startIndex,
              scalars[cursor].properties.canonicalCombiningClass == .virama else { return false }
        cursor -= 1
        while cursor >= scalars.startIndex, isNonspacingMark(scalars[cursor]) { cursor -= 1 }
        guard cursor >= scalars.startIndex, isLetter(scalars[cursor]) else { return false }

        let following = index + 1
        if !requiresFollowingLetter {
            return following >= scalars.endIndex
                || !matches(scalars[following], using: dependentVowelMatcher)
        }
        var next = following
        while next < scalars.endIndex,
              isNonspacingMark(scalars[next]),
              scalars[next].properties.canonicalCombiningClass != .notReordered {
            next += 1
        }
        return next < scalars.endIndex && isLetter(scalars[next])
    }

    private static func emojiTagSequenceEnd(
        startingAt index: Int,
        in scalars: [Unicode.Scalar]
    ) -> Int? {
        var cursor = index + 1
        let firstTag = cursor
        while cursor < scalars.endIndex,
              (0xE0030...0xE0039).contains(scalars[cursor].value)
                || (0xE0061...0xE007A).contains(scalars[cursor].value) {
            cursor += 1
        }
        guard cursor > firstTag, cursor < scalars.endIndex,
              scalars[cursor].value == 0xE007F,
              cursor - index + 1 <= 32 else { return nil }
        let payload = String(String.UnicodeScalarView(
            scalars[firstTag..<cursor].compactMap { Unicode.Scalar($0.value - 0xE0000) }
        ))
        guard UnicodeSequenceData.isValidSubdivisionIdentifier(payload) else { return nil }
        return cursor
    }

    private static func matches(
        _ scalar: Unicode.Scalar,
        using matcher: ScalarMatcher
    ) -> Bool {
        matcher.matches(scalar)
    }

    private static func isNonspacingMark(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .nonspacingMark
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            true
        default:
            false
        }
    }
}
