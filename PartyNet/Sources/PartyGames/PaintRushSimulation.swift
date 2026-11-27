import Foundation
import PartyBoxCore
import PartyGameRuntime
import PartyNet

/// 45-second territory war: drive a puck over the floor to paint it in your
/// color, steal rivals' tiles, grab power-ups. Most tiles at the buzzer wins.
struct PaintRushSimulation: ArcadeSimulation, Equatable {
    static let columns = 40
    static let rows = 22
    static let tileSize = 33.0
    static let tileCount = columns * rows
    static let boardSize = ArcadeVector(x: Double(columns) * tileSize, y: Double(rows) * tileSize)
    /// Bottom-left corner of the board in scene points; row 0 is the bottom row.
    static let origin = ArcadeArena.center - (boardSize / 2)
    static let duration = 45.0
    static let halfTime = duration / 2
    static let frenzyDuration = 10.0
    static let puckRadius = 26.0
    static let brushRadius = 30.0
    static let frenzyBrushMultiplier = 2.0
    static let maximumSpeed = 480.0
    static let deadZone = 0.15
    static let boostMultiplier = 1.6
    static let boostDuration = 3.0
    static let splatRadiusTiles = 3
    static let powerUpInterval = 5.0
    static let maximumPowerUps = 2
    static let powerUpRadius = 22.0
    static let powerUpClearance = 160.0
    static let bumpPush = 180.0
    static let maximumKnock = 360.0
    static let knockDecay = 6.0
    static let bumpHapticCooldown = 0.5
    static let boostColor = "#FFD60A"
    static let splatColor = "#FF4FD8"
    static let frenzyColor = "#FF375F"
    /// Guards the 1/60 s frame sum so the clock lands on whole-second marks.
    private static let timeEpsilon = 0.000_000_1

    enum PowerUpKind: Equatable, Sendable {
        /// ×1.6 speed for 3 s.
        case boost
        /// Instantly paints a 3-tile-radius circle.
        case splat

        var label: String {
            switch self {
            case .boost: "BOOST"
            case .splat: "SPLAT"
            }
        }

        var colorHex: String {
            switch self {
            case .boost: PaintRushSimulation.boostColor
            case .splat: PaintRushSimulation.splatColor
            }
        }
    }

    struct PowerUp: Equatable, Sendable {
        let id: Int
        let kind: PowerUpKind
        let position: ArcadeVector
    }

    struct Puck: Equatable, Sendable {
        let playerID: PlayerID
        var position: ArcadeVector
        var velocity = ArcadeVector.zero
        /// Decaying shove from bumping into other pucks, added to the stick velocity.
        var knock = ArcadeVector.zero
        var boostRemaining = 0.0
        var bumpCooldown = 0.0
        /// False once the player forfeits: their tiles stay but stop growing.
        var active = true

        var isBoosted: Bool { boostRemaining > 0 }
    }

    private(set) var pucks: [Puck]
    /// Owning player index per tile (`row * columns + column`), -1 for neutral.
    private(set) var owners: [Int8]
    /// Tiles owned, by player index.
    private(set) var tileCounts: [Int]
    private(set) var powerUps: [PowerUp] = []
    private(set) var elapsed = 0.0
    private(set) var isFinished = false
    private(set) var frameCount = 0
    private var random: ArcadeRandomNumberGenerator
    private var powerUpAccumulator = 0.0
    private var nextPowerUpID = 0
    private var announcedHalfTime = false
    private var announcedFrenzy = false
    private let indexByID: [PlayerID: Int]

    init(players: [PlayerID], seed: UInt64) {
        precondition(players.count <= Int(Int8.max), "Paint Rush stores owners as Int8")
        random = ArcadeRandomNumberGenerator(seed: ArcadeRandomNumberGenerator.mixed(seed, 0x9A17))
        indexByID = Dictionary(players.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        owners = Array(repeating: -1, count: Self.tileCount)
        tileCounts = Array(repeating: 0, count: players.count)
        pucks = players.enumerated().map { index, playerID in
            Puck(playerID: playerID, position: Self.spawnPoint(index: index, count: players.count))
        }
        for index in pucks.indices {
            paintCircle(center: pucks[index].position, radius: Self.brushRadius, owner: index)
        }
    }

    // MARK: Geometry

    static func spawnPoint(index: Int, count: Int) -> ArcadeVector {
        guard count > 1 else { return ArcadeArena.center }
        let angle = .pi + ((Double(index) / Double(count)) * .pi * 2)
        return ArcadeArena.center + ArcadeVector(x: cos(angle) * 470, y: sin(angle) * 250)
    }

    static func tileCenter(column: Int, row: Int) -> ArcadeVector {
        origin + ArcadeVector(x: (Double(column) + 0.5) * tileSize, y: (Double(row) + 0.5) * tileSize)
    }

    static func tileCenter(_ tile: Int) -> ArcadeVector {
        tileCenter(column: tile % columns, row: tile / columns)
    }

    /// The tile under a scene point, clamped onto the board.
    static func tileCoordinate(containing point: ArcadeVector) -> (column: Int, row: Int) {
        let column = Int(((point.x - origin.x) / tileSize).rounded(.down))
        let row = Int(((point.y - origin.y) / tileSize).rounded(.down))
        return (min(max(column, 0), columns - 1), min(max(row, 0), rows - 1))
    }

    static func tileIndex(containing point: ArcadeVector) -> Int {
        let (column, row) = tileCoordinate(containing: point)
        return (row * columns) + column
    }

    /// Keeps a puck fully on the board.
    static func clampToBoard(_ point: ArcadeVector) -> ArcadeVector {
        ArcadeVector(
            x: min(max(point.x, origin.x + puckRadius), origin.x + boardSize.x - puckRadius),
            y: min(max(point.y, origin.y + puckRadius), origin.y + boardSize.y - puckRadius)
        )
    }

    // MARK: Queries

    var isFrenzy: Bool { elapsed >= Self.duration - Self.frenzyDuration - Self.timeEpsilon }

    var brushRadius: Double { isFrenzy ? Self.brushRadius * Self.frenzyBrushMultiplier : Self.brushRadius }

    func puck(for playerID: PlayerID) -> Puck? {
        indexByID[playerID].map { pucks[$0] }
    }

    func tiles(for playerID: PlayerID) -> Int {
        indexByID[playerID].map { tileCounts[$0] } ?? 0
    }

    func owner(ofTile tile: Int) -> PlayerID? {
        guard owners.indices.contains(tile) else { return nil }
        let owner = Int(owners[tile])
        return owner >= 0 ? pucks[owner].playerID : nil
    }

    func owner(at point: ArcadeVector) -> PlayerID? {
        owner(ofTile: Self.tileIndex(containing: point))
    }

    static func percent(_ count: Int) -> Int {
        Int((Double(count) * 100 / Double(tileCount)).rounded())
    }

    // MARK: ArcadeSimulation

    var timeRemaining: Double? { max(0, Self.duration - elapsed) }

    func isActive(_ playerID: PlayerID) -> Bool {
        indexByID[playerID].map { pucks[$0].active } ?? false
    }

    mutating func step(deltaTime: Double, inputs: [PlayerID: ArcadeInput]) -> [ArcadeEvent] {
        guard !isFinished else { return [] }
        let delta = min(min(max(deltaTime, 0), 0.05), max(0, Self.duration - elapsed))
        var events: [ArcadeEvent] = []
        elapsed += delta
        frameCount += 1
        announce(events: &events)
        movePucks(delta: delta, inputs: inputs)
        resolveBumps(events: &events)
        collectPowerUps(events: &events)
        paint()
        spawnPowerUps(delta: delta)
        if elapsed >= Self.duration - Self.timeEpsilon {
            elapsed = Self.duration
            isFinished = true
        }
        return events
    }

    mutating func forfeit(_ playerID: PlayerID) -> [ArcadeEvent] {
        guard !isFinished, let index = indexByID[playerID], pucks[index].active else { return [] }
        pucks[index].active = false
        pucks[index].velocity = .zero
        pucks[index].knock = .zero
        pucks[index].boostRemaining = 0
        if !pucks.contains(where: \.active) { isFinished = true }
        return [.eliminated(playerID)]
    }

    func ranking() -> [ArcadeRankEntry] {
        ArcadeRanking.byScore(
            Array(pucks.indices),
            id: { pucks[$0].playerID },
            score: { tileCounts[$0] },
            detail: { "\(tileCounts[$0]) tiles • \(Self.percent(tileCounts[$0]))%" }
        )
    }

    func scoreLine(for playerID: PlayerID) -> String {
        guard let index = indexByID[playerID] else { return "" }
        return "\(tileCounts[index])  \(Self.percent(tileCounts[index]))%"
    }

    var resultMetric: MatchMetric {
        .init(id: "most-tiles", label: "Most tiles", value: "\(tileCounts.max() ?? 0)")
    }

    static func botReactionInterval(for difficulty: GameBotDifficulty) -> Double {
        switch difficulty {
        case .easy: 0.4
        case .normal: 0.25
        case .hard: 0.15
        }
    }

    /// Picks the best of a random sample of tiles (half near the bot, the rest
    /// anywhere) by value / (distance + c), with a mild bonus for staying on
    /// course, plus nearby power-ups, and drives straight at it.
    func botDecision(
        for playerID: PlayerID,
        difficulty: GameBotDifficulty,
        random: inout ArcadeRandomNumberGenerator
    ) -> ArcadeBotDecision {
        guard !isFinished, let index = indexByID[playerID], pucks[index].active else { return .idle }
        let puck = pucks[index]
        let samples = switch difficulty {
        case .easy: 24
        case .normal: 36
        case .hard: 48
        }
        let heading = puck.velocity.normalized()
        let distanceBias = 90.0
        var bestTarget: ArcadeVector?
        var bestScore = 0.0

        func consider(_ target: ArcadeVector, value: Double) {
            guard value > 0 else { return }
            let offset = target - puck.position
            let distance = offset.length
            let alignment = heading == .zero || distance < 0.001 ? 0 : heading.dot(offset / distance)
            let score = value * (1 + (0.35 * alignment)) / (distance + distanceBias)
            if score > bestScore {
                bestScore = score
                bestTarget = target
            }
        }

        for sample in 0..<samples {
            let tile: Int
            if sample.isMultiple(of: 2) {
                let reach = ArcadeVector(angle: random.unit() * .pi * 2, length: 45 + (random.unit() * 260))
                tile = Self.tileIndex(containing: puck.position + reach)
            } else {
                tile = random.index(below: Self.tileCount)
            }
            let owner = Int(owners[tile])
            let value = owner == index ? 0 : owner < 0 ? 1.0 : 1.5
            consider(Self.tileCenter(tile), value: value)
        }
        for powerUp in powerUps where powerUp.position.distance(to: puck.position) < 420 {
            consider(powerUp.position, value: 6)
        }

        let target = bestTarget ?? ArcadeArena.center
        var direction = (target - puck.position).normalized()
        if direction == .zero { direction = ArcadeVector(angle: random.unit() * .pi * 2) }
        if difficulty == .easy {
            direction = ArcadeVector(angle: direction.angle + random.double(in: -0.8...0.8))
        }
        return ArcadeBotDecision(vector: direction)
    }

    // MARK: Simulation

    private mutating func announce(events: inout [ArcadeEvent]) {
        if !announcedHalfTime, elapsed >= Self.halfTime - Self.timeEpsilon {
            announcedHalfTime = true
            events.append(.banner("HALF TIME"))
            events.append(.sound(.lightImpact))
        }
        if !announcedFrenzy, isFrenzy {
            announcedFrenzy = true
            events.append(.banner("FRENZY!"))
            events.append(.sound(.heavyImpact))
            for puck in pucks where puck.active {
                events.append(.cue(puck.playerID, colorHex: Self.frenzyColor, haptic: .heavyImpact))
            }
        }
    }

    private func speed(for puck: Puck) -> Double {
        puck.isBoosted ? Self.maximumSpeed * Self.boostMultiplier : Self.maximumSpeed
    }

    private mutating func movePucks(delta: Double, inputs: [PlayerID: ArcadeInput]) {
        let decay = exp(-Self.knockDecay * delta)
        for index in pucks.indices where pucks[index].active {
            pucks[index].boostRemaining = max(0, pucks[index].boostRemaining - delta)
            pucks[index].bumpCooldown = max(0, pucks[index].bumpCooldown - delta)
            let input = inputs[pucks[index].playerID] ?? .idle
            let x = input.axisX.isFinite ? input.axisX : 0
            let y = input.axisY.isFinite ? input.axisY : 0
            let stick = ArcadeVector(x: x, y: y).clampedLength(1)
            let drive = stick.length < Self.deadZone ? ArcadeVector.zero : stick * speed(for: pucks[index])
            pucks[index].velocity = drive + pucks[index].knock
            pucks[index].position = Self.clampToBoard(pucks[index].position + (pucks[index].velocity * delta))
            pucks[index].knock = pucks[index].knock * decay
        }
    }

    private mutating func resolveBumps(events: inout [ArcadeEvent]) {
        let minimum = Self.puckRadius * 2
        for first in pucks.indices where pucks[first].active {
            for second in pucks.indices where second > first && pucks[second].active {
                let offset = pucks[second].position - pucks[first].position
                let distanceSquared = offset.lengthSquared
                guard distanceSquared < minimum * minimum else { continue }
                let distance = distanceSquared.squareRoot()
                let normal = distance > 0.001
                    ? offset / distance
                    : ArcadeVector(angle: Double((first * 7) + second))
                let separation = normal * ((minimum - distance) / 2)
                pucks[first].position = Self.clampToBoard(pucks[first].position - separation)
                pucks[second].position = Self.clampToBoard(pucks[second].position + separation)
                pucks[first].knock = (pucks[first].knock - (normal * Self.bumpPush)).clampedLength(Self.maximumKnock)
                pucks[second].knock = (pucks[second].knock + (normal * Self.bumpPush)).clampedLength(Self.maximumKnock)
                for index in [first, second] where pucks[index].bumpCooldown <= 0 {
                    pucks[index].bumpCooldown = Self.bumpHapticCooldown
                    events.append(.haptic(pucks[index].playerID, .lightImpact))
                }
            }
        }
    }

    /// Player indices starting from a frame-rotating offset so simultaneous
    /// claims don't always favour the same seat.
    private var fairOrder: [Int] {
        let count = pucks.count
        guard count > 0 else { return [] }
        return (0..<count).map { (frameCount + $0) % count }
    }

    private mutating func collectPowerUps(events: inout [ArcadeEvent]) {
        guard !powerUps.isEmpty else { return }
        let reach = Self.puckRadius + Self.powerUpRadius
        for index in fairOrder where pucks[index].active {
            let position = pucks[index].position
            guard let found = powerUps.firstIndex(where: { $0.position.distance(to: position) <= reach }) else { continue }
            let powerUp = powerUps.remove(at: found)
            let playerID = pucks[index].playerID
            switch powerUp.kind {
            case .boost:
                pucks[index].boostRemaining = Self.boostDuration
                events.append(.sound(.lightImpact))
                events.append(.cue(playerID, colorHex: Self.boostColor, haptic: .lightImpact))
            case .splat:
                splat(at: position, owner: index)
                events.append(.sound(.heavyImpact))
                events.append(.cue(playerID, colorHex: Self.splatColor, haptic: .heavyImpact))
            }
            if powerUps.isEmpty { break }
        }
    }

    private mutating func paint() {
        let radius = brushRadius
        for index in fairOrder where pucks[index].active {
            paintCircle(center: pucks[index].position, radius: radius, owner: index)
        }
    }

    private mutating func paintCircle(center: ArcadeVector, radius: Double, owner: Int) {
        let radiusSquared = radius * radius
        let minColumn = max(0, Int(((center.x - radius - Self.origin.x) / Self.tileSize).rounded(.down)))
        let maxColumn = min(Self.columns - 1, Int(((center.x + radius - Self.origin.x) / Self.tileSize).rounded(.down)))
        let minRow = max(0, Int(((center.y - radius - Self.origin.y) / Self.tileSize).rounded(.down)))
        let maxRow = min(Self.rows - 1, Int(((center.y + radius - Self.origin.y) / Self.tileSize).rounded(.down)))
        guard minColumn <= maxColumn, minRow <= maxRow else { return }
        for row in minRow...maxRow {
            let dy = Self.origin.y + ((Double(row) + 0.5) * Self.tileSize) - center.y
            for column in minColumn...maxColumn {
                let dx = Self.origin.x + ((Double(column) + 0.5) * Self.tileSize) - center.x
                guard (dx * dx) + (dy * dy) <= radiusSquared else { continue }
                claim((row * Self.columns) + column, for: owner)
            }
        }
    }

    /// Paints every tile within `splatRadiusTiles` (in tile steps) of the tile under `point`.
    private mutating func splat(at point: ArcadeVector, owner: Int) {
        let (column, row) = Self.tileCoordinate(containing: point)
        let radius = Self.splatRadiusTiles
        for dy in -radius...radius {
            for dx in -radius...radius where (dx * dx) + (dy * dy) <= radius * radius {
                let tileColumn = column + dx
                let tileRow = row + dy
                guard (0..<Self.columns).contains(tileColumn), (0..<Self.rows).contains(tileRow) else { continue }
                claim((tileRow * Self.columns) + tileColumn, for: owner)
            }
        }
    }

    private mutating func claim(_ tile: Int, for owner: Int) {
        let previous = Int(owners[tile])
        guard previous != owner else { return }
        if previous >= 0 { tileCounts[previous] -= 1 }
        tileCounts[owner] += 1
        owners[tile] = Int8(owner)
    }

    private mutating func spawnPowerUps(delta: Double) {
        powerUpAccumulator += delta
        guard powerUpAccumulator >= Self.powerUpInterval - Self.timeEpsilon else { return }
        powerUpAccumulator = max(0, powerUpAccumulator - Self.powerUpInterval)
        guard powerUps.count < Self.maximumPowerUps else { return }
        let kind: PowerUpKind = random.chance(0.5) ? .boost : .splat
        var position = ArcadeArena.center
        var bestClearance = -Double.infinity
        for _ in 0..<12 {
            let candidate = Self.tileCenter(
                column: 1 + random.index(below: Self.columns - 2),
                row: 1 + random.index(below: Self.rows - 2)
            )
            let clearance = clearance(at: candidate)
            if clearance > bestClearance {
                bestClearance = clearance
                position = candidate
            }
            if clearance >= Self.powerUpClearance { break }
        }
        nextPowerUpID += 1
        powerUps.append(PowerUp(id: nextPowerUpID, kind: kind, position: position))
    }

    /// Distance from `point` to the nearest active puck or existing power-up.
    private func clearance(at point: ArcadeVector) -> Double {
        let pucksDistance = pucks.filter(\.active).map { $0.position.distance(to: point) }.min() ?? .infinity
        let powerUpDistance = powerUps.map { $0.position.distance(to: point) }.min() ?? .infinity
        return min(pucksDistance, powerUpDistance)
    }

    mutating func placeForTesting(_ playerID: PlayerID, at position: ArcadeVector) {
        guard let index = indexByID[playerID] else { return }
        pucks[index].position = Self.clampToBoard(position)
        pucks[index].knock = .zero
    }

    mutating func setElapsedForTesting(_ elapsed: Double) {
        self.elapsed = elapsed
    }

    mutating func clearBoardForTesting() {
        owners = Array(repeating: -1, count: Self.tileCount)
        tileCounts = Array(repeating: 0, count: pucks.count)
    }

    mutating func setOwnerForTesting(tile: Int, to playerID: PlayerID?) {
        guard owners.indices.contains(tile) else { return }
        if let playerID, let index = indexByID[playerID] {
            claim(tile, for: index)
        } else {
            let previous = Int(owners[tile])
            if previous >= 0 { tileCounts[previous] -= 1 }
            owners[tile] = -1
        }
    }

    mutating func addPowerUpForTesting(_ kind: PowerUpKind, at position: ArcadeVector) {
        nextPowerUpID += 1
        powerUps.append(PowerUp(id: nextPowerUpID, kind: kind, position: position))
    }
}
