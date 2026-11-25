import Foundation
import PartyBoxCore
import PartyGameRuntime
import PartyNet
import Testing
@testable import PartyGames

@Suite("Hot Fuse")
@MainActor
struct HotFuseTests {
    private let frame = 1.0 / 60.0
    private let center = ArcadeArena.center
    private let bomb = HotFuseSimulation.bombColor

    /// A started simulation (opening cues already drained) with a known carrier.
    private func started(_ count: Int, seed: UInt64 = 1, carrier: PlayerID = PlayerID(0)) -> HotFuseSimulation {
        var simulation = HotFuseSimulation(players: ArcadeHarness.playerIDs(count), seed: seed)
        _ = simulation.step(deltaTime: 0, inputs: [:])
        // Single-life players keep these tests about bomb mechanics; lives have their own test.
        for playerID in ArcadeHarness.playerIDs(count) { simulation.setLivesForTesting(1, playerID: playerID) }
        simulation.setCarrierForTesting(carrier)
        simulation.setFuseForTesting(length: 30)
        return simulation
    }

    @discardableResult
    private func advance(
        _ simulation: inout HotFuseSimulation,
        seconds: Double,
        inputs: [PlayerID: ArcadeInput] = [:]
    ) -> [ArcadeEvent] {
        var events: [ArcadeEvent] = []
        var remaining = seconds
        while remaining > 0.000_001, !simulation.isFinished {
            let delta = min(frame, remaining)
            events += simulation.step(deltaTime: delta, inputs: inputs)
            remaining -= delta
        }
        return events
    }

    private func isClose(_ lhs: ClosedRange<Double>, _ rhs: ClosedRange<Double>) -> Bool {
        abs(lhs.lowerBound - rhs.lowerBound) < 0.000_1 && abs(lhs.upperBound - rhs.upperBound) < 0.000_1
    }

    // MARK: Passing

    @Test func contactPassesTheBombAndBlocksAnInstantTagBack() {
        let holder = PlayerID(0)
        let runner = PlayerID(1)
        var simulation = started(3, carrier: holder)
        simulation.placeForTesting(holder, at: center)
        simulation.placeForTesting(runner, at: center + ArcadeVector(x: 60, y: 0))
        simulation.placeForTesting(PlayerID(2), at: center + ArcadeVector(x: -560, y: 280))

        let events = simulation.step(deltaTime: frame, inputs: [:])

        #expect(simulation.carrier == runner)
        #expect(events.contains(.cue(runner, colorHex: bomb, haptic: .heavyImpact)))
        #expect(events.contains(.sound(.lightImpact)))
        #expect(simulation.player(for: holder)?.passes == 1)
        #expect(simulation.player(for: runner)?.passes == 0)
        #expect(simulation.player(for: holder)?.isImmune == true)
        #expect(simulation.scoreLine(for: runner) == "0  💣")
        #expect(simulation.scoreLine(for: holder) == "1")

        // Both bounce apart a little.
        advance(&simulation, seconds: 0.1)
        let holderPosition = simulation.player(for: holder)?.position ?? .zero
        let runnerPosition = simulation.player(for: runner)?.position ?? .zero
        #expect(holderPosition.distance(to: runnerPosition) > (HotFuseSimulation.playerRadius * 2) + 20)

        // Pressing straight back into the old holder does nothing inside 0.6s.
        for _ in 0..<24 {
            simulation.placeForTesting(holder, at: center)
            simulation.placeForTesting(runner, at: center + ArcadeVector(x: 50, y: 0))
            _ = simulation.step(deltaTime: frame, inputs: [:])
            #expect(simulation.carrier == runner)
        }

        // Once the shield drops, contact passes it back.
        advance(&simulation, seconds: 0.25)
        #expect(simulation.player(for: holder)?.isImmune == false)
        simulation.placeForTesting(holder, at: center)
        simulation.placeForTesting(runner, at: center + ArcadeVector(x: 50, y: 0))
        _ = simulation.step(deltaTime: frame, inputs: [:])
        #expect(simulation.carrier == holder)
        #expect(simulation.player(for: runner)?.passes == 1)
    }

    @Test func carrierRunsFasterAndBumpersAreSolid() {
        var simulation = started(2, carrier: PlayerID(0))
        simulation.placeForTesting(PlayerID(0), at: center + ArcadeVector(x: 0, y: 300))
        simulation.placeForTesting(PlayerID(1), at: center + ArcadeVector(x: 0, y: -300))
        let right = ArcadeInput(axisX: 1, axisY: 0)
        advance(&simulation, seconds: 0.5, inputs: [PlayerID(0): right, PlayerID(1): right])

        let carrierX = (simulation.player(for: PlayerID(0))?.position.x ?? 0) - center.x
        let runnerX = (simulation.player(for: PlayerID(1))?.position.x ?? 0) - center.x
        #expect(abs(carrierX - 275) < 1)
        #expect(abs(runnerX - 250) < 1)

        // Driving into a bumper slides around it instead of passing through.
        let bumper = HotFuseSimulation.bumpers[3]
        simulation.placeForTesting(PlayerID(1), at: bumper + ArcadeVector(x: -200, y: 20))
        advance(&simulation, seconds: 1.5, inputs: [PlayerID(1): right])
        let position = simulation.player(for: PlayerID(1))?.position ?? bumper
        #expect(position.distance(to: bumper) >= HotFuseSimulation.bumperRadius + HotFuseSimulation.playerRadius - 0.001)
        #expect(position.x > bumper.x)

        // Sticks inside the dead zone do nothing.
        let before = simulation.player(for: PlayerID(1))?.position
        advance(&simulation, seconds: 0.2, inputs: [PlayerID(1): ArcadeInput(axisX: 0.1, axisY: 0.05)])
        #expect(simulation.player(for: PlayerID(1))?.position == before)
    }

    // MARK: Boom

    @Test func boomEliminatesTheCarrierAndTheNextBombGoesToTheSurvivorNearestTheBlast() {
        let holder = PlayerID(0)
        let near = PlayerID(1)
        var simulation = started(4, carrier: holder)
        let blast = center + ArcadeVector(x: -200, y: 0)
        simulation.placeForTesting(holder, at: blast)
        simulation.placeForTesting(near, at: center + ArcadeVector(x: -200, y: 250))
        simulation.placeForTesting(PlayerID(2), at: center + ArcadeVector(x: 300, y: 0))
        simulation.placeForTesting(PlayerID(3), at: center + ArcadeVector(x: 100, y: -260))
        simulation.setFuseForTesting(length: 5, elapsed: 4.995)

        let boom = simulation.step(deltaTime: frame, inputs: [:])

        #expect(boom.contains(.eliminated(holder)))
        #expect(boom.contains(.sound(.heavyImpact)))
        #expect(boom.contains(.banner("NEXT FUSE")))
        #expect(!simulation.isActive(holder))
        #expect(simulation.carrier == nil)
        #expect(simulation.lastBlast?.position == blast)
        #expect(simulation.lastBlast?.playerID == holder)
        #expect(!simulation.isFinished)
        #expect(simulation.timeRemaining == nil)

        let pause = advance(&simulation, seconds: 1.1)
        #expect(simulation.carrier == nil)
        #expect(!pause.contains { if case .cue = $0 { true } else { false } })

        let next = advance(&simulation, seconds: 0.2)
        #expect(simulation.carrier == near)
        #expect(simulation.round == 2)
        #expect(next.contains(.cue(near, colorHex: bomb, haptic: .heavyImpact)))
        #expect(HotFuseSimulation.fuseWindow(forRound: 2).contains(simulation.fuseLength))
        #expect(simulation.player(for: holder)?.eliminatedInRound == 1)
    }

    @Test func smallGroupsSurviveBoomsOnSpareLivesAndThePassMovesOn() {
        #expect(HotFuseSimulation.startingLives(playerCount: 2) == 3)
        #expect(HotFuseSimulation.startingLives(playerCount: 4) == 2)
        #expect(HotFuseSimulation.startingLives(playerCount: 5) == 1)
        let holder = PlayerID(0)
        let other = PlayerID(1)
        var simulation = HotFuseSimulation(players: [holder, other], seed: 3)
        _ = simulation.step(deltaTime: 0, inputs: [:])
        simulation.setCarrierForTesting(holder)
        simulation.placeForTesting(holder, at: center)
        simulation.placeForTesting(other, at: center + ArcadeVector(x: 500, y: 0))
        simulation.setFuseForTesting(length: 1, elapsed: 0.999)

        let boom = simulation.step(deltaTime: frame, inputs: [:])

        #expect(boom.contains(.lostLife(holder, remaining: 2)))
        #expect(!boom.contains(.eliminated(holder)))
        #expect(simulation.isActive(holder))
        #expect(simulation.scoreLine(for: holder).hasPrefix("◆◆"))
        advance(&simulation, seconds: 1.3)
        #expect(simulation.carrier == other, "The survivor standing on the blast is skipped")

        // Two players with three lives each: at most five more booms settle it.
        for _ in 0..<5 where !simulation.isFinished {
            #expect(simulation.carrier != nil)
            simulation.setFuseForTesting(length: 1, elapsed: 0.999)
            _ = simulation.step(deltaTime: frame, inputs: [:])
            if !simulation.isFinished { advance(&simulation, seconds: 1.3) }
        }
        #expect(simulation.isFinished)
        #expect(simulation.ranking().last.map { simulation.player(for: $0.playerID)?.lives } == 0)
    }

    @Test func lastSurvivorWinsAndRanksFirst() {
        var simulation = started(3, carrier: PlayerID(2))
        simulation.placeForTesting(PlayerID(2), at: center)
        simulation.setFuseForTesting(length: 1, elapsed: 0.999)
        _ = simulation.step(deltaTime: frame, inputs: [:])
        advance(&simulation, seconds: 1.3)
        let second = simulation.carrier
        #expect(second != nil)
        simulation.setFuseForTesting(length: 1, elapsed: 0.999)
        _ = simulation.step(deltaTime: frame, inputs: [:])

        #expect(simulation.isFinished)
        let ranking = simulation.ranking()
        let survivor = ranking.first?.playerID
        #expect(survivor != nil && survivor != second && survivor != PlayerID(2))
        #expect(Array(ranking.map(\.playerID).dropFirst()) == [second, PlayerID(2)].compactMap { $0 })
        #expect(ranking.first?.detail.hasSuffix("survived") == true)
        #expect(simulation.resultMetric.label == "Most passes")
    }

    @Test func carrierForfeitStartsTheIntermissionInsteadOfStrandingTheBomb() {
        var simulation = started(3, carrier: PlayerID(1))
        simulation.placeForTesting(PlayerID(1), at: center)
        simulation.placeForTesting(PlayerID(2), at: center + ArcadeVector(x: 150, y: 0))
        simulation.placeForTesting(PlayerID(0), at: center + ArcadeVector(x: -560, y: 0))

        let events = simulation.forfeit(PlayerID(1))

        #expect(events == [.eliminated(PlayerID(1)), .banner("NEXT FUSE")])
        #expect(simulation.carrier == nil)
        #expect(simulation.forfeit(PlayerID(1)).isEmpty)
        advance(&simulation, seconds: 1.3)
        #expect(simulation.carrier == PlayerID(2))
    }

    // MARK: Fuse

    @Test func fuseWindowShrinksEachRoundDownToTheFloor() {
        #expect(isClose(HotFuseSimulation.fuseWindow(forRound: 1), 7...11))
        #expect(isClose(HotFuseSimulation.fuseWindow(forRound: 2), 6.2...10.2))
        #expect(isClose(HotFuseSimulation.fuseWindow(forRound: 3), 5.4...9.4))
        #expect(isClose(HotFuseSimulation.fuseWindow(forRound: 5), 4...7.8))
        #expect(isClose(HotFuseSimulation.fuseWindow(forRound: 7), 4...6.2))
        #expect(isClose(HotFuseSimulation.fuseWindow(forRound: 8), 4...6))
        #expect(isClose(HotFuseSimulation.fuseWindow(forRound: 40), 4...6))
        for round in 1..<12 {
            let window = HotFuseSimulation.fuseWindow(forRound: round)
            let later = HotFuseSimulation.fuseWindow(forRound: round + 1)
            #expect(later.lowerBound <= window.lowerBound && later.upperBound <= window.upperBound)
        }

        // Round 1 is a seeded random carrier and length in 7–11s.
        var carriers: Set<PlayerID> = []
        var lengths: Set<Double> = []
        for seed in UInt64(0)..<40 {
            let simulation = HotFuseSimulation(players: ArcadeHarness.playerIDs(8), seed: seed)
            #expect((7...11).contains(simulation.fuseLength))
            if let carrier = simulation.carrier { carriers.insert(carrier) }
            lengths.insert(simulation.fuseLength)
        }
        #expect(carriers.count >= 4)
        #expect(lengths.count == 40)

        // Every drawn fuse lands inside its round's window.
        var simulation = HotFuseSimulation(players: ArcadeHarness.playerIDs(8), seed: 77)
        var rounds: [Int] = []
        while !simulation.isFinished {
            #expect(HotFuseSimulation.fuseWindow(forRound: simulation.round).contains(simulation.fuseLength))
            rounds.append(simulation.round)
            simulation.setFuseForTesting(length: simulation.fuseLength, elapsed: simulation.fuseLength - 0.001)
            _ = simulation.step(deltaTime: frame, inputs: [:])
            advance(&simulation, seconds: 1.3)
        }
        #expect(rounds == Array(1...7))
    }

    @Test func carrierGetsOneHapticTickPerWholeSecond() {
        let holder = PlayerID(0)
        var simulation = started(2, carrier: holder)
        simulation.placeForTesting(holder, at: center + ArcadeVector(x: -540, y: 0))
        simulation.placeForTesting(PlayerID(1), at: center + ArcadeVector(x: 540, y: 0))
        simulation.setFuseForTesting(length: 5.5)

        var ticks: [Double] = []
        for _ in 0..<180 {
            for event in simulation.step(deltaTime: frame, inputs: [:]) {
                if case .haptic(let playerID, let pattern) = event {
                    #expect(playerID == holder)
                    #expect(pattern == .lightImpact)
                    ticks.append(simulation.elapsed)
                }
            }
        }

        #expect(ticks.count == 3)
        #expect(abs((ticks.first ?? 0) - 0.5) < 0.02)
        for (earlier, later) in zip(ticks, ticks.dropFirst()) {
            #expect(abs((later - earlier) - 1) < 0.02)
        }
    }

    @Test func pulseRateTracksTheElapsedFraction() {
        #expect(HotFuseSimulation.pulseRate(progress: 0) < HotFuseSimulation.pulseRate(progress: 0.5))
        #expect(HotFuseSimulation.pulseRate(progress: 0.5) < HotFuseSimulation.pulseRate(progress: 0.95))
        #expect(HotFuseSimulation.pulseRate(progress: 2) == HotFuseSimulation.pulseRate(progress: 1))

        // Two fuses at the same fraction pulse at the same rate regardless of length.
        var short = started(2)
        short.setFuseForTesting(length: 4)
        var long = started(2)
        long.setFuseForTesting(length: 8)
        advance(&short, seconds: 2)
        advance(&long, seconds: 4)
        #expect(abs(short.fuseProgress - long.fuseProgress) < 0.01)
    }

    // MARK: Solo drill

    @Test func soloDrillTagsDronesShortensTheFuseAndEndsOnTheBoom() throws {
        let runner = PlayerID(0)
        var simulation = HotFuseSimulation(players: [runner], seed: 9)
        #expect(simulation.isDrill)
        #expect(simulation.drones.count == 3)
        #expect(simulation.carrier == runner)
        let opening = simulation.step(deltaTime: 0, inputs: [:])
        #expect(opening.contains(.banner("DEFUSE DRILL")))
        let firstFuse = simulation.fuseLength
        #expect((7...11).contains(firstFuse))

        advance(&simulation, seconds: 1)
        simulation.placeForTesting(runner, at: center)
        simulation.placeDroneForTesting(0, at: center + ArcadeVector(x: 40, y: 0))
        let tag = simulation.step(deltaTime: frame, inputs: [:])

        #expect(simulation.player(for: runner)?.passes == 1)
        #expect(abs(simulation.fuseLength - (firstFuse * 0.9)) < 0.000_001)
        #expect(simulation.fuseElapsed == 0)
        #expect(tag.contains(.sound(.lightImpact)))
        let drone = try #require(simulation.drones.first)
        #expect(drone.generation == 1)
        #expect(drone.position.distance(to: center) > 300)
        #expect(simulation.carrier == runner)

        simulation.placeDroneForTesting(1, at: center + ArcadeVector(x: 0, y: -40))
        _ = simulation.step(deltaTime: frame, inputs: [:])
        #expect(simulation.player(for: runner)?.passes == 2)
        #expect(abs(simulation.fuseLength - (firstFuse * 0.81)) < 0.000_001)

        simulation.setFuseForTesting(length: simulation.fuseLength, elapsed: simulation.fuseLength - 0.001)
        let boom = simulation.step(deltaTime: frame, inputs: [:])
        #expect(boom.contains(.eliminated(runner)))
        #expect(boom.contains(.sound(.heavyImpact)))
        #expect(!boom.contains(.banner("NEXT FUSE")))
        #expect(simulation.isFinished)
        #expect(simulation.ranking().map(\.score) == [2])
    }

    @Test func soloDrillDronesFleeAndAHardBotStillTagsThem() throws {
        var simulation = HotFuseSimulation(players: [PlayerID(0)], seed: 4)
        simulation.placeDroneForTesting(0, at: center + ArcadeVector(x: 120, y: 0))
        advance(&simulation, seconds: 0.2)
        #expect((simulation.drones.first?.position.distance(to: center) ?? 0) > 160)

        let result = ArcadeHarness.playOut(HotFuseGame(), players: 1, difficulty: .hard)
        let outcome = try #require(result.outcome)
        #expect(outcome.title == "PRACTICE COMPLETE")
        #expect((outcome.standings.first?.score ?? 0) >= 3)
    }

    // MARK: Determinism and bots

    @Test func sameSeedAndScriptedInputsReplayIdentically() {
        func run(seed: UInt64) -> (HotFuseSimulation, [ArcadeEvent]) {
            let playerIDs = ArcadeHarness.playerIDs(5)
            var simulation = HotFuseSimulation(players: playerIDs, seed: seed)
            var botRandom = ArcadeRandomNumberGenerator(seed: seed &+ 99)
            var events: [ArcadeEvent] = []
            for index in 0..<1_500 {
                let time = Double(index) * frame
                var inputs: [PlayerID: ArcadeInput] = [:]
                for (offset, playerID) in playerIDs.enumerated() {
                    if offset < 3 {
                        let phase = Double(offset)
                        inputs[playerID] = ArcadeInput(axisX: sin((time * (1 + (0.3 * phase))) + phase), axisY: cos(time * (0.7 + (0.2 * phase))))
                    } else {
                        let decision = simulation.botDecision(for: playerID, difficulty: .easy, random: &botRandom)
                        inputs[playerID] = ArcadeInput(axisX: decision.axisX, axisY: decision.axisY)
                    }
                }
                events += simulation.step(deltaTime: frame, inputs: inputs)
            }
            return (simulation, events)
        }

        let first = run(seed: 11)
        let second = run(seed: 11)
        #expect(first.0 == second.0)
        #expect(first.1 == second.1)
        #expect(first.1.contains { if case .cue = $0 { true } else { false } })
        #expect(run(seed: 12).0 != first.0)
    }

    @Test func eightHardBotsPlayDownToOneSurvivor() throws {
        let result = ArcadeHarness.playOut(HotFuseGame(), players: 8, difficulty: .hard)
        let outcome = try #require(result.outcome)
        #expect(result.seconds < 150)
        #expect(outcome.standings.count == 8)
        #expect(Set(result.eliminated).count == 7)

        let survivor = ArcadeHarness.playerIDs(8).first { !result.eliminated.contains($0) }
        #expect(outcome.standings.first?.playerID == survivor)
        #expect(outcome.winner == survivor)
        #expect(outcome.standings.dropFirst().map(\.playerID) == Array(result.eliminated.reversed()))
        #expect(outcome.metrics.first?.label == "Most passes")
        #expect(outcome.standings.map(\.score).reduce(0, +) >= 7)
    }

    @Test func twoPlayerMatchPlaysOut() throws {
        let result = ArcadeHarness.playOut(HotFuseGame(), players: 2)
        let outcome = try #require(result.outcome)
        #expect(outcome.standings.count == 2)
        #expect(result.eliminated.count == 1)
        #expect(outcome.winner == outcome.standings.first?.playerID)
        #expect(outcome.winner != result.eliminated.first)
    }

    @Test func carrierBotChasesAndRunnerBotsFlee() {
        var simulation = started(3, carrier: PlayerID(0))
        simulation.placeForTesting(PlayerID(0), at: center)
        simulation.placeForTesting(PlayerID(1), at: center + ArcadeVector(x: 250, y: 0))
        simulation.placeForTesting(PlayerID(2), at: center + ArcadeVector(x: -560, y: 280))
        var random = ArcadeRandomNumberGenerator(seed: 1)

        let chase = simulation.botDecision(for: PlayerID(0), difficulty: .hard, random: &random)
        let flee = simulation.botDecision(for: PlayerID(1), difficulty: .hard, random: &random)
        let normal = simulation.botDecision(for: PlayerID(0), difficulty: .normal, random: &random)
        let easy = simulation.botDecision(for: PlayerID(0), difficulty: .easy, random: &random)

        #expect(chase.axisX > 0.9)
        #expect(flee.axisX > 0.5)
        #expect(abs(ArcadeVector(x: chase.axisX, y: chase.axisY).length - 1) < 0.001)
        #expect(abs(ArcadeVector(x: normal.axisX, y: normal.axisY).length - 0.95) < 0.001)
        #expect(ArcadeVector(x: easy.axisX, y: easy.axisY).length <= 0.85 + 0.001)
        #expect(HotFuseSimulation.botReactionInterval(for: .easy) == 0.3)
        #expect(HotFuseSimulation.botReactionInterval(for: .normal) == 0.15)
        #expect(HotFuseSimulation.botReactionInterval(for: .hard) == 0.08)
    }

    // MARK: Phone

    @Test func controllerUsesAHeadingSwipeSurfaceWithMotion() throws {
        let game = HotFuseGame()
        #expect(game.descriptor.id == "hot-fuse")
        #expect(game.descriptor.title == "HOT FUSE")
        #expect(game.descriptor.estimatedDurationSeconds == 75)
        #expect(game.descriptor.supportsMotion)
        let session = game.makeSession(
            context: .init(participants: ArcadeHarness.participants(2), inputs: InputStore(), seed: 1, modifierID: nil),
            onEvents: { _ in }
        )
        let screen = session.controllerScreen(for: PlayerID(0))
        #expect(screen.isValid)
        #expect(screen.accessibilityID == "controller.layout.hot-fuse")
        #expect(screen.requestedInputs == .orientation)
        #expect(screen.components.contains(.axisSurface(.init(
            id: "fuse.steer",
            binding: .twoDimensional,
            instruction: "DRAG TO RUN  •  MOTION OPTIONAL",
            swipe: .heading
        ))))
        #expect(screen.components.contains(.text(.init(
            id: "fuse.rule",
            text: "PASS THE BOMB • DON'T HOLD IT AT THE BOOM",
            style: .caption,
            tint: .secondary
        ))))
    }
}
