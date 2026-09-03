import Dependencies
import PartyNet
import Testing
@testable import PartyBox

@Suite("Deterministic four-way Pong")
@MainActor
struct PartyBoxTests {
    private let bottom = PlayerID(0)
    private let top = PlayerID(1)

    @Test func hostLaunchArgumentsAreDeterministicAndBounded() {
        let configuration = HostLaunchConfiguration(arguments: [
            "PartyBox", "--ui-testing", "--scenario", "four-way-match",
            "--disable-animations", "--disable-effects", "--seed", "42",
            "--host-name", "Automation Host", "--bot-count", "99",
        ])

        #expect(configuration.isUITesting)
        #expect(configuration.scenario == "four-way-match")
        #expect(configuration.disableAnimations)
        #expect(configuration.disableEffects)
        #expect(configuration.seed == 42)
        #expect(configuration.hostName == "Automation Host")
        #expect(configuration.botCount == PartyNetConstants.maximumControllers)
    }

    @Test func hostLaunchArgumentsDoNotForceAProductionSeed() {
        let configuration = HostLaunchConfiguration(arguments: ["PartyBox"])
        #expect(configuration.seed == nil)
    }

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

    @Test func seededLongRunMaintainsInvariantsAndScriptedMatchCompletes() {
        var game = PongSimulation(assignments: PaddleEdge.allCases.enumerated().map {
            SeatAssignment(playerID: PlayerID(UInt8($0.offset)), edge: $0.element)
        }, seed: 0xDEADBEEF)
        var randomState: UInt64 = 0xBAD5EED

        for _ in 0..<10_000 where !game.isFinished {
            for player in game.activePlayers {
                randomState = randomState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let position = (Double(randomState & 0xFFFF) / Double(0xFFFF) * 2) - 1
                game.setPaddle(for: player.playerID, normalizedPosition: position)
            }
            _ = game.step(deltaTime: 1.0 / 120.0)
            assertInvariants(game)
        }

        if !game.isFinished, let survivor = game.activePlayers.first?.playerID {
            for player in game.activePlayers where player.playerID != survivor {
                while game.players[player.edge]?.isActive == true {
                    forceMiss(edge: player.edge, in: &game)
                    assertInvariants(game)
                }
            }
        }

        #expect(game.isFinished)
        #expect(game.activePlayers.count == 1)
    }

    @Test func activeDepartureKeepsSurvivorEdgesAndNewMatchStartsNeutral() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
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
        try #require(condition())
    }

    @MainActor
    private func paddleEdge(of client: PartyClient) -> PaddleEdge? {
        guard case let .paddle(layout) = client.layout else { return nil }
        return layout.edge
    }

    private func assertInvariants(_ game: PongSimulation) {
        #expect(game.ballPosition.x.isFinite)
        #expect(game.ballPosition.y.isFinite)
        #expect(game.ballVelocity.x.isFinite)
        #expect(game.ballVelocity.y.isFinite)
        #expect(abs(game.ballPosition.x) <= PongSimulation.arenaHalfExtent)
        #expect(abs(game.ballPosition.y) <= PongSimulation.arenaHalfExtent)
        #expect(game.ballVelocity.length <= 1_150.000_001)
        #expect(game.players.values.allSatisfy { (0...3).contains($0.lives) })
        #expect((0...4).contains(game.activePlayers.count))
    }

    private func forceMiss(edge: PaddleEdge, in game: inout PongSimulation) {
        guard let player = game.players[edge] else { return }
        game.setPaddle(for: player.playerID, normalizedPosition: -1)
        switch edge {
        case .bottom:
            game.setBallForTesting(position: PongPoint(x: 300, y: -480), velocity: PongPoint(x: 0, y: -100))
        case .top:
            game.setBallForTesting(position: PongPoint(x: 300, y: 480), velocity: PongPoint(x: 0, y: 100))
        case .left:
            game.setBallForTesting(position: PongPoint(x: -480, y: 300), velocity: PongPoint(x: -100, y: 0))
        case .right:
            game.setBallForTesting(position: PongPoint(x: 480, y: 300), velocity: PongPoint(x: 100, y: 0))
        }
        _ = game.step(deltaTime: 0.05)
    }
}
