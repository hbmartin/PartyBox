import Dependencies
import Foundation
import PartyBoxCore
import PartyGameRuntime
import PartyNet
import Testing
@testable import PartyBox

@Suite("Deterministic four-way Pong")
@MainActor
struct PartyBoxTests {
    private let bottom = PlayerID(0)
    private let top = PlayerID(1)

    @MainActor
    private final class CleanupGate {
        private(set) var isWaiting = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            isWaiting = true
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

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

    @Test func uiFixtureIsAppliedOnStartAndRestoredAfterRestart() async {
        let configuration = HostLaunchConfiguration(arguments: [
            "PartyBox", "--ui-testing", "--scenario", "menu", "--disable-effects",
        ])
        let coordinator = HostCoordinator(configuration: configuration)

        #expect(coordinator.phase == .lobby)
        #expect(coordinator.host.players.isEmpty)

        await coordinator.start()
        #expect(coordinator.phase == .gameMenu)
        #expect(coordinator.host.players.count == 4)

        await coordinator.stop()
        #expect(coordinator.phase == .lobby)
        #expect(coordinator.host.players.isEmpty)

        await coordinator.start()
        #expect(coordinator.phase == .gameMenu)
        #expect(coordinator.host.players.count == 4)
        await coordinator.stop()
    }

    @Test func unexpectedHostEventStreamEndingRestartsTheHost() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let coordinator = HostCoordinator()
            await coordinator.start()
            let originalInstanceID = coordinator.host.hostInstanceID
            try #require(coordinator.host.port != nil)

            await coordinator.simulateHostEventStreamEndingForTesting()

            try await waitUntil {
                coordinator.host.port != nil
                    && coordinator.host.hostInstanceID != originalInstanceID
            }
            #expect(coordinator.statusMessage == "Ready for controllers")
            await coordinator.stop()
        }
    }

    @Test func staleStartFailureCannotOverwriteANewerSuccessfulStart() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let coordinator = HostCoordinator()
            let gate = CleanupGate()
            let staleFailure = Task {
                await coordinator.simulateSuspendedStartFailureForTesting {
                    await gate.wait()
                }
            }
            defer { staleFailure.cancel() }
            try await waitUntil { gate.isWaiting }

            await coordinator.start()
            #expect(coordinator.host.port != nil)
            #expect(coordinator.statusMessage == "Ready for controllers")

            gate.release()
            await staleFailure.value
            #expect(coordinator.statusMessage == "Ready for controllers")
            await coordinator.stop()
        }
    }

    @Test func unchangedVotesDoNotRecomputeTalliesAndModifierTitlesAreResolved() {
        let coordinator = HostCoordinator(configuration: .init(arguments: ["PartyBox", "--disable-effects"]))
        let playerID = PlayerID(7)

        #expect(coordinator.storeVoteIfChanged("fast-ball", from: playerID))
        #expect(!coordinator.storeVoteIfChanged("fast-ball", from: playerID))
        #expect(!coordinator.storeVoteIfChanged("unknown", from: playerID))
        #expect(coordinator.voteTallies == ["fast-ball": 1])
        #expect(coordinator.displayedVoteTallies == [
            VoteTallyPresentation(id: "fast-ball", title: "FAST BALL", count: 1),
        ])
    }

    @Test func reactionCoordinatesAreStableForEachBurstIdentity() throws {
        let id = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let burst = ReactionBurst(id: id, emoji: "🔥")

        #expect(burst.positionOffsets.horizontal == 66)
        #expect(burst.positionOffsets.vertical == 5)
    }

    @Test func hostKeepsMemoryOnlyHistoryVisibleAndReportsPersistenceFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let blockedParent = directory.appendingPathComponent("not-a-directory")
        let url = blockedParent.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("blocked".utf8).write(to: blockedParent)
        let coordinator = HostCoordinator(
            configuration: .init(arguments: ["PartyBox", "--disable-effects"]),
            historyFileURL: url
        )
        let record = MatchRecord(
            gameID: "pong",
            gameTitle: "Pong",
            endedAt: Date(timeIntervalSince1970: 10),
            durationSeconds: 5,
            modifierTitle: nil,
            participants: [],
            metrics: []
        )

        await coordinator.appendHistoryForTesting(record)
        await coordinator.appendHistoryForTesting(record)

        #expect(coordinator.historyRecords == [record])
        #expect(coordinator.historyPersistenceError?.isEmpty == false)
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

    @Test func ballUsesTimeRemainingAfterRespawnCountdownExpires() {
        var game = PongSimulation(assignments: [.init(playerID: bottom, edge: .bottom)])

        for _ in 0..<19 { _ = game.step(deltaTime: 0.05) }
        _ = game.step(deltaTime: 0.02)
        #expect(game.ballPosition == .zero)
        #expect(game.ballVelocity == .zero)

        _ = game.step(deltaTime: 0.05)

        #expect(game.ballVelocity.length > 0)
        #expect(game.ballPosition.length > 0)
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

    @Test func rejectedForfeitDoesNotChangeTheRecordedPlayerOutcome() throws {
        let left = PlayerID(2)
        let players = [bottom, top, left].map {
            PlayerInfo(id: $0, displayName: "P\($0.rawValue)", colorHex: PlayerPalette.color(for: $0))
        }
        let context = GameSessionContext(
            participants: players.map { .init(player: $0, controllerID: ControllerID()) },
            inputs: InputStore(),
            seed: 42,
            modifierID: nil
        )
        var completed: GameOutcome?
        let session = PongGameSession(context: context) { events in
            for case .completed(let outcome) in events { completed = outcome }
        }
        session.pongScene.forfeit(top, onAccepted: {})

        session.forfeit(top)
        session.forfeit(left)

        let outcome = try #require(completed)
        #expect(outcome.playerOutcomes.first(where: { $0.playerID == top })?.outcome == .lost)
        #expect(outcome.playerOutcomes.first(where: { $0.playerID == left })?.outcome == .forfeited)
        #expect(outcome.playerOutcomes.first(where: { $0.playerID == bottom })?.outcome == .won)
    }

    @Test func pongPublishesItsOwnCapacityControllerLayoutAndModifiers() throws {
        let game = PongGame()
        #expect(game.descriptor.minimumPlayers == 1)
        #expect(game.descriptor.maximumPlayers == 4)
        #expect(game.descriptor.modifiers.map(\.id) == ["fast-ball", "big-paddles", "extra-life"])

        let player = PlayerInfo(id: bottom, displayName: "Ada", colorHex: "#32E6FF")
        let session = game.makeSession(
            context: .init(
                participants: [.init(player: player, controllerID: ControllerID())],
                inputs: InputStore(), seed: 42, modifierID: nil
            ),
            onEvents: { _ in }
        )
        let screen = session.controllerScreen(for: bottom)
        #expect(screen.isValid)
        #expect(screen.accessibilityID == "controller.layout.paddle.bottom")
        #expect(screen.components.contains { if case .axisSurface = $0 { true } else { false } })
    }

    @Test func pongModifiersApplyTheSpecifiedRuleChanges() {
        let normal = PongRules()
        #expect(PongGame.rules(for: "fast-ball").startingSpeed == normal.startingSpeed * 1.25)
        #expect(PongGame.rules(for: "big-paddles").paddleLength == normal.paddleLength * 1.35)
        #expect(PongGame.rules(for: "extra-life").initialLives == 4)
        let extraLife = PongSimulation(
            assignments: [.init(playerID: bottom, edge: .bottom)],
            rules: PongGame.rules(for: "extra-life")
        )
        #expect(extraLife.players[.bottom]?.lives == 4)
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
            try await waitUntil { coordinator.turnOrder.players.count == 3 }

            clients[0].setInput(axisX: 0.75)
            try await waitUntil { coordinator.host.inputs.snapshot()[PlayerID(0)]?.axisX == 0.75 }
            coordinator.perform(.select)
            coordinator.perform(.select)

            #expect(coordinator.host.inputs.snapshot()[PlayerID(0)]?.axisX == 0)
            try await waitUntil {
                self.paddleEdge(of: PlayerID(1), coordinator: coordinator) == .top
                    && self.paddleEdge(of: PlayerID(2), coordinator: coordinator) == .left
            }
            await clients[0].disconnect()
            try await waitUntil { coordinator.turnOrder.players.count == 2 }

            #expect(paddleEdge(of: PlayerID(1), coordinator: coordinator) == .top)
            #expect(paddleEdge(of: PlayerID(2), coordinator: coordinator) == .left)
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
    private func paddleEdge(of playerID: PlayerID, coordinator: HostCoordinator) -> PaddleEdge? {
        (coordinator.currentScene as? PongScene)?.edge(for: playerID)
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
