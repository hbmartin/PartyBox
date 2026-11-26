import Foundation
import PartyBoxCore
import PartyGameRuntime
import PartyNet
import Testing
@testable import PartyGames

@Suite("Turbo Loop")
@MainActor
struct TurboLoopTests {
    private let frame = 1.0 / 60.0
    private let track = TurboLoopTrack.standard
    private let solo = PlayerID(0)

    // MARK: Helpers

    /// Full-throttle stick toward the centerline `lookahead` ahead (or behind).
    private func follow(
        _ simulation: TurboLoopSimulation,
        _ playerID: PlayerID,
        lookahead: Double = 200,
        lateral: Double = 0
    ) -> ArcadeInput {
        guard let car = simulation.car(for: playerID) else { return .idle }
        let distance = car.trackDistance + lookahead
        let target = track.position(at: distance) + (track.sample(at: distance).normal * lateral)
        let direction = (target - car.position).normalized()
        return ArcadeInput(axisX: direction.x, axisY: direction.y)
    }

    @discardableResult
    private func run(
        _ simulation: inout TurboLoopSimulation,
        seconds: Double,
        until stop: (TurboLoopSimulation) -> Bool = { _ in false },
        inputs: (TurboLoopSimulation) -> [PlayerID: ArcadeInput]
    ) -> [ArcadeEvent] {
        var events: [ArcadeEvent] = []
        var steps = Int((seconds / frame).rounded())
        while steps > 0, !simulation.isFinished, !stop(simulation) {
            events += simulation.step(deltaTime: frame, inputs: inputs(simulation))
            steps -= 1
        }
        return events
    }

    private func segmentsCross(_ a: ArcadeVector, _ b: ArcadeVector, _ c: ArcadeVector, _ d: ArcadeVector) -> Bool {
        func side(_ p: ArcadeVector, _ q: ArcadeVector, _ r: ArcadeVector) -> Double {
            ((q.x - p.x) * (r.y - p.y)) - ((q.y - p.y) * (r.x - p.x))
        }
        let d1 = side(c, d, a)
        let d2 = side(c, d, b)
        let d3 = side(a, b, c)
        let d4 = side(a, b, d)
        return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0))
    }

    // MARK: Track

    @Test func trackIsAClosedEvenlySampledLoopThatNeverOverlapsItself() {
        let closing = TurboLoopTrack.closingPose()
        #expect(closing.position.distance(to: TurboLoopTrack.startPosition) < 0.001)
        // Exactly one clockwise turn: a simple closed loop.
        #expect(abs(closing.heading - (TurboLoopTrack.startHeading - (2 * .pi))) < 0.000_001)

        let samples = track.samples
        #expect(samples.count == 360)
        #expect(samples[0].distance == 0)
        #expect(abs(track.length - (track.spacing * 360)) < 0.000_001)
        for (index, sample) in samples.enumerated() {
            let next = samples[(index + 1) % samples.count]
            let chord = sample.position.distance(to: next.position)
            #expect(chord <= track.spacing + 0.000_1 && chord > track.spacing * 0.99, "uneven spacing at \(index)")
            #expect(abs(sample.tangent.length - 1) < 0.000_001)
            #expect(abs(sample.normal.dot(sample.tangent)) < 0.000_001)
            // Every bend is wider than the half-width, so the inner edge never folds.
            #expect(abs(sample.curvature) < 1 / (TurboLoopTrack.halfWidth * 1.1))
        }

        let neighbourhood = Int((Double.pi * TurboLoopTrack.halfWidth / track.spacing).rounded(.up))
        var closest = Double.infinity
        for first in samples.indices {
            for second in (first + 1)..<samples.count {
                let separation = min(second - first, samples.count - (second - first))
                guard separation > neighbourhood else { continue }
                closest = min(closest, samples[first].position.distance(to: samples[second].position))
            }
        }
        #expect(closest >= 2 * TurboLoopTrack.halfWidth, "ribbon overlaps itself: \(closest)")

        var crossings = 0
        for first in samples.indices {
            for second in (first + 2)..<(samples.count + first - 1) where second < samples.count {
                if segmentsCross(
                    samples[first].position, samples[(first + 1) % samples.count].position,
                    samples[second].position, samples[(second + 1) % samples.count].position
                ) { crossings += 1 }
            }
        }
        #expect(crossings == 0)

        for sample in samples {
            for edge in [sample.position + (sample.normal * TurboLoopTrack.halfWidth),
                         sample.position - (sample.normal * TurboLoopTrack.halfWidth)] {
                #expect((115...1_805).contains(edge.x) && (105...955).contains(edge.y), "ribbon leaves the screen at \(edge)")
            }
        }

        #expect(track.gates == [0.25, 0.5, 0.75].map { $0 * track.length } + [0])
        #expect(track.pads.count == 3)
        for pad in track.pads {
            #expect(abs(pad.lateral) + TurboLoopTrack.padHalfWidth <= TurboLoopTrack.halfWidth)
        }
    }

    // MARK: Laps

    @Test func lapCountsOnlyAfterEveryCheckpointAndReversingAcrossTheLineNeverCounts() throws {
        var simulation = TurboLoopSimulation(players: [solo], seed: 1)
        #expect(simulation.car(for: solo)?.lap == -1)
        #expect(simulation.car(for: solo)?.nextGate == 3)
        let halfThrottle = { (simulation: TurboLoopSimulation, lookahead: Double) -> [PlayerID: ArcadeInput] in
            let input = self.follow(simulation, self.solo, lookahead: lookahead)
            return [self.solo: ArcadeInput(axisX: input.axisX * 0.5, axisY: input.axisY * 0.5)]
        }

        // Off the grid and over the line: lap 1 starts, nothing completed.
        run(&simulation, seconds: 1.2) { halfThrottle($0, 200) }
        #expect(simulation.car(for: solo)?.lap == 0)
        #expect(simulation.car(for: solo)?.nextGate == 0)

        // A real U-turn back over the line takes the lap start back; turning
        // round again only restores it.
        var highestLap = 0
        for _ in 0..<2 {
            run(&simulation, seconds: 3) { simulation in
                highestLap = max(highestLap, simulation.car(for: solo)?.lap ?? 0)
                return halfThrottle(simulation, -200)
            }
            #expect(simulation.car(for: solo)?.lap == -1)
            #expect(simulation.car(for: solo)?.nextGate == 3)
            run(&simulation, seconds: 3) { simulation in
                highestLap = max(highestLap, simulation.car(for: solo)?.lap ?? 0)
                return halfThrottle(simulation, 200)
            }
            #expect(simulation.car(for: solo)?.lap == 0)
        }
        #expect(highestLap == 0)

        // Teleporting behind the line skips the checkpoints, so crossing again does not count.
        simulation.placeForTesting(solo, distance: -50, speed: 300)
        run(&simulation, seconds: 0.4) { halfThrottle($0, 200) }
        #expect(simulation.car(for: solo)?.lap == 0)
        #expect(simulation.car(for: solo)?.nextGate == 0)

        // A real lap passes the checkpoints in order, then the line.
        var gateSequence: [Int] = []
        run(&simulation, seconds: 30, until: { $0.car(for: solo)?.lap == 1 }) { simulation in
            let gate = simulation.car(for: solo)?.nextGate ?? -1
            if gateSequence.last != gate { gateSequence.append(gate) }
            #expect(simulation.car(for: solo)?.lap == 0)
            return [solo: follow(simulation, solo)]
        }
        let car = try #require(simulation.car(for: solo))
        #expect(gateSequence == [0, 1, 2, 3])
        #expect(car.lap == 1)
        #expect(car.nextGate == 0)
        #expect(car.lapTimes.count == 1)
    }

    @Test func cuttingAcrossTheInfieldNeverGainsGround() throws {
        var simulation = TurboLoopSimulation(players: [solo], seed: 1)
        simulation.setLapStateForTesting(solo, completedLaps: 0, nextGate: 0)
        // From the top straight, straight down over the grass onto the inner
        // right corner, which is ~1,600 pt further round the loop.
        simulation.placeForTesting(solo, at: ArcadeVector(x: 1_300, y: 790), heading: -.pi / 2, speed: TurboLoopSimulation.topSpeed)
        let before = try #require(simulation.car(for: solo))
        #expect(before.isOnTrack)
        let seconds = 1.2
        run(&simulation, seconds: seconds) { _ in [solo: ArcadeInput(axisX: 0, axisY: -1)] }
        let after = try #require(simulation.car(for: solo))
        let innerCorner = ArcadeVector(x: 1_303, y: 485)
        #expect(abs(after.position.distance(to: innerCorner) - 130) < TurboLoopTrack.halfWidth, "the car sits on the inner corner's tarmac")
        #expect(!after.isOnTrack, "tarmac on a later stretch still counts as off track")
        #expect(after.progress - before.progress < TurboLoopSimulation.topSpeed * seconds, "cutting is slower than driving")
        #expect(after.nextGate == 0)
    }

    @Test func wrongWayMarkerAppearsAfterFacingBackwardsForAMoment() {
        var simulation = TurboLoopSimulation(players: [solo], seed: 1)
        simulation.placeForTesting(solo, distance: 300, speed: 0, reversed: true)
        let backwards = { (simulation: TurboLoopSimulation) in [self.solo: self.follow(simulation, self.solo, lookahead: -200)] }
        var events = run(&simulation, seconds: 0.5, inputs: backwards)
        #expect(simulation.car(for: solo)?.isWrongWay == false)
        events += run(&simulation, seconds: 0.4, inputs: backwards)
        #expect(simulation.car(for: solo)?.isWrongWay == true)
        #expect(events.filter { $0 == .haptic(solo, .error) }.count == 1)
        run(&simulation, seconds: 1.5) { [solo: follow($0, solo)] }
        #expect(simulation.car(for: solo)?.isWrongWay == false)
    }

    // MARK: Driving

    @Test func offTrackCarsAreCappedAtOffTrackSpeed() throws {
        var simulation = TurboLoopSimulation(players: [solo], seed: 1)
        // The bare infield under the dip, heading right at full speed.
        simulation.placeForTesting(solo, at: ArcadeVector(x: 650, y: 200), heading: 0, speed: TurboLoopSimulation.topSpeed)
        #expect(simulation.car(for: solo)?.isOnTrack == false)
        run(&simulation, seconds: 1.5) { simulation in
            #expect(simulation.car(for: solo)?.isOnTrack == false)
            return [solo: ArcadeInput(axisX: 1, axisY: 0)]
        }
        let grass = try #require(simulation.car(for: solo))
        #expect(grass.forwardSpeed <= TurboLoopSimulation.offTrackTopSpeed + 0.000_1)
        #expect(grass.forwardSpeed > TurboLoopSimulation.offTrackTopSpeed - 1)

        // Keep clear of the boost pad on the right-hand side of the straight.
        simulation.placeForTesting(solo, distance: 60, lateral: 50, speed: 0)
        run(&simulation, seconds: 1.2) { [solo: follow($0, solo, lateral: 50)] }
        let tarmac = try #require(simulation.car(for: solo))
        #expect(tarmac.isOnTrack)
        #expect(tarmac.forwardSpeed > TurboLoopSimulation.topSpeed - 1)
        #expect(tarmac.forwardSpeed <= TurboLoopSimulation.topSpeed + 0.000_1)
    }

    @Test func boostPadRaisesTheSpeedCapForAboutOneSecond() throws {
        let pad = track.pads[0]
        var simulation = TurboLoopSimulation(players: [solo], seed: 1)
        simulation.placeForTesting(solo, distance: pad.distance - 160, lateral: pad.lateral, speed: TurboLoopSimulation.topSpeed)
        let line = { (simulation: TurboLoopSimulation) in [self.solo: self.follow(simulation, self.solo, lateral: pad.lateral)] }

        let events = run(&simulation, seconds: 0.5, until: { $0.car(for: self.solo)?.isBoosting == true }, inputs: line)
        #expect(simulation.car(for: solo)?.isBoosting == true)
        #expect(events.contains(.cue(solo, colorHex: TurboLoopSimulation.boostColor, haptic: .lightImpact)))
        #expect(events.contains(.sound(.lightImpact)))

        var peak = 0.0
        run(&simulation, seconds: 0.6) { simulation in
            peak = max(peak, simulation.car(for: solo)?.forwardSpeed ?? 0)
            return line(simulation)
        }
        #expect(peak > TurboLoopSimulation.topSpeed * 1.2)
        #expect(peak <= (TurboLoopSimulation.topSpeed * TurboLoopSimulation.boostMultiplier) + 0.000_1)

        run(&simulation, seconds: 2) { [solo: follow($0, solo)] }
        let after = try #require(simulation.car(for: solo))
        #expect(!after.isBoosting)
        #expect(after.forwardSpeed <= TurboLoopSimulation.topSpeed + 0.000_1)
    }

    @Test func carsPushApartAndTradeSpeedOnContact() throws {
        let chaser = PlayerID(0)
        let leader = PlayerID(1)
        var simulation = TurboLoopSimulation(players: [chaser, leader], seed: 1)
        simulation.placeForTesting(leader, distance: 250, speed: 150)
        simulation.placeForTesting(chaser, distance: 215, speed: 600)
        let events = simulation.step(deltaTime: frame, inputs: [:])
        let back = try #require(simulation.car(for: chaser))
        let front = try #require(simulation.car(for: leader))
        #expect(back.position.distance(to: front.position) >= (TurboLoopSimulation.carRadius * 2) - 0.000_1)
        #expect(front.forwardSpeed > 300)
        #expect(back.forwardSpeed < 450)
        #expect(events.contains(.haptic(chaser, .lightImpact)))
    }

    // MARK: Race flow

    @Test func finishWindowEndsTheRaceEightSecondsAfterTheFirstFinisher() throws {
        let first = PlayerID(0)
        let second = PlayerID(1)
        var simulation = TurboLoopSimulation(players: [first, second], seed: 3)
        simulation.setLapStateForTesting(first, completedLaps: TurboLoopSimulation.laps - 1, nextGate: 3)
        simulation.placeForTesting(first, distance: -40, speed: 500)

        let events = run(&simulation, seconds: 0.5, until: { $0.car(for: first)?.isFinished == true }) {
            [first: follow($0, first)]
        }
        let finishTime = try #require(simulation.car(for: first)?.finishTime)
        #expect(events.contains(.banner("P1 FINISHES!")))
        #expect(events.contains(.cue(first, colorHex: ArcadeOutcomeBuilder.winnerColor, haptic: .success)))
        #expect(!simulation.isFinished)
        #expect(try #require(simulation.timeRemaining) <= TurboLoopSimulation.finishWindow)

        run(&simulation, seconds: 7.9) { _ in [:] }
        #expect(!simulation.isFinished)
        run(&simulation, seconds: 1) { _ in [:] }
        #expect(simulation.isFinished)
        #expect(abs(simulation.elapsed - (finishTime + TurboLoopSimulation.finishWindow)) < frame * 2)

        let ranking = simulation.ranking()
        #expect(ranking.map(\.playerID) == [first, second])
        #expect(ranking[0].detail == TurboLoopSimulation.formatTime(finishTime))
        #expect(ranking[1].detail == "Lap 1/\(TurboLoopSimulation.laps)")
    }

    @Test func raceStopsAtTheCapAndTheTimerCountsItDown() {
        var simulation = TurboLoopSimulation(players: [PlayerID(0), PlayerID(1)], seed: 2)
        #expect(simulation.timeRemaining == TurboLoopSimulation.raceCap)
        run(&simulation, seconds: 30) { _ in [:] }
        #expect(abs((simulation.timeRemaining ?? 0) - 90) < 0.001)
        run(&simulation, seconds: 100) { _ in [:] }
        #expect(simulation.isFinished)
        #expect(simulation.elapsed >= TurboLoopSimulation.raceCap)
        #expect(simulation.elapsed < TurboLoopSimulation.raceCap + 0.05)
    }

    @Test func rankingOrdersFinishersByTimeThenEveryoneElseByProgress() {
        let ids = (0..<5).map { PlayerID(UInt8($0)) }
        var simulation = TurboLoopSimulation(players: ids, seed: 9)
        simulation.finishForTesting(ids[2], at: 61.5)
        simulation.finishForTesting(ids[0], at: 64.2)
        simulation.setLapStateForTesting(ids[1], completedLaps: 1, nextGate: 1, lapSeconds: 25)
        simulation.placeForTesting(ids[1], distance: track.length * 0.3)
        simulation.setLapStateForTesting(ids[3], completedLaps: 2, nextGate: 0, lapSeconds: 25)
        simulation.placeForTesting(ids[3], distance: track.length * 0.105)
        #expect(simulation.forfeit(ids[4]) == [.eliminated(ids[4])])
        _ = simulation.step(deltaTime: 0, inputs: [:])

        let ranking = simulation.ranking()
        #expect(ranking.map(\.playerID) == [ids[2], ids[0], ids[3], ids[1], ids[4]])
        #expect(ranking.map(\.detail) == ["1:01.5", "1:04.2", "Lap 3/\(TurboLoopSimulation.laps)", "Lap 2/\(TurboLoopSimulation.laps)", "DNF"])
        #expect(zip(ranking, ranking.dropFirst()).allSatisfy { $0.score >= $1.score })
        #expect(ranking[0].score == TurboLoopSimulation.laps * 1_000)
        #expect(ranking[2].score == 2_010)
        #expect(simulation.scoreLine(for: ids[2]) == "1ST  1:01.5")
        #expect(simulation.scoreLine(for: ids[3]) == "LAP 3/\(TurboLoopSimulation.laps)  3RD")
        #expect(simulation.scoreLine(for: ids[4]) == "DNF")
        #expect(simulation.resultMetric == .init(
            id: "best-lap", label: "Best lap",
            value: TurboLoopSimulation.formatTime(61.5 / Double(TurboLoopSimulation.laps))
        ))
        // A car that already finished cannot be forfeited out of its result.
        #expect(simulation.forfeit(ids[2]).isEmpty)
    }

    @Test func soloTimeTrialEndsWhenTheDriverFinishesOrForfeits() {
        var simulation = TurboLoopSimulation(players: [solo], seed: 5)
        simulation.setLapStateForTesting(solo, completedLaps: TurboLoopSimulation.laps - 1, nextGate: 3)
        simulation.placeForTesting(solo, distance: -30, speed: 500)
        run(&simulation, seconds: 1) { [solo: follow($0, solo)] }
        #expect(simulation.isFinished)
        #expect(simulation.car(for: solo)?.isFinished == true)

        var forfeited = TurboLoopSimulation(players: [solo], seed: 5)
        #expect(forfeited.forfeit(solo) == [.eliminated(solo)])
        #expect(forfeited.isFinished)
    }

    @Test func sameSeedAndInputsReplayIdentically() {
        func play(seed: UInt64) -> (TurboLoopSimulation, [ArcadeEvent]) {
            let ids = (0..<4).map { PlayerID(UInt8($0)) }
            let difficulties: [GameBotDifficulty] = [.easy, .normal, .hard]
            var simulation = TurboLoopSimulation(players: ids, seed: seed)
            var random = ArcadeRandomNumberGenerator(seed: seed)
            var events: [ArcadeEvent] = []
            for step in 0..<(60 * 20) {
                var inputs: [PlayerID: ArcadeInput] = [:]
                inputs[ids[0]] = ArcadeInput(axisX: cos(Double(step) * 0.02) * 0.9, axisY: sin(Double(step) * 0.031) * 0.9)
                for (index, playerID) in ids.enumerated().dropFirst() {
                    let decision = simulation.botDecision(
                        for: playerID,
                        difficulty: difficulties[index % difficulties.count],
                        random: &random
                    )
                    inputs[playerID] = ArcadeInput(axisX: decision.axisX, axisY: decision.axisY)
                }
                events += simulation.step(deltaTime: frame, inputs: inputs)
            }
            return (simulation, events)
        }
        let (first, firstEvents) = play(seed: 77)
        let (second, secondEvents) = play(seed: 77)
        #expect(first.cars == second.cars)
        #expect(firstEvents == secondEvents)
        #expect(first.order == second.order)
        #expect(first.cars.contains { $0.lapsCompleted >= 1 })

        let grids = (0..<6).map { TurboLoopSimulation(players: (0..<4).map { PlayerID(UInt8($0)) }, seed: $0).cars.map(\.slot) }
        #expect(Set(grids.map { $0.map(String.init).joined() }).count > 1, "the seed shuffles the grid")
        #expect(grids.allSatisfy { Set($0) == Set(0..<4) })
    }

    // MARK: Session and bots

    @Test func controllerScreenOffersHeadingSwipeSteering() {
        let game = TurboLoopGame()
        #expect(game.descriptor.id == "turbo-loop")
        #expect(game.descriptor.supportsMotion)
        #expect(game.descriptor.estimatedDurationSeconds == 60)
        #expect(TurboLoopGame.controls == [
            .text(.init(id: "turbo.rule", text: "FIVE LAPS • HIT THE BOOST PADS", style: .caption, tint: .secondary)),
            .axisSurface(.init(
                id: "turbo.steer",
                binding: .twoDimensional,
                instruction: "POINT WHERE TO DRIVE  •  MOTION OPTIONAL",
                swipe: .heading
            )),
        ])
    }

    @Test func eightHardBotsFinishInsideTheCap() throws {
        let result = ArcadeHarness.playOut(TurboLoopGame(), players: 8, difficulty: .hard)
        let outcome = try #require(result.outcome)
        #expect(result.seconds < 125)
        #expect(outcome.standings.count == 8)
        #expect(outcome.standings.contains { $0.detail.contains(":") })
        #expect(outcome.winner != nil)
        #expect(outcome.metrics.first?.label == "Best lap")
        #expect(outcome.metrics.first?.value != "—")
    }

    @Test func hardSoloBotFinishesEveryLapUnderOneHundredSeconds() throws {
        let result = ArcadeHarness.playOut(TurboLoopGame(), players: 1, difficulty: .hard)
        let outcome = try #require(result.outcome)
        #expect(result.seconds < 100)
        #expect(outcome.title == "PRACTICE COMPLETE")
        #expect(outcome.standings.first?.detail.contains(":") == true)
    }

    @Test func easyBotsStillFinishComfortablyInsideTheCap() throws {
        let result = ArcadeHarness.playOut(TurboLoopGame(), players: 8, difficulty: .easy)
        let outcome = try #require(result.outcome)
        #expect(result.seconds < TurboLoopSimulation.raceCap / 2)
        #expect(outcome.standings.allSatisfy { $0.detail.contains(":") }, "every easy bot finishes")
    }
}
