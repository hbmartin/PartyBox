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

public enum PartyBoxRuntimeLimits {
    public static let releasePartySize = PartyNetConstants.maximumControllers
    public static let maximumLobbyBots = PartyNetConstants.maximumControllers - 1
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

public struct DeviceCue: Codable, Equatable, Sendable {
    public let id: UUID
    public let colorHex: String
    public let durationMilliseconds: Int
    public let haptic: HapticPattern?

    public init(
        id: UUID = UUID(),
        colorHex: String,
        durationMilliseconds: Int = 220,
        haptic: HapticPattern? = nil
    ) {
        self.id = id
        self.colorHex = colorHex
        self.durationMilliseconds = min(max(durationMilliseconds, 80), 250)
        self.haptic = haptic
    }

    private enum CodingKeys: String, CodingKey {
        case id, colorHex, durationMilliseconds, haptic
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            colorHex: try values.decode(String.self, forKey: .colorHex),
            durationMilliseconds: try values.decode(Int.self, forKey: .durationMilliseconds),
            haptic: try values.decodeIfPresent(HapticPattern.self, forKey: .haptic)
        )
    }
}

public struct GameLayoutEnvelope: Codable, Equatable, Sendable {
    public let gameID: String
    public let schemaVersion: UInt16
    public let payload: Data

    public init(
        gameID: String,
        schemaVersion: UInt16 = ControllerScreen.schemaVersion,
        payload: Data
    ) {
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

    public init(
        gameID: String,
        schemaVersion: UInt16 = ControllerScreen.schemaVersion,
        action: ControllerAction
    ) {
        self.gameID = gameID
        self.schemaVersion = schemaVersion
        self.action = action
    }
}

public enum MenuKind: String, Codable, Equatable, Sendable {
    case gameSelection
    case cupSetup
}

public struct MenuLayout: Codable, Equatable, Sendable {
    public let kind: MenuKind
    public let items: [String]
    public let details: [String]
    public let selected: Int
    public let control: PartyControlStatus

    public init(
        kind: MenuKind = .gameSelection,
        items: [String],
        details: [String],
        selected: Int,
        control: PartyControlStatus = .uncontrolled
    ) {
        self.kind = kind
        self.items = items
        self.details = details
        self.selected = selected
        self.control = control
    }

    private enum CodingKeys: String, CodingKey {
        case kind, items, details, selected, control
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try values.decodeIfPresent(MenuKind.self, forKey: .kind) ?? .gameSelection,
            items: try values.decode([String].self, forKey: .items),
            details: try values.decode([String].self, forKey: .details),
            selected: try values.decode(Int.self, forKey: .selected),
            control: try values.decodeIfPresent(PartyControlStatus.self, forKey: .control) ?? .uncontrolled
        )
    }
}

public struct PartyControlStatus: Codable, Equatable, Sendable {
    public let captainID: PlayerID?
    public let isCaptain: Bool
    public let isReady: Bool
    public let readyCount: Int
    public let requiredReadyCount: Int
    public let canToggleReady: Bool

    public init(
        captainID: PlayerID?,
        isCaptain: Bool,
        isReady: Bool,
        readyCount: Int,
        requiredReadyCount: Int,
        canToggleReady: Bool = false
    ) {
        self.captainID = captainID
        self.isCaptain = isCaptain
        self.isReady = isReady
        self.readyCount = max(0, readyCount)
        self.requiredReadyCount = max(0, requiredReadyCount)
        self.canToggleReady = canToggleReady
    }

    private enum CodingKeys: String, CodingKey {
        case captainID, isCaptain, isReady, readyCount, requiredReadyCount, canToggleReady
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            captainID: try values.decodeIfPresent(PlayerID.self, forKey: .captainID),
            isCaptain: try values.decode(Bool.self, forKey: .isCaptain),
            isReady: try values.decode(Bool.self, forKey: .isReady),
            readyCount: try values.decode(Int.self, forKey: .readyCount),
            requiredReadyCount: try values.decode(Int.self, forKey: .requiredReadyCount),
            canToggleReady: try values.decodeIfPresent(Bool.self, forKey: .canToggleReady) ?? false
        )
    }

    public static let uncontrolled = PartyControlStatus(
        captainID: nil,
        isCaptain: true,
        isReady: false,
        readyCount: 0,
        requiredReadyCount: 0,
        canToggleReady: false
    )
}

public struct LobbyLayout: Codable, Equatable, Sendable {
    public let captainID: PlayerID?
    public let isCaptain: Bool
    public let botFillTarget: Int
    public let activeBotCount: Int
    public let maximumBotCount: Int
    public let botDifficulty: String

    public init(
        captainID: PlayerID?,
        isCaptain: Bool,
        botFillTarget: Int,
        activeBotCount: Int,
        maximumBotCount: Int,
        botDifficulty: String
    ) {
        self.captainID = captainID
        self.isCaptain = isCaptain
        self.botFillTarget = max(0, botFillTarget)
        self.activeBotCount = max(0, activeBotCount)
        self.maximumBotCount = max(0, maximumBotCount)
        self.botDifficulty = botDifficulty
    }

    public static let waiting = LobbyLayout(
        captainID: nil,
        isCaptain: false,
        botFillTarget: 0,
        activeBotCount: 0,
        maximumBotCount: PartyBoxRuntimeLimits.maximumLobbyBots,
        botDifficulty: "NORMAL"
    )
}

public struct GameOverLayout: Codable, Equatable, Sendable {
    public let title: String
    public let subtitle: String
    public let nextUp: String?
    public let control: PartyControlStatus
    public let botDifficultyChange: String?

    public init(
        title: String,
        subtitle: String,
        nextUp: String? = nil,
        control: PartyControlStatus = .uncontrolled,
        botDifficultyChange: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.nextUp = nextUp
        self.control = control
        self.botDifficultyChange = botDifficultyChange
    }
}

public enum ControllerLayout: Codable, Equatable, Sendable {
    case lobby(LobbyLayout)
    case menu(MenuLayout)
    case game(GameLayoutEnvelope)
    case gameOver(GameOverLayout)
    case historyNavigation

    public var isGame: Bool {
        if case .game = self { return true }
        return false
    }
}

public enum LobbyAction: Codable, Equatable, Sendable {
    case selectMark(PlayerMark)
    case setBotFillTarget(Int)
}

public enum SpectatorAction: Codable, Equatable, Sendable {
    case reaction(String)
    case vote(String)
}

public enum ControllerCommand: Codable, Equatable, Sendable {
    case lobby(LobbyAction)
    case menu(MenuAction)
    case game(GameActionEnvelope)
    case spectator(SpectatorAction)
}

public enum HostPresentation: Codable, Equatable, Sendable {
    case roster([PlayerInfo])
    case layout(ControllerLayout)
    case haptic(HapticPattern)
    case deviceCue(DeviceCue)
    case matchCompleted(PersonalMatchRecord)
    case cupCompleted(PersonalCupRecord)
}
