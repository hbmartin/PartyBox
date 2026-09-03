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

    @Test @MainActor func activeDepartureKeepsSurvivorEdgesAndNewMatchStartsNeutral() async throws {
        let coordinator = HostCoordinator()
        await coordinator.start()
        let port = try #require(coordinator.host.port)
        let clients = [
            PartyClient(displayName: "Bottom"),
            PartyClient(displayName: "Top"),
            PartyClient(displayName: "Left"),
        ]
        for client in clients {
            await client.connect(host: "127.0.0.1", port: port)
        }
        try await waitUntil { coordinator.seatQueue.active.count == 3 }

        clients[0].setInput(axisX: 0.75)
        try await waitUntil { coordinator.host.inputs.snapshot()[PlayerID(0)]?.axisX == 0.75 }
        coordinator.perform(.select)
        coordinator.perform(.select)

        #expect(coordinator.host.inputs.snapshot()[PlayerID(0)]?.axisX == 0)
        try await waitUntil {
            self.paddleEdge(of: clients[1]) == .top && self.paddleEdge(of: clients[2]) == .left
        }
        await clients[0].disconnect()
        try await waitUntil { coordinator.seatQueue.active.count == 2 }

        #expect(paddleEdge(of: clients[1]) == .top)
        #expect(paddleEdge(of: clients[2]) == .left)
        for client in clients.dropFirst() { await client.disconnect() }
        await coordinator.stop()
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }

    @MainActor
    private func paddleEdge(of client: PartyClient) -> PaddleEdge? {
        guard case let .paddle(layout) = client.layout else { return nil }
        return layout.edge
    }
}
