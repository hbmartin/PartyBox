import Foundation
import PartyBoxCore
import PartyGameRuntime
import PartyNet
import Testing
@testable import PartyGames

@Suite("Deterministic PartyGames")
@MainActor
struct PartyGamesTests {
    private let bottom = PlayerID(0)
    private let top = PlayerID(1)

    private enum EventSignature: Equatable {
        case audio(HapticPattern)
        case haptic(PlayerID, HapticPattern)
        case deviceCue(PlayerID, colorHex: String, durationMilliseconds: Int, haptic: HapticPattern?)
        case eliminated(PlayerID)
        case completed(GameOutcome)
    }

    private func eventSignature(_ event: GameEvent) -> EventSignature {
        switch event {
        case .audio(let pattern): .audio(pattern)
        case .haptic(let playerID, let pattern): .haptic(playerID, pattern)
        case .deviceCue(let playerID, let cue):
            .deviceCue(playerID, colorHex: cue.colorHex,
                       durationMilliseconds: cue.durationMilliseconds, haptic: cue.haptic)
        case .eliminated(let playerID): .eliminated(playerID)
        case .completed(let outcome): .completed(outcome)
        }
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
        let completed = translated.compactMap { event -> GameOutcome? in
            if case .completed(let outcome) = event { outcome } else { nil }
        }.first
        #expect(completed?.subtitle != "Party Cup event complete")
    }

    @Test func pongCupStandingsFollowSurvivalOrder() throws {
        let left = PlayerID(2)
        let players = [bottom, top, left].map {
            PlayerInfo(id: $0, displayName: "P\($0.rawValue)", colorHex: PlayerPalette.color(for: $0))
        }
        let session = PongGameSession(
            supportsMotion: true,
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
        #expect(completed?.subtitle == "Select to play again")
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
        let session = PongGameSession(supportsMotion: true, context: context) { events in
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
        let games = PartyGames.all()
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
                supportsMotion: false,
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
            supportsMotion: false,
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

    @Test func heldSignalInputIsAcceptedAfterTheRoundActivationDelay() throws {
        let playerID = PlayerID(0)
        let inputs = InputStore()
        let session = ArcadeChallengeSession(
            mode: .signalSnap,
            supportsMotion: false,
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
        let axes: (Float, Float) = switch session.signalDirectionForTesting() {
        case "up": (0, 1)
        case "down": (0, -1)
        case "left": (-1, 0)
        default: (1, 0)
        }
        #expect(inputs.update(
            .init(token: 1, sequence: 1, clientTimeMs: 1, axisX: axes.0, axisY: axes.1),
            for: playerID
        ))

        for step in 0...5 {
            session.updateForTesting(Double(step) * 0.05)
        }

        #expect(try #require(session.scoreForTesting(playerID)) > 0)
    }

    @Test func signalInputEventsIgnoreInputInsertionAndStateStorageOrder() throws {
        let participants = (0..<4).map { index in
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
        let firstInputs = InputStore()
        let secondInputs = InputStore()
        var firstEvents: [GameEvent] = []
        var secondEvents: [GameEvent] = []
        let first = ArcadeChallengeSession(
            mode: .signalSnap,
            supportsMotion: false,
            context: .init(participants: participants, inputs: firstInputs, seed: 42, modifierID: nil),
            onEvents: { firstEvents.append(contentsOf: $0) }
        )
        let second = ArcadeChallengeSession(
            mode: .signalSnap,
            supportsMotion: false,
            context: .init(participants: participants, inputs: secondInputs, seed: 42, modifierID: nil),
            onEvents: { secondEvents.append(contentsOf: $0) }
        )
        second.reverseStorageForTesting()
        let axes: (Float, Float) = switch first.signalDirectionForTesting() {
        case "up": (0, 1)
        case "down": (0, -1)
        case "left": (-1, 0)
        default: (1, 0)
        }
        #expect(second.signalDirectionForTesting() == first.signalDirectionForTesting())
        for (index, participant) in participants.enumerated() {
            #expect(firstInputs.update(
                .init(token: 1, sequence: UInt32(index + 1), clientTimeMs: 1, axisX: axes.0, axisY: axes.1),
                for: participant.player.id
            ))
        }
        for (index, participant) in participants.reversed().enumerated() {
            #expect(secondInputs.update(
                .init(token: 1, sequence: UInt32(index + 1), clientTimeMs: 1, axisX: axes.0, axisY: axes.1),
                for: participant.player.id
            ))
        }

        for step in 0...5 {
            let time = Double(step) * 0.05
            first.updateForTesting(time)
            second.updateForTesting(time)
        }

        #expect(firstEvents.map(eventSignature) == secondEvents.map(eventSignature))
        let cueOrder = firstEvents.compactMap { event -> PlayerID? in
            if case .deviceCue(let playerID, _) = event { playerID } else { nil }
        }
        #expect(cueOrder == participants.map(\.player.id))
    }

    @Test func gravityEventsIgnoreInputInsertionAndStateStorageOrder() {
        let participants = (0..<4).map { index in
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
        let firstInputs = InputStore()
        let secondInputs = InputStore()
        var firstEvents: [GameEvent] = []
        var secondEvents: [GameEvent] = []
        let first = ArcadeChallengeSession(
            mode: .gravityGrab,
            supportsMotion: true,
            context: .init(participants: participants, inputs: firstInputs, seed: 42, modifierID: nil),
            onEvents: { firstEvents.append(contentsOf: $0) }
        )
        let second = ArcadeChallengeSession(
            mode: .gravityGrab,
            supportsMotion: true,
            context: .init(participants: participants, inputs: secondInputs, seed: 42, modifierID: nil),
            onEvents: { secondEvents.append(contentsOf: $0) }
        )
        second.reverseStorageForTesting()
        var random = ArcadeRandomNumberGenerator(seed: 42)
        let targetAngle = Double(random.next() % 628) / 100
        let axes = (Float(cos(targetAngle)), Float(sin(targetAngle)))
        for (index, participant) in participants.enumerated() {
            #expect(firstInputs.update(
                .init(token: 1, sequence: UInt32(index + 1), clientTimeMs: 1, axisX: axes.0, axisY: axes.1),
                for: participant.player.id
            ))
        }
        for (index, participant) in participants.reversed().enumerated() {
            #expect(secondInputs.update(
                .init(token: 1, sequence: UInt32(index + 1), clientTimeMs: 1, axisX: axes.0, axisY: axes.1),
                for: participant.player.id
            ))
        }

        for step in 0...13 {
            let time = Double(step) * 0.05
            first.updateForTesting(time)
            second.updateForTesting(time)
        }

        #expect(firstEvents.map(eventSignature) == secondEvents.map(eventSignature))
        let cueOrder = firstEvents.compactMap { event -> PlayerID? in
            if case .deviceCue(let playerID, _) = event { playerID } else { nil }
        }
        #expect(cueOrder == participants.map(\.player.id))
    }

    @Test func gravityInputIsNormalizedWithoutChangingDirection() throws {
        let playerID = PlayerID(0)
        let inputs = InputStore()
        let session = ArcadeChallengeSession(
            mode: .gravityGrab,
            supportsMotion: true,
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
        #expect(inputs.update(.init(
            token: 1,
            sequence: 1,
            clientTimeMs: 1,
            axisX: 0.3,
            axisY: 0.4
        ), for: playerID))

        session.updateForTesting(0)

        let state = try #require(session.snapshotForTesting()[playerID])
        #expect(abs(state.x - 0.6) < 0.000_001)
        #expect(abs(state.y - 0.8) < 0.000_001)
    }

    @Test func soloArcadeEliminationCompletesImmediately() throws {
        let playerID = PlayerID(0)
        var events: [GameEvent] = []
        let session = ArcadeChallengeSession(
            mode: .lastLight,
            supportsMotion: true,
            context: .init(
                participants: [.init(
                    player: .init(id: playerID, displayName: "Ada", colorHex: "#32E6FF"),
                    controllerID: ControllerID()
                )],
                inputs: InputStore(),
                seed: 42,
                modifierID: nil
            ),
            onEvents: { events.append(contentsOf: $0) }
        )
        session.setLivesForTesting(1, playerID: playerID)

        session.loseLifeForTesting(playerID)

        #expect(try #require(session.snapshotForTesting()[playerID]).alive == false)
        #expect(events.contains { if case .completed = $0 { true } else { false } })
    }

    @Test func soloArcadeCupEventRetainsPracticeOutcomeAndGameSubtitle() throws {
        let playerID = PlayerID(0)
        var events: [GameEvent] = []
        let session = ArcadeChallengeSession(
            mode: .lastLight,
            supportsMotion: true,
            context: .init(
                participants: [.init(
                    player: .init(id: playerID, displayName: "Ada", colorHex: "#32E6FF"),
                    controllerID: ControllerID()
                )],
                inputs: InputStore(),
                seed: 42,
                modifierID: nil
            ),
            onEvents: { events.append(contentsOf: $0) }
        )
        session.setLivesForTesting(1, playerID: playerID)

        session.loseLifeForTesting(playerID)

        let completed = try #require(events.compactMap { event -> GameOutcome? in
            if case .completed(let outcome) = event { outcome } else { nil }
        }.first)
        #expect(completed.title == "PRACTICE COMPLETE")
        #expect(completed.subtitle == "Last Light complete")
        #expect(completed.winner == nil)
        #expect(completed.playerOutcomes == [.init(playerID: playerID, outcome: .practice)])
    }

    @Test(arguments: [1, 2])
    func arcadeForfeitUsesSharedEliminationCompletion(playerCount: Int) throws {
        let participants = (0..<playerCount).map { index in
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
        var events: [GameEvent] = []
        let session = ArcadeChallengeSession(
            mode: .snakePit,
            supportsMotion: false,
            context: .init(participants: participants, inputs: InputStore(), seed: 42, modifierID: nil),
            onEvents: { events.append(contentsOf: $0) }
        )

        session.forfeit(PlayerID(0))

        #expect(events.contains(.eliminated(PlayerID(0))))
        let completed = try #require(events.compactMap { event -> GameOutcome? in
            if case .completed(let outcome) = event { outcome } else { nil }
        }.first)
        #expect(completed.winner == (playerCount == 1 ? nil : PlayerID(1)))
    }

    @Test func seededLastLightCollisionsIgnoreDictionaryStorageOrder() {
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
            mode: .lastLight,
            supportsMotion: true,
            context: .init(participants: participants, inputs: InputStore(), seed: 42, modifierID: nil),
            onEvents: { _ in }
        )
        let second = ArcadeChallengeSession(
            mode: .lastLight,
            supportsMotion: true,
            context: .init(participants: participants, inputs: InputStore(), seed: 42, modifierID: nil),
            onEvents: { _ in }
        )
        second.reverseStorageForTesting()
        first.prepareLastLightCollisionForTesting()
        second.prepareLastLightCollisionForTesting()

        first.updateForTesting(0)
        second.updateForTesting(0)

        #expect(first.snapshotForTesting() == second.snapshotForTesting())
    }

    @Test func simultaneousLastLightEliminationsFinishAfterAllCollisionEvents() {
        let participants = (0..<2).map { index in
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
        var events: [GameEvent] = []
        let session = ArcadeChallengeSession(
            mode: .lastLight,
            supportsMotion: true,
            context: .init(participants: participants, inputs: InputStore(), seed: 42, modifierID: nil),
            onEvents: { events.append(contentsOf: $0) }
        )
        for participant in participants {
            session.setLivesForTesting(1, playerID: participant.player.id)
        }
        session.prepareLastLightCollisionForTesting()

        session.updateForTesting(0)

        #expect(events.compactMap { event -> PlayerID? in
            if case .eliminated(let playerID) = event { playerID } else { nil }
        } == participants.map(\.player.id))
        #expect(events.count(where: { if case .completed = $0 { true } else { false } }) == 1)
        #expect(events.last.map { if case .completed = $0 { true } else { false } } == true)
        let completedEventCount = events.count
        session.updateForTesting(1)
        #expect(events.count == completedEventCount)
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
            supportsMotion: false,
            context: .init(participants: participants, inputs: InputStore(), seed: 42, modifierID: nil),
            onEvents: { _ in }
        )
        let second = ArcadeChallengeSession(
            mode: .snakePit,
            supportsMotion: false,
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
            supportsMotion: false,
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
        let games = PartyGames.all()

        for game in games {
            let session = game.makeSession(context: context, onEvents: { _ in })
            for participant in participants {
                let screen = session.controllerScreen(for: participant.player.id)
                #expect(screen.isValid, "\(game.descriptor.title) must publish a valid controller screen")
                #expect(screen.requestedInputs == (game.descriptor.supportsMotion ? .orientation : []))
                #expect(session.botInput(
                    for: participant.player.id,
                    difficulty: .normal,
                    deltaTime: .milliseconds(16)
                ) != nil, "\(game.descriptor.title) must drive every bot")
            }
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
            PongGameSession(supportsMotion: true, context: .init(
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
