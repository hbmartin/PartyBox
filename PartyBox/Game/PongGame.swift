import PartyBoxCore
import PartyGameRuntime
import PartyNet
import SpriteKit

@MainActor
struct PongGame: PartyGame {
    static let fastBall = GameModifierDescriptor(
        id: "fast-ball", title: "FAST BALL", detail: "Starts 25% faster"
    )
    static let bigPaddles = GameModifierDescriptor(
        id: "big-paddles", title: "BIG PADDLES", detail: "35% longer paddles"
    )
    static let extraLife = GameModifierDescriptor(
        id: "extra-life", title: "EXTRA LIFE", detail: "Start with four lives"
    )

    let descriptor = GameDescriptor(
        id: "pong",
        title: "FOUR-WAY PONG",
        summary: "1–4 players  •  Three lives  •  Winner stays",
        minimumPlayers: 1,
        maximumPlayers: 4,
        modifiers: [fastBall, bigPaddles, extraLife]
    )

    static func rules(for modifierID: String?) -> PongRules {
        var rules = PongRules()
        switch modifierID {
        case fastBall.id: rules.startingSpeed *= 1.25
        case bigPaddles.id: rules.paddleLength *= 1.35
        case extraLife.id: rules.initialLives = 4
        default: break
        }
        return rules
    }

    func makeSession(
        context: GameSessionContext,
        onEvents: @escaping @MainActor ([GameEvent]) -> Void
    ) -> any PartyGameSession {
        PongGameSession(context: context, onEvents: onEvents)
    }
}

@MainActor
final class PongGameSession: PartyGameSession {
    private let context: GameSessionContext
    private let onEvents: @MainActor ([GameEvent]) -> Void
    private var forfeited: Set<PlayerID> = []
    private(set) var pongScene: PongScene!

    var scene: SKScene { pongScene }

    init(context: GameSessionContext, onEvents: @escaping @MainActor ([GameEvent]) -> Void) {
        self.context = context
        self.onEvents = onEvents
        let assignments = zip(context.participants, PaddleEdge.allCases).map {
            SeatAssignment(playerID: $0.0.player.id, edge: $0.1)
        }
        let rules = PongGame.rules(for: context.modifierID)
        pongScene = PongScene(
            assignments: assignments,
            players: context.participants.map(\.player),
            inputs: context.inputs,
            seed: context.seed,
            rules: rules
        ) { [weak self] events in
            self?.handle(events)
        }
    }

    func controllerScreen(for playerID: PlayerID) -> ControllerScreen {
        guard let edge = pongScene.edge(for: playerID),
              let participant = context.participants.first(where: { $0.player.id == playerID }) else {
            return ControllerScreen(
                accessibilityID: "controller.layout.unavailable",
                accentColorHex: ArcadePalette.cyan,
                components: [.text(.init(id: "unavailable", text: "WAITING", style: .title))]
            )
        }
        let direction = switch edge {
        case .bottom, .top: "LEFT  ←  PADDLE  →  RIGHT"
        case .left, .right: "BOTTOM  ←  PADDLE  →  TOP"
        }
        return ControllerScreen(
            accessibilityID: "controller.layout.paddle.\(edge.rawValue)",
            accentColorHex: participant.player.colorHex,
            components: [
                .text(.init(
                    id: "pong.player",
                    text: "P\(participant.player.number) \(participant.player.displayName)",
                    style: .headline,
                    tint: .accent
                )),
                .text(.init(id: "pong.direction", text: direction, style: .caption, tint: .secondary)),
                .axisSurface(.init(id: "pong.paddle", binding: .horizontal, instruction: "DRAG ANYWHERE ON THE TRACK")),
            ]
        )
    }

    func handle(action: ControllerAction, from playerID: PlayerID) {}

    func forfeit(_ playerID: PlayerID) {
        forfeited.insert(playerID)
        pongScene.forfeit(playerID)
    }

    private func handle(_ events: [PongEvent]) {
        var translated: [GameEvent] = []
        for event in events {
            switch event {
            case .paddleHit(let playerID):
                translated.append(.haptic(playerID, .lightImpact))
            case let .lostLife(playerID, remaining):
                if remaining > 0 { translated.append(.haptic(playerID, .heavyImpact)) }
            case .eliminated(let playerID):
                translated.append(.haptic(playerID, .error))
                translated.append(.eliminated(playerID))
            case .forfeited(let playerID):
                translated.append(.eliminated(playerID))
            case let .gameOver(winner, rally):
                if let winner { translated.append(.haptic(winner, .success)) }
                let solo = context.participants.count == 1
                let title: String
                let subtitle: String
                if solo {
                    title = "PRACTICE COMPLETE"
                    subtitle = "Rally: \(rally)  •  Select to rotate and play again"
                } else if let winner,
                          let player = context.participants.first(where: { $0.player.id == winner })?.player {
                    title = "P\(player.number) \(player.displayName) WINS"
                    subtitle = "Winner stays  •  Select for the next match"
                } else {
                    title = "MATCH OVER"
                    subtitle = "Select for the next match"
                }
                let outcomes = context.participants.map { participant in
                    let outcome: MatchParticipantOutcome = if solo {
                        .practice
                    } else if forfeited.contains(participant.player.id) {
                        .forfeited
                    } else if participant.player.id == winner {
                        .won
                    } else {
                        .lost
                    }
                    return PlayerMatchOutcome(playerID: participant.player.id, outcome: outcome)
                }
                translated.append(.completed(GameOutcome(
                    title: title,
                    subtitle: subtitle,
                    winner: winner,
                    playerOutcomes: outcomes,
                    metrics: [.init(id: "paddle-hits", label: "Paddle hits", value: "\(rally)")]
                )))
            }
        }
        if !translated.isEmpty { onEvents(translated) }
    }
}
