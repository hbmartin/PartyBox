import Foundation
import PartyBoxCore
import PartyGameRuntime
import PartyNet

/// Light-cycle arena: permanent trails, ramping tick speed, three lives.
struct SnakePitSimulation: ArcadeSimulation {
    static let columns = 60
    static let rows = 33
    static let cellSize = 22.0
    static let origin = ArcadeVector(x: 960 - (Double(columns) * cellSize / 2), y: 525 - (Double(rows) * cellSize / 2))
    static let duration = 60.0
    static let startingLives = 3
    static let startTickInterval = 0.09
    static let fastestTickInterval = 0.05
    static let rampDuration = 45.0
    static let respawnDelay = 0.8
    static let ghostDuration = 1.0
    static let pelletValue = 20
    static let crashCreditValue = 15
    static let maximumBufferedTurns = 2
    static let pelletColor = "#FFD60A"

    struct Cell: Hashable, Sendable {
        var column: Int
        var row: Int

        func moved(_ direction: ArcadeDirection) -> Cell {
            Cell(column: column + direction.dx, row: row + direction.dy)
        }

        var isInside: Bool {
            (0..<SnakePitSimulation.columns).contains(column) && (0..<SnakePitSimulation.rows).contains(row)
        }

        var index: Int { row * SnakePitSimulation.columns + column }

        var center: ArcadeVector {
            SnakePitSimulation.origin + ArcadeVector(
                x: (Double(column) + 0.5) * SnakePitSimulation.cellSize,
                y: (Double(row) + 0.5) * SnakePitSimulation.cellSize
            )
        }
    }

    struct Snake: Equatable, Sendable {
        let playerID: PlayerID
        var head: Cell
        var direction: ArcadeDirection
        var pendingTurns: [ArcadeDirection] = []
        var stickDirection: ArcadeDirection?
        var trail: [Cell]
        var lives: Int
        var score = 0
        var crashCredits = 0
        var respawnRemaining = 0.0
        var ghostRemaining = 0.0
        /// Increments whenever the trail is wiped so renderers can dissolve it.
        var trailGeneration = 0

        var alive: Bool { lives > 0 }
        var onBoard: Bool { alive && respawnRemaining <= 0 }
        var isGhost: Bool { onBoard && ghostRemaining > 0 }
    }

    private(set) var snakes: [Snake]
    private(set) var pellet: Cell?
    private(set) var elapsed = 0.0
    private(set) var isFinished = false
    private(set) var tickCount = 0
    private var tickAccumulator = 0.0
    private var occupancy: [Int16]
    private var random: ArcadeRandomNumberGenerator
    private var eliminationOrder = ArcadeEliminations()
    private let indexByID: [PlayerID: Int]
    private let multiplayer: Bool
    private var announcedRampStage = 0

    static let startSlots: [(Cell, ArcadeDirection)] = [
        (Cell(column: 8, row: 6), .right),
        (Cell(column: 51, row: 22), .left),
        (Cell(column: 8, row: 26), .right),
        (Cell(column: 51, row: 10), .left),
        (Cell(column: 30, row: 2), .up),
        (Cell(column: 37, row: 30), .down),
        (Cell(column: 3, row: 14), .up),
        (Cell(column: 56, row: 18), .down),
    ]

    init(players: [PlayerID], seed: UInt64) {
        random = ArcadeRandomNumberGenerator(seed: ArcadeRandomNumberGenerator.mixed(seed, 0x5A4B))
        occupancy = Array(repeating: -1, count: Self.columns * Self.rows)
        multiplayer = players.count > 1
        indexByID = Dictionary(players.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        snakes = players.enumerated().map { index, playerID in
            let slot = Self.startSlots[index % Self.startSlots.count]
            return Snake(playerID: playerID, head: slot.0, direction: slot.1, trail: [slot.0], lives: Self.startingLives)
        }
        for (index, snake) in snakes.enumerated() {
            occupancy[snake.head.index] = Int16(index)
        }
        spawnPellet()
    }

    // MARK: ArcadeSimulation

    var timeRemaining: Double? { max(0, Self.duration - elapsed) }

    var tickInterval: Double {
        arcadeRamp(from: Self.startTickInterval, to: Self.fastestTickInterval, start: 0, end: Self.rampDuration, at: elapsed)
    }

    func isActive(_ playerID: PlayerID) -> Bool {
        indexByID[playerID].map { snakes[$0].alive } ?? false
    }

    func snake(for playerID: PlayerID) -> Snake? {
        indexByID[playerID].map { snakes[$0] }
    }

    func owner(of cell: Cell) -> PlayerID? {
        guard cell.isInside else { return nil }
        let owner = occupancy[cell.index]
        return owner >= 0 ? snakes[Int(owner)].playerID : nil
    }

    mutating func step(deltaTime: Double, inputs: [PlayerID: ArcadeInput]) -> [ArcadeEvent] {
        guard !isFinished else { return [] }
        let delta = min(max(deltaTime, 0), 0.05)
        var events: [ArcadeEvent] = []
        ingest(inputs)
        elapsed += delta
        announceRamp(events: &events)
        advanceTimers(delta: delta, events: &events)
        tickAccumulator += delta
        while tickAccumulator >= tickInterval, !isFinished {
            tickAccumulator -= tickInterval
            tick(events: &events)
        }
        if !isFinished, elapsed >= Self.duration { isFinished = true }
        return events
    }

    mutating func forfeit(_ playerID: PlayerID) -> [ArcadeEvent] {
        guard !isFinished, let index = indexByID[playerID], snakes[index].alive else { return [] }
        snakes[index].lives = 0
        clearTrail(of: index)
        eliminationOrder.record(playerID)
        var events: [ArcadeEvent] = [.eliminated(playerID)]
        finishIfDecided(events: &events)
        return events
    }

    func ranking() -> [ArcadeRankEntry] {
        ArcadeRanking.bySurvival(
            snakes,
            id: \.playerID,
            alive: \.alive,
            lives: { _ in 0 },
            score: \.score,
            eliminationOrder: eliminationOrder,
            shareTiedPlacements: true,
            detail: { "\($0.lives) lives • \($0.crashCredits) crashes caused" }
        )
    }

    func scoreLine(for playerID: PlayerID) -> String {
        guard let snake = snake(for: playerID) else { return "" }
        return "\(snake.score)  \(ArcadeRanking.lives(snake.lives))"
    }

    var resultMetric: MatchMetric {
        .init(id: "top-score", label: "Top score", value: "\(snakes.map(\.score).max() ?? 0)")
    }

    static func botReactionInterval(for difficulty: GameBotDifficulty) -> Double {
        switch difficulty {
        case .easy: 0.2
        case .normal: 0.11
        case .hard: 0.05
        }
    }

    func botDecision(
        for playerID: PlayerID,
        difficulty: GameBotDifficulty,
        random: inout ArcadeRandomNumberGenerator
    ) -> ArcadeBotDecision {
        guard let snake = snake(for: playerID), snake.onBoard else { return .idle }
        let depth = switch difficulty {
        case .easy: 12
        case .normal: 20
        case .hard: 40
        }
        let candidates = [snake.direction, snake.direction.turnedLeft, snake.direction.turnedRight]
        var scored: [(direction: ArcadeDirection, score: Double)] = []
        for direction in candidates {
            let next = snake.head.moved(direction)
            guard next.isInside, snake.isGhost || occupancy[next.index] < 0 else {
                scored.append((direction, -1_000))
                continue
            }
            var score = Double(freeSpace(from: next, limit: depth))
            if headThreat(at: next, excluding: playerID) { score -= Double(depth) * 0.6 }
            if difficulty != .easy, let pellet, score >= Double(depth) * 0.75 {
                let before = abs(snake.head.column - pellet.column) + abs(snake.head.row - pellet.row)
                let after = abs(next.column - pellet.column) + abs(next.row - pellet.row)
                if after < before { score += 4 }
            }
            if direction == snake.direction { score += 0.5 }
            scored.append((direction, score))
        }
        var choice = scored.max { $0.score < $1.score }?.direction ?? snake.direction
        if difficulty == .easy, random.chance(0.1) {
            let safe = scored.filter { $0.score > 0 }
            if !safe.isEmpty { choice = safe[random.index(below: safe.count)].direction }
        }
        let axes = choice.axes
        return ArcadeBotDecision(axisX: Double(axes.x), axisY: Double(axes.y))
    }

    // MARK: Simulation

    private mutating func ingest(_ inputs: [PlayerID: ArcadeInput]) {
        for index in snakes.indices where snakes[index].alive {
            guard let input = inputs[snakes[index].playerID] else { continue }
            for turn in input.turns {
                let last = snakes[index].pendingTurns.last ?? snakes[index].direction
                guard turn != last, turn != last.opposite else { continue }
                if snakes[index].pendingTurns.count < Self.maximumBufferedTurns {
                    snakes[index].pendingTurns.append(turn)
                }
            }
            snakes[index].stickDirection = ArcadeDirection.dominant(x: input.axisX, y: input.axisY)
        }
    }

    private mutating func announceRamp(events: inout [ArcadeEvent]) {
        let stage = min(3, Int(elapsed / 15))
        guard stage > announcedRampStage else { return }
        announcedRampStage = stage
        events.append(.banner(stage == 3 ? "MAX SPEED" : "SPEED UP"))
        events.append(.sound(.lightImpact))
    }

    private mutating func advanceTimers(delta: Double, events: inout [ArcadeEvent]) {
        for index in snakes.indices where snakes[index].alive {
            if snakes[index].respawnRemaining > 0 {
                snakes[index].respawnRemaining -= delta
                if snakes[index].respawnRemaining <= 0 { respawn(index) }
            } else if snakes[index].ghostRemaining > 0 {
                snakes[index].ghostRemaining -= delta
                if snakes[index].ghostRemaining <= 0 {
                    let head = snakes[index].head
                    if occupancy[head.index] >= 0 {
                        // Stay ghosted until the head is on open floor.
                        snakes[index].ghostRemaining = 0.000_1
                    } else {
                        snakes[index].ghostRemaining = 0
                        snakes[index].trail = [head]
                        occupancy[head.index] = Int16(index)
                    }
                }
            }
        }
    }

    private mutating func tick(events: inout [ArcadeEvent]) {
        tickCount += 1
        let movers = snakes.indices.filter { snakes[$0].onBoard }
        var nextHeads: [Int: Cell] = [:]
        for index in movers {
            var snake = snakes[index]
            var turned = false
            while let turn = snake.pendingTurns.first {
                snake.pendingTurns.removeFirst()
                if turn != snake.direction, turn != snake.direction.opposite {
                    snake.direction = turn
                    turned = true
                    break
                }
            }
            if !turned, let stick = snake.stickDirection,
               stick != snake.direction, stick != snake.direction.opposite {
                snake.direction = stick
            }
            snakes[index] = snake
            nextHeads[index] = snake.head.moved(snake.direction)
        }

        var crashed: Set<Int> = []
        var credits: [Int: Int] = [:]
        for index in movers {
            guard let next = nextHeads[index] else { continue }
            guard next.isInside else {
                crashed.insert(index)
                continue
            }
            guard !snakes[index].isGhost else { continue }
            let owner = Int(occupancy[next.index])
            if owner >= 0 {
                crashed.insert(index)
                if owner != index { credits[owner, default: 0] += 1 }
                continue
            }
            let rivals = movers.filter { $0 != index && !snakes[$0].isGhost && nextHeads[$0] == next }
            if !rivals.isEmpty { crashed.insert(index) }
        }

        for index in movers where !crashed.contains(index) {
            guard let next = nextHeads[index] else { continue }
            snakes[index].head = next
            snakes[index].score += 1
            if !snakes[index].isGhost {
                snakes[index].trail.append(next)
                occupancy[next.index] = Int16(index)
            }
            if next == pellet {
                snakes[index].score += Self.pelletValue
                events.append(.sound(.lightImpact))
                events.append(.cue(snakes[index].playerID, colorHex: Self.pelletColor, haptic: .lightImpact))
                pellet = nil
            }
        }

        for (owner, count) in credits.sorted(by: { $0.key < $1.key }) where snakes[owner].alive {
            snakes[owner].score += count * Self.crashCreditValue
            snakes[owner].crashCredits += count
            events.append(.cue(snakes[owner].playerID, colorHex: ArcadeOutcomeBuilder.winnerColor, haptic: .lightImpact))
        }

        let firstCrashEvent = events.count
        for index in crashed.sorted() {
            crash(index, events: &events)
        }
        if pellet == nil { spawnPellet() }
        if !crashed.isEmpty {
            eliminationOrder.recordBatch(events[firstCrashEvent...])
            finishIfDecided(events: &events)
        }
    }

    private mutating func crash(_ index: Int, events: inout [ArcadeEvent]) {
        clearTrail(of: index)
        snakes[index].lives -= 1
        snakes[index].pendingTurns = []
        if snakes[index].lives <= 0 {
            snakes[index].lives = 0
            events.append(.eliminated(snakes[index].playerID))
        } else {
            snakes[index].respawnRemaining = Self.respawnDelay
            events.append(.lostLife(snakes[index].playerID, remaining: snakes[index].lives))
        }
    }

    private mutating func clearTrail(of index: Int) {
        for cell in snakes[index].trail where occupancy[cell.index] == Int16(index) {
            occupancy[cell.index] = -1
        }
        snakes[index].trail = []
        snakes[index].trailGeneration += 1
    }

    private mutating func finishIfDecided(events: inout [ArcadeEvent]) {
        let alive = snakes.count(where: \.alive)
        if alive == 0 || (multiplayer && alive <= 1) { isFinished = true }
    }

    private mutating func respawn(_ index: Int) {
        let (cell, direction) = safestSpawn(for: index)
        snakes[index].respawnRemaining = 0
        snakes[index].head = cell
        snakes[index].direction = direction
        snakes[index].pendingTurns = []
        snakes[index].trail = []
        snakes[index].ghostRemaining = Self.ghostDuration
    }

    /// The open cell farthest from every trail and head, facing its longest run.
    private func safestSpawn(for index: Int) -> (Cell, ArcadeDirection) {
        let blockers: [Cell] = snakes.enumerated().flatMap { offset, snake -> [Cell] in
            guard offset != index, snake.onBoard else { return [] }
            return snake.trail + [snake.head]
        }
        var best: (cell: Cell, direction: ArcadeDirection, score: Int)?
        for row in stride(from: 3, to: Self.rows - 3, by: 3) {
            for column in stride(from: 3, to: Self.columns - 3, by: 3) {
                let cell = Cell(column: column, row: row)
                guard occupancy[cell.index] < 0 else { continue }
                let clearance = blockers.map { abs($0.column - column) + abs($0.row - row) }.min() ?? 99
                let (direction, run) = ArcadeDirection.allCases.map { ($0, runLength(from: cell, direction: $0)) }
                    .max { $0.1 < $1.1 } ?? (.right, 0)
                let score = min(clearance, 20) * 10 + min(run, 20)
                if best == nil || score > best!.score {
                    best = (cell, direction, score)
                }
            }
        }
        return best.map { ($0.cell, $0.direction) } ?? (Self.startSlots[index % Self.startSlots.count].0, .right)
    }

    private func runLength(from cell: Cell, direction: ArcadeDirection) -> Int {
        var length = 0
        var current = cell.moved(direction)
        while current.isInside, occupancy[current.index] < 0, length < 30 {
            length += 1
            current = current.moved(direction)
        }
        return length
    }

    private mutating func spawnPellet() {
        let heads = snakes.filter(\.onBoard).map(\.head)
        for _ in 0..<40 {
            let cell = Cell(column: 2 + random.index(below: Self.columns - 4), row: 2 + random.index(below: Self.rows - 4))
            guard occupancy[cell.index] < 0 else { continue }
            if heads.contains(where: { abs($0.column - cell.column) + abs($0.row - cell.row) < 6 }) { continue }
            pellet = cell
            return
        }
        pellet = nil
    }

    private func freeSpace(from start: Cell, limit: Int) -> Int {
        var visited: Set<Int> = [start.index]
        var queue = [start]
        var cursor = 0
        while cursor < queue.count, visited.count < limit {
            let cell = queue[cursor]
            cursor += 1
            for direction in ArcadeDirection.allCases {
                let next = cell.moved(direction)
                guard next.isInside, occupancy[next.index] < 0, visited.insert(next.index).inserted else { continue }
                queue.append(next)
                if visited.count >= limit { break }
            }
        }
        return visited.count
    }

    private func headThreat(at cell: Cell, excluding playerID: PlayerID) -> Bool {
        snakes.contains { snake in
            guard snake.playerID != playerID, snake.onBoard, !snake.isGhost else { return false }
            return abs(snake.head.column - cell.column) + abs(snake.head.row - cell.row) <= 1
        }
    }

    mutating func placeForTesting(_ playerID: PlayerID, at cell: Cell, direction: ArcadeDirection) {
        guard let index = indexByID[playerID] else { return }
        clearTrail(of: index)
        snakes[index].head = cell
        snakes[index].direction = direction
        snakes[index].trail = [cell]
        snakes[index].ghostRemaining = 0
        snakes[index].respawnRemaining = 0
        occupancy[cell.index] = Int16(index)
    }

    mutating func setLivesForTesting(_ lives: Int, playerID: PlayerID) {
        guard let index = indexByID[playerID] else { return }
        snakes[index].lives = lives
    }

    mutating func removePelletForTesting() { pellet = nil }
    mutating func setPelletForTesting(_ cell: Cell) { pellet = cell }

    /// Advances exactly one grid tick.
    mutating func tickForTesting(inputs: [PlayerID: ArcadeInput] = [:]) -> [ArcadeEvent] {
        _ = step(deltaTime: 0, inputs: inputs)
        var events: [ArcadeEvent] = []
        tick(events: &events)
        return events
    }
}
