import Foundation
import PartyBoxCore
import PartyGameRuntime
import PartyNet
import Testing
@testable import PartyGames

@Suite("Paint Rush")
@MainActor
struct PaintRushTests {
    private typealias Simulation = PaintRushSimulation

    private let frame = 1.0 / 60.0
    private let first = PlayerID(0)
    private let second = PlayerID(1)
    private let third = PlayerID(2)

    private static func stick(_ x: Double, _ y: Double = 0) -> ArcadeInput {
        ArcadeInput(axisX: x, axisY: y)
    }

    @discardableResult
    private func run(
        _ game: inout Simulation,
        frames: Int,
        inputs: [PlayerID: ArcadeInput] = [:]
    ) -> [ArcadeEvent] {
        var events: [ArcadeEvent] = []
        for _ in 0..<frames {
            events += game.step(deltaTime: frame, inputs: inputs)
        }
        return events
    }

    /// Tiles whose centers lie within `radius` of `point`.
    private func tiles(within radius: Double, of point: ArcadeVector) -> Set<Int> {
        Set((0..<Simulation.tileCount).filter { Simulation.tileCenter($0).distance(to: point) <= radius })
    }

    private func recount(_ game: Simulation, _ playerID: PlayerID) -> Int {
        (0..<Simulation.tileCount).count(where: { game.owner(ofTile: $0) == playerID })
    }

    private func context(_ count: Int, kind: PlayerKind = .human) -> GameSessionContext {
        GameSessionContext(
            participants: ArcadeHarness.participants(count, kind: kind),
            inputs: InputStore(),
            seed: 42,
            modifierID: nil
        )
    }

    // MARK: Painting

    @Test func movingPaintsTilesAndCrossingAnEnemyTileStealsIt() throws {
        var game = Simulation(players: [first, second], seed: 7)
        game.clearBoardForTesting()
        let contested = ArcadeArena.center
        let parked = ArcadeVector(x: 1_500, y: 250)
        let runway = contested - ArcadeVector(x: 200, y: 0)

        game.placeForTesting(second, at: contested)
        game.placeForTesting(first, at: runway)
        run(&game, frames: 1)
        let enemyBlot = tiles(within: Simulation.brushRadius, of: contested)
        #expect(!enemyBlot.isEmpty)
        #expect(enemyBlot.allSatisfy { game.owner(ofTile: $0) == second })
        #expect(game.owner(at: runway) == first)

        game.placeForTesting(second, at: parked)
        run(&game, frames: 1)
        let secondBefore = game.tiles(for: second)
        let firstBefore = game.tiles(for: first)
        #expect(secondBefore == enemyBlot.count + tiles(within: Simulation.brushRadius, of: parked).count)

        // Half a second at full stick covers 240 pt, straight through the enemy blot.
        run(&game, frames: 30, inputs: [first: Self.stick(1)])
        let puck = try #require(game.puck(for: first))
        #expect(abs(puck.position.x - (runway.x + 240)) < 0.001)
        #expect(abs(puck.position.y - runway.y) < 0.001)
        #expect(enemyBlot.allSatisfy { game.owner(ofTile: $0) == first })
        #expect(game.tiles(for: second) == secondBefore - enemyBlot.count)
        #expect(game.tiles(for: first) >= firstBefore + enemyBlot.count + 8)
        #expect(game.tiles(for: first) == recount(game, first))
        #expect(game.tiles(for: second) == recount(game, second))
    }

    @Test func stickInsideTheDeadZoneStandsStill() throws {
        var game = Simulation(players: [first], seed: 1)
        let start = ArcadeVector(x: 700, y: 400)
        game.placeForTesting(first, at: start)
        run(&game, frames: 30, inputs: [first: Self.stick(0.1, -0.1)])
        #expect(try #require(game.puck(for: first)).position == start)

        run(&game, frames: 30, inputs: [first: Self.stick(0, 0.5)])
        let moved = try #require(game.puck(for: first)).position
        #expect(abs(moved.y - (start.y + 120)) < 0.001)
        #expect(abs(moved.x - start.x) < 0.001)
    }

    @Test func pucksStayOnTheBoard() throws {
        var game = Simulation(players: [first], seed: 1)
        run(&game, frames: 240, inputs: [first: Self.stick(-1, 1)])
        let puck = try #require(game.puck(for: first))
        #expect(abs(puck.position.x - (Simulation.origin.x + Simulation.puckRadius)) < 0.001)
        #expect(abs(puck.position.y - (Simulation.origin.y + Simulation.boardSize.y - Simulation.puckRadius)) < 0.001)
        // The corner tile is still reachable by the brush.
        #expect(game.owner(ofTile: (Simulation.rows - 1) * Simulation.columns) == first)
    }

    @Test func pucksBumpApartWithoutStun() throws {
        var game = Simulation(players: [first, second], seed: 3)
        game.placeForTesting(first, at: ArcadeArena.center - ArcadeVector(x: 40, y: 0))
        game.placeForTesting(second, at: ArcadeArena.center + ArcadeVector(x: 40, y: 0))
        let events = run(&game, frames: 20, inputs: [first: Self.stick(1), second: Self.stick(-1)])
        let left = try #require(game.puck(for: first))
        let right = try #require(game.puck(for: second))
        #expect(left.position.distance(to: right.position) >= (Simulation.puckRadius * 2) - 0.001)
        #expect(left.position.x < right.position.x)
        #expect(events.contains(.haptic(first, .lightImpact)))
        #expect(events.contains(.haptic(second, .lightImpact)))

        // The shove decays and steering takes over again immediately.
        run(&game, frames: 60, inputs: [first: Self.stick(0, 1)])
        let steered = try #require(game.puck(for: first))
        #expect(steered.knock.length < 10)
        #expect(steered.position.y > left.position.y + 300)
    }

    @Test func frenzyDoublesTheBrushInTheLastTenSeconds() {
        let spot = ArcadeArena.center
        var calm = Simulation(players: [first], seed: 3)
        calm.clearBoardForTesting()
        calm.setElapsedForTesting(Simulation.duration - Simulation.frenzyDuration - 0.1)
        calm.placeForTesting(first, at: spot)
        let calmEvents = run(&calm, frames: 1)
        #expect(!calm.isFrenzy)
        #expect(calm.brushRadius == Simulation.brushRadius)
        #expect(calm.tiles(for: first) == tiles(within: Simulation.brushRadius, of: spot).count)
        #expect(!calmEvents.contains(.banner("FRENZY!")))

        var frenzy = Simulation(players: [first], seed: 3)
        frenzy.clearBoardForTesting()
        frenzy.setElapsedForTesting(Simulation.duration - Simulation.frenzyDuration)
        frenzy.placeForTesting(first, at: spot)
        let events = run(&frenzy, frames: 1)
        #expect(frenzy.isFrenzy)
        #expect(frenzy.brushRadius == Simulation.brushRadius * 2)
        let wide = tiles(within: Simulation.brushRadius * 2, of: spot)
        #expect(frenzy.tiles(for: first) == wide.count)
        #expect(wide.count > calm.tiles(for: first) * 2)
        #expect(events.contains(.banner("FRENZY!")))
        #expect(events.contains(.cue(first, colorHex: Simulation.frenzyColor, haptic: .heavyImpact)))
        #expect(!run(&frenzy, frames: 30).contains(.banner("FRENZY!")))
    }

    @Test func halfTimeBannerFiresOnceAtTwentyTwoAndAHalfSeconds() {
        var game = Simulation(players: [first, second], seed: 3)
        let before = run(&game, frames: 1_349)
        #expect(!before.contains(.banner("HALF TIME")))
        let at = run(&game, frames: 1)
        #expect(at.contains(.banner("HALF TIME")))
        #expect(abs(game.elapsed - Simulation.halfTime) < 0.000_001)
        #expect(!run(&game, frames: 60).contains(.banner("HALF TIME")))
    }

    // MARK: Power-ups

    @Test func splatPaintsEveryTileWithinThreeTiles() throws {
        var game = Simulation(players: [first, second], seed: 5)
        game.clearBoardForTesting()
        let column = 10
        let row = 10
        let spot = Simulation.tileCenter(column: column, row: row)
        // Some of the splat lands on rival paint and steals it.
        game.setOwnerForTesting(tile: (row * Simulation.columns) + column + 2, to: second)
        game.placeForTesting(second, at: ArcadeVector(x: 1_500, y: 800))
        game.placeForTesting(first, at: spot)
        game.addPowerUpForTesting(.splat, at: spot + ArcadeVector(x: 20, y: 0))

        let events = run(&game, frames: 1)

        #expect(game.powerUps.isEmpty)
        var expected: Set<Int> = []
        for dy in -3...3 {
            for dx in -3...3 where (dx * dx) + (dy * dy) <= 9 {
                expected.insert(((row + dy) * Simulation.columns) + column + dx)
            }
        }
        #expect(expected.count == 29)
        #expect(expected.allSatisfy { game.owner(ofTile: $0) == first })
        #expect(game.tiles(for: first) == 29)
        #expect(game.owner(at: spot + ArcadeVector(x: 0, y: 4 * Simulation.tileSize)) == nil)
        #expect(game.tiles(for: second) == recount(game, second))
        #expect(events.contains(.sound(.heavyImpact)))
        #expect(events.contains(.cue(first, colorHex: Simulation.splatColor, haptic: .heavyImpact)))
    }

    @Test func boostSpeedsUpForThreeSecondsThenExpires() throws {
        var game = Simulation(players: [first], seed: 5)
        let start = ArcadeVector(x: 500, y: 525)
        game.placeForTesting(first, at: start)
        game.addPowerUpForTesting(.boost, at: start)

        let pickup = run(&game, frames: 1, inputs: [first: Self.stick(1)])
        #expect(pickup.contains(.sound(.lightImpact)))
        #expect(pickup.contains(.cue(first, colorHex: Simulation.boostColor, haptic: .lightImpact)))
        #expect(game.powerUps.isEmpty)
        #expect(try #require(game.puck(for: first)).isBoosted)

        let boostedStart = try #require(game.puck(for: first)).position.x
        run(&game, frames: 1, inputs: [first: Self.stick(1)])
        let boostedStep = try #require(game.puck(for: first)).position.x - boostedStart
        #expect(abs(boostedStep - (Simulation.maximumSpeed * Simulation.boostMultiplier * frame)) < 0.000_001)

        run(&game, frames: 175)
        #expect(try #require(game.puck(for: first)).isBoosted)
        run(&game, frames: 5)
        #expect(!(try #require(game.puck(for: first)).isBoosted))

        let normalStart = try #require(game.puck(for: first)).position.x
        run(&game, frames: 1, inputs: [first: Self.stick(1)])
        let normalStep = try #require(game.puck(for: first)).position.x - normalStart
        #expect(abs(normalStep - (Simulation.maximumSpeed * frame)) < 0.000_001)
    }

    @Test func powerUpsSpawnEveryFiveSecondsAtMostTwoAtATime() {
        var game = Simulation(players: [first], seed: 11)
        run(&game, frames: 299)
        #expect(game.powerUps.isEmpty)
        run(&game, frames: 1)
        #expect(game.powerUps.count == 1)
        run(&game, frames: 300)
        #expect(game.powerUps.count == 2)
        run(&game, frames: 600)
        #expect(game.powerUps.count == 2)
        let puck = game.puck(for: first)
        for powerUp in game.powerUps {
            #expect(powerUp.position.distance(to: puck?.position ?? .zero) > Simulation.puckRadius + Simulation.powerUpRadius)
        }
    }

    // MARK: Scoring and flow

    @Test func standingsFollowTileCounts() throws {
        var game = Simulation(players: [first, second, third], seed: 9)
        game.clearBoardForTesting()
        for tile in 0..<50 { game.setOwnerForTesting(tile: tile, to: second) }
        for tile in 50..<80 { game.setOwnerForTesting(tile: tile, to: third) }
        for tile in 80..<90 { game.setOwnerForTesting(tile: tile, to: first) }

        let ranking = game.ranking()
        #expect(ranking.map(\.playerID) == [second, third, first])
        #expect(ranking.map(\.score) == [50, 30, 10])
        #expect(ranking.first?.detail == "50 tiles • 6%")
        #expect(game.scoreLine(for: second) == "50  6%")
        #expect(game.scoreLine(for: first) == "10  1%")
        #expect(game.resultMetric == MatchMetric(id: "most-tiles", label: "Most tiles", value: "50"))

        // The session reports the same order at the buzzer.
        var events: [GameEvent] = []
        let session = try #require(PaintRushGame().makeSession(
            context: context(3),
            onEvents: { events.append(contentsOf: $0) }
        ) as? ArcadeSession<PaintRushRenderer>)
        session.skipIntroForTesting()
        game.setElapsedForTesting(Simulation.duration - 0.05)
        session.simulationForTesting = game
        session.advanceForTesting(seconds: 0.2)

        #expect(session.isCompletedForTesting)
        let outcome = try #require(events.compactMap { event -> GameOutcome? in
            if case .completed(let outcome) = event { outcome } else { nil }
        }.first)
        #expect(outcome.standings.map(\.playerID) == [second, third, first])
        #expect(outcome.winner == second)
        #expect(outcome.metrics.first?.label == "Most tiles")
    }

    @Test func gameEndsExactlyAtFortyFiveSeconds() {
        var game = Simulation(players: [first, second], seed: 11)
        run(&game, frames: 2_699, inputs: [first: Self.stick(1, 0.3), second: Self.stick(-0.4, -1)])
        #expect(!game.isFinished)
        #expect((game.timeRemaining ?? 0) > 0.01)

        run(&game, frames: 1)
        #expect(game.isFinished)
        #expect(game.timeRemaining == 0)
        let frozen = game
        #expect(game.step(deltaTime: frame, inputs: [first: Self.stick(1)]).isEmpty)
        #expect(game == frozen)

        // A long frame never overshoots the buzzer.
        var coarse = Simulation(players: [first], seed: 11)
        coarse.setElapsedForTesting(Simulation.duration - 0.02)
        _ = coarse.step(deltaTime: 0.05, inputs: [:])
        #expect(coarse.isFinished)
        #expect(coarse.elapsed == Simulation.duration)
    }

    @Test func forfeitFreezesTilesAndPlayContinuesWhileAnyoneIsActive() throws {
        var game = Simulation(players: [first, second], seed: 2)
        run(&game, frames: 60, inputs: [first: Self.stick(0, 1), second: Self.stick(0, -1)])
        let frozenTiles = game.tiles(for: first)
        let frozenPosition = try #require(game.puck(for: first)).position

        #expect(game.forfeit(first) == [.eliminated(first)])
        #expect(game.forfeit(first).isEmpty)
        #expect(!game.isActive(first))
        #expect(game.isActive(second))
        #expect(!game.isFinished)

        run(&game, frames: 120, inputs: [first: Self.stick(1), second: Self.stick(0, 1)])
        #expect(game.tiles(for: first) == frozenTiles)
        #expect(try #require(game.puck(for: first)).position == frozenPosition)
        #expect(!game.isFinished)
        #expect(game.ranking().count == 2)

        #expect(game.forfeit(second) == [.eliminated(second)])
        #expect(game.isFinished)
    }

    @Test func sessionForfeitKeepsTheMatchRunningUntilTheBuzzer() throws {
        var events: [GameEvent] = []
        let session = try #require(PaintRushGame().makeSession(
            context: context(2),
            onEvents: { events.append(contentsOf: $0) }
        ) as? ArcadeSession<PaintRushRenderer>)
        session.skipIntroForTesting()
        session.advanceForTesting(seconds: 1)
        session.forfeit(first)

        #expect(events.contains(.eliminated(first)))
        #expect(!session.isCompletedForTesting)
        session.advanceForTesting(seconds: 50)
        #expect(session.isCompletedForTesting)
        let outcome = try #require(events.compactMap { event -> GameOutcome? in
            if case .completed(let outcome) = event { outcome } else { nil }
        }.first)
        #expect(outcome.winner == second)
        #expect(outcome.playerOutcomes.contains(.init(playerID: first, outcome: .forfeited)))
    }

    @Test func sameSeedAndScriptedInputsReplayIdentically() {
        func scripted(_ seed: UInt64) -> (Simulation, [ArcadeEvent]) {
            var game = Simulation(players: [first, second, third], seed: seed)
            var events: [ArcadeEvent] = []
            for index in 0..<2_700 {
                let time = Double(index) * frame
                events += game.step(deltaTime: frame, inputs: [
                    first: Self.stick(cos(time * 1.3), sin(time * 0.7)),
                    second: Self.stick(sin(time * 0.9), cos(time * 1.7)),
                    third: Self.stick(-cos(time * 0.5), 0.6),
                ])
            }
            return (game, events)
        }

        let (replayA, eventsA) = scripted(42)
        let (replayB, eventsB) = scripted(42)
        let (other, _) = scripted(43)
        #expect(replayA.isFinished)
        #expect(replayA == replayB)
        #expect(eventsA == eventsB)
        #expect(replayA.owners != other.owners || replayA.powerUps != other.powerUps)

        var randomA = ArcadeRandomNumberGenerator(seed: 9)
        var randomB = ArcadeRandomNumberGenerator(seed: 9)
        let live = Simulation(players: [first, second], seed: 4)
        #expect(
            live.botDecision(for: first, difficulty: .hard, random: &randomA)
                == live.botDecision(for: first, difficulty: .hard, random: &randomB)
        )
    }

    // MARK: Bots

    @Test func botsSteerAtFullStickTowardPaintAndPowerUps() throws {
        var game = Simulation(players: [first], seed: 8)
        var random = ArcadeRandomNumberGenerator(seed: 1)
        let decision = game.botDecision(for: first, difficulty: .hard, random: &random)
        #expect(abs(ArcadeVector(x: decision.axisX, y: decision.axisY).length - 1) < 0.001)

        let spot = ArcadeVector(x: 700, y: 525)
        game.placeForTesting(first, at: spot)
        game.addPowerUpForTesting(.splat, at: spot + ArcadeVector(x: 0, y: -220))
        let grab = game.botDecision(for: first, difficulty: .hard, random: &random)
        #expect(grab.axisY < -0.99)

        // With its own paint all around, the bot heads for unpainted floor.
        var painted = Simulation(players: [first], seed: 8)
        painted.placeForTesting(first, at: Simulation.tileCenter(column: 5, row: 11))
        for row in 0..<Simulation.rows {
            for column in 0..<30 { painted.setOwnerForTesting(tile: (row * Simulation.columns) + column, to: first) }
        }
        let escape = painted.botDecision(for: first, difficulty: .hard, random: &random)
        #expect(escape.axisX > 0.5)

        #expect(Simulation.botReactionInterval(for: .easy) == 0.4)
        #expect(Simulation.botReactionInterval(for: .normal) == 0.25)
        #expect(Simulation.botReactionInterval(for: .hard) == 0.15)
    }

    @Test func eightHardBotsPlayTheFullFortyFiveSeconds() throws {
        let result = ArcadeHarness.playOut(PaintRushGame(), players: 8, difficulty: .hard)
        let outcome = try #require(result.outcome)
        #expect(abs(result.seconds - 46.5) < 0.1)
        #expect(outcome.standings.count == 8)
        #expect(result.eliminated.isEmpty)
        let scores = outcome.standings.map(\.score)
        #expect(scores == scores.sorted(by: >))
        #expect(scores.allSatisfy { $0 > 0 })
        #expect(scores.reduce(0, +) <= Simulation.tileCount)
        #expect(outcome.winner == outcome.standings.first?.playerID)
        #expect(outcome.metrics == [MatchMetric(id: "most-tiles", label: "Most tiles", value: "\(scores[0])")])
    }

    @Test(arguments: [GameBotDifficulty.easy, .hard])
    func soloBotCoversMoreThanAQuarterOfTheFloor(difficulty: GameBotDifficulty) throws {
        let result = ArcadeHarness.playOut(PaintRushGame(), players: 1, difficulty: difficulty)
        let outcome = try #require(result.outcome)
        #expect(outcome.title == "PRACTICE COMPLETE")
        let tiles = try #require(outcome.standings.first?.score)
        #expect(Double(tiles) / Double(Simulation.tileCount) > 0.25)
    }

    // MARK: Phone and TV

    @Test func descriptorAndControllerScreenMatchTheSpec() {
        let game = PaintRushGame()
        #expect(game.descriptor.id == "paint-rush")
        #expect(game.descriptor.title == "PAINT RUSH")
        #expect(game.descriptor.summary == "1–8 players  •  Claim the most floor in 45 seconds")
        #expect(game.descriptor.estimatedDurationSeconds == 50)
        #expect(game.descriptor.supportsMotion)
        #expect(game.descriptor.minimumPlayers == 1)
        #expect(game.descriptor.maximumPlayers == 8)
        #expect(PartyGames.all().contains { $0.descriptor.id == "paint-rush" })

        let session = game.makeSession(context: context(8, kind: .bot), onEvents: { _ in })
        let screen = session.controllerScreen(for: second)
        #expect(screen.isValid)
        #expect(screen.accessibilityID == "controller.layout.paint-rush")
        #expect(screen.requestedInputs == .orientation)
        #expect(screen.components.contains(.text(.init(
            id: "paint.rule",
            text: "PAINT THE FLOOR • STEAL THEIR COLOR",
            style: .caption,
            tint: .secondary
        ))))
        #expect(screen.components.contains(.axisSurface(.init(
            id: "paint.steer",
            binding: .twoDimensional,
            instruction: "DRAG TO MOVE  •  MOTION OPTIONAL",
            swipe: .heading
        ))))
    }

    @Test func rendererRecolorsOnlyChangedTilesAndTracksTheShareBar() {
        let participants = ArcadeHarness.participants(2)
        let scene = ArcadeScene(title: "PAINT RUSH", players: participants.map(\.player))
        var game = Simulation(players: participants.map(\.player.id), seed: 6)
        let renderer = PaintRushRenderer()
        renderer.build(in: scene, simulation: game)
        renderer.render(game, events: [], in: scene)
        #expect(renderer.tileSpriteCountForTesting == Simulation.tileCount)
        #expect(renderer.shownOwnersForTesting == game.owners)

        let neutral = renderer.tileColorForTesting(0)
        game.placeForTesting(first, at: Simulation.tileCenter(0))
        run(&game, frames: 1)
        renderer.render(game, events: [], in: scene)
        #expect(renderer.shownOwnersForTesting == game.owners)
        #expect(renderer.tileColorForTesting(0) != neutral)
        #expect(renderer.tileColorForTesting(Simulation.tileCount - 1) == neutral)

        let widths = renderer.barWidthsForTesting
        #expect(widths.count == 2)
        let expected = Simulation.boardSize.x * Double(game.tiles(for: first)) / Double(Simulation.tileCount)
        #expect(abs(Double(widths[0]) - expected) < 0.001)
    }
}
