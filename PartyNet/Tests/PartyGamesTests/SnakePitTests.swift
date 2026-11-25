import Foundation
import PartyBoxCore
import PartyGameRuntime
import PartyNet
import Testing
@testable import PartyGames

@Suite("Snake Pit")
@MainActor
struct SnakePitTests {
    private typealias Cell = SnakePitSimulation.Cell
    private let first = PlayerID(0)
    private let second = PlayerID(1)

    private func duel(seed: UInt64 = 42) -> SnakePitSimulation {
        var game = SnakePitSimulation(players: [first, second], seed: seed)
        game.removePelletForTesting()
        return game
    }

    @Test func gridIsIsotropicAndTickRateRampsToMaximumSpeed() {
        var game = duel()
        #expect(abs(game.tickInterval - 0.09) < 0.000_1)
        for _ in 0..<(45 * 60) { _ = game.step(deltaTime: 1.0 / 60.0, inputs: [:]) }
        #expect(game.isFinished || abs(game.tickInterval - 0.05) < 0.000_1)
        let a = Cell(column: 10, row: 10).center
        let right = Cell(column: 11, row: 10).center
        let up = Cell(column: 10, row: 11).center
        #expect(abs(a.distance(to: right) - a.distance(to: up)) < 0.000_1)
    }

    @Test func trailsArePermanentAndCrashingIntoOneCreditsItsOwner() {
        var game = duel()
        game.placeForTesting(first, at: Cell(column: 10, row: 25), direction: .right)
        game.placeForTesting(second, at: Cell(column: 20, row: 5), direction: .up)
        for _ in 0..<12 { _ = game.tickForTesting() }
        let trail = game.snake(for: second)?.trail ?? []
        #expect(trail.count == 13)
        #expect(game.owner(of: Cell(column: 20, row: 5)) == second)

        // First player's row 10 run reaches column 20 where the second trail sits.
        game.placeForTesting(first, at: Cell(column: 18, row: 10), direction: .right)
        var events: [ArcadeEvent] = []
        for _ in 0..<2 { events += game.tickForTesting() }

        #expect(events.contains(.lostLife(first, remaining: 2)))
        #expect(game.snake(for: second)?.crashCredits == 1)
        #expect(game.snake(for: first)?.trail.isEmpty == true)
        #expect(game.owner(of: Cell(column: 18, row: 10)) == nil)
    }

    @Test func headOnCollisionsCostBothPlayersALife() {
        var game = duel()
        game.placeForTesting(first, at: Cell(column: 10, row: 10), direction: .right)
        game.placeForTesting(second, at: Cell(column: 12, row: 10), direction: .left)

        let events = game.tickForTesting()

        #expect(events.contains(.lostLife(first, remaining: 2)))
        #expect(events.contains(.lostLife(second, remaining: 2)))
        #expect(game.snake(for: first)?.crashCredits == 0)
        #expect(game.snake(for: second)?.crashCredits == 0)
    }

    @Test func swappingHeadsIsAlsoACrash() {
        var game = duel()
        game.placeForTesting(first, at: Cell(column: 10, row: 10), direction: .right)
        game.placeForTesting(second, at: Cell(column: 11, row: 10), direction: .left)

        let events = game.tickForTesting()

        #expect(events.contains(.lostLife(first, remaining: 2)))
        #expect(events.contains(.lostLife(second, remaining: 2)))
    }

    @Test func twoBufferedTurnsResolveOnConsecutiveTicksAndReversalsAreIgnored() {
        var game = duel()
        game.placeForTesting(first, at: Cell(column: 10, row: 10), direction: .right)
        game.placeForTesting(second, at: Cell(column: 40, row: 25), direction: .left)

        // A quick U-turn: up then left inside one tick window, plus a stray reversal.
        _ = game.tickForTesting(inputs: [first: ArcadeInput(turns: [.left, .up, .left, .down])])
        #expect(game.snake(for: first)?.direction == .up)
        #expect(game.snake(for: first)?.head == Cell(column: 10, row: 11))
        _ = game.tickForTesting()
        #expect(game.snake(for: first)?.direction == .left)
        #expect(game.snake(for: first)?.head == Cell(column: 9, row: 11))
        _ = game.tickForTesting()
        #expect(game.snake(for: first)?.direction == .left)
    }

    @Test func crashedSnakesRespawnGhostedOnOpenFloorFacingOpenSpace() throws {
        var game = duel()
        game.placeForTesting(first, at: Cell(column: 59, row: 10), direction: .right)
        game.placeForTesting(second, at: Cell(column: 30, row: 20), direction: .left)
        _ = game.tickForTesting()
        #expect(game.snake(for: first)?.onBoard == false)

        for _ in 0..<50 { _ = game.step(deltaTime: 1.0 / 60.0, inputs: [:]) }
        let respawned = try #require(game.snake(for: first))
        #expect(respawned.onBoard)
        #expect(respawned.isGhost)
        #expect(respawned.trail.isEmpty)
        #expect(respawned.lives == 2)
    }

    @Test func pelletsAwardBonusPoints() {
        var game = duel()
        game.placeForTesting(first, at: Cell(column: 10, row: 10), direction: .right)
        game.placeForTesting(second, at: Cell(column: 40, row: 25), direction: .left)
        game.setPelletForTesting(Cell(column: 11, row: 10))

        let events = game.tickForTesting()

        #expect(game.snake(for: first)?.score == 1 + SnakePitSimulation.pelletValue)
        #expect(events.contains(.cue(first, colorHex: SnakePitSimulation.pelletColor, haptic: .lightImpact)))
        #expect(game.pellet != Cell(column: 11, row: 10))
    }

    @Test func eliminationEndsMultiplayerAndLastSurvivorRanksFirst() {
        var game = duel()
        game.setLivesForTesting(1, playerID: first)
        game.placeForTesting(first, at: Cell(column: 0, row: 10), direction: .left)
        game.placeForTesting(second, at: Cell(column: 30, row: 20), direction: .left)

        let events = game.tickForTesting()

        #expect(events.contains(.eliminated(first)))
        #expect(game.isFinished)
        #expect(game.ranking().map(\.playerID) == [second, first])
    }

    @Test func sameSeedAndInputsReplayIdentically() {
        func run() -> [SnakePitSimulation.Snake] {
            var game = SnakePitSimulation(players: ArcadeHarness.playerIDs(4), seed: 99)
            var random = ArcadeRandomNumberGenerator(seed: 5)
            for frame in 0..<900 {
                var inputs: [PlayerID: ArcadeInput] = [:]
                if frame.isMultiple(of: 9) {
                    for playerID in ArcadeHarness.playerIDs(4) {
                        inputs[playerID] = ArcadeInput(turns: [ArcadeDirection.allCases[random.index(below: 4)]])
                    }
                }
                _ = game.step(deltaTime: 1.0 / 60.0, inputs: inputs)
            }
            return game.snakes
        }
        #expect(run() == run())
    }

    @Test func hardBotsOutlastEasyOnesOnTheSameBoard() {
        var survivedHard = 0
        var survivedEasy = 0
        for seed in UInt64(1)...4 {
            let hard = ArcadeHarness.playOut(SnakePitGame(), players: 1, seed: seed, difficulty: .hard, maximumSeconds: 70)
            let easy = ArcadeHarness.playOut(SnakePitGame(), players: 1, seed: seed, difficulty: .easy, maximumSeconds: 70)
            survivedHard += hard.outcome?.standings.first?.score ?? 0
            survivedEasy += easy.outcome?.standings.first?.score ?? 0
        }
        #expect(survivedHard > survivedEasy)
    }

    @Test func hardSoloBotSurvivesMostOfTheRound() {
        let result = ArcadeHarness.playOut(SnakePitGame(), players: 1, seed: 7, difficulty: .hard, maximumSeconds: 70)
        #expect(result.outcome != nil)
        #expect(result.seconds > 30)
    }

    @Test func eightBotMatchCompletesWithFullStandings() throws {
        let result = ArcadeHarness.playOut(SnakePitGame(), players: 8, difficulty: .hard, maximumSeconds: 70)
        let outcome = try #require(result.outcome)
        #expect(outcome.standings.count == 8)
        #expect(Set(outcome.standings.map(\.playerID)).count == 8)
        #expect(result.seconds <= 62)
    }
}
