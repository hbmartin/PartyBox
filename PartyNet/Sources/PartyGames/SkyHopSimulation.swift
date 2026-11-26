import Foundation
import PartyBoxCore
import PartyGameRuntime
import PartyNet

/// Flappy-style survival: every bird shares one corridor of scrolling gates,
/// a tap flaps, and one crash is out.
struct SkyHopSimulation: ArcadeSimulation {
    static let duration = 90.0
    static let birdRadius = 22.0
    static let birdStartX = 520.0
    static let gravity = 2_400.0
    static let flapVelocity = 760.0
    static let terminalFallSpeed = 900.0
    /// After GO, each bird hovers until its first flap or until this many seconds pass,
    /// so a player still looking up at the TV doesn't hit the floor in half a second.
    static let hoverGrace = 1.5
    static let pillarWidth = 110.0
    static let gapMargin = 40.0
    static let maximumGapShift = 220.0
    /// Left edge of the first gate, far enough right to give a beat after GO.
    static let firstGateX = 1_500.0
    /// Gates are generated once the newest one has scrolled left of this x.
    static let spawnHorizon = ArcadeArena.maxX + 100
    static let rampDuration = 50.0
    static let pointsPerGate = 10
    static let passColor = ArcadeOutcomeBuilder.winnerColor

    struct Gate: Equatable, Sendable {
        let id: Int
        /// Left (leading) edge of both pillars.
        var x: Double
        let gapCenter: Double
        let gapHeight: Double

        var trailingEdge: Double { x + SkyHopSimulation.pillarWidth }
        var gapBottom: Double { gapCenter - gapHeight / 2 }
        var gapTop: Double { gapCenter + gapHeight / 2 }

        /// The lower pillar, from the corridor floor up to the gap.
        var lowerPillar: CGRect {
            CGRect(x: x, y: ArcadeArena.minY, width: SkyHopSimulation.pillarWidth, height: max(0, gapBottom - ArcadeArena.minY))
        }

        /// The upper pillar, from the gap up to the corridor ceiling.
        var upperPillar: CGRect {
            CGRect(x: x, y: gapTop, width: SkyHopSimulation.pillarWidth, height: max(0, ArcadeArena.maxY - gapTop))
        }
    }

    struct Bird: Equatable, Sendable {
        let playerID: PlayerID
        var x: Double { SkyHopSimulation.birdStartX }
        var y: Double
        var vy = 0.0
        var alive = true
        var gates = 0
        /// Id of the last gate this bird fully cleared.
        var lastClearedGateID = 0
        var crashedAt: Double?
        var hovering = true

        var score: Int { gates * SkyHopSimulation.pointsPerGate }
    }

    private(set) var birds: [Bird]
    private(set) var gates: [Gate] = []
    private(set) var elapsed = 0.0
    /// Total corridor distance scrolled, for parallax backgrounds.
    private(set) var distance = 0.0
    private(set) var isFinished = false
    private var random: ArcadeRandomNumberGenerator
    private var nextGateID = 1
    private var previousGapCenter = ArcadeArena.center.y
    private var announcedStage = 0
    private var eliminationOrder = ArcadeEliminations()
    private let indexByID: [PlayerID: Int]
    private let multiplayer: Bool

    init(players: [PlayerID], seed: UInt64) {
        random = ArcadeRandomNumberGenerator(seed: ArcadeRandomNumberGenerator.mixed(seed, 0x5C40))
        multiplayer = players.count > 1
        indexByID = Dictionary(players.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        birds = players.map { playerID in
            Bird(playerID: playerID, y: ArcadeArena.center.y)
        }
        addGate(at: Self.firstGateX)
        spawnGates()
    }

    // MARK: Tuning

    static func scrollSpeed(at time: Double) -> Double {
        arcadeRamp(from: 360, to: 700, start: 0, end: rampDuration, at: time)
    }

    static func gapHeight(at time: Double) -> Double {
        arcadeRamp(from: 300, to: 175, start: 0, end: rampDuration, at: time)
    }

    /// Leading edge to leading edge distance between consecutive gates.
    static func gateSpacing(at time: Double) -> Double {
        arcadeRamp(from: 560, to: 400, start: 0, end: rampDuration, at: time)
    }

    var scrollSpeed: Double { Self.scrollSpeed(at: elapsed) }

    /// Allowed gap centers for a gap of `height`, keeping `gapMargin` clear of
    /// the floor and ceiling.
    static func gapCenterRange(forHeight height: Double) -> ClosedRange<Double> {
        (ArcadeArena.minY + gapMargin + height / 2)...(ArcadeArena.maxY - gapMargin - height / 2)
    }

    // MARK: ArcadeSimulation

    var timeRemaining: Double? { max(0, Self.duration - elapsed) }

    func isActive(_ playerID: PlayerID) -> Bool {
        indexByID[playerID].map { birds[$0].alive } ?? false
    }

    func bird(for playerID: PlayerID) -> Bird? {
        indexByID[playerID].map { birds[$0] }
    }

    mutating func step(deltaTime: Double, inputs: [PlayerID: ArcadeInput]) -> [ArcadeEvent] {
        guard !isFinished else { return [] }
        let delta = min(max(deltaTime, 0), 0.05)
        var events: [ArcadeEvent] = []
        elapsed += delta
        announceStage(events: &events)
        moveBirds(delta: delta, inputs: inputs)
        scrollGates(delta: delta)
        resolveCrashes(events: &events)
        scoreGates(events: &events)
        if !isFinished, elapsed >= Self.duration { isFinished = true }
        return events
    }

    mutating func forfeit(_ playerID: PlayerID) -> [ArcadeEvent] {
        guard !isFinished, let index = indexByID[playerID], birds[index].alive else { return [] }
        var events: [ArcadeEvent] = []
        crash(index, events: &events)
        eliminationOrder.record(playerID)
        finishIfDecided()
        return events
    }

    func ranking() -> [ArcadeRankEntry] {
        ArcadeRanking.bySurvival(
            birds,
            id: \.playerID,
            alive: \.alive,
            lives: { _ in 0 },
            score: \.score,
            eliminationOrder: eliminationOrder,
            shareEliminationPlacements: true,
            detail: { bird in
                let gates = "\(bird.gates) \(bird.gates == 1 ? "gate" : "gates")"
                guard let crashedAt = bird.crashedAt else { return "\(gates) • still flying" }
                return "\(gates) • crashed at \(Int(crashedAt))s"
            }
        )
    }

    func scoreLine(for playerID: PlayerID) -> String {
        guard let bird = bird(for: playerID) else { return "" }
        return "\(bird.gates)"
    }

    var resultMetric: MatchMetric {
        .init(id: "most-gates", label: "Most gates", value: "\(birds.map(\.gates).max() ?? 0)")
    }

    static func botReactionInterval(for difficulty: GameBotDifficulty) -> Double {
        switch difficulty {
        case .easy: 0.12
        case .normal: 0.07
        case .hard: 0.03
        }
    }

    func botDecision(
        for playerID: PlayerID,
        difficulty: GameBotDifficulty,
        random: inout ArcadeRandomNumberGenerator
    ) -> ArcadeBotDecision {
        guard let bird = bird(for: playerID), bird.alive else { return .idle }
        let target = nextGate(for: bird).map(\.gapCenter) ?? ArcadeArena.center.y
        let noise = Self.botAimNoise(for: difficulty)
        let aim = target + random.double(in: -noise...noise)
        let lookahead = Self.botLookahead
        let predicted = bird.y + (bird.vy * lookahead) - (0.5 * Self.gravity * lookahead * lookahead)
        let wantsLift = predicted < aim - Self.botAimMargin(for: difficulty)
        let fallingOrSlow = bird.vy < Self.botFlapCeilingVelocity
        return ArcadeBotDecision(press: wantsLift && fallingOrSlow)
    }

    static let botLookahead = 0.12
    /// Bots only flap again once they are falling or near the top of an arc.
    static let botFlapCeilingVelocity = 150.0

    static func botAimNoise(for difficulty: GameBotDifficulty) -> Double {
        switch difficulty {
        case .easy: 40
        case .normal: 20
        case .hard: 8
        }
    }

    /// How far below the aim a bot lets its predicted height drop before it
    /// flaps. In level flight a bird flaps while falling at about 760pt/s, so
    /// the 0.12s lookahead triggers about 110pt above `aim - margin`, and the
    /// 120pt flap arc is centered about 170pt above it. A margin near 170
    /// therefore centers the arc on the aim. Slower bots notice the crossing
    /// about half a reaction interval late, so they use a smaller margin.
    static func botAimMargin(for difficulty: GameBotDifficulty) -> Double {
        switch difficulty {
        case .easy: 110
        case .normal: 135
        case .hard: 160
        }
    }

    /// The first gate this bird has not fully cleared.
    func nextGate(for bird: Bird) -> Gate? {
        gates.first { $0.trailingEdge > bird.x - Self.birdRadius }
    }

    // MARK: Simulation

    private mutating func announceStage(events: inout [ArcadeEvent]) {
        let stage = elapsed >= 45 ? 3 : elapsed >= 30 ? 2 : elapsed >= 15 ? 1 : 0
        guard stage > announcedStage else { return }
        announcedStage = stage
        events.append(.banner(stage == 3 ? "MAX SPEED" : "FASTER!"))
        events.append(.sound(.lightImpact))
    }

    private mutating func moveBirds(delta: Double, inputs: [PlayerID: ArcadeInput]) {
        for index in birds.indices where birds[index].alive {
            let flapped = inputs[birds[index].playerID]?.pressed == true
            if birds[index].hovering {
                if !flapped, elapsed < Self.hoverGrace { continue }
                birds[index].hovering = false
            }
            var vy = max(birds[index].vy - (Self.gravity * delta), -Self.terminalFallSpeed)
            if flapped { vy = Self.flapVelocity }
            birds[index].vy = vy
            birds[index].y += vy * delta
        }
    }

    private mutating func scrollGates(delta: Double) {
        let travel = scrollSpeed * delta
        distance += travel
        for index in gates.indices {
            gates[index].x -= travel
        }
        gates.removeAll { $0.trailingEdge < ArcadeArena.minX - 20 }
        spawnGates()
    }

    private mutating func spawnGates() {
        while let last = gates.last, last.x < Self.spawnHorizon {
            addGate(at: last.x + Self.gateSpacing(at: elapsed))
        }
    }

    private mutating func addGate(at x: Double) {
        let height = Self.gapHeight(at: elapsed)
        let range = Self.gapCenterRange(forHeight: height)
        let shift = random.double(in: -Self.maximumGapShift...Self.maximumGapShift)
        let center = min(max(previousGapCenter + shift, range.lowerBound), range.upperBound)
        previousGapCenter = center
        gates.append(Gate(id: nextGateID, x: x, gapCenter: center, gapHeight: height))
        nextGateID += 1
    }

    private mutating func resolveCrashes(events: inout [ArcadeEvent]) {
        let firstEvent = events.count
        for index in birds.indices where birds[index].alive && Self.collides(birds[index], with: gates) {
            crash(index, events: &events)
        }
        if events.count > firstEvent {
            eliminationOrder.recordBatch(events[firstEvent...])
            finishIfDecided()
        }
    }

    private mutating func scoreGates(events: inout [ArcadeEvent]) {
        for index in birds.indices where birds[index].alive {
            let tail = birds[index].x - Self.birdRadius
            for gate in gates where gate.id > birds[index].lastClearedGateID {
                guard gate.trailingEdge <= tail else { break }
                birds[index].lastClearedGateID = gate.id
                birds[index].gates += 1
                events.append(.cue(birds[index].playerID, colorHex: Self.passColor, haptic: .lightImpact))
            }
        }
    }

    private mutating func crash(_ index: Int, events: inout [ArcadeEvent]) {
        birds[index].alive = false
        birds[index].crashedAt = elapsed
        events.append(.eliminated(birds[index].playerID))
    }

    private mutating func finishIfDecided() {
        let alive = birds.count(where: \.alive)
        if alive == 0 || (multiplayer && alive <= 1) { isFinished = true }
    }

    /// Ceiling, floor or any pillar.
    static func collides(_ bird: Bird, with gates: [Gate]) -> Bool {
        if bird.y + birdRadius > ArcadeArena.maxY || bird.y - birdRadius < ArcadeArena.minY { return true }
        let point = ArcadeVector(x: bird.x, y: bird.y)
        return gates.contains { gate in
            abs(gate.x + pillarWidth / 2 - bird.x) < pillarWidth / 2 + birdRadius
                && (circleHitsRect(point, rect: gate.lowerPillar) || circleHitsRect(point, rect: gate.upperPillar))
        }
    }

    private static func circleHitsRect(_ point: ArcadeVector, rect: CGRect) -> Bool {
        guard rect.height > 0 else { return false }
        let dx = max(Double(rect.minX) - point.x, 0, point.x - Double(rect.maxX))
        let dy = max(Double(rect.minY) - point.y, 0, point.y - Double(rect.maxY))
        return (dx * dx) + (dy * dy) < birdRadius * birdRadius
    }

#if DEBUG
    mutating func placeForTesting(_ playerID: PlayerID, y: Double, vy: Double = 0) {
        guard let index = indexByID[playerID] else { return }
        birds[index].y = y
        birds[index].vy = vy
        birds[index].hovering = false
    }

    /// Replaces the course. Spawning resumes once the newest gate scrolls
    /// left of `spawnHorizon`, so place a far gate last to keep a test clean.
    mutating func setGatesForTesting(_ gates: [Gate]) {
        self.gates = gates
        nextGateID = (gates.map(\.id).max() ?? 0) + 1
        previousGapCenter = gates.last?.gapCenter ?? ArcadeArena.center.y
        for index in birds.indices {
            birds[index].lastClearedGateID = 0
        }
    }

    mutating func setElapsedForTesting(_ elapsed: Double) {
        self.elapsed = elapsed
        announcedStage = elapsed >= 45 ? 3 : elapsed >= 30 ? 2 : elapsed >= 15 ? 1 : 0
    }
#endif
}
