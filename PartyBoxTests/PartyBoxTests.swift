import PartyNet
import Testing
@testable import PartyBox

@Suite("Deterministic four-way Pong")
struct PartyBoxTests {
    private let bottom = PlayerID(0)
    private let top = PlayerID(1)

    @Test func emptyEdgeActsAsWall() {
        var game = PongSimulation(assignments: [.init(playerID: bottom, edge: .bottom)])
        game.setBallForTesting(position: PongPoint(x: 480, y: 0), velocity: PongPoint(x: 100, y: 0))

        let events = game.step(deltaTime: 0.05)

        #expect(events.isEmpty)
        #expect(game.ballVelocity.x < 0)
    }

    @Test func centeredPaddleReflectsAndAcceleratesBall() {
        var game = PongSimulation(assignments: [.init(playerID: bottom, edge: .bottom)])
        game.setPaddle(for: bottom, normalizedPosition: 0)
        game.setBallForTesting(position: PongPoint(x: 0, y: -480), velocity: PongPoint(x: 0, y: -500))

        let events = game.step(deltaTime: 0.05)

        #expect(events == [.paddleHit(bottom)])
        #expect(game.ballVelocity.y > 0)
        #expect(game.ballVelocity.length > 500)
        #expect(game.rallyCount == 1)
    }

    @Test func soloEndsAfterThreeMissesAndReportsRally() {
        var game = PongSimulation(assignments: [.init(playerID: bottom, edge: .bottom)])
        game.setPaddle(for: bottom, normalizedPosition: -1)

        for expectedLives in stride(from: 2, through: 0, by: -1) {
            game.setBallForTesting(position: PongPoint(x: 300, y: -480), velocity: PongPoint(x: 0, y: -100))
            let events = game.step(deltaTime: 0.05)
            #expect(events.contains(.lostLife(bottom, remaining: expectedLives)))
        }

        #expect(game.isFinished)
        #expect(game.activePlayers.isEmpty)
    }

    @Test func multiplayerEndsWithLastSurvivor() {
        var game = PongSimulation(assignments: [
            .init(playerID: bottom, edge: .bottom),
            .init(playerID: top, edge: .top),
        ])
        game.setPaddle(for: top, normalizedPosition: -1)
        var finalEvents: [PongEvent] = []
        for _ in 0..<3 {
            game.setBallForTesting(position: PongPoint(x: 300, y: 480), velocity: PongPoint(x: 0, y: 100))
            finalEvents = game.step(deltaTime: 0.05)
        }

        #expect(finalEvents.contains(.eliminated(top)))
        #expect(finalEvents.contains(.gameOver(winner: bottom, rally: 0)))
        #expect(game.isFinished)
    }

    @Test func disconnectForfeitTurnsSeatIntoWallAndCanFinishMatch() {
        var game = PongSimulation(assignments: [
            .init(playerID: bottom, edge: .bottom),
            .init(playerID: top, edge: .top),
        ])

        let events = game.forfeit(top)

        #expect(events == [.forfeited(top), .gameOver(winner: bottom, rally: 0)])
        #expect(game.players[.top]?.isActive == false)
    }
}
