import Foundation
import PartyBoxCore
import PartyGameRuntime
import PartyNet
import Testing
@testable import PartyGames

@Suite("Pong bench rotation")
@MainActor
struct PongBenchTests {
    private func seats(_ count: Int) -> [SeatAssignment] {
        zip(ArcadeHarness.playerIDs(count), PaddleEdge.allCases).map { SeatAssignment(playerID: $0.0, edge: $0.1) }
    }

    private func forceMiss(edge: PaddleEdge, in game: inout PongSimulation) -> [PongEvent] {
        guard let player = game.players[edge] else { return [] }
        game.setPaddle(for: player.playerID, normalizedPosition: -1)
        switch edge {
        case .bottom: game.setBallForTesting(position: PongPoint(x: 300, y: -480), velocity: PongPoint(x: 0, y: -100))
        case .top: game.setBallForTesting(position: PongPoint(x: 300, y: 480), velocity: PongPoint(x: 0, y: 100))
        case .left: game.setBallForTesting(position: PongPoint(x: -480, y: 300), velocity: PongPoint(x: -100, y: 0))
        case .right: game.setBallForTesting(position: PongPoint(x: 480, y: 300), velocity: PongPoint(x: 100, y: 0))
        }
        return game.step(deltaTime: 0.05)
    }

    @Test func bigPartiesStartOnTwoLivesAndModifiersStillAddOne() {
        #expect(PongRules.standard(participantCount: 4).initialLives == 3)
        #expect(PongRules.standard(participantCount: 5).initialLives == 2)
        #expect(PongGame.rules(for: "extra-life", participantCount: 8).initialLives == 3)
        #expect(PongGame().availableModifiers(participantCount: 8) == PongGame().descriptor.modifiers)
    }

    @Test func knockedOutEdgeGoesToTheNextBenchedPlayer() throws {
        let ids = ArcadeHarness.playerIDs(6)
        var game = PongSimulation(
            assignments: seats(4),
            bench: Array(ids[4...]),
            rules: .standard(participantCount: 6)
        )
        #expect(game.bench == [ids[4], ids[5]])

        _ = forceMiss(edge: .bottom, in: &game)
        let events = forceMiss(edge: .bottom, in: &game)

        #expect(events == [
            .lostLife(ids[0], remaining: 0),
            .eliminated(ids[0]),
            .rotatedIn(ids[4], edge: .bottom),
        ])
        #expect(game.edge(for: ids[4]) == .bottom)
        #expect(game.edge(for: ids[0]) == nil)
        #expect(game.players[.bottom]?.lives == 2)
        #expect(game.bench == [ids[5]])
        #expect(!game.isFinished)
        #expect(game.countdown == 1)
    }

    @Test func matchEndsOnlyOnceTheBenchIsEmpty() {
        let ids = ArcadeHarness.playerIDs(5)
        var game = PongSimulation(assignments: seats(4), bench: [ids[4]], rules: .standard(participantCount: 5))
        var events: [PongEvent] = []
        for edge in [PaddleEdge.top, .left, .right] {
            events += forceMiss(edge: edge, in: &game)
            events += forceMiss(edge: edge, in: &game)
        }
        #expect(events.contains(.rotatedIn(ids[4], edge: .top)))
        #expect(!game.isFinished)

        events += forceMiss(edge: .top, in: &game)
        events += forceMiss(edge: .top, in: &game)

        #expect(game.isFinished)
        #expect(events.last == .gameOver(winner: ids[0], rally: 0))
    }

    @Test func benchedForfeitLeavesTheQueueWithoutTouchingTheCourt() {
        let ids = ArcadeHarness.playerIDs(6)
        var game = PongSimulation(assignments: seats(4), bench: [ids[4], ids[5]], rules: .standard(participantCount: 6))

        #expect(game.forfeit(ids[4]) == [.forfeited(ids[4])])
        #expect(game.bench == [ids[5]])
        #expect(game.forfeit(ids[1]) == [.forfeited(ids[1]), .rotatedIn(ids[5], edge: .top)])
        #expect(game.bench.isEmpty)
        #expect(game.activePlayers.count == 4)
    }

    @Test func seatedForfeitStartsAFreshServeForTheBenchReplacement() {
        let ids = ArcadeHarness.playerIDs(6)
        var game = PongSimulation(assignments: seats(4), bench: [ids[4], ids[5]], rules: .standard(participantCount: 6))
        game.setBallForTesting(position: .init(x: 300, y: -480), velocity: .init(x: 0, y: -100))

        let benchedForfeit = game.forfeit(ids[5])
        #expect(benchedForfeit == [.forfeited(ids[5])])
        #expect(game.countdown == nil)
        let seatedForfeit = game.forfeit(ids[0])
        #expect(seatedForfeit == [.forfeited(ids[0]), .rotatedIn(ids[4], edge: .bottom)])
        #expect(game.countdown == 1)
        let followingFrame = game.step(deltaTime: 0.05)
        #expect(followingFrame.isEmpty)
        #expect(game.players[.bottom]?.lives == 2)
    }

    @Test func benchedPhonesShowTheirPlaceThenTheirPaddleAfterRotating() throws {
        var events: [GameEvent] = []
        let session = try #require(PongGame().makeSession(
            context: .init(
                participants: ArcadeHarness.participants(6, kind: .human),
                inputs: InputStore(), seed: 42, modifierID: nil
            ),
            onEvents: { events.append(contentsOf: $0) }
        ) as? PongGameSession)
        let fifth = PlayerID(4)
        let sixth = PlayerID(5)

        let onDeck = session.controllerScreen(for: sixth)
        #expect(onDeck.accessibilityID == "controller.layout.pong.bench")
        #expect(onDeck.isValid)
        #expect(onDeck.components.contains(.text(.init(id: "pong.bench.position", text: "ON DECK  #2", style: .title, tint: .success))))
        #expect(session.pongScene.onDeckTextForTesting == "ON DECK  P5  P6")

        session.pongScene.forceMissForTesting(.bottom)
        session.pongScene.forceMissForTesting(.bottom)

        #expect(session.controllerScreen(for: fifth).accessibilityID == "controller.layout.paddle.bottom")
        #expect(session.controllerScreen(for: sixth).components.contains(
            .text(.init(id: "pong.bench.position", text: "ON DECK  #1", style: .title, tint: .success))
        ))
        #expect(session.pongScene.nameLabelTextForTesting(.bottom) == "P5  Player 5")
        #expect(session.pongScene.onDeckTextForTesting == "ON DECK  P6")
        #expect(events.contains(.eliminated(PlayerID(0))))
        #expect(events.contains { event in
            if case .deviceCue(let playerID, let cue) = event { playerID == fifth && cue.haptic == .success } else { false }
        })
    }

    @Test func eightPlayerMatchGivesEveryoneACourtTurnAndRanksThemAll() throws {
        var events: [GameEvent] = []
        let session = try #require(PongGame().makeSession(
            context: .init(
                participants: ArcadeHarness.participants(8, kind: .human),
                inputs: InputStore(), seed: 42, modifierID: nil
            ),
            onEvents: { events.append(contentsOf: $0) }
        ) as? PongGameSession)

        var guardCount = 0
        while !events.contains(where: { if case .completed = $0 { true } else { false } }), guardCount < 200 {
            guardCount += 1
            let edge = PaddleEdge.allCases[guardCount % 3]
            session.pongScene.forceMissForTesting(edge)
        }

        let outcome = try #require(events.lazy.compactMap { event -> GameOutcome? in
            if case .completed(let outcome) = event { outcome } else { nil }
        }.first)
        #expect(outcome.standings.count == 8)
        #expect(outcome.winner == PlayerID(3))
        #expect(Set(outcome.standings.map(\.playerID)).count == 8)
    }
}
