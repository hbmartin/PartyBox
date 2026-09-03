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
    public static func sanitized(_ candidate: String, fallback: String) -> String {
        let compactCandidate = compact(candidate)
        let compactFallback = compact(fallback)
        let resolved = compactCandidate.isEmpty ? compactFallback : compactCandidate
        return String((resolved.isEmpty ? "Player" : resolved).prefix(24))
    }

    private static func compact(_ value: String) -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
        let scalars = Array(normalized.unicodeScalars)
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
        var index = scalars.startIndex
        while index < scalars.endIndex {
            switch scalars[index].value {
            case 0x200C:
                if hasCursiveZWNJContext(at: index, in: scalars)
                    || hasViramaContext(before: index, in: scalars, requiresFollowingLetter: true) {
                    permitted.insert(index)
                }
            case 0x200D:
                if hasEmojiZWJContext(at: index, in: scalars)
                    || hasViramaContext(before: index, in: scalars, requiresFollowingLetter: false) {
                    permitted.insert(index)
                }
            case 0xFE00...0xFE0F:
                if index > scalars.startIndex,
                   !scalars[index - 1].properties.isDefaultIgnorableCodePoint {
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
        let leftJoining = #"^[\p{Joining_Type=Left_Joining}\p{Joining_Type=Dual_Joining}]$"#
        let rightJoining = #"^[\p{Joining_Type=Right_Joining}\p{Joining_Type=Dual_Joining}]$"#
        return matches(previous, pattern: leftJoining) && matches(next, pattern: rightJoining)
    }

    private static func nonTransparentScalar(
        before index: Int,
        in scalars: [Unicode.Scalar]
    ) -> Unicode.Scalar? {
        var cursor = index - 1
        while cursor >= scalars.startIndex {
            let scalar = scalars[cursor]
            if !matches(scalar, pattern: #"^\p{Joining_Type=Transparent}$"#) { return scalar }
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
            if !matches(scalar, pattern: #"^\p{Joining_Type=Transparent}$"#) { return scalar }
            cursor += 1
        }
        return nil
    }

    private static func hasEmojiZWJContext(
        at index: Int,
        in scalars: [Unicode.Scalar]
    ) -> Bool {
        var left = index - 1
        while left >= scalars.startIndex, (0xFE00...0xFE0F).contains(scalars[left].value) {
            left -= 1
        }
        var right = index + 1
        while right < scalars.endIndex, (0xFE00...0xFE0F).contains(scalars[right].value) {
            right += 1
        }
        guard left >= scalars.startIndex, right < scalars.endIndex,
              isEmojiPresentationComponent(at: left, in: scalars),
              isEmojiPresentationComponent(at: right, in: scalars) else { return false }
        let sequence = String(String.UnicodeScalarView(scalars[left...right]))
        return sequence.count == 1
    }

    private static func isEmojiPresentationComponent(
        at index: Int,
        in scalars: [Unicode.Scalar]
    ) -> Bool {
        scalars[index].properties.isEmojiPresentation
            || (index + 1 < scalars.endIndex && scalars[index + 1].value == 0xFE0F)
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
                || !matches(
                    scalars[following],
                    pattern: #"^\p{Indic_Syllabic_Category=Vowel_Dependent}$"#
                )
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
              scalars[cursor].value == 0xE007F else { return nil }
        return cursor
    }

    private static func matches(_ scalar: Unicode.Scalar, pattern: String) -> Bool {
        String(scalar).range(of: pattern, options: .regularExpression) != nil
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
