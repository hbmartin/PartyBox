import Foundation
import PartyBoxCore
import PartyGameRuntime
import PartyNet
@testable import PartyGames

/// Shared fixtures for arcade game tests.
@MainActor
enum ArcadeHarness {
    static func participants(_ count: Int, kind: PlayerKind = .bot) -> [GameParticipant] {
        (0..<count).map { index in
            let playerID = PlayerID(UInt8(index))
            return GameParticipant(
                player: PlayerInfo(
                    id: playerID,
                    displayName: "Player \(index + 1)",
                    colorHex: PlayerPalette.color(for: playerID),
                    kind: kind
                ),
                controllerID: ControllerID()
            )
        }
    }

    static func playerIDs(_ count: Int) -> [PlayerID] {
        (0..<count).map { PlayerID(UInt8($0)) }
    }

    static func finishedDuel(_ simulation: some ArcadeSimulation) -> GameOutcome? {
        guard simulation.isFinished else { return nil }
        let events = ArcadeOutcomeBuilder.completionEvents(
            title: "Arcade", participants: participants(2),
            ranking: simulation.ranking(), metric: simulation.resultMetric, forfeited: []
        )
        return PlayOut(events: events).outcome
    }

    struct PlayOut {
        var events: [GameEvent] = []
        var seconds = 0.0

        var outcome: GameOutcome? {
            events.lazy.compactMap { event -> GameOutcome? in
                if case .completed(let outcome) = event { outcome } else { nil }
            }.first
        }

        var eliminated: [PlayerID] {
            events.compactMap { event in
                if case .eliminated(let playerID) = event { playerID } else { nil }
            }
        }
    }

    /// Plays a whole match the way the host does: every seat is a bot whose
    /// `botInput` is written into the shared `InputStore`, and the scene's
    /// `update` drives the session at 60 fps.
    static func playOut(
        _ game: any PartyGame,
        players: Int,
        seed: UInt64 = 42,
        difficulty: GameBotDifficulty = .normal,
        maximumSeconds: Double = 180,
        idle: Set<PlayerID> = []
    ) -> PlayOut {
        let inputs = InputStore()
        let context = GameSessionContext(
            participants: participants(players),
            inputs: inputs,
            seed: seed,
            modifierID: nil
        )
        var result = PlayOut()
        let session = game.makeSession(context: context, onEvents: { result.events.append(contentsOf: $0) })
        var sequence: UInt32 = 0
        let frame = 1.0 / 60.0
        var time = 0.0
        while result.outcome == nil, time < maximumSeconds {
            sequence &+= 1
            for participant in context.participants {
                let playerID = participant.player.id
                let bot = idle.contains(playerID)
                    ? GameBotInput(axisX: 0)
                    : session.botInput(for: playerID, difficulty: difficulty, deltaTime: .milliseconds(16))
                guard let bot else { continue }
                inputs.update(
                    InputFrame(
                        token: 1,
                        sequence: sequence,
                        clientTimeMs: 0,
                        axisX: bot.axisX,
                        axisY: bot.axisY,
                        buttons: bot.buttons
                    ),
                    for: playerID
                )
            }
            time += frame
            session.scene.update(time)
        }
        result.seconds = time
        return result
    }
}
