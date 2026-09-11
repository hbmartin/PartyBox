import PartyBoxCore
import PartyNet
import SpriteKit

public struct GameParticipant: Equatable, Sendable {
    public let player: PlayerInfo
    public let controllerID: ControllerID

    public init(player: PlayerInfo, controllerID: ControllerID) {
        self.player = player
        self.controllerID = controllerID
    }
}

public struct GameSessionContext: Sendable {
    public let participants: [GameParticipant]
    public let inputs: InputStore
    public let seed: UInt64
    public let modifierID: String?
    public let isCupEvent: Bool

    public init(
        participants: [GameParticipant],
        inputs: InputStore,
        seed: UInt64,
        modifierID: String?,
        isCupEvent: Bool = false
    ) {
        self.participants = participants
        self.inputs = inputs
        self.seed = seed
        self.modifierID = modifierID
        self.isCupEvent = isCupEvent
    }
}

public struct GameStanding: Equatable, Sendable {
    public let playerID: PlayerID
    public let rank: Int
    public let score: Int
    public let detail: String

    public init(playerID: PlayerID, rank: Int, score: Int, detail: String = "") {
        self.playerID = playerID
        self.rank = max(1, rank)
        self.score = score
        self.detail = detail
    }
}

public struct PlayerMatchOutcome: Equatable, Sendable {
    public let playerID: PlayerID
    public let outcome: MatchParticipantOutcome

    public init(playerID: PlayerID, outcome: MatchParticipantOutcome) {
        self.playerID = playerID
        self.outcome = outcome
    }
}

public struct GameOutcome: Equatable, Sendable {
    public let title: String
    public let subtitle: String
    public let winner: PlayerID?
    public let playerOutcomes: [PlayerMatchOutcome]
    public let metrics: [MatchMetric]
    public let standings: [GameStanding]

    public init(
        title: String,
        subtitle: String,
        winner: PlayerID?,
        playerOutcomes: [PlayerMatchOutcome],
        metrics: [MatchMetric],
        standings: [GameStanding] = []
    ) {
        self.title = title
        self.subtitle = subtitle
        self.winner = winner
        self.playerOutcomes = playerOutcomes
        self.metrics = metrics
        self.standings = standings
    }
}

public enum GameEvent: Equatable, Sendable {
    case audio(HapticPattern)
    case haptic(PlayerID, HapticPattern)
    case deviceCue(PlayerID, DeviceCue)
    case eliminated(PlayerID)
    case completed(GameOutcome)
}

public enum GameBotDifficulty: Int, Codable, CaseIterable, Equatable, Sendable {
    case easy
    case normal
    case hard

    public var title: String { String(describing: self).uppercased() }

    public var harder: Self {
        Self(rawValue: min(Self.hard.rawValue, rawValue + 1)) ?? .hard
    }

    public var easier: Self {
        Self(rawValue: max(Self.easy.rawValue, rawValue - 1)) ?? .easy
    }
}

public struct GameBotInput: Equatable, Sendable {
    public let axisX: Float
    public let axisY: Float
    public let buttons: Buttons

    public init(axisX: Float, axisY: Float = 0, buttons: Buttons = []) {
        self.axisX = axisX.isFinite ? min(max(axisX, -1), 1) : 0
        self.axisY = axisY.isFinite ? min(max(axisY, -1), 1) : 0
        self.buttons = buttons
    }
}

@MainActor
public protocol PartyGameSession: AnyObject {
    var scene: SKScene { get }
    func controllerScreen(for playerID: PlayerID) -> ControllerScreen
    func handle(action: ControllerAction, from playerID: PlayerID)
    func forfeit(_ playerID: PlayerID)
    func botInput(
        for playerID: PlayerID,
        difficulty: GameBotDifficulty,
        deltaTime: Duration
    ) -> GameBotInput?
}

public extension PartyGameSession {
    func botInput(
        for playerID: PlayerID,
        difficulty: GameBotDifficulty,
        deltaTime: Duration
    ) -> GameBotInput? { nil }
}

@MainActor
public protocol PartyGame {
    var descriptor: GameDescriptor { get }
    func makeSession(
        context: GameSessionContext,
        onEvents: @escaping @MainActor ([GameEvent]) -> Void
    ) -> any PartyGameSession
}
