import Foundation
import PartyBoxCore
import PartyGameRuntime
import PartyNet
import Testing
@testable import PartyGames

@Suite("Bumper Brawl")
@MainActor
struct BumperBrawlTests {
    private typealias Simulation = BumperBrawlSimulation

    private let center = ArcadeArena.center
    private let frame = 1.0 / 60.0

    private func offset(_ x: Double, _ y: Double = 0) -> ArcadeVector {
        center + ArcadeVector(x: x, y: y)
    }

    @discardableResult
    private func run(
        _ simulation: inout Simulation,
        seconds: Double,
        inputs: [PlayerID: ArcadeInput] = [:],
        until stop: (([ArcadeEvent]) -> Bool)? = nil
    ) -> [ArcadeEvent] {
        var events: [ArcadeEvent] = []
        var remaining = seconds
        while remaining > 0.000_001, !simulation.isFinished {
            events += simulation.step(deltaTime: min(frame, remaining), inputs: inputs)
            remaining -= frame
            if let stop, stop(events) { break }
        }
        return events
    }

    @Test func controllerAndDescriptorMatchTheSpec() {
        let game = BumperBrawlGame()
        #expect(game.descriptor.id == "bumper-brawl")
        #expect(game.descriptor.title == "BUMPER BRAWL")
        #expect(game.descriptor.supportsMotion)
        #expect(game.descriptor.estimatedDurationSeconds == 75)
        #expect(BumperBrawlGame.controls == [
            .text(.init(id: "bumper.rule", text: "PUSH RIVALS OFF THE ICE • TAP DASH", style: .caption, tint: .secondary)),
            .axisSurface(.init(
                id: "bumper.steer",
                binding: .twoDimensional,
                instruction: "DRAG TO PUSH  •  MOTION OPTIONAL",
                swipe: .heading
            )),
            .actionButton(.init(id: "bumper.dash", label: "DASH", route: .game("bumper.dash"))),
        ])
        #expect(Simulation.botReactionInterval(for: .easy) == 0.3)
        #expect(Simulation.botReactionInterval(for: .normal) == 0.15)
        #expect(Simulation.botReactionInterval(for: .hard) == 0.08)
    }

    @Test func pucksSpawnEvenlyOnTheInnerRing() {
        let simulation = Simulation(players: ArcadeHarness.playerIDs(8), seed: 1)
        #expect(simulation.pucks.count == 8)
        #expect(simulation.drones.isEmpty)
        for puck in simulation.pucks {
            #expect(abs(puck.position.distance(to: center) - 480 * 0.55) < 0.001)
            #expect(puck.lives == 3)
        }
    }

    @Test func dashUsesThePressSnapshotWhileMovementUsesTheLatestFrame() throws {
        let player = PlayerID(0)
        let rival = PlayerID(1)
        let inputs = InputStore()
        inputs.update(.init(token: 1, sequence: 1, clientTimeMs: 0, axisX: -1, axisY: 0), for: player)
        let session = try #require(BumperBrawlGame().makeSession(
            context: .init(participants: ArcadeHarness.participants(2), inputs: inputs, seed: 1, modifierID: nil),
            onEvents: { _ in }
        ) as? ArcadeSession<BumperBrawlRenderer>)
        session.skipIntroForTesting()
        session.simulationForTesting.placeForTesting(player, at: offset(0))
        session.simulationForTesting.placeForTesting(rival, at: offset(250))
        session.handle(action: .init(
            id: "bumper.dash", value: .trigger, steering: .init(axisX: 1, axisY: 0)
        ), from: player)
        session.advance(by: frame)

        let puck = try #require(session.simulationForTesting.puck(for: player))
        #expect(puck.velocity.x > 0)
        #expect(puck.stick.x == -1)
    }

    @Test func rivalPushedOffTheEdgeLosesALifeRespawnsGhostedAndCreditsTheToucher() throws {
        let pusher = PlayerID(0)
        let victim = PlayerID(1)
        var simulation = Simulation(players: [pusher, victim], seed: 7)
        simulation.placeForTesting(victim, at: offset(400))
        simulation.placeForTesting(pusher, at: offset(300), velocity: ArcadeVector(x: 600, y: 0))

        var events = run(&simulation, seconds: 2) { $0.contains(.lostLife(victim, remaining: 2)) }

        #expect(events.contains(.lostLife(victim, remaining: 2)))
        #expect(events.contains(.haptic(pusher, .lightImpact)))
        #expect(events.contains(.haptic(victim, .lightImpact)))
        #expect(events.contains(.cue(pusher, colorHex: ArcadeOutcomeBuilder.winnerColor, haptic: .success)))
        let fallen = try #require(simulation.puck(for: victim))
        #expect(fallen.lives == 2)
        #expect(fallen.isFalling)
        #expect(fallen.falls == 1)
        let hero = try #require(simulation.puck(for: pusher))
        #expect(hero.kos == 1)
        #expect(hero.onBoard)
        #expect(hero.score >= Simulation.koValue)

        events = run(&simulation, seconds: Simulation.respawnDelay + 0.05)
        let respawned = try #require(simulation.puck(for: victim))
        #expect(respawned.onBoard)
        #expect(respawned.isGhost)
        #expect(respawned.position.distance(to: center) < 150)
        #expect(respawned.velocity == .zero)

        // Ghosts pass through other pucks.
        simulation.placeForTesting(pusher, at: respawned.position + ArcadeVector(x: 30, y: 0), velocity: ArcadeVector(x: -300, y: 0))
        run(&simulation, seconds: frame)
        #expect(simulation.puck(for: victim)?.velocity == .zero)
        #expect(simulation.puck(for: pusher).map { $0.velocity.x < -250 } == true)

        run(&simulation, seconds: Simulation.ghostDuration)
        #expect(simulation.puck(for: victim)?.isGhost == false)
        #expect(simulation.puck(for: victim)?.onBoard == true)
    }

    @Test func fallingWithoutARecentTouchCreditsNobody() throws {
        let loner = PlayerID(0)
        let bystander = PlayerID(1)
        var simulation = Simulation(players: [loner, bystander], seed: 3)
        simulation.placeForTesting(loner, at: offset(470), velocity: ArcadeVector(x: 300, y: 0))
        let events = run(&simulation, seconds: 1) { $0.contains(.lostLife(loner, remaining: 2)) }
        #expect(events.contains(.lostLife(loner, remaining: 2)))
        #expect(simulation.puck(for: bystander)?.kos == 0)
        #expect(!events.contains { if case .cue = $0 { true } else { false } })
    }

    @Test func dashIgnoresPressesDuringItsCooldown() throws {
        let dasher = PlayerID(0)
        let other = PlayerID(1)
        var simulation = Simulation(players: [dasher, other], seed: 3)
        simulation.placeForTesting(other, at: offset(0, 300))
        simulation.placeForTesting(dasher, at: offset(-400))

        _ = simulation.step(deltaTime: frame, inputs: [dasher: ArcadeInput(axisX: 1, axisY: 0, pressed: true)])
        let dashed = try #require(simulation.puck(for: dasher))
        #expect(dashed.velocity.x > Simulation.dashImpulse * 0.95)
        #expect(dashed.isDashing)
        #expect(!dashed.dashReady)

        run(&simulation, seconds: 0.5)
        simulation.placeForTesting(dasher, at: center)
        var control = simulation
        _ = control.step(deltaTime: frame, inputs: [:])
        _ = simulation.step(deltaTime: frame, inputs: [dasher: ArcadeInput(pressed: true)])
        #expect(simulation == control, "A press during the 1.2s cooldown must do nothing")

        run(&simulation, seconds: Simulation.dashCooldown - 0.5)
        simulation.placeForTesting(dasher, at: center)
        #expect(simulation.puck(for: dasher)?.dashReady == true)
        _ = simulation.step(deltaTime: frame, inputs: [dasher: ArcadeInput(axisX: 0, axisY: -1, pressed: true)])
        #expect(simulation.puck(for: dasher).map { $0.velocity.y < -Simulation.dashImpulse * 0.95 } == true)
    }

    @Test func idleDashFollowsTheCurrentVelocity() throws {
        let dasher = PlayerID(0)
        var simulation = Simulation(players: [dasher, PlayerID(1)], seed: 3)
        simulation.placeForTesting(PlayerID(1), at: offset(0, 300))
        simulation.placeForTesting(dasher, at: center, velocity: ArcadeVector(x: 0, y: 100))
        _ = simulation.step(deltaTime: frame, inputs: [dasher: ArcadeInput(axisX: 0.05, axisY: 0, pressed: true)])
        let puck = try #require(simulation.puck(for: dasher))
        #expect(puck.velocity.y > Simulation.dashImpulse)
        #expect(abs(puck.velocity.x) < 5)
    }

    @Test func dashKnockbackBeatsANormalBump() {
        func knockback(dashing: Bool) -> Double {
            let attacker = PlayerID(0)
            let target = PlayerID(1)
            var simulation = Simulation(players: [attacker, target], seed: 5)
            simulation.placeForTesting(target, at: center)
            if dashing {
                simulation.placeForTesting(attacker, at: offset(-160))
                _ = simulation.step(deltaTime: frame, inputs: [attacker: ArcadeInput(axisX: 1, axisY: 0, pressed: true)])
            } else {
                // Same approach speed as the dash, so only the knockback differs.
                simulation.placeForTesting(attacker, at: offset(-160), velocity: ArcadeVector(x: Simulation.dashImpulse, y: 0))
                _ = simulation.step(deltaTime: frame, inputs: [:])
            }
            for _ in 0..<30 where simulation.puck(for: target)?.velocity == .zero {
                _ = simulation.step(deltaTime: frame, inputs: [:])
            }
            return simulation.puck(for: target)?.velocity.x ?? 0
        }
        let bump = knockback(dashing: false)
        let dash = knockback(dashing: true)
        #expect(bump > Simulation.dashImpulse * 0.6)
        #expect(dash > bump * (Simulation.dashKnockback - 0.05))
    }

    @Test func thrustAloneIsCappedButHitsAndDashesExceedTheCap() throws {
        let racer = PlayerID(0)
        var simulation = Simulation(players: [racer, PlayerID(1)], seed: 2)
        simulation.placeForTesting(PlayerID(1), at: offset(0, 400))
        simulation.placeForTesting(racer, at: offset(-450, -100))
        run(&simulation, seconds: 1, inputs: [racer: ArcadeInput(axisX: 1, axisY: 0)])
        let cruising = try #require(simulation.puck(for: racer))
        #expect(cruising.velocity.length <= Simulation.cruiseSpeed + 0.001)
        #expect(cruising.velocity.length > Simulation.cruiseSpeed * 0.95)

        simulation.placeForTesting(racer, at: offset(-300, -100), velocity: cruising.velocity)
        _ = simulation.step(deltaTime: frame, inputs: [racer: ArcadeInput(axisX: 1, axisY: 0, pressed: true)])
        #expect(simulation.puck(for: racer).map {
            $0.velocity.length > Simulation.cruiseSpeed + (Simulation.dashImpulse * 0.9)
        } == true)
    }

    @Test func platformShrinksOnSchedule() {
        var simulation = Simulation(players: ArcadeHarness.playerIDs(2), seed: 1)
        for (time, radius) in [(0.0, 480.0), (15, 480), (37.5, 340), (60, 200), (70, 200)] {
            simulation.setElapsedForTesting(time)
            #expect(abs(simulation.platformRadius - radius) < 0.000_1, "radius at \(time)s")
        }

        var live = Simulation(players: ArcadeHarness.playerIDs(2), seed: 1)
        let early = run(&live, seconds: 16)
        #expect(early.contains(.banner("THE ICE IS MELTING")))
        #expect(!early.contains(.banner("FINAL RING")))
        #expect(live.isShrinking)
        // Idle pucks parked on the spawn ring survive the first stretch of the melt.
        #expect(live.players.allSatisfy { $0.lives == 3 })
        live.setElapsedForTesting(49.9)
        #expect(run(&live, seconds: 0.2).contains(.banner("FINAL RING")))
        #expect(live.timeRemaining.map { abs($0 - 19.9) < 0.05 } == true)
    }

    @Test func soloPlayerFacesTwoChaserDronesAndEndsWhenLivesRunOut() throws {
        let solo = PlayerID(0)
        var simulation = Simulation(players: [solo], seed: 9)
        #expect(simulation.drones.count == 2)
        #expect(simulation.pucks.count == 3)
        #expect(simulation.ranking().map(\.playerID) == [solo])

        let start = try #require(simulation.puck(for: solo)).position
        let before = simulation.drones.map { $0.position.distance(to: start) }.min() ?? 0
        run(&simulation, seconds: 0.8)
        let after = simulation.drones.map { $0.position.distance(to: start) }.min() ?? 0
        #expect(after < before - 100, "drones chase the player")

        // A drone knocked off counts as a solo KO and comes back.
        var knock = Simulation(players: [solo], seed: 9)
        knock.placeDroneForTesting(0, at: offset(420))
        knock.placeDroneForTesting(1, at: offset(-300, 200))
        knock.placeForTesting(solo, at: offset(300), velocity: ArcadeVector(x: 700, y: 0))
        let events = run(&knock, seconds: 0.6) { $0.contains(.sound(.heavyImpact)) }
        #expect(events.contains(.sound(.heavyImpact)))
        let player = try #require(knock.puck(for: solo))
        #expect(player.kos == 1)
        #expect(player.score == 100 + Int(player.survivalTime * 10))
        #expect(knock.drones[0].isFalling)
        run(&knock, seconds: 1.1)
        #expect(knock.drones[0].onBoard)

        simulation.setLivesForTesting(1, playerID: solo)
        simulation.placeForTesting(solo, at: offset(simulation.platformRadius + 5))
        let final = simulation.step(deltaTime: frame, inputs: [:])
        #expect(final.contains(.eliminated(solo)))
        #expect(simulation.isFinished)
        #expect(!simulation.isActive(solo))
    }

    @Test func multiplayerEndsWhenOnePuckHasLivesLeft() {
        let ids = ArcadeHarness.playerIDs(3)
        var simulation = Simulation(players: ids, seed: 4)
        _ = simulation.forfeit(ids[0])
        #expect(!simulation.isFinished)
        simulation.setLivesForTesting(1, playerID: ids[1])
        simulation.placeForTesting(ids[1], at: offset(0, -490))
        let events = simulation.step(deltaTime: frame, inputs: [:])
        #expect(events.contains(.eliminated(ids[1])))
        #expect(simulation.isFinished)
        #expect(simulation.ranking().map(\.playerID) == [ids[2], ids[1], ids[0]])
    }

    @Test func equalSurvivorsShareFirstAtTheTimeCap() throws {
        let ids = ArcadeHarness.playerIDs(2)
        var simulation = Simulation(players: ids, seed: 7)
        simulation.placeForTesting(ids[0], at: offset(-90))
        simulation.placeForTesting(ids[1], at: offset(90))
        simulation.setElapsedForTesting(Simulation.duration - (frame / 2))

        _ = simulation.step(deltaTime: frame, inputs: [:])

        #expect(ids.allSatisfy { simulation.isActive($0) })
        let outcome = try #require(ArcadeHarness.finishedDuel(simulation))
        #expect(outcome.winner == nil)
        #expect(outcome.standings.map(\.rank) == [1, 1])
    }

    @Test func simultaneousRingOutsWithTheSameScoreEndInADraw() throws {
        let ids = ArcadeHarness.playerIDs(2)
        var simulation = Simulation(players: ids, seed: 7)
        simulation.setLivesForTesting(1, playerID: ids[0])
        simulation.setLivesForTesting(1, playerID: ids[1])
        simulation.placeForTesting(ids[0], at: offset(0, -490))
        simulation.placeForTesting(ids[1], at: offset(0, 490))
        _ = simulation.step(deltaTime: frame, inputs: [:])
        #expect(simulation.isFinished)

        let events = ArcadeOutcomeBuilder.completionEvents(
            title: "Bumper Brawl", participants: ArcadeHarness.participants(2),
            ranking: simulation.ranking(), metric: simulation.resultMetric, forfeited: []
        )
        let outcome = try #require(events.compactMap { event -> GameOutcome? in
            if case .completed(let outcome) = event { outcome } else { nil }
        }.first)
        #expect(outcome.winner == nil)
        #expect(outcome.standings.map(\.rank) == [1, 1])
        #expect(outcome.playerOutcomes.map(\.outcome) == [.draw, .draw])
    }

    @Test func simultaneousRingOutsUseScoreBeforeSeatOrder() {
        let ids = ArcadeHarness.playerIDs(2)
        var simulation = Simulation(players: ids, seed: 7)
        simulation.placeForTesting(ids[1], at: offset(400))
        simulation.placeForTesting(ids[0], at: offset(300), velocity: ArcadeVector(x: 600, y: 0))
        run(&simulation, seconds: 2) { $0.contains(.lostLife(ids[1], remaining: 2)) }
        #expect(simulation.puck(for: ids[0])?.kos == 1)
        run(&simulation, seconds: Simulation.respawnDelay + Simulation.ghostDuration + 0.1)
        simulation.setLivesForTesting(1, playerID: ids[0])
        simulation.setLivesForTesting(1, playerID: ids[1])
        simulation.placeForTesting(ids[0], at: offset(0, -490))
        simulation.placeForTesting(ids[1], at: offset(0, 490))

        let events = simulation.step(deltaTime: frame, inputs: [:])

        #expect(events.contains(.eliminated(ids[0])))
        #expect(events.contains(.eliminated(ids[1])))
        #expect(simulation.isFinished)
        #expect(simulation.ranking().map(\.playerID) == ids)
    }

    @Test func sameSeedAndScriptedInputsReplayIdentically() {
        func play(players: Int) -> (Simulation, [ArcadeEvent]) {
            let ids = ArcadeHarness.playerIDs(players)
            var simulation = Simulation(players: ids, seed: 1_234)
            var log: [ArcadeEvent] = []
            for tick in 0..<(60 * 30) {
                var inputs: [PlayerID: ArcadeInput] = [:]
                for (slot, id) in ids.enumerated() {
                    let time = (Double(tick) / 60) + Double(slot)
                    inputs[id] = ArcadeInput(
                        axisX: sin(time * 1.3),
                        axisY: cos((time * 0.7) + Double(slot)),
                        pressed: (tick + (slot * 17)) % 70 == 0
                    )
                }
                log += simulation.step(deltaTime: tick % 7 == 0 ? 1.0 / 45.0 : frame, inputs: inputs)
            }
            return (simulation, log)
        }
        for players in [1, 4] {
            let (first, firstLog) = play(players: players)
            let (second, secondLog) = play(players: players)
            #expect(first == second)
            #expect(firstLog == secondLog)
            #expect(firstLog.contains { event in
                switch event {
                case .lostLife, .eliminated, .sound(.heavyImpact): true
                default: false
                }
            }, "the script should knock something off the ice")
        }
    }

    @Test func eightHardBotsFinishBeforeTheBuzzer() throws {
        let result = ArcadeHarness.playOut(BumperBrawlGame(), players: 8, difficulty: .hard)
        let outcome = try #require(result.outcome)
        #expect(result.seconds < 75)
        #expect(outcome.standings.count == 8)
        #expect(Set(outcome.standings.map(\.playerID)).count == 8)
        #expect(outcome.standings.map(\.rank) == Array(1...8))
        #expect(outcome.metrics.first?.label == "Most KOs")
        #expect(!result.eliminated.isEmpty)
    }

    @Test func soloPlayOutCompletesAsPractice() throws {
        let result = ArcadeHarness.playOut(BumperBrawlGame(), players: 1)
        let outcome = try #require(result.outcome)
        #expect(result.seconds < 75)
        #expect(outcome.title == "PRACTICE COMPLETE")
        #expect(outcome.standings.map(\.playerID) == [PlayerID(0)])
        #expect(outcome.playerOutcomes == [.init(playerID: PlayerID(0), outcome: .practice)])
    }

    @Test func hardBotBeatsAnIdlePuck() {
        let seeds: [UInt64] = [1, 2, 3, 4, 5]
        let wins = seeds.filter { seed in
            let result = ArcadeHarness.playOut(
                BumperBrawlGame(),
                players: 2,
                seed: seed,
                difficulty: .hard,
                idle: [PlayerID(1)]
            )
            return result.outcome?.winner == PlayerID(0) && result.eliminated.contains(PlayerID(1))
        }
        #expect(wins.count >= 4, "hard bot won \(wins.count) of \(seeds.count)")
    }
}
