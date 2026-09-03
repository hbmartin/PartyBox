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
        let space = Unicode.Scalar(" ")
        let safeScalars = value.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            if scalar.properties.isDefaultIgnorableCodePoint,
               scalar.value != 0x200D,
               !(0xFE00...0xFE0F).contains(scalar.value) {
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
}
