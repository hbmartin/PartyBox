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
    private struct BotState {
        var position: Double
        var target: Double
        var reactionRemaining: Double
        let errorUnit: Double
    }

    private struct BotParameters {
        let reactionInterval: Double
        let maximumSpeed: Double
        let aimError: Double

        static func forDifficulty(_ difficulty: GameBotDifficulty) -> Self {
            switch difficulty {
            case .easy: .init(reactionInterval: 0.300, maximumSpeed: 1.0, aimError: 0.22)
            case .normal: .init(reactionInterval: 0.160, maximumSpeed: 1.8, aimError: 0.10)
            case .hard: .init(reactionInterval: 0.080, maximumSpeed: 3.0, aimError: 0.03)
            }
        }
    }

    private let context: GameSessionContext
    private let onEvents: @MainActor ([GameEvent]) -> Void
    private var forfeited: Set<PlayerID> = []
    private var botStates: [PlayerID: BotState] = [:]
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
        for participant in context.participants where participant.player.kind == .bot {
            let mixed = context.seed
                &+ (UInt64(participant.player.id.rawValue) &* 0x9E37_79B9_7F4A_7C15)
            let fraction = Double((mixed ^ (mixed >> 29)) & 0xFFFF) / Double(0xFFFF)
            botStates[participant.player.id] = BotState(
                position: 0,
                target: 0,
                reactionRemaining: 0,
                errorUnit: (fraction * 2) - 1
            )
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
                    text: "\(participant.player.mark.glyph)  P\(participant.player.number) \(participant.player.displayName)",
                    style: .headline,
                    tint: .accent
                )),
                .text(.init(id: "pong.direction", text: direction, style: .caption, tint: .secondary)),
                .axisSurface(.init(id: "pong.paddle", binding: .horizontal, instruction: "DRAG ANYWHERE ON THE TRACK")),
            ]
        )
    }

    func handle(action: ControllerAction, from playerID: PlayerID) {}

    func botInput(
        for playerID: PlayerID,
        difficulty: GameBotDifficulty,
        deltaTime: Duration
    ) -> GameBotInput? {
        guard var state = botStates[playerID] else { return nil }
        let components = deltaTime.components
        let seconds = max(
            0,
            Double(components.seconds) + (Double(components.attoseconds) / 1_000_000_000_000_000_000)
        )
        let parameters = BotParameters.forDifficulty(difficulty)
        state.reactionRemaining -= seconds
        if state.reactionRemaining <= 0 {
            let projected = pongScene.botTarget(for: playerID) ?? 0
            state.target = min(max(projected + (state.errorUnit * parameters.aimError), -1), 1)
            state.reactionRemaining = parameters.reactionInterval
        }
        let current = pongScene.paddlePosition(for: playerID) ?? state.position
        let maximumDelta = parameters.maximumSpeed * seconds
        state.position = current + min(max(state.target - current, -maximumDelta), maximumDelta)
        state.position = min(max(state.position, -1), 1)
        botStates[playerID] = state
        return GameBotInput(axisX: Float(state.position))
    }

    func forfeit(_ playerID: PlayerID) {
        pongScene.forfeit(playerID) { forfeited.insert(playerID) }
    }

    private func handle(_ events: [PongEvent]) {
        let translated = translate(events)
        if !translated.isEmpty { onEvents(translated) }
    }

    private func translate(_ events: [PongEvent]) -> [GameEvent] {
        var translated: [GameEvent] = []
        for event in events {
            switch event {
            case .paddleHit(let playerID):
                translated.append(.audio(.lightImpact))
                translated.append(.haptic(playerID, .lightImpact))
            case let .lostLife(playerID, remaining):
                translated.append(.audio(.heavyImpact))
                if remaining > 0 { translated.append(.haptic(playerID, .heavyImpact)) }
            case .eliminated(let playerID):
                translated.append(.audio(.error))
                translated.append(.haptic(playerID, .error))
                translated.append(.eliminated(playerID))
            case .forfeited(let playerID):
                translated.append(.audio(.error))
                translated.append(.eliminated(playerID))
            case let .gameOver(winner, rally):
                translated.append(.audio(.success))
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
        return translated
    }

#if DEBUG
    func translateForTesting(_ events: [PongEvent]) -> [GameEvent] { translate(events) }
#endif
}
