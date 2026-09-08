import Foundation
import PartyNet

public struct GameModifierDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String

    public init(id: String, title: String, detail: String) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

public struct GameDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let minimumPlayers: Int
    public let maximumPlayers: Int
    public let modifiers: [GameModifierDescriptor]

    public init(
        id: String,
        title: String,
        summary: String,
        minimumPlayers: Int,
        maximumPlayers: Int,
        modifiers: [GameModifierDescriptor] = []
    ) {
        precondition((1...PartyNetConstants.maximumControllers).contains(minimumPlayers))
        precondition((minimumPlayers...PartyNetConstants.maximumControllers).contains(maximumPlayers))
        self.id = id
        self.title = title
        self.summary = summary
        self.minimumPlayers = minimumPlayers
        self.maximumPlayers = maximumPlayers
        self.modifiers = modifiers
    }
}

public enum PlayerRole: Equatable, Sendable {
    case active
    case waiting(position: Int)
    case eliminated
}

public struct SpectatorState: Equatable, Sendable {
    public let role: PlayerRole
    public let choices: [GameModifierDescriptor]
    public let tallies: [String: Int]
    public let selection: String?

    public init(role: PlayerRole, choices: [GameModifierDescriptor], tallies: [String: Int], selection: String?) {
        self.role = role
        self.choices = choices
        self.tallies = tallies
        self.selection = selection
    }
}

public enum SpectatorScreenFactory {
    public static let reactions = ["🔥", "👏", "😤", "😱", "💀", "🧂"]

    public static func make(game: GameDescriptor, state: SpectatorState) -> ControllerScreen {
        let status: String = switch state.role {
        case .active: "SPECTATING"
        case .eliminated: "OUT THIS ROUND"
        case .waiting(let position): "#\(position) IN QUEUE"
        }
        var components: [ScreenComponent] = [
            .text(.init(id: "spectator.title", text: "SPECTATING", style: .title)),
            .text(.init(id: "controller.spectator.position", text: status, style: .headline, tint: .success)),
            .emojiPalette(.init(id: "spectator.reactions", emojis: reactions)),
        ]
        if !state.choices.isEmpty {
            components.append(.choiceGroup(.init(
                id: "spectator.vote",
                title: "NEXT ROUND",
                choices: state.choices.map {
                    ChoiceItem(id: $0.id, title: $0.title, detail: $0.detail, tally: state.tallies[$0.id, default: 0])
                },
                selection: state.selection,
                route: .spectatorVote
            )))
        }
        return ControllerScreen(
            accessibilityID: "controller.layout.spectator",
            accentColorHex: ArcadePalette.cyan,
            components: components
        )
    }
}

public struct TurnOrder: Equatable, Sendable {
    public private(set) var players: [PlayerID]

    public init(joinOrder: [PlayerID] = []) {
        players = joinOrder.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    public mutating func joined(_ playerID: PlayerID) {
        if !players.contains(playerID) { players.append(playerID) }
    }

    public mutating func left(_ playerID: PlayerID) {
        players.removeAll { $0 == playerID }
    }

    public func participants(connected: Set<PlayerID>, maximum: Int) -> [PlayerID] {
        Array(players.filter { connected.contains($0) }.prefix(maximum))
    }

    public mutating func rotateAfterMatch(active: [PlayerID], winner: PlayerID?) {
        let knownPlayers = Set(players)
        let active = active.filter { knownPlayers.contains($0) }
        let activeSet = Set(active)
        let waiting = players.filter { !activeSet.contains($0) }
        if let winner, activeSet.contains(winner) {
            players = [winner] + waiting + active.filter { $0 != winner }
        } else {
            players = waiting + active
        }
    }

    public func waitingPosition(of playerID: PlayerID, active: [PlayerID]) -> Int? {
        let activeSet = Set(active)
        return players.filter { !activeSet.contains($0) }.firstIndex(of: playerID).map { $0 + 1 }
    }
}
