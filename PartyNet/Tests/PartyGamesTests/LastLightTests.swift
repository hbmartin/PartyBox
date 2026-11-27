import Foundation
import PartyBoxCore
import PartyGameRuntime
import PartyNet
import Testing
@testable import PartyGames

@Suite("Last Light")
@MainActor
struct LastLightTests {
    private typealias Hazard = LastLightSimulation.Hazard
    private let first = PlayerID(0)
    private let second = PlayerID(1)

    @Test func orbsChaseTheStickTargetAtACappedSpeed() throws {
        var game = LastLightSimulation(players: [first], seed: 1)
        game.setHazardsForTesting([])
        game.placeForTesting(first, at: ArcadeArena.center)
        let input = ArcadeInput(axisX: 1, axisY: 0)

        _ = game.step(deltaTime: 0.1, inputs: [first: input])
        let moved = try #require(game.player(for: first)).position.x - ArcadeArena.center.x

        #expect(moved > 0)
        #expect(moved <= LastLightSimulation.maximumSpeed * 0.05 + 0.001)
    }

    @Test func hitsCostALifeThenGrantInvulnerability() throws {
        var game = LastLightSimulation(players: [first, second], seed: 1)
        game.placeForTesting(first, at: ArcadeArena.center)
        game.placeForTesting(second, at: ArcadeArena.center + ArcadeVector(x: 500, y: 200))
        let bar = Hazard(
            id: 900, kind: .rowSweeper, position: ArcadeArena.center,
            velocity: .zero, gapCenter: ArcadeArena.minX + 40, armRemaining: 0
        )
        game.setHazardsForTesting([bar])

        let events = game.step(deltaTime: 0.01, inputs: [:])
        let afterHit = try #require(game.player(for: first))
        _ = game.step(deltaTime: 0.01, inputs: [:])

        #expect(events.contains(.lostLife(first, remaining: 2)))
        #expect(afterHit.isInvulnerable)
        #expect(game.player(for: first)?.lives == 2)
    }

    @Test func simultaneousLastLifeHitsShareFirst() throws {
        var game = LastLightSimulation(players: [first, second], seed: 1)
        for id in [first, second] {
            game.setLivesForTesting(1, playerID: id)
            game.placeForTesting(id, at: ArcadeArena.center)
        }
        game.setHazardsForTesting([Hazard(
            id: 900, kind: .rowSweeper, position: ArcadeArena.center,
            velocity: .zero, gapCenter: ArcadeArena.minX + 40, armRemaining: 0
        )])

        let events = game.step(deltaTime: 0.01, inputs: [:])

        #expect(events.contains(.eliminated(first)))
        #expect(events.contains(.eliminated(second)))
        let outcome = try #require(ArcadeHarness.finishedDuel(game))
        #expect(outcome.winner == nil)
        #expect(outcome.playerOutcomes.map(\.outcome) == [.draw, .draw])
    }

    @Test func sweeperGapsAreSafeAndTelegraphedHazardsAreHarmless() {
        let bar = Hazard(id: 1, kind: .rowSweeper, position: ArcadeVector(x: 960, y: 500), velocity: .zero, gapCenter: 700, armRemaining: 0)
        #expect(LastLightSimulation.hits(bar, at: ArcadeVector(x: 700, y: 500), radius: 24) == false)
        #expect(LastLightSimulation.hits(bar, at: ArcadeVector(x: 1_200, y: 500), radius: 24))
        #expect(LastLightSimulation.hits(bar, at: ArcadeVector(x: 1_200, y: 600), radius: 24) == false)

        var game = LastLightSimulation(players: [first, second], seed: 1)
        game.placeForTesting(first, at: ArcadeArena.center)
        game.setHazardsForTesting([
            Hazard(id: 2, kind: .block, position: ArcadeArena.center, velocity: .zero, armRemaining: 0.3),
        ])
        let events = game.step(deltaTime: 0.01, inputs: [:])
        #expect(!events.contains(.lostLife(first, remaining: 2)))
    }

    @Test func hazardWavesEscalateOnSchedule() {
        var game = LastLightSimulation(players: [first], seed: 3)
        #expect(abs(game.rainInterval - 0.55) < 0.000_1)
        var kinds: Set<String> = []
        var banners: [String] = []
        for _ in 0..<(46 * 60) {
            let events = game.step(deltaTime: 1.0 / 60.0, inputs: [first: ArcadeInput(axisX: 0.9, axisY: 0.9)])
            for case .banner(let text) in events { banners.append(text) }
            for hazard in game.hazards { kinds.insert("\(hazard.kind)") }
            if game.isFinished { break }
            game.setLivesForTesting(3, playerID: first)
        }
        #expect(kinds.isSuperset(of: ["block", "seeker"]))
        #expect(kinds.contains("rowSweeper") || kinds.contains("columnSweeper"))
        #expect(banners == ["SWEEPERS!", "SEEKERS!", "FINAL STRETCH"])
        #expect(game.rainInterval < 0.25)
        #expect(game.lightRadius < 260)
    }

    @Test func standingInTheLightScoresTripleOutsideIt() throws {
        var game = LastLightSimulation(players: [first, second], seed: 1)
        game.setHazardsForTesting([])
        game.placeForTesting(first, at: game.lightCenter)
        game.placeForTesting(second, at: ArcadeVector(x: ArcadeArena.minX + 40, y: ArcadeArena.minY + 40))

        _ = game.step(deltaTime: 0.05, inputs: [:])
        for _ in 0..<5 {
            game.setHazardsForTesting([])
            game.placeForTesting(first, at: game.lightCenter)
            _ = game.step(deltaTime: 0.05, inputs: [:])
        }

        let inLight = try #require(game.player(for: first)).score
        let inDark = try #require(game.player(for: second)).score
        #expect(inLight == inDark * 3)
        #expect(inDark == 1)
    }

    @Test func sameSeedAndInputsReplayIdentically() {
        func run() -> ([LastLightSimulation.Player], [Hazard]) {
            var game = LastLightSimulation(players: ArcadeHarness.playerIDs(3), seed: 77)
            for frame in 0..<1_200 {
                let angle = Double(frame) * 0.03
                let inputs = Dictionary(uniqueKeysWithValues: ArcadeHarness.playerIDs(3).enumerated().map { index, id in
                    (id, ArcadeInput(axisX: sin(angle + Double(index)), axisY: cos(angle * 0.7)))
                })
                _ = game.step(deltaTime: 1.0 / 60.0, inputs: inputs)
            }
            return (game.players, game.hazards)
        }
        let first = run()
        let second = run()
        #expect(first.0 == second.0)
        #expect(first.1 == second.1)
    }

    @Test func hardBotsDodgeBetterThanAnIdleOrb() {
        var botLives = 0
        var idleLives = 0
        for seed in UInt64(1)...3 {
            let result = ArcadeHarness.playOut(
                LastLightGame(), players: 2, seed: seed, difficulty: .hard,
                maximumSeconds: 70, idle: [PlayerID(1)]
            )
            let standings = result.outcome?.standings ?? []
            if standings.first?.playerID == PlayerID(0) { botLives += 1 } else { idleLives += 1 }
        }
        #expect(botLives > idleLives)
    }

    @Test func eightBotMatchCompletesWithFullStandings() throws {
        let result = ArcadeHarness.playOut(LastLightGame(), players: 8, difficulty: .hard, maximumSeconds: 70)
        let outcome = try #require(result.outcome)
        #expect(outcome.standings.count == 8)
        #expect(result.seconds <= 62)
    }
}
