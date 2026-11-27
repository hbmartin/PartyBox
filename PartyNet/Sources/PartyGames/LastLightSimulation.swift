import Foundation
import PartyBoxCore
import PartyGameRuntime
import PartyNet

/// Dodge escalating hazards while competing for a shrinking spotlight.
struct LastLightSimulation: ArcadeSimulation {
    static let duration = 60.0
    static let startingLives = 3
    static let playerRadius = 24.0
    static let maximumSpeed = 1_100.0
    static let invulnerability = 1.0
    static let movementInset = 30.0
    static let blockHalfSize = ArcadeVector(x: 35, y: 18)
    static let sweeperHalfThickness = 11.0
    static let sweeperGapHalfWidth = 80.0
    static let seekerRadius = 18.0
    static let seekerLifetime = 4.0
    static let scoreInterval = 0.25
    static let sweepersStart = 15.0
    static let seekersStart = 30.0

    enum HazardKind: Equatable, Sendable {
        case block
        /// A bar spanning the arena width that travels vertically.
        case rowSweeper
        /// A bar spanning the arena height that travels horizontally.
        case columnSweeper
        case seeker
    }

    struct Hazard: Equatable, Sendable {
        var id: Int
        let kind: HazardKind
        var position: ArcadeVector
        var velocity: ArcadeVector
        /// Center of the safe gap along the bar (sweepers only).
        var gapCenter: Double = 0
        /// Seconds of warning before the hazard becomes dangerous.
        var armRemaining: Double
        var lifeRemaining: Double = .infinity

        var isArmed: Bool { armRemaining <= 0 }
    }

    struct Player: Equatable, Sendable {
        let playerID: PlayerID
        var position: ArcadeVector
        var lives: Int
        var score = 0
        var invulnerableRemaining = 0.0
        var lightTime = 0.0

        var alive: Bool { lives > 0 }
        var isInvulnerable: Bool { invulnerableRemaining > 0 }
    }

    private(set) var players: [Player]
    private(set) var hazards: [Hazard] = []
    private(set) var elapsed = 0.0
    private(set) var isFinished = false
    private var random: ArcadeRandomNumberGenerator
    private var nextHazardID = 0
    private var rainAccumulator = 0.0
    private var sweeperAccumulator = 0.0
    private var seekerAccumulator = 0.0
    private var scoreAccumulator = 0.0
    private var sweeperCount = 0
    private var announcedStage = 0
    private var eliminationOrder = ArcadeEliminations()
    private let indexByID: [PlayerID: Int]
    private let multiplayer: Bool

    init(players: [PlayerID], seed: UInt64) {
        random = ArcadeRandomNumberGenerator(seed: ArcadeRandomNumberGenerator.mixed(seed, 0x11A7))
        multiplayer = players.count > 1
        indexByID = Dictionary(players.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        self.players = players.enumerated().map { index, playerID in
            let angle = (Double(index) / Double(max(1, players.count))) * .pi * 2
            let position = ArcadeArena.center + ArcadeVector(x: cos(angle) * 260, y: sin(angle) * 160)
            return Player(playerID: playerID, position: position, lives: Self.startingLives)
        }
    }

    // MARK: Tuning

    static var halfExtents: ArcadeVector {
        ArcadeVector(
            x: (ArcadeArena.maxX - ArcadeArena.minX) / 2 - movementInset,
            y: (ArcadeArena.maxY - ArcadeArena.minY) / 2 - movementInset
        )
    }

    var rainInterval: Double { arcadeRamp(from: 0.55, to: 0.16, start: 0, end: 50, at: elapsed) }
    var rainSpeed: Double { arcadeRamp(from: 380, to: 900, start: 0, end: 55, at: elapsed) }
    var sweeperInterval: Double { arcadeRamp(from: 4.0, to: 2.6, start: Self.sweepersStart, end: 55, at: elapsed) }
    var sweeperSpeed: Double { arcadeRamp(from: 500, to: 650, start: Self.sweepersStart, end: 55, at: elapsed) }
    var seekerInterval: Double { arcadeRamp(from: 5.0, to: 3.0, start: Self.seekersStart, end: 55, at: elapsed) }
    var seekerSpeed: Double { arcadeRamp(from: 220, to: 280, start: Self.seekersStart, end: 55, at: elapsed) }

    var lightRadius: Double { arcadeRamp(from: 260, to: 170, start: 0, end: Self.duration, at: elapsed) }

    var lightCenter: ArcadeVector {
        Self.lightCenter(at: elapsed)
    }

    static func lightCenter(at time: Double) -> ArcadeVector {
        ArcadeArena.center + ArcadeVector(x: sin(time * 0.37) * 430, y: sin((time * 0.53) + 1) * 220)
    }

    /// Converts a stick reading into the point the orb steers toward.
    static func target(forAxisX x: Double, axisY y: Double) -> ArcadeVector {
        let half = halfExtents
        return ArcadeArena.center + ArcadeVector(x: min(max(x, -1), 1) * half.x, y: min(max(y, -1), 1) * half.y)
    }

    // MARK: ArcadeSimulation

    var timeRemaining: Double? { max(0, Self.duration - elapsed) }

    func isActive(_ playerID: PlayerID) -> Bool {
        indexByID[playerID].map { players[$0].alive } ?? false
    }

    func player(for playerID: PlayerID) -> Player? {
        indexByID[playerID].map { players[$0] }
    }

    mutating func step(deltaTime: Double, inputs: [PlayerID: ArcadeInput]) -> [ArcadeEvent] {
        guard !isFinished else { return [] }
        let delta = min(max(deltaTime, 0), 0.05)
        var events: [ArcadeEvent] = []
        elapsed += delta
        announceStage(events: &events)
        movePlayers(delta: delta, inputs: inputs)
        spawnHazards(delta: delta)
        moveHazards(delta: delta)
        resolveHits(events: &events)
        awardScore(delta: delta)
        if !isFinished, elapsed >= Self.duration { isFinished = true }
        return events
    }

    mutating func forfeit(_ playerID: PlayerID) -> [ArcadeEvent] {
        guard !isFinished, let index = indexByID[playerID], players[index].alive else { return [] }
        players[index].lives = 0
        eliminationOrder.record(playerID)
        var events: [ArcadeEvent] = [.eliminated(playerID)]
        finishIfDecided(events: &events)
        return events
    }

    func ranking() -> [ArcadeRankEntry] {
        ArcadeRanking.bySurvival(
            players,
            id: \.playerID,
            alive: \.alive,
            lives: { _ in 0 },
            score: \.score,
            eliminationOrder: eliminationOrder,
            shareTiedPlacements: true,
            detail: { "\($0.lives) lives • \(Int($0.lightTime))s in the light" }
        )
    }

    func scoreLine(for playerID: PlayerID) -> String {
        guard let player = player(for: playerID) else { return "" }
        return "\(player.score)  \(ArcadeRanking.lives(player.lives))"
    }

    var resultMetric: MatchMetric {
        .init(id: "top-score", label: "Top score", value: "\(players.map(\.score).max() ?? 0)")
    }

    func botDecision(
        for playerID: PlayerID,
        difficulty: GameBotDifficulty,
        random: inout ArcadeRandomNumberGenerator
    ) -> ArcadeBotDecision {
        guard let player = player(for: playerID), player.alive else { return .idle }
        let samples = switch difficulty {
        case .easy: 8
        case .normal: 16
        case .hard: 24
        }
        var candidates = [player.position, lightCenter]
        for index in 0..<samples {
            let angle = (Double(index) / Double(samples)) * .pi * 2
            let radius = index.isMultiple(of: 2) ? 140.0 : 300.0
            candidates.append(player.position + ArcadeVector(angle: angle, length: radius))
        }
        let half = Self.halfExtents
        var best = player.position
        var bestScore = -Double.infinity
        for raw in candidates {
            let candidate = ArcadeArena.clamp(raw, inset: Self.movementInset)
            var score = -danger(movingFrom: player.position, toward: candidate) * 100
            let lightDistance = candidate.distance(to: lightCenter)
            if lightDistance < lightRadius * 0.8 { score += 30 }
            score -= lightDistance * 0.02
            if score > bestScore {
                bestScore = score
                best = candidate
            }
        }
        if difficulty == .easy {
            best += ArcadeVector(x: random.double(in: -80...80), y: random.double(in: -80...80))
        }
        let offset = best - ArcadeArena.center
        return ArcadeBotDecision(axisX: offset.x / half.x, axisY: offset.y / half.y)
    }

    // MARK: Simulation

    private mutating func announceStage(events: inout [ArcadeEvent]) {
        let stage = elapsed >= 45 ? 3 : elapsed >= Self.seekersStart ? 2 : elapsed >= Self.sweepersStart ? 1 : 0
        guard stage > announcedStage else { return }
        announcedStage = stage
        events.append(.banner(["", "SWEEPERS!", "SEEKERS!", "FINAL STRETCH"][stage]))
        events.append(.sound(.lightImpact))
    }

    private mutating func movePlayers(delta: Double, inputs: [PlayerID: ArcadeInput]) {
        for index in players.indices where players[index].alive {
            if players[index].invulnerableRemaining > 0 { players[index].invulnerableRemaining -= delta }
            guard let input = inputs[players[index].playerID] else { continue }
            let target = Self.target(forAxisX: input.axisX, axisY: input.axisY)
            let offset = target - players[index].position
            players[index].position += offset.clampedLength(Self.maximumSpeed * delta)
            players[index].position = ArcadeArena.clamp(players[index].position, inset: Self.movementInset)
        }
    }

    private mutating func spawnHazards(delta: Double) {
        rainAccumulator += delta
        while rainAccumulator >= rainInterval {
            rainAccumulator -= rainInterval
            let x = random.double(in: (ArcadeArena.minX + 40)...(ArcadeArena.maxX - 40))
            addHazard(Hazard(
                id: 0, kind: .block,
                position: ArcadeVector(x: x, y: ArcadeArena.maxY + Self.blockHalfSize.y),
                velocity: ArcadeVector(x: 0, y: -rainSpeed),
                armRemaining: 0.35
            ))
        }
        if elapsed >= Self.sweepersStart {
            sweeperAccumulator += delta
            if sweeperAccumulator >= sweeperInterval {
                sweeperAccumulator = 0
                spawnSweeper()
            }
        }
        if elapsed >= Self.seekersStart {
            seekerAccumulator += delta
            if seekerAccumulator >= seekerInterval {
                seekerAccumulator = 0
                spawnSeeker()
            }
        }
    }

    private mutating func spawnSweeper() {
        sweeperCount += 1
        let fromStart = random.chance(0.5)
        if sweeperCount.isMultiple(of: 2) {
            let gap = random.double(in: (ArcadeArena.minY + 100)...(ArcadeArena.maxY - 100))
            let x = fromStart ? ArcadeArena.minX : ArcadeArena.maxX
            addHazard(Hazard(
                id: 0, kind: .columnSweeper,
                position: ArcadeVector(x: x, y: ArcadeArena.center.y),
                velocity: ArcadeVector(x: fromStart ? sweeperSpeed : -sweeperSpeed, y: 0),
                gapCenter: gap,
                armRemaining: 0.6
            ))
        } else {
            let gap = random.double(in: (ArcadeArena.minX + 100)...(ArcadeArena.maxX - 100))
            let y = fromStart ? ArcadeArena.maxY : ArcadeArena.minY
            addHazard(Hazard(
                id: 0, kind: .rowSweeper,
                position: ArcadeVector(x: ArcadeArena.center.x, y: y),
                velocity: ArcadeVector(x: 0, y: fromStart ? -sweeperSpeed : sweeperSpeed),
                gapCenter: gap,
                armRemaining: 0.6
            ))
        }
    }

    private mutating func spawnSeeker() {
        let perimeter = random.unit()
        let position: ArcadeVector = switch Int(perimeter * 4) {
        case 0: ArcadeVector(x: ArcadeArena.minX + 20, y: random.double(in: ArcadeArena.minY...ArcadeArena.maxY))
        case 1: ArcadeVector(x: ArcadeArena.maxX - 20, y: random.double(in: ArcadeArena.minY...ArcadeArena.maxY))
        case 2: ArcadeVector(x: random.double(in: ArcadeArena.minX...ArcadeArena.maxX), y: ArcadeArena.minY + 20)
        default: ArcadeVector(x: random.double(in: ArcadeArena.minX...ArcadeArena.maxX), y: ArcadeArena.maxY - 20)
        }
        addHazard(Hazard(
            id: 0, kind: .seeker,
            position: position,
            velocity: .zero,
            armRemaining: 0.5,
            lifeRemaining: Self.seekerLifetime + 0.5
        ))
    }

    private mutating func addHazard(_ hazard: Hazard) {
        nextHazardID += 1
        var hazard = hazard
        hazard.id = nextHazardID
        hazards.append(hazard)
    }

    private mutating func moveHazards(delta: Double) {
        for index in hazards.indices {
            if hazards[index].armRemaining > 0 {
                hazards[index].armRemaining -= delta
                continue
            }
            if hazards[index].kind == .seeker {
                hazards[index].lifeRemaining -= delta
                if let target = nearestAlivePlayer(to: hazards[index].position) {
                    let heading = (target - hazards[index].position).normalized()
                    hazards[index].velocity = heading * seekerSpeed
                }
            }
            hazards[index].position += hazards[index].velocity * delta
        }
        hazards.removeAll { hazard in
            if hazard.lifeRemaining <= 0 { return true }
            let margin = 120.0
            return hazard.position.x < ArcadeArena.minX - margin || hazard.position.x > ArcadeArena.maxX + margin
                || hazard.position.y < ArcadeArena.minY - margin || hazard.position.y > ArcadeArena.maxY + margin
        }
    }

    private func nearestAlivePlayer(to point: ArcadeVector) -> ArcadeVector? {
        players.filter(\.alive).min { $0.position.distance(to: point) < $1.position.distance(to: point) }?.position
    }

    private mutating func resolveHits(events: inout [ArcadeEvent]) {
        let firstEvent = events.count
        var consumed: Set<Int> = []
        var anyEliminated = false
        for index in players.indices where players[index].alive && !players[index].isInvulnerable {
            let position = players[index].position
            guard let hazard = hazards.first(where: { $0.isArmed && !consumed.contains($0.id) && Self.hits($0, at: position, radius: Self.playerRadius) })
            else { continue }
            if hazard.kind == .block || hazard.kind == .seeker { consumed.insert(hazard.id) }
            players[index].lives -= 1
            players[index].invulnerableRemaining = Self.invulnerability
            if players[index].lives <= 0 {
                players[index].lives = 0
                events.append(.eliminated(players[index].playerID))
                anyEliminated = true
            } else {
                events.append(.lostLife(players[index].playerID, remaining: players[index].lives))
            }
        }
        if !consumed.isEmpty { hazards.removeAll { consumed.contains($0.id) } }
        if anyEliminated {
            eliminationOrder.recordBatch(events[firstEvent...])
            finishIfDecided(events: &events)
        }
    }

    private mutating func awardScore(delta: Double) {
        guard !isFinished else { return }
        let center = lightCenter
        let radius = lightRadius
        for index in players.indices where players[index].alive
            && players[index].position.distance(to: center) <= radius {
            players[index].lightTime += delta
        }
        scoreAccumulator += delta
        while scoreAccumulator >= Self.scoreInterval {
            scoreAccumulator -= Self.scoreInterval
            for index in players.indices where players[index].alive {
                players[index].score += players[index].position.distance(to: center) <= radius ? 3 : 1
            }
        }
    }

    private mutating func finishIfDecided(events: inout [ArcadeEvent]) {
        let alive = players.count(where: \.alive)
        if alive == 0 || (multiplayer && alive <= 1) { isFinished = true }
    }

    static func hits(_ hazard: Hazard, at point: ArcadeVector, radius: Double) -> Bool {
        switch hazard.kind {
        case .block:
            return circleHitsRect(point, radius: radius, center: hazard.position, halfSize: blockHalfSize)
        case .seeker:
            return point.distance(to: hazard.position) < radius + seekerRadius
        case .rowSweeper:
            guard abs(point.y - hazard.position.y) < sweeperHalfThickness + radius else { return false }
            return abs(point.x - hazard.gapCenter) > sweeperGapHalfWidth - radius
        case .columnSweeper:
            guard abs(point.x - hazard.position.x) < sweeperHalfThickness + radius else { return false }
            return abs(point.y - hazard.gapCenter) > sweeperGapHalfWidth - radius
        }
    }

    private static func circleHitsRect(_ point: ArcadeVector, radius: Double, center: ArcadeVector, halfSize: ArcadeVector) -> Bool {
        let dx = max(abs(point.x - center.x) - halfSize.x, 0)
        let dy = max(abs(point.y - center.y) - halfSize.y, 0)
        return (dx * dx) + (dy * dy) < radius * radius
    }

    /// Predicted collision risk for an orb steering from `start` toward `target`.
    private func danger(movingFrom start: ArcadeVector, toward target: ArcadeVector) -> Double {
        var risk = 0.0
        for time in [0.12, 0.25, 0.4, 0.6] {
            let travel = (target - start).clampedLength(Self.maximumSpeed * time)
            let position = start + travel
            for hazard in hazards {
                let wait = max(0, hazard.armRemaining)
                let moving = max(0, time - wait)
                var future = hazard
                future.armRemaining = 0
                if hazard.kind == .seeker {
                    future.position += (position - hazard.position).normalized() * (seekerSpeed * moving)
                } else {
                    future.position += hazard.velocity * moving
                }
                if Self.hits(future, at: position, radius: Self.playerRadius + 18) {
                    risk += 1.0 / (1 + time)
                }
            }
        }
        return risk
    }

    mutating func placeForTesting(_ playerID: PlayerID, at position: ArcadeVector) {
        guard let index = indexByID[playerID] else { return }
        players[index].position = position
        players[index].invulnerableRemaining = 0
    }

    mutating func setLivesForTesting(_ lives: Int, playerID: PlayerID) {
        guard let index = indexByID[playerID] else { return }
        players[index].lives = lives
    }

    mutating func setHazardsForTesting(_ hazards: [Hazard]) {
        self.hazards = hazards
    }

    mutating func setElapsedForTesting(_ elapsed: Double) {
        self.elapsed = elapsed
    }
}
