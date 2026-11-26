import Foundation
import PartyBoxCore
import PartyGameRuntime
import PartyNet
import Testing
@testable import PartyGames

@Suite("Sky Hop")
@MainActor
struct SkyHopTests {
    private typealias Sim = SkyHopSimulation
    private let frame = 1.0 / 60.0
    private let tolerance = 0.000_001

    private func press(_ playerIDs: PlayerID...) -> [PlayerID: ArcadeInput] {
        Dictionary(uniqueKeysWithValues: playerIDs.map { ($0, ArcadeInput(pressed: true)) })
    }

    /// A gate far off to the right so a test's course stays empty and nothing
    /// new spawns while it runs.
    private func farGate(id: Int) -> Sim.Gate {
        Sim.Gate(id: id, x: 5_000, gapCenter: ArcadeArena.center.y, gapHeight: 300)
    }

    // MARK: Physics

    @Test func gravityPullsDownAndAFlapSetsUpwardVelocity() throws {
        let playerID = PlayerID(0)
        var sim = Sim(players: [playerID], seed: 1)
        let start = try #require(sim.bird(for: playerID))
        #expect(start.y == ArcadeArena.center.y)
        #expect(start.vy == 0)
        #expect(start.x == Sim.birdStartX)
        sim.placeForTesting(playerID, y: start.y)

        _ = sim.step(deltaTime: frame, inputs: [:])
        let falling = try #require(sim.bird(for: playerID))
        #expect(abs(falling.vy - (-Sim.gravity * frame)) < tolerance)
        #expect(abs(falling.y - (start.y - Sim.gravity * frame * frame)) < tolerance)

        _ = sim.step(deltaTime: frame, inputs: press(playerID))
        let flapped = try #require(sim.bird(for: playerID))
        #expect(flapped.vy == Sim.flapVelocity)
        #expect(abs(flapped.y - (falling.y + Sim.flapVelocity * frame)) < tolerance)

        _ = sim.step(deltaTime: frame, inputs: [:])
        let rising = try #require(sim.bird(for: playerID))
        #expect(abs(rising.vy - (Sim.flapVelocity - Sim.gravity * frame)) < tolerance)
        #expect(rising.y > flapped.y)
    }

    @Test func fallSpeedIsCappedAtTerminalVelocity() throws {
        let playerID = PlayerID(0)
        var sim = Sim(players: [playerID], seed: 1)
        sim.setGatesForTesting([farGate(id: 1)])
        sim.placeForTesting(playerID, y: 880, vy: 0)
        for _ in 0..<30 {
            _ = sim.step(deltaTime: frame, inputs: [:])
        }
        let bird = try #require(sim.bird(for: playerID))
        #expect(bird.alive)
        #expect(bird.vy == -Sim.terminalFallSpeed)
    }

    @Test func birdsShareAFlightLineAcrossTheCorridor() {
        let sim = Sim(players: ArcadeHarness.playerIDs(8), seed: 1)
        #expect(sim.birds.allSatisfy { $0.x == Sim.birdStartX })
        #expect(sim.birds.allSatisfy { $0.y == ArcadeArena.center.y && $0.vy == 0 && $0.alive })
        #expect(sim.gates.first?.x == Sim.firstGateX)
    }

    // MARK: Crashes

    @Test func ceilingAndFloorCrashesEliminateTheBird() {
        let ids = ArcadeHarness.playerIDs(3)
        var sim = Sim(players: ids, seed: 1)
        sim.setGatesForTesting([farGate(id: 1)])
        sim.placeForTesting(ids[0], y: ArcadeArena.maxY - Sim.birdRadius - 1, vy: Sim.flapVelocity)

        let ceiling = sim.step(deltaTime: frame, inputs: [:])

        #expect(ceiling.contains(.eliminated(ids[0])))
        #expect(!sim.isActive(ids[0]))
        #expect(sim.isActive(ids[1]) && sim.isActive(ids[2]))
        #expect(!sim.isFinished)

        sim.placeForTesting(ids[1], y: ArcadeArena.minY + Sim.birdRadius + 1, vy: -Sim.terminalFallSpeed)
        let floor = sim.step(deltaTime: frame, inputs: [:])

        #expect(floor.contains(.eliminated(ids[1])))
        #expect(!floor.contains(.eliminated(ids[0])))
        #expect(!sim.isActive(ids[1]))
        #expect(sim.bird(for: ids[1])?.crashedAt == sim.elapsed)
    }

    @Test func pillarContactEliminatesButTheGapIsSafe() throws {
        let playerID = PlayerID(0)
        let birdFront = Sim.birdStartX + Sim.birdRadius
        func run(gapCenter: Double) -> (Sim, [ArcadeEvent]) {
            var sim = Sim(players: [playerID], seed: 1)
            sim.setGatesForTesting([
                Sim.Gate(id: 1, x: birdFront + 2, gapCenter: gapCenter, gapHeight: 200),
                farGate(id: 2),
            ])
            let events = (0..<3).flatMap { _ in sim.step(deltaTime: frame, inputs: [:]) }
            return (sim, events)
        }

        let (blocked, hit) = run(gapCenter: 800)
        #expect(hit == [.eliminated(playerID)])
        #expect(!blocked.isActive(playerID))
        #expect(blocked.isFinished, "a solo flight ends on its first crash")

        let (clear, events) = run(gapCenter: ArcadeArena.center.y)
        #expect(events.isEmpty)
        #expect(clear.isActive(playerID))

        var upper = Sim(players: [playerID], seed: 1)
        upper.setGatesForTesting([
            Sim.Gate(id: 1, x: birdFront + 2, gapCenter: 300, gapHeight: 200),
            farGate(id: 2),
        ])
        _ = upper.step(deltaTime: frame, inputs: [:])
        #expect(!upper.isActive(playerID), "the upper pillar is solid too")
    }

    // MARK: Scoring

    @Test func clearingAGateTrailingEdgeScoresOnce() throws {
        let playerID = PlayerID(0)
        var sim = Sim(players: [playerID], seed: 1)
        let tail = Sim.birdStartX - Sim.birdRadius
        sim.setGatesForTesting([
            Sim.Gate(id: 1, x: tail - Sim.pillarWidth + 2, gapCenter: ArcadeArena.center.y, gapHeight: 300),
            farGate(id: 2),
        ])

        let passed = sim.step(deltaTime: frame, inputs: [:])

        #expect(passed == [.cue(playerID, colorHex: ArcadeOutcomeBuilder.winnerColor, haptic: .lightImpact)])
        let bird = try #require(sim.bird(for: playerID))
        #expect(bird.gates == 1)
        #expect(bird.score == 10)
        #expect(sim.scoreLine(for: playerID) == "1")

        let later = (0..<10).flatMap { _ in sim.step(deltaTime: frame, inputs: [:]) }
        #expect(later.isEmpty)
        #expect(sim.bird(for: playerID)?.gates == 1)
        #expect(sim.resultMetric == .init(id: "most-gates", label: "Most gates", value: "1"))
    }

    @Test func equallyPlacedBirdsScoreAndCrashAtTheSameTime() {
        let ids = ArcadeHarness.playerIDs(2)
        var sim = Sim(players: ids, seed: 1)
        let birdTail = Sim.birdStartX - Sim.birdRadius
        sim.setGatesForTesting([
            Sim.Gate(id: 1, x: birdTail - Sim.pillarWidth + 2, gapCenter: ArcadeArena.center.y, gapHeight: 300),
            farGate(id: 2),
        ])

        let first = sim.step(deltaTime: frame, inputs: [:])
        #expect(first == ids.map { .cue($0, colorHex: ArcadeOutcomeBuilder.winnerColor, haptic: .lightImpact) })
        #expect(sim.birds.map(\.gates) == [1, 1])

        sim.setGatesForTesting([
            Sim.Gate(id: 2, x: Sim.birdStartX + Sim.birdRadius + 2, gapCenter: 800, gapHeight: 200),
            farGate(id: 3),
        ])
        let crashes = sim.step(deltaTime: frame, inputs: [:])
        #expect(crashes == ids.map { .eliminated($0) })
        #expect(sim.birds[0].crashedAt == sim.birds[1].crashedAt)
        #expect(sim.ranking().map(\.playerID) == ids)
    }

    // MARK: Course generation

    @Test func everyGeneratedGapIsReachableAndInsideTheCorridor() {
        let floor = ArcadeArena.minY + Sim.gapMargin
        let ceiling = ArcadeArena.maxY - Sim.gapMargin
        for seed in UInt64(0)...50 {
            var sim = Sim(players: [], seed: seed)
            var course: [Int: Sim.Gate] = [:]
            while !sim.isFinished {
                for gate in sim.gates where course[gate.id] == nil {
                    course[gate.id] = gate
                }
                _ = sim.step(deltaTime: frame, inputs: [:])
            }
            let gates = course.values.sorted { $0.id < $1.id }
            #expect(gates.count > 80, "seed \(seed) should generate a full 90s course")
            #expect(gates.map(\.id) == Array(1...gates.count))
            var previous = ArcadeArena.center.y
            for gate in gates {
                #expect(abs(gate.gapCenter - previous) <= Sim.maximumGapShift + tolerance, "seed \(seed) gate \(gate.id)")
                #expect(gate.gapBottom >= floor - tolerance, "seed \(seed) gate \(gate.id)")
                #expect(gate.gapTop <= ceiling + tolerance, "seed \(seed) gate \(gate.id)")
                #expect((175.0...300.0).contains(gate.gapHeight))
                previous = gate.gapCenter
            }
        }
    }

    @Test func difficultyRampsRunFromStartToFiftySeconds() {
        #expect(Sim.scrollSpeed(at: 0) == 360)
        #expect(Sim.scrollSpeed(at: 50) == 700)
        #expect(Sim.scrollSpeed(at: 80) == 700)
        #expect(Sim.gapHeight(at: 0) == 300)
        #expect(Sim.gapHeight(at: 50) == 175)
        #expect(Sim.gateSpacing(at: 0) == 560)
        #expect(Sim.gateSpacing(at: 50) == 400)

        var early = Sim(players: [], seed: 9)
        #expect(early.gates.count >= 2)
        #expect(early.gates[0].gapHeight == 300)
        #expect(abs(early.gates[1].x - early.gates[0].x - 560) < tolerance)

        early.setElapsedForTesting(55)
        let newest = early.gates.map(\.id).max() ?? 0
        while early.gates.last.map({ $0.id <= newest }) ?? true {
            _ = early.step(deltaTime: frame, inputs: [:])
        }
        let count = early.gates.count
        #expect(early.gates[count - 1].gapHeight == 175)
        #expect(abs(early.gates[count - 1].x - early.gates[count - 2].x - 400) < tolerance)
        #expect(early.scrollSpeed == 700)
    }

    @Test func bannersAnnounceEachSpeedStage() {
        var sim = Sim(players: [], seed: 1)
        var banners: [String] = []
        for start in [14.99, 29.99, 44.99] {
            sim.setElapsedForTesting(start)
            for case .banner(let text) in sim.step(deltaTime: 0.02, inputs: [:]) {
                banners.append(text)
            }
        }
        #expect(banners == ["FASTER!", "FASTER!", "MAX SPEED"])
    }

    // MARK: Match flow

    @Test func multiplayerEndsWhenOneBirdIsLeftAndRanksBySurvival() {
        let ids = ArcadeHarness.playerIDs(3)
        var sim = Sim(players: ids, seed: 1)
        sim.setGatesForTesting([farGate(id: 1)])

        sim.placeForTesting(ids[1], y: ArcadeArena.minY + Sim.birdRadius, vy: -Sim.terminalFallSpeed)
        _ = sim.step(deltaTime: frame, inputs: [:])
        #expect(!sim.isFinished)

        sim.placeForTesting(ids[0], y: ArcadeArena.minY + Sim.birdRadius, vy: -Sim.terminalFallSpeed)
        sim.placeForTesting(ids[2], y: ArcadeArena.center.y)
        _ = sim.step(deltaTime: frame, inputs: [:])

        #expect(sim.isFinished)
        #expect((sim.timeRemaining ?? 0) > 80)
        #expect(sim.ranking().map(\.playerID) == [ids[2], ids[0], ids[1]])
        #expect(sim.ranking().first?.detail == "0 gates • still flying")
        #expect(sim.step(deltaTime: frame, inputs: [:]).isEmpty, "a finished match is frozen")
    }

    @Test func birdsHoverAfterGoUntilTheirFirstFlapOrTheGraceRunsOut() throws {
        let ids = [PlayerID(0), PlayerID(1)]
        var sim = Sim(players: ids, seed: 1)
        sim.setGatesForTesting([farGate(id: 1)])
        let startY = try #require(sim.bird(for: ids[0])).y

        for _ in 0..<30 { _ = sim.step(deltaTime: frame, inputs: [:]) }
        #expect(sim.bird(for: ids[0])?.y == startY)
        #expect(sim.bird(for: ids[0])?.vy == 0)

        _ = sim.step(deltaTime: frame, inputs: press(ids[0]))
        #expect(sim.bird(for: ids[0])?.vy == Sim.flapVelocity, "a flap ends the hover at once")
        #expect(sim.bird(for: ids[1])?.y == startY)

        while sim.elapsed < Sim.hoverGrace + frame { _ = sim.step(deltaTime: frame, inputs: [:]) }
        #expect((sim.bird(for: ids[1])?.vy ?? 0) < 0, "the idle bird starts falling once the grace ends")
    }

    @Test func soloFlightEndsOnTheFirstCrash() {
        let playerID = PlayerID(0)
        var sim = Sim(players: [playerID], seed: 1)
        var events: [ArcadeEvent] = []
        while !sim.isFinished, sim.elapsed < 5 {
            events += sim.step(deltaTime: frame, inputs: [:])
        }
        #expect(sim.isFinished)
        #expect(sim.elapsed < Sim.hoverGrace + 1, "after the hover grace an idle bird falls in about half a second")
        #expect(events == [.eliminated(playerID)])
        #expect(sim.ranking().map(\.playerID) == [playerID])
    }

    @Test func hardCapEndsTheMatchAtNinetySeconds() {
        let ids = ArcadeHarness.playerIDs(2)
        var sim = Sim(players: ids, seed: 1)
        sim.setGatesForTesting([farGate(id: 1)])
        sim.setElapsedForTesting(Sim.duration - 0.01)
        _ = sim.step(deltaTime: frame, inputs: [:])
        #expect(sim.isFinished)
        #expect(sim.timeRemaining == 0)
        #expect(ids.allSatisfy(sim.isActive))
    }

    @Test func equalSurvivorsShareFirstAtTheTimeCap() throws {
        var sim = Sim(players: ArcadeHarness.playerIDs(2), seed: 1)
        sim.setGatesForTesting([farGate(id: 1)])
        sim.setElapsedForTesting(Sim.duration - (frame / 2))

        _ = sim.step(deltaTime: frame, inputs: [:])

        #expect(sim.birds.allSatisfy { $0.alive })
        let outcome = try #require(ArcadeHarness.finishedDuel(sim))
        #expect(outcome.winner == nil)
        #expect(outcome.playerOutcomes.map(\.outcome) == [.draw, .draw])
    }

    @Test func simultaneousCrashesWithTheSameScoreEndInADraw() throws {
        let seats = Set(ArcadeHarness.playerIDs(2))
        let match = ArcadeHarness.playOut(SkyHopGame(), players: 2, idle: seats)
        let outcome = try #require(match.outcome)

        #expect(outcome.title == "DRAW")
        #expect(outcome.winner == nil)
        #expect(outcome.standings.map(\.rank) == [1, 1])
        #expect(outcome.playerOutcomes.map(\.outcome) == [.draw, .draw])
        #expect(!match.events.contains { event in
            if case .deviceCue(_, let cue) = event { cue.colorHex == ArcadeOutcomeBuilder.winnerColor } else { false }
        })
    }

    @Test func forfeitEliminatesOnceAndCanDecideTheMatch() {
        let ids = ArcadeHarness.playerIDs(2)
        var sim = Sim(players: ids, seed: 1)
        #expect(sim.forfeit(ids[0]) == [.eliminated(ids[0])])
        #expect(sim.forfeit(ids[0]).isEmpty)
        #expect(sim.isFinished)
        #expect(sim.ranking().map(\.playerID) == [ids[1], ids[0]])
    }

    @Test func phoneFlapsKeepTheLastFlyerAliveToWin() throws {
        var events: [GameEvent] = []
        let session = try #require(SkyHopGame().makeSession(
            context: .init(
                participants: ArcadeHarness.participants(2, kind: .human),
                inputs: InputStore(), seed: 42, modifierID: nil
            ),
            onEvents: { events.append(contentsOf: $0) }
        ) as? ArcadeSession<SkyHopRenderer>)
        session.skipIntroForTesting()

        for _ in 0..<4 where !session.isCompletedForTesting {
            session.handle(action: .init(id: "sky.flap", value: .trigger), from: PlayerID(1))
            session.advanceForTesting(seconds: 0.6)
        }

        #expect(session.isCompletedForTesting)
        #expect(session.simulationForTesting.isActive(PlayerID(1)))
        #expect(events.contains(.eliminated(PlayerID(0))))
        let outcome = try #require(events.compactMap { event -> GameOutcome? in
            if case .completed(let outcome) = event { outcome } else { nil }
        }.first)
        #expect(outcome.winner == PlayerID(1))
        #expect(outcome.standings.map(\.playerID) == [PlayerID(1), PlayerID(0)])
        #expect(outcome.metrics.map(\.label) == ["Most gates"])
    }

    @Test func sameSeedAndInputsReplayIdentically() {
        let ids = ArcadeHarness.playerIDs(3)
        func replay(seed: UInt64) -> (Sim, [[ArcadeEvent]]) {
            var sim = Sim(players: ids, seed: seed)
            var log: [[ArcadeEvent]] = []
            for frameIndex in 0..<900 {
                var inputs: [PlayerID: ArcadeInput] = [:]
                for (offset, playerID) in ids.enumerated() where (frameIndex + offset * 5).isMultiple(of: 19 + offset * 4) {
                    inputs[playerID] = ArcadeInput(pressed: true)
                }
                log.append(sim.step(deltaTime: frame, inputs: inputs))
            }
            return (sim, log)
        }

        let (first, firstLog) = replay(seed: 77)
        let (second, secondLog) = replay(seed: 77)
        #expect(first.birds == second.birds)
        #expect(first.gates == second.gates)
        #expect(first.elapsed == second.elapsed)
        #expect(firstLog == secondLog)

        let (other, _) = replay(seed: 78)
        #expect(other.gates.map(\.gapCenter) != first.gates.map(\.gapCenter))
    }

    // MARK: Session, bots and rendering

    @Test func descriptorAndPhoneControlsMatchTheSpec() {
        let game = SkyHopGame()
        #expect(game.descriptor.id == "sky-hop")
        #expect(game.descriptor.title == "SKY HOP")
        #expect(game.descriptor.summary == "1–8 players  •  Tap to flap through ever-tighter gaps")
        #expect(game.descriptor.supportsMotion == false)
        #expect(game.descriptor.estimatedDurationSeconds == 60)
        #expect(game.descriptor.minimumPlayers == 1)
        #expect(game.descriptor.maximumPlayers == 8)
        #expect(PartyGames.all().contains { $0.descriptor.id == "sky-hop" })
        #expect(SkyHopGame.controls == [
            .text(.init(id: "sky.rule", text: "TAP TO FLAP • LAST ONE FLYING WINS", style: .caption, tint: .secondary)),
            .actionButton(.init(id: "sky.flap", label: "FLAP", route: .game("sky.flap"))),
        ])

        let session = game.makeSession(
            context: .init(participants: ArcadeHarness.participants(1, kind: .human), inputs: InputStore(), seed: 1, modifierID: nil),
            onEvents: { _ in }
        )
        let screen = session.controllerScreen(for: PlayerID(0))
        #expect(screen.isValid)
        #expect(screen.accessibilityID == "controller.layout.sky-hop")
        #expect(screen.requestedInputs == [])
    }

    @Test func eightHardBotsFinishWithFullStandings() throws {
        let result = ArcadeHarness.playOut(SkyHopGame(), players: 8, difficulty: .hard)
        let outcome = try #require(result.outcome)
        #expect(result.seconds < 95)
        #expect(outcome.standings.count == 8)
        #expect(Set(outcome.standings.map(\.playerID)).count == 8)
        #expect(outcome.winner == outcome.standings.first?.playerID)
        #expect(result.eliminated.count >= 7 || result.seconds >= Sim.duration)
    }

    @Test func hardSoloBotReliablyClearsTenGates() throws {
        var gates: [Int] = []
        for seed in UInt64(1)...5 {
            let result = ArcadeHarness.playOut(SkyHopGame(), players: 1, seed: seed, difficulty: .hard)
            let standing = try #require(result.outcome?.standings.first)
            gates.append(standing.score / 10)
        }
        #expect(gates.count { $0 >= 10 } >= 4, "hard bot gates per seed: \(gates)")
    }

    @Test func botDifficultyOrdersHowFarBirdsGet() {
        func median(_ difficulty: GameBotDifficulty) -> Int {
            let scores = (UInt64(1)...7).map { seed in
                (ArcadeHarness.playOut(SkyHopGame(), players: 1, seed: seed, difficulty: difficulty)
                    .outcome?.standings.first?.score ?? 0) / 10
            }
            return scores.sorted()[scores.count / 2]
        }
        let easy = median(.easy)
        let hard = median(.hard)
        #expect(easy >= 1, "easy bots should still clear a gate or two")
        #expect(hard > easy)
    }

    @Test func rendererReusesPillarSpritesFromAPool() {
        let scene = ArcadeScene(title: "SKY HOP", players: [])
        let renderer = SkyHopRenderer()
        var sim = Sim(players: [], seed: 5)
        renderer.build(in: scene, simulation: sim)
        var created = Set<Int>()
        while sim.elapsed < 60 {
            let events = sim.step(deltaTime: frame, inputs: [:])
            renderer.render(sim, events: events, in: scene)
            for gate in sim.gates { created.insert(gate.id) }
        }
        #expect(created.count > 60)
        #expect(renderer.pillarSpriteCountForTesting <= 40, "pillars must come from a small reused pool")
        #expect(renderer.visiblePillarSpriteCountForTesting > 0)
    }
}
