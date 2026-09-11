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
            let coordinator = isolatedHostCoordinator()
            await coordinator.start()
            let originalInstanceID = coordinator.host.hostInstanceID
            try #require(coordinator.host.port != nil)

            await coordinator.simulateHostEventStreamEndingForTesting()

            try await waitUntil {
                coordinator.host.port != nil
                    && coordinator.host.hostInstanceID == originalInstanceID
            }
            #expect(coordinator.statusMessage == "Ready for controllers")
            await coordinator.stop()
        }
    }

    @Test func stopDuringStartCannotInstallAStaleHostConsumer() async throws {
        let coordinator = isolatedHostCoordinator()
        let gate = CleanupGate()
        coordinator.setStartCheckpointForTesting { await gate.wait() }
        let start = Task { await coordinator.start() }
        defer {
            gate.release()
            start.cancel()
        }
        try await waitUntil { gate.isWaiting }

        await coordinator.stop()
        gate.release()
        await start.value

        #expect(coordinator.phase == .lobby)
        #expect(coordinator.host.port == nil)
        #expect(!coordinator.hasHostEventConsumerForTesting)
    }

    @Test func staleStartFailureCannotOverwriteANewerSuccessfulStart() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let coordinator = isolatedHostCoordinator()
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
        let coordinator = isolatedHostCoordinator()
        let playerID = PlayerID(7)
        let now = ContinuousClock().now

        #expect(coordinator.storeVoteIfChanged("fast-ball", from: playerID, now: now))
        #expect(!coordinator.storeVoteIfChanged("fast-ball", from: playerID, now: now))
        #expect(!coordinator.storeVoteIfChanged("unknown", from: playerID, now: now))
        #expect(!coordinator.storeVoteIfChanged(
            "big-paddles", from: playerID, now: now.advanced(by: .milliseconds(249))
        ))
        #expect(coordinator.voteTallies == ["fast-ball": 1])
        #expect(coordinator.displayedVoteTallies == [
            VoteTallyPresentation(id: "fast-ball", title: "FAST BALL", count: 1),
        ])

        #expect(coordinator.storeVoteIfChanged(
            "big-paddles", from: playerID, now: now.advanced(by: .milliseconds(250))
        ))
        #expect(coordinator.displayedVoteTallies == [
            VoteTallyPresentation(id: "big-paddles", title: "BIG PADDLES", count: 1),
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

        coordinator.requestHistoryClear()
        await coordinator.confirmHistoryClear()

        #expect(coordinator.historyRecords == [record])
        #expect(coordinator.historyPersistenceError?.contains("could not be cleared") == true)
    }

    @Test func oversizedNestedControllerLayoutFallsBackToASendableScreen() throws {
        let coordinator = isolatedHostCoordinator()
        let oversized = ControllerScreen(
            accessibilityID: "oversized",
            accentColorHex: "#32E6FF",
            components: [.text(.init(
                id: "oversized.text",
                text: String(repeating: "x", count: 50_000),
                style: .body
            ))]
        )
        let screenPayload = try PartyBoxWireCodec.encode(oversized)
        let layout = PartyBoxCore.ControllerLayout.game(.init(gameID: "oversized-game", payload: screenPayload))
        #expect(throws: PartyBoxWireError.self) {
            try PartyBoxWireCodec.encode(HostPresentation.layout(layout))
        }

        let payload = try #require(coordinator.encodedLayoutPresentation(layout))
        let presentation = try PartyBoxWireCodec.decode(HostPresentation.self, from: payload)
        guard case .layout(.game(let envelope)) = presentation else {
            Issue.record("Expected a game controller fallback")
            return
        }
        #expect(envelope.gameID == "oversized-game")
        #expect(envelope.validatedControllerScreen?.accessibilityID == "controller.layout.unavailable")
    }

    @Test func pongTranslationPreservesEveryTVAudioCue() throws {
        let player = PlayerInfo(id: bottom, displayName: "Ada", colorHex: "#32E6FF")
        let session = try #require(PongGame().makeSession(
            context: .init(
                participants: [.init(player: player, controllerID: ControllerID())],
                inputs: InputStore(), seed: 42, modifierID: nil
            ),
            onEvents: { _ in }
        ) as? PongGameSession)

        let translated = session.translateForTesting([
            .lostLife(bottom, remaining: 0),
            .forfeited(bottom),
            .gameOver(winner: nil, rally: 3),
        ])
        let audio = translated.compactMap { event -> HapticPattern? in
            guard case .audio(let cue) = event else { return nil }
            return cue
        }
        #expect(audio == [.heavyImpact, .error, .success])
    }

    @Test func pongCupStandingsFollowSurvivalOrder() throws {
        let left = PlayerID(2)
        let players = [bottom, top, left].map {
            PlayerInfo(id: $0, displayName: "P\($0.rawValue)", colorHex: PlayerPalette.color(for: $0))
        }
        let session = PongGameSession(
            context: .init(
                participants: players.map { .init(player: $0, controllerID: ControllerID()) },
                inputs: InputStore(), seed: 42, modifierID: nil
            ),
            onEvents: { _ in }
        )

        let translated = session.translateForTesting([
            .eliminated(top),
            .eliminated(left),
            .gameOver(winner: bottom, rally: 12),
        ])
        let completed = translated.compactMap { event -> GameOutcome? in
            guard case .completed(let outcome) = event else { return nil }
            return outcome
        }.first

        #expect(completed?.standings.map(\.playerID) == [bottom, left, top])
        #expect(completed?.standings.map(\.rank) == [1, 2, 3])
    }

    @Test func stoppedCoordinatorCannotBeRevivedBySuspendedMatchCompletion() async throws {
        let coordinator = HostCoordinator(configuration: .init(arguments: [
            "PartyBox", "--ui-testing", "--scenario", "four-way-match", "--disable-effects",
        ]))
        await coordinator.start()
        let gate = CleanupGate()
        coordinator.setFinishMatchCheckpointForTesting { await gate.wait() }
        let outcome = GameOutcome(
            title: "MATCH OVER", subtitle: "Done", winner: bottom,
            playerOutcomes: [.init(playerID: bottom, outcome: .won)], metrics: []
        )
        let completion = Task { await coordinator.finishCurrentMatchForTesting(outcome) }
        defer {
            gate.release()
            completion.cancel()
        }
        try await waitUntil { gate.isWaiting }

        await coordinator.stop()
        gate.release()
        await completion.value

        #expect(coordinator.phase == .lobby)
        #expect(coordinator.currentScene == nil)
    }

    @Test func stoppedCoordinatorCannotBeRevivedBySuspendedCupCompletion() async throws {
        let coordinator = HostCoordinator(configuration: .init(arguments: [
            "PartyBox", "--ui-testing", "--scenario", "cup-final-match", "--disable-effects",
        ]))
        await coordinator.start()
        let gate = CleanupGate()
        coordinator.setFinishCupCheckpointForTesting { await gate.wait() }
        let players = coordinator.host.players
        let outcome = GameOutcome(
            title: "CUP COMPLETE",
            subtitle: "Done",
            winner: players.first?.id,
            playerOutcomes: players.map {
                .init(playerID: $0.id, outcome: $0.id == players.first?.id ? .won : .lost)
            },
            metrics: [],
            standings: players.enumerated().map {
                .init(playerID: $0.element.id, rank: $0.offset + 1, score: 100 - $0.offset)
            }
        )
        let completion = Task { await coordinator.finishCurrentMatchForTesting(outcome) }
        defer {
            gate.release()
            completion.cancel()
        }
        try await waitUntil { gate.isWaiting }

        await coordinator.stop()
        gate.release()
        await completion.value

        #expect(coordinator.phase == .lobby)
        #expect(coordinator.currentScene == nil)
        #expect(coordinator.cupRecords.isEmpty)
    }

    @Test func failedCupEventStartDoesNotAdvanceTheEventIndex() async {
        let coordinator = HostCoordinator(configuration: .init(arguments: [
            "PartyBox", "--ui-testing", "--scenario", "cup-standings", "--disable-effects",
        ]))
        await coordinator.start()
        #expect(coordinator.cupEventIndex == 0)

        coordinator.perform(.select)

        #expect(coordinator.cupEventIndex == 0)
        guard case .cupStandings = coordinator.phase else {
            Issue.record("A failed event start must leave the Cup on its standings screen")
            await coordinator.stop()
            return
        }
        await coordinator.stop()
    }

    @Test func centralizedGameStartEligibilityEnforcesMinimumAndMaximumPlayers() {
        let descriptor = GameDescriptor(
            id: "two-player", title: "Two Player", summary: "Test",
            minimumPlayers: 2, maximumPlayers: 2
        )
        let participants = (0..<3).map { index in
            let player = PlayerInfo(
                id: PlayerID(UInt8(index)),
                displayName: "P\(index)",
                colorHex: PlayerPalette.color(for: PlayerID(UInt8(index)))
            )
            return GameParticipant(player: player, controllerID: ControllerID())
        }

        #expect(HostCoordinator.participantsForStart(
            Array(participants.prefix(1)), descriptor: descriptor
        ) == nil)
        #expect(HostCoordinator.participantsForStart(
            participants, descriptor: descriptor
        ) == Array(participants.prefix(2)))
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
        #expect(game.descriptor.maximumPlayers == 8)
        #expect(game.descriptor.modifiers.map(\.id) == ["fast-ball", "big-paddles", "extra-life"])
        #expect(game.availableModifiers(participantCount: 4) == game.descriptor.modifiers)
        #expect(game.availableModifiers(participantCount: 5).isEmpty)
        #expect(HostCoordinator.applicableModifier(
            PongGame.fastBall,
            for: game,
            participantCount: 4
        ) == PongGame.fastBall)
        #expect(HostCoordinator.applicableModifier(
            PongGame.fastBall,
            for: game,
            participantCount: 5
        ) == nil)

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
        #expect(screen.requestedInputs == .orientation)
        #expect(screen.components.contains { if case .axisSurface = $0 { true } else { false } })
    }

    @Test func pongUsesTheResolvedAxisForTouchAndCalibratedMotion() throws {
        let inputs = InputStore()
        let player = PlayerInfo(id: bottom, displayName: "Ada", colorHex: "#32E6FF")
        let scene = PongScene(
            assignments: [.init(playerID: bottom, edge: .bottom)],
            players: [player],
            inputs: inputs,
            seed: 42
        ) { _ in }

        #expect(inputs.update(
            InputFrame(token: 1, sequence: 1, clientTimeMs: 0, axisX: -0.6, axisY: 0),
            for: bottom
        ))
        scene.update(0)
        #expect(abs(try #require(scene.paddlePosition(for: bottom)) + 0.6) < 0.001)

        let halfAngle = Float.pi / 12
        #expect(inputs.update(
            InputFrame(
                token: 1,
                sequence: 2,
                clientTimeMs: 1,
                axisX: -0.9,
                axisY: 0,
                orientation: .init(x: 0, y: sin(halfAngle), z: 0, w: cos(halfAngle)),
                flags: .motionAvailable
            ),
            for: bottom
        ))
        scene.update(1.0 / 60.0)
        #expect(abs(try #require(scene.paddlePosition(for: bottom)) + 0.9) < 0.001)
    }

    @Test func gameLibraryProvidesFiveCupEligibleGamesAndEightPlayerNewGames() {
        let games: [any PartyGame] = [PongGame(), SignalSnapGame(), GravityGrabGame(), SnakePitGame(), LastLightGame()]
        #expect(games.map(\.descriptor.id) == ["pong", "signal-snap", "gravity-grab", "snake-pit", "last-light"])
        #expect(games.allSatisfy { $0.descriptor.isCupEligible })
        #expect(games.allSatisfy { $0.descriptor.maximumPlayers == 8 })
    }

    @Test func arcadeRandomChoicesDoNotUseRepeatingLowOrderLCGBits() {
        var generator = ArcadeRandomNumberGenerator(seed: 42)
        let values = (0..<12).map { _ in generator.next() }
        let parity = values.map { $0 % 2 }
        let directions = values.map { $0 % 4 }

        #expect(zip(parity, parity.dropFirst()).contains { $0.0 == $0.1 })
        #expect(Array(directions.prefix(4)) != Array(directions.dropFirst(4).prefix(4)))
    }

    @Test func easyArcadeBotsCrossTheSignalActivationThreshold() throws {
        let playerID = PlayerID(0)
        let participant = GameParticipant(
            player: .init(id: playerID, displayName: "Bot", colorHex: "#32E6FF", kind: .bot),
            controllerID: ControllerID()
        )

        for mode in [ArcadeChallengeMode.pongQualifiers, .signalSnap] {
            let session = ArcadeChallengeSession(
                mode: mode,
                context: .init(
                    participants: [participant],
                    inputs: InputStore(),
                    seed: 42,
                    modifierID: nil
                ),
                onEvents: { _ in }
            )
            let input = try #require(session.botInput(
                for: playerID,
                difficulty: .easy,
                deltaTime: .milliseconds(16)
            ))
            #expect(max(abs(input.axisX), abs(input.axisY)) > 0.58)
        }
    }

    @Test func signalRecenteringCannotScoreTwiceInOneRound() throws {
        let playerID = PlayerID(0)
        let inputs = InputStore()
        let session = ArcadeChallengeSession(
            mode: .signalSnap,
            context: .init(
                participants: [.init(
                    player: .init(id: playerID, displayName: "Ada", colorHex: "#32E6FF"),
                    controllerID: ControllerID()
                )],
                inputs: inputs,
                seed: 42,
                modifierID: nil
            ),
            onEvents: { _ in }
        )
        for step in 0...5 {
            session.updateForTesting(Double(step) * 0.05)
        }
        let direction = session.signalDirectionForTesting()
        let axes: (Float, Float) = switch direction {
        case "up": (0, 1)
        case "down": (0, -1)
        case "left": (-1, 0)
        default: (1, 0)
        }

        #expect(inputs.update(
            .init(token: 1, sequence: 1, clientTimeMs: 1, axisX: axes.0, axisY: axes.1),
            for: playerID
        ))
        session.updateForTesting(0.30)
        let firstScore = try #require(session.scoreForTesting(playerID))
        #expect(firstScore > 0)

        #expect(inputs.update(
            .init(token: 1, sequence: 2, clientTimeMs: 2, axisX: 0, axisY: 0),
            for: playerID
        ))
        session.updateForTesting(0.35)
        #expect(inputs.update(
            .init(token: 1, sequence: 3, clientTimeMs: 3, axisX: axes.0, axisY: axes.1),
            for: playerID
        ))
        session.updateForTesting(0.40)

        #expect(session.scoreForTesting(playerID) == firstScore)
    }

    @Test func seededSnakeSimulationIgnoresDictionaryStorageOrder() {
        let participants = (0..<6).map { index in
            let playerID = PlayerID(UInt8(index))
            return GameParticipant(
                player: .init(
                    id: playerID,
                    displayName: "P\(index + 1)",
                    colorHex: PlayerPalette.color(for: playerID)
                ),
                controllerID: ControllerID()
            )
        }
        let first = ArcadeChallengeSession(
            mode: .snakePit,
            context: .init(participants: participants, inputs: InputStore(), seed: 42, modifierID: nil),
            onEvents: { _ in }
        )
        let second = ArcadeChallengeSession(
            mode: .snakePit,
            context: .init(participants: participants, inputs: InputStore(), seed: 42, modifierID: nil),
            onEvents: { _ in }
        )
        second.reverseStorageForTesting()

        for step in 0...100 {
            let time = Double(step) * 0.05
            first.updateForTesting(time)
            second.updateForTesting(time)
        }

        #expect(first.snapshotForTesting() == second.snapshotForTesting())
    }

    @Test func snakeTrailRenderingReusesItsBoundedNodePool() throws {
        let playerID = PlayerID(0)
        let session = ArcadeChallengeSession(
            mode: .snakePit,
            context: .init(
                participants: [.init(
                    player: .init(id: playerID, displayName: "Ada", colorHex: "#32E6FF"),
                    controllerID: ControllerID()
                )],
                inputs: InputStore(),
                seed: 42,
                modifierID: nil
            ),
            onEvents: { _ in }
        )

        for step in 0...20 {
            session.updateForTesting(Double(step) * 0.05)
        }
        let initial = try #require(session.snakeTrailNodeIdentitiesForTesting()[playerID])
        #expect(!initial.isEmpty)

        for step in 21...60 {
            session.updateForTesting(Double(step) * 0.05)
        }
        let later = try #require(session.snakeTrailNodeIdentitiesForTesting()[playerID])

        #expect(Array(later.prefix(initial.count)) == initial)
        #expect(later.count <= 36)
    }

    @Test func everyGameBuildsAValidEightPlayerControllerAndBotSession() {
        let participants = (0..<8).map { index in
            let playerID = PlayerID(UInt8(index))
            return GameParticipant(
                player: PlayerInfo(
                    id: playerID,
                    displayName: "Bot \(index + 1)",
                    colorHex: PlayerPalette.color(for: playerID),
                    kind: .bot
                ),
                controllerID: ControllerID()
            )
        }
        let context = GameSessionContext(
            participants: participants,
            inputs: InputStore(),
            seed: 42,
            modifierID: nil
        )
        let games: [any PartyGame] = [PongGame(), SignalSnapGame(), GravityGrabGame(), SnakePitGame(), LastLightGame()]

        for game in games {
            let session = game.makeSession(context: context, onEvents: { _ in })
            for participant in participants {
                let screen = session.controllerScreen(for: participant.player.id)
                #expect(screen.isValid, "\(game.descriptor.title) must publish a valid controller screen")
                #expect(screen.requestedInputs == .orientation)
                #expect(session.botInput(
                    for: participant.player.id,
                    difficulty: .normal,
                    deltaTime: .milliseconds(16)
                ) != nil, "\(game.descriptor.title) must drive every bot")
            }
        }
    }

    @Test func captainCanBuildAThreeEventCupAndScoreTheFirstEvent() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let coordinator = isolatedHostCoordinator()
            await coordinator.start()
            let port = try #require(coordinator.host.port)
            let captain = PartyClient(displayName: "Captain")
            let teammate = PartyClient(displayName: "Teammate")
            await captain.connect(host: "127.0.0.1", port: port)
            await teammate.connect(host: "127.0.0.1", port: port)
            try await waitUntil { coordinator.connectedHumanCount == 2 }
            let teammateID = try #require(teammate.player?.id)

            coordinator.perform(.select)
            for _ in 0..<5 { coordinator.perform(.down) }
            #expect(coordinator.menuItems[coordinator.menuSelection] == "PARTY CUP")
            #expect(!coordinator.controlStatusForTesting(teammateID).canToggleReady)
            coordinator.perform(.select)
            #expect(coordinator.phase == .cupSetup)
            #expect(!coordinator.controlStatusForTesting(teammateID).canToggleReady)

            coordinator.perform(.select)
            coordinator.perform(.down)
            coordinator.perform(.select)
            coordinator.perform(.down)
            coordinator.perform(.select)
            #expect(coordinator.selectedCupGameIDs.count == 3)
            #expect(coordinator.controlStatusForTesting(teammateID).canToggleReady)
            coordinator.perform(.select, source: .controller(teammateID))
            #expect(coordinator.phase == .playing)

            let players = coordinator.host.players
            let standings = players.enumerated().map {
                GameStanding(playerID: $0.element.id, rank: $0.offset + 1, score: 100 - $0.offset)
            }
            let winner = try #require(players.first?.id)
            await coordinator.finishCurrentMatchForTesting(.init(
                title: "EVENT COMPLETE",
                subtitle: "Done",
                winner: winner,
                playerOutcomes: players.map { .init(playerID: $0.id, outcome: $0.id == winner ? .won : .lost) },
                metrics: [],
                standings: standings
            ))
            guard case .cupStandings = coordinator.phase else {
                Issue.record("Expected cup standings after the first event")
                return
            }
            #expect(coordinator.cupLeaderboard.first?.points == 8)
            await teammate.stop()
            await captain.stop()
            await coordinator.stop()
        }
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

    @Test func pongBotProjectionIsBoundedDeterministicAndDifficultyControlsSpeed() throws {
        var simulation = PongSimulation(assignments: [
            .init(playerID: bottom, edge: .bottom),
            .init(playerID: top, edge: .top),
        ])
        simulation.setBallForTesting(
            position: PongPoint(x: 300, y: -400),
            velocity: PongPoint(x: 0, y: -100)
        )
        let projected = try #require(simulation.botTarget(for: bottom))
        #expect(projected > 0.7 && projected < 0.8)
        #expect(simulation.botTarget(for: top) == nil)

        let human = PlayerInfo(id: bottom, displayName: "Ada", colorHex: "#32E6FF")
        let bot = PlayerInfo(
            id: top, displayName: "Bot", colorHex: "#FF4FD8", mark: .star, kind: .bot
        )
        func session() -> PongGameSession {
            PongGameSession(context: .init(
                participants: [
                    .init(player: human, controllerID: ControllerID()),
                    .init(player: bot, controllerID: ControllerID()),
                ],
                inputs: InputStore(), seed: 42, modifierID: nil
            )) { _ in }
        }
        let easy = session()
        let normal = session()
        let hard = session()
        for value in [easy, normal, hard] {
            value.pongScene.setBallForTesting(
                position: PongPoint(x: 300, y: 400),
                velocity: PongPoint(x: 0, y: 100)
            )
        }
        let easyInput = try #require(easy.botInput(for: top, difficulty: .easy, deltaTime: .milliseconds(50)))
        let normalInput = try #require(normal.botInput(for: top, difficulty: .normal, deltaTime: .milliseconds(50)))
        let hardInput = try #require(hard.botInput(for: top, difficulty: .hard, deltaTime: .milliseconds(50)))
        #expect(abs(easyInput.axisX) < abs(normalInput.axisX))
        #expect(abs(normalInput.axisX) < abs(hardInput.axisX))
        #expect((-1...1).contains(easyInput.axisX))
        #expect((-1...1).contains(normalInput.axisX))
        #expect((-1...1).contains(hardInput.axisX))

        let first = session()
        let second = session()
        first.pongScene.setBallForTesting(position: PongPoint(x: -250, y: 400), velocity: PongPoint(x: 0, y: 100))
        second.pongScene.setBallForTesting(position: PongPoint(x: -250, y: 400), velocity: PongPoint(x: 0, y: 100))
        #expect(
            first.botInput(for: top, difficulty: .normal, deltaTime: .milliseconds(16))
                == second.botInput(for: top, difficulty: .normal, deltaTime: .milliseconds(16))
        )
        #expect(GameBotInput(axisX: .infinity, axisY: -.infinity).axisX == 0)
    }

    @Test func pongPaddlesCarryMarksAndTrailClearsOnServeResetAndGameOver() {
        let player = PlayerInfo(
            id: bottom, displayName: "Ada", colorHex: "#32E6FF", mark: .hexagon
        )
        let scene = PongScene(
            assignments: [.init(playerID: bottom, edge: .bottom)],
            players: [player], inputs: InputStore(), seed: 42
        ) { _ in }
        #expect(scene.paddleMarkCountForTesting == 1)
        scene.animateForTesting([.paddleHit(bottom)])
        #expect(scene.hasActiveTrailForTesting)
        scene.animateForTesting([.lostLife(bottom, remaining: 2)])
        #expect(!scene.hasActiveTrailForTesting)
        scene.animateForTesting([.paddleHit(bottom), .gameOver(winner: nil, rally: 1)])
        #expect(!scene.hasActiveTrailForTesting)
    }

    @Test func mixedMatchDifficultyMovesOneStepAndClamps() {
        let coordinator = isolatedHostCoordinator()
        let human = PlayerInfo(id: bottom, displayName: "Ada", colorHex: "#32E6FF")
        let bot = PlayerInfo(
            id: top, displayName: "Bot", colorHex: "#FF4FD8", kind: .bot
        )
        let participants = [human, bot].map {
            GameParticipant(player: $0, controllerID: ControllerID())
        }
        func outcome(winner: PlayerID?) -> GameOutcome {
            GameOutcome(title: "Done", subtitle: "", winner: winner, playerOutcomes: [], metrics: [])
        }

        coordinator.updateBotDifficultyForTesting(outcome: outcome(winner: bottom), participants: participants)
        #expect(coordinator.currentBotDifficulty == .hard)
        coordinator.updateBotDifficultyForTesting(outcome: outcome(winner: bottom), participants: participants)
        #expect(coordinator.currentBotDifficulty == .hard)
        coordinator.updateBotDifficultyForTesting(outcome: outcome(winner: top), participants: participants)
        #expect(coordinator.currentBotDifficulty == .normal)
        coordinator.setBotDifficultyForTesting(.easy)
        coordinator.updateBotDifficultyForTesting(outcome: outcome(winner: top), participants: participants)
        #expect(coordinator.currentBotDifficulty == .easy)
        coordinator.updateBotDifficultyForTesting(outcome: outcome(winner: nil), participants: participants)
        #expect(coordinator.currentBotDifficulty == .easy)
        coordinator.updateBotDifficultyForTesting(
            outcome: outcome(winner: bottom),
            participants: [participants[0]]
        )
        #expect(coordinator.currentBotDifficulty == .easy)
    }

    @Test func seededServesReachEveryActiveEdge() throws {
        for count in [2, 4] {
            let assignments = PaddleEdge.allCases.prefix(count).enumerated().map {
                SeatAssignment(playerID: PlayerID(UInt8($0.offset)), edge: $0.element)
            }
            var game = PongSimulation(assignments: assignments, seed: 42)
            var observed: Set<PaddleEdge> = []
            for _ in 0..<64 {
                let launchTarget = game.launchTargetForTesting()
                observed.insert(try #require(launchTarget))
            }
            #expect(observed == Set(assignments.map(\.edge)))
        }
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
            let coordinator = isolatedHostCoordinator()
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

    @Test func captainAuthorizationCooldownsAndStrictMajorityReadiness() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let coordinator = isolatedHostCoordinator()
            await coordinator.start()
            let port = try #require(coordinator.host.port)
            let clients = (1...4).map { PartyClient(displayName: "Human \($0)") }
            for client in clients { await client.connect(host: "127.0.0.1", port: port) }
            try await waitUntil { coordinator.connectedHumanCount == 4 && coordinator.captainID != nil }
            let ids = try clients.map { try #require($0.player?.id) }
            #expect(coordinator.captainID == ids[0])
            #expect(coordinator.requiredReadyCount == 3)

            let now = ContinuousClock().now
            coordinator.perform(.select, source: .controller(ids[1]), now: now)
            #expect(coordinator.phase == .lobby)
            coordinator.perform(.select, source: .controller(ids[0]), now: now)
            #expect(coordinator.phase == .gameMenu)

            coordinator.perform(.down, source: .controller(ids[0]), now: now)
            #expect(coordinator.menuSelection == 1)
            coordinator.perform(.up, source: .controller(ids[0]), now: now.advanced(by: .milliseconds(149)))
            #expect(coordinator.menuSelection == 1)
            coordinator.perform(.up, source: .controller(ids[0]), now: now.advanced(by: .milliseconds(150)))
            #expect(coordinator.menuSelection == 0)

            coordinator.perform(.back, source: .controller(ids[1]), now: now.advanced(by: .seconds(1)))
            #expect(coordinator.phase == .gameMenu)
            coordinator.perform(.select, source: .controller(ids[1]), now: now.advanced(by: .seconds(1)))
            #expect(coordinator.readyCount == 2)
            #expect(coordinator.phase == .gameMenu)
            coordinator.perform(.select, source: .controller(ids[1]), now: now.advanced(by: .seconds(1.749)))
            #expect(coordinator.readyCount == 2)
            coordinator.perform(.select, source: .controller(ids[1]), now: now.advanced(by: .seconds(1.750)))
            #expect(coordinator.readyCount == 1)

            coordinator.perform(.down, source: .controller(ids[0]), now: now.advanced(by: .seconds(2)))
            #expect(coordinator.readyPlayerIDs.isEmpty)
            coordinator.perform(.up, source: .controller(ids[0]), now: now.advanced(by: .seconds(2.2)))
            #expect(coordinator.menuSelection == 0)
            coordinator.perform(.select, source: .controller(ids[1]), now: now.advanced(by: .seconds(3)))
            #expect(coordinator.readyCount == 2)

            let newcomer = PartyClient(displayName: "Human 5")
            await newcomer.connect(host: "127.0.0.1", port: port)
            try await waitUntil { coordinator.connectedHumanCount == 5 }
            #expect(coordinator.readyPlayerIDs.isEmpty)
            #expect(coordinator.requiredReadyCount == 3)
            #expect(coordinator.phase == .gameMenu)

            coordinator.perform(.select, source: .controller(ids[1]), now: now.advanced(by: .seconds(4)))
            coordinator.perform(.select, source: .controller(ids[2]), now: now.advanced(by: .seconds(4)))
            #expect(coordinator.phase == .playing)
            #expect(coordinator.readyPlayerIDs.isEmpty)

            await newcomer.stop()
            for client in clients { await client.stop() }
            await coordinator.stop()
        }
    }

    @Test func captainTransfersOnInterruptionAndPromotionSurvivesReconnect() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let coordinator = isolatedHostCoordinator()
            await coordinator.start()
            let port = try #require(coordinator.host.port)
            let first = PartyClient(displayName: "First")
            let second = PartyClient(displayName: "Second")
            let third = PartyClient(displayName: "Third")
            let fourth = PartyClient(displayName: "Fourth")
            await first.connect(host: "127.0.0.1", port: port)
            await second.connect(host: "127.0.0.1", port: port)
            await third.connect(host: "127.0.0.1", port: port)
            await fourth.connect(host: "127.0.0.1", port: port)
            try await waitUntil { coordinator.connectedHumanCount == 4 }
            let firstID = try #require(first.player?.id)
            let secondID = try #require(second.player?.id)
            #expect(coordinator.captainID == firstID)

            coordinator.perform(.select)
            coordinator.perform(.select, source: .controller(secondID), now: ContinuousClock().now)
            #expect(coordinator.readyPlayerIDs == [secondID])

            await first.interruptForTesting()
            try await waitUntil { coordinator.captainID == secondID }
            #expect(coordinator.readyPlayerIDs.isEmpty)
            first.reconnectAfterForeground()
            try await waitUntil(timeout: .seconds(5)) {
                if case .connected = first.state { return true }
                return false
            }
            #expect(coordinator.captainID == secondID)

            await first.stop()
            await second.stop()
            await third.stop()
            await fourth.stop()
            await coordinator.stop()
        }
    }

    @Test func releaseBotsFillSafelyAndSendRealInputFrames() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let coordinator = isolatedHostCoordinator()
            await coordinator.start()
            let port = try #require(coordinator.host.port)
            let captain = PartyClient(displayName: "Captain")
            await captain.connect(host: "127.0.0.1", port: port)
            try await waitUntil { coordinator.captainID == captain.player?.id }

            let botCommand = try PartyBoxWireCodec.encode(
                ControllerCommand.lobby(.setBotFillTarget(6))
            )
            #expect(await captain.sendApplication(botCommand))
            try await waitUntil(timeout: .seconds(5)) { coordinator.activeBotCount == 6 }
            #expect(Set(coordinator.host.players.map(\.mark)).count == coordinator.host.players.count)
            #expect(coordinator.connectedHumanCount == 1)
            #expect(coordinator.requiredReadyCount == 1)

            coordinator.perform(.select)
            coordinator.perform(.select)
            #expect(coordinator.phase == .playing)
            #expect(coordinator.botParticipantCountForTesting == 6)
            #expect(coordinator.readyBotClientCountForTesting == 6)
            let appliedBeforeBotControl = coordinator.botInputFramesAppliedForTesting
            try await waitUntil(timeout: .seconds(5)) {
                coordinator.botInputFramesAppliedForTesting > appliedBeforeBotControl
            }

            let newcomer = PartyClient(displayName: "New Human")
            await newcomer.connect(host: "127.0.0.1", port: port)
            try await waitUntil { coordinator.connectedHumanCount == 2 }
            #expect(coordinator.activeBotCount == 6)

            let humanID = try #require(captain.player?.id)
            await coordinator.finishCurrentMatchForTesting(.init(
                title: "DONE", subtitle: "", winner: humanID,
                playerOutcomes: [.init(playerID: humanID, outcome: .won)], metrics: []
            ))
            try await waitUntil(timeout: .seconds(5)) { coordinator.activeBotCount == 6 }

            await newcomer.stop()
            await captain.stop()
            await coordinator.stop()
        }
    }

    @Test func recycledPlayerIDDoesNotAcquireThePreviousControllersMatchIdentity() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let host = PartyHost(reconnectGrace: .zero)
            let coordinator = HostCoordinator(
                configuration: .init(arguments: ["PartyBox", "--ui-testing", "--disable-effects"]),
                host: host
            )
            let originalControllerID = ControllerID()
            let original = PartyClient(controllerID: originalControllerID, displayName: "Original")
            let replacementControllerID = ControllerID()
            let replacement = PartyClient(controllerID: replacementControllerID, displayName: "Replacement")

            await coordinator.start()
            let port = try #require(host.port)
            await original.connect(host: "127.0.0.1", port: port)
            try await waitUntil { host.players.count == 1 }
            let player = try #require(host.players.first)
            let participant = GameParticipant(player: player, controllerID: originalControllerID)
            #expect(coordinator.isLiveParticipantForTesting(participant))

            await original.disconnect()
            try await waitUntil { host.players.isEmpty }
            await replacement.connect(host: "127.0.0.1", port: port)
            try await waitUntil { host.players.count == 1 }

            #expect(host.players.first?.id == player.id)
            #expect(host.controllerID(for: player.id) == replacementControllerID)
            #expect(!coordinator.isLiveParticipantForTesting(participant))

            await replacement.disconnect()
            await coordinator.stop()
        }
    }

    @MainActor
    private func isolatedHostCoordinator() -> HostCoordinator {
        HostCoordinator(configuration: .init(arguments: ["PartyBox", "--ui-testing", "--disable-effects"]))
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
