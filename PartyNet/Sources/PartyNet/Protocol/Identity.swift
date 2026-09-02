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

public enum PlayerPalette {
    public static let colors = [
        "#32E6FF", "#FF4FD8", "#FFE44D", "#6DFF78",
        "#FF7A3D", "#9F7BFF", "#F5F7FF", "#55A7FF",
    ]

    public static func color(for id: PlayerID) -> String {
        colors[Int(id.rawValue) % colors.count]
    }
}

public enum DisplayName {
    public static func sanitized(_ candidate: String, fallback: String) -> String {
        let compact = candidate
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return String((compact.isEmpty ? fallback : compact).prefix(24))
    }
}
