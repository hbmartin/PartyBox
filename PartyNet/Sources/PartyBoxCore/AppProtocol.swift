import Foundation
import PartyNet

public enum PartyBoxWireCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(value)
        guard data.count <= PartyNetConstants.maximumApplicationPayloadBytes else {
            throw PartyBoxWireError.payloadTooLarge
        }
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= PartyNetConstants.maximumApplicationPayloadBytes else {
            throw PartyBoxWireError.payloadTooLarge
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}

public enum PartyBoxWireError: Error, Sendable {
    case payloadTooLarge
}

public enum MenuAction: String, Codable, CaseIterable, Sendable {
    case up, down, left, right, select, back
}

public enum HapticPattern: String, Codable, Equatable, Sendable {
    case lightImpact
    case heavyImpact
    case error
    case success
}

public struct GameLayoutEnvelope: Codable, Equatable, Sendable {
    public let gameID: String
    public let schemaVersion: UInt16
    public let payload: Data

    public init(gameID: String, schemaVersion: UInt16 = 1, payload: Data) {
        self.gameID = gameID
        self.schemaVersion = schemaVersion
        self.payload = payload
    }

    public var validatedControllerScreen: ControllerScreen? {
        guard schemaVersion == ControllerScreen.schemaVersion,
              let screen = try? PartyBoxWireCodec.decode(ControllerScreen.self, from: payload),
              screen.isValid else { return nil }
        return screen
    }
}

public struct GameActionEnvelope: Codable, Equatable, Sendable {
    public let gameID: String
    public let schemaVersion: UInt16
    public let action: ControllerAction

    public init(gameID: String, schemaVersion: UInt16 = 1, action: ControllerAction) {
        self.gameID = gameID
        self.schemaVersion = schemaVersion
        self.action = action
    }
}

public struct MenuLayout: Codable, Equatable, Sendable {
    public let items: [String]
    public let details: [String]
    public let selected: Int

    public init(items: [String], details: [String], selected: Int) {
        self.items = items
        self.details = details
        self.selected = selected
    }
}

public struct GameOverLayout: Codable, Equatable, Sendable {
    public let title: String
    public let subtitle: String
    public let nextModifier: String?

    public init(title: String, subtitle: String, nextModifier: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.nextModifier = nextModifier
    }
}

public enum ControllerLayout: Codable, Equatable, Sendable {
    case lobby
    case menu(MenuLayout)
    case game(GameLayoutEnvelope)
    case gameOver(GameOverLayout)
    case historyNavigation

    public var isGame: Bool {
        if case .game = self { return true }
        return false
    }
}

public enum SpectatorAction: Codable, Equatable, Sendable {
    case reaction(String)
    case vote(String)
}

public enum ControllerCommand: Codable, Equatable, Sendable {
    case menu(MenuAction)
    case game(GameActionEnvelope)
    case spectator(SpectatorAction)
}

public enum HostPresentation: Codable, Equatable, Sendable {
    case roster([PlayerInfo])
    case layout(ControllerLayout)
    case haptic(HapticPattern)
    case matchCompleted(PersonalMatchRecord)
}
