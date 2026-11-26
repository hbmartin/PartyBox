import Foundation
import PartyBoxCore
import PartyGameRuntime
import PartyNet

/// Sumo on ice: shove rival pucks off a shrinking circular platform.
struct BumperBrawlSimulation: ArcadeSimulation, Equatable {
    static let duration = 70.0
    static let startingLives = 3
    static let puckRadius = 40.0
    static let startPlatformRadius = 480.0
    static let finalPlatformRadius = 200.0
    static let shrinkStart = 15.0
    static let shrinkEnd = 60.0
    static let finalRingTime = 50.0
    static let spawnRingFraction = 0.55
    static let thrust = 2_000.0
    static let drag = 1.5
    /// Thrust alone never pushes a puck past this speed; hits and dashes can.
    static let cruiseSpeed = 700.0
    static let dashImpulse = 600.0
    static let dashCooldown = 1.2
    static let dashWindow = 0.25
    static let dashKnockback = 1.25
    static let restitution = 0.75
    static let stickDeadZone = 0.15
    static let creditWindow = 3.0
    static let respawnDelay = 1.0
    static let ghostDuration = 1.2
    /// A ghost still overlapping a solid puck stays ghosted this much longer at
    /// most; after that the overlap resolves as an ordinary shove.
    static let maximumGhostOverstay = 0.6
    static let maximumSubstep = 1.0 / 120.0
    static let koValue = 100
    static let survivalPointsPerSecond = 10.0
    static let droneCount = 2
    static let droneReaction = 0.18
    /// Closing speed that buzzes both phones.
    static let bumpSpeed = 220.0
    /// Closing speed that also thuds on the TV.
    static let hardHitSpeed = 520.0
    static let bumpFeedbackCooldown = 0.15

    struct Puck: Equatable, Sendable {
        /// `nil` for a solo-mode chaser drone.
        let playerID: PlayerID?
        var position: ArcadeVector
        var velocity = ArcadeVector.zero
        var stick = ArcadeVector.zero
        /// Last deliberate travel direction; a dash with no stick or speed uses it.
        var heading: ArcadeVector
        var lives: Int
        var kos = 0
        var survivalTime = 0.0
        var dashCooldownRemaining = 0.0
        var dashRemaining = 0.0
        var fallRemaining = 0.0
        var ghostRemaining = 0.0
        var ghostOverstay = 0.0
        /// Index into `pucks` of the last body this puck touched.
        var lastToucher: Int?
        var touchRemaining = 0.0
        var bumpCooldown = 0.0
        /// Increments on every fall so renderers can play the splash once.
        var falls = 0
        /// Drone-only decision timer.
        var thinkRemaining = 0.0

        var isDrone: Bool { playerID == nil }
        var alive: Bool { lives > 0 }
        var onBoard: Bool { alive && fallRemaining <= 0 }
        var isFalling: Bool { fallRemaining > 0 }
        var isGhost: Bool { onBoard && ghostRemaining > 0 }
        var isSolid: Bool { onBoard && ghostRemaining <= 0 }
        var isDashing: Bool { dashRemaining > 0 }
        var dashReady: Bool { dashCooldownRemaining <= 0 }
        /// 0 right after a dash, 1 once the next dash is ready.
        var dashCharge: Double {
            1 - min(max(dashCooldownRemaining / BumperBrawlSimulation.dashCooldown, 0), 1)
        }

        var score: Int {
            kos * BumperBrawlSimulation.koValue + Int(survivalTime * BumperBrawlSimulation.survivalPointsPerSecond)
        }
    }

    /// Per-difficulty steering knobs shared by bots and drones.
    struct BotSkill: Equatable, Sendable {
        /// Seconds of target motion to lead.
        var lead: Double
        /// 0 steers straight at the goal (and skates past it); 1 matches velocity.
        var compensation: Double
        /// Maximum random aim error in radians.
        var noise: Double
        var dashChance: Double
        /// How much stopping distance counts when checking the edge.
        var lookAhead: Double
        /// Seconds the decision is held, so the edge check covers that drift too.
        var reaction: Double
        /// Fraction of cruise speed the puck tries to travel at.
        var throttle: Double

        static func forDifficulty(_ difficulty: GameBotDifficulty) -> BotSkill {
            let reaction = BumperBrawlSimulation.botReactionInterval(for: difficulty)
            return switch difficulty {
            case .easy:
                BotSkill(lead: 0, compensation: 0.85, noise: 0.45, dashChance: 0.12, lookAhead: 1, reaction: reaction, throttle: 0.75)
            case .normal:
                BotSkill(lead: 0.1, compensation: 0.9, noise: 0.15, dashChance: 0.6, lookAhead: 1.1, reaction: reaction, throttle: 0.9)
            case .hard:
                BotSkill(lead: 0.15, compensation: 1, noise: 0, dashChance: 1, lookAhead: 1.2, reaction: reaction, throttle: 1)
            }
        }

        /// Solo chasers start lazy and get pushier as the ice melts.
        static func drone(at time: Double) -> BotSkill {
            BotSkill(
                lead: 0.1,
                compensation: 0.9,
                noise: 0.3,
                dashChance: arcadeRamp(from: 0.08, to: 0.35, start: 5, end: 60, at: time),
                lookAhead: 1,
                reaction: BumperBrawlSimulation.droneReaction,
                throttle: arcadeRamp(from: 0.5, to: 0.85, start: 5, end: 60, at: time)
            )
        }
    }

    struct BotPlan: Equatable, Sendable {
        var stick: ArcadeVector
        var dash: Bool
    }

    private(set) var pucks: [Puck]
    private(set) var elapsed = 0.0
    private(set) var isFinished = false
    private var random: ArcadeRandomNumberGenerator
    private var eliminationOrder: [PlayerID] = []
    private var announcedStage = 0
    private var soundCooldown = 0.0
    private let indexByID: [PlayerID: Int]
    private let multiplayer: Bool

    init(players: [PlayerID], seed: UInt64) {
        random = ArcadeRandomNumberGenerator(seed: ArcadeRandomNumberGenerator.mixed(seed, 0xB0B5))
        multiplayer = players.count > 1
        indexByID = Dictionary(players.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let total = players.count + (players.count == 1 ? Self.droneCount : 0)
        let ring = Self.startPlatformRadius * Self.spawnRingFraction
        pucks = (0..<total).map { slot in
            let angle = .pi + (Double(slot) / Double(max(1, total))) * .pi * 2
            let position = ArcadeArena.center + ArcadeVector(angle: angle, length: ring)
            let playerID = slot < players.count ? players[slot] : nil
            return Puck(
                playerID: playerID,
                position: position,
                heading: (ArcadeArena.center - position).normalized(),
                lives: playerID == nil ? 1 : Self.startingLives
            )
        }
    }

    // MARK: Tuning

    static func platformRadius(at time: Double) -> Double {
        arcadeRamp(from: startPlatformRadius, to: finalPlatformRadius, start: shrinkStart, end: shrinkEnd, at: time)
    }

    var platformRadius: Double { Self.platformRadius(at: elapsed) }

    /// 0 before the melt, 1 once the platform reaches its final size.
    var shrinkProgress: Double {
        min(max((elapsed - Self.shrinkStart) / (Self.shrinkEnd - Self.shrinkStart), 0), 1)
    }

    var isShrinking: Bool { elapsed > Self.shrinkStart && elapsed < Self.shrinkEnd }

    var players: [Puck] { pucks.filter { !$0.isDrone } }
    var drones: [Puck] { pucks.filter(\.isDrone) }

    // MARK: ArcadeSimulation

    var timeRemaining: Double? { max(0, Self.duration - elapsed) }

    func isActive(_ playerID: PlayerID) -> Bool {
        indexByID[playerID].map { pucks[$0].alive } ?? false
    }

    func puck(for playerID: PlayerID) -> Puck? {
        indexByID[playerID].map { pucks[$0] }
    }

    mutating func step(deltaTime: Double, inputs: [PlayerID: ArcadeInput]) -> [ArcadeEvent] {
        guard !isFinished else { return [] }
        let delta = min(max(deltaTime, 0), 0.05)
        var events: [ArcadeEvent] = []
        ingest(inputs)
        thinkDrones(delta: delta)
        let substeps = max(1, Int(((delta / Self.maximumSubstep) - 0.000_001).rounded(.up)))
        let substep = delta / Double(substeps)
        for _ in 0..<substeps where !isFinished {
            simulate(substep, events: &events)
        }
        if !isFinished, elapsed >= Self.duration { isFinished = true }
        return events
    }

    mutating func forfeit(_ playerID: PlayerID) -> [ArcadeEvent] {
        guard !isFinished, let index = indexByID[playerID], pucks[index].alive else { return [] }
        pucks[index].lives = 0
        pucks[index].fallRemaining = 0
        pucks[index].ghostRemaining = 0
        pucks[index].velocity = .zero
        pucks[index].stick = .zero
        eliminationOrder.append(playerID)
        var events: [ArcadeEvent] = [.eliminated(playerID)]
        finishIfDecided(events: &events)
        return events
    }

    func ranking() -> [ArcadeRankEntry] {
        let seated = pucks.compactMap { puck in puck.playerID.map { (id: $0, puck: puck) } }
        let solo = !multiplayer
        return ArcadeRanking.bySurvival(
            seated,
            id: \.id,
            alive: \.puck.alive,
            lives: \.puck.lives,
            score: \.puck.score,
            eliminationOrder: eliminationOrder,
            detail: { entry in
                solo
                    ? "\(Int(entry.puck.survivalTime))s on the ice • \(entry.puck.kos) drone KOs"
                    : "\(entry.puck.lives) lives • \(entry.puck.kos) KOs"
            }
        )
    }

    func scoreLine(for playerID: PlayerID) -> String {
        guard let puck = puck(for: playerID) else { return "" }
        return "\(puck.score)  \(ArcadeRanking.lives(puck.lives))"
    }

    var resultMetric: MatchMetric {
        .init(id: "most-kos", label: "Most KOs", value: "\(players.map(\.kos).max() ?? 0)")
    }

    static func botReactionInterval(for difficulty: GameBotDifficulty) -> Double {
        switch difficulty {
        case .easy: 0.3
        case .normal: 0.15
        case .hard: 0.08
        }
    }

    func botDecision(
        for playerID: PlayerID,
        difficulty: GameBotDifficulty,
        random: inout ArcadeRandomNumberGenerator
    ) -> ArcadeBotDecision {
        guard let index = indexByID[playerID], pucks[index].onBoard else { return .idle }
        let decision = plan(for: index, skill: .forDifficulty(difficulty), random: &random)
        return ArcadeBotDecision(vector: decision.stick, press: decision.dash)
    }

    /// Steering shared by player bots and solo drones: line up on the inner side
    /// of the nearest rival and drive it outward, bailing toward the middle
    /// whenever this puck's own momentum would carry it near the edge.
    func plan(for index: Int, skill: BotSkill, random: inout ArcadeRandomNumberGenerator) -> BotPlan {
        let me = pucks[index]
        let center = ArcadeArena.center
        let radius = platformRadius
        let fromCenter = me.position - center
        let distance = fromCenter.length
        let inward = distance > 0.001 ? -(fromCenter / distance) : .zero
        let cruise = Self.cruiseSpeed * skill.throttle

        var stick: ArcadeVector
        var dash = false
        if let target = targetIndex(for: index) {
            let rival = pucks[target]
            let predicted = rival.position + (rival.velocity * skill.lead)
            var outward = predicted - center
            if outward.length < 20 { outward = predicted - me.position }
            outward = outward.normalized()
            if rival.isGhost {
                // Wait on the ghost's inner side, ready to shove once it turns solid.
                let post = predicted - (outward * ((Self.puckRadius * 2) + 50))
                let toPost = post - me.position
                let speed = min(cruise, toPost.length * 3)
                stick = Self.seek(toPost.normalized(), speed: speed, velocity: me.velocity, compensation: 1)
            } else {
                let aim = predicted + (outward * (Self.puckRadius * 1.25))
                var direction = (aim - me.position).normalized()
                if skill.noise > 0 {
                    direction = ArcadeVector(angle: direction.angle + random.double(in: -skill.noise...skill.noise))
                }
                stick = Self.seek(direction, speed: cruise, velocity: me.velocity, compensation: skill.compensation)
                let toRival = predicted - me.position
                let gap = toRival.length
                // Only commit when the dash line actually meets the rival.
                let miss = abs(toRival.dot(direction.perpendicular))
                if me.dashReady, gap < 230, gap > 0.001,
                   direction.dot(toRival / gap) > 0.9,
                   skill.noise > 0.3 || miss < Self.puckRadius * 1.5,
                   skill.dashChance >= 1 || random.chance(skill.dashChance) {
                    dash = true
                    stick = direction
                }
            }
        } else {
            let speed = min(cruise, distance * 3)
            stick = Self.seek(inward, speed: speed, velocity: me.velocity, compensation: 1)
        }

        // Edge safety: past 0.75R, counting the drift until the next decision
        // and the distance needed to stop, blend hard toward the middle.
        let edgeLimit = radius * 0.75
        let outwardSpeed = max(0, -me.velocity.dot(inward))
        let stopping = (outwardSpeed * outwardSpeed) / (2 * Self.thrust)
        let projected = distance + (outwardSpeed * skill.reaction) + (stopping * skill.lookAhead)
        if projected > edgeLimit, distance > 0.001 {
            let room = max(1, radius - edgeLimit)
            let urgency = min(1, (projected - edgeLimit) / room)
            let rescue = Self.seek(inward, speed: Self.cruiseSpeed * 0.6, velocity: me.velocity, compensation: 1)
            stick = ((stick * (1 - urgency)) + (rescue * (2 + (2 * urgency)))).normalized()
            dash = false
        }
        return BotPlan(stick: stick, dash: dash)
    }

    /// The nearest solid rival on the ice, or the nearest ghost when none is solid.
    /// Drones only hunt players; players hunt everyone.
    private func targetIndex(for index: Int) -> Int? {
        let me = pucks[index]
        var bestSolid: (index: Int, distance: Double)?
        var bestGhost: (index: Int, distance: Double)?
        for other in pucks.indices where other != index && pucks[other].onBoard {
            if me.isDrone, pucks[other].isDrone { continue }
            let distance = pucks[other].position.distance(to: me.position)
            if pucks[other].isGhost {
                if bestGhost.map({ distance < $0.distance }) ?? true { bestGhost = (other, distance) }
            } else if bestSolid.map({ distance < $0.distance }) ?? true {
                bestSolid = (other, distance)
            }
        }
        return (bestSolid ?? bestGhost)?.index
    }

    private static func seek(_ direction: ArcadeVector, speed: Double, velocity: ArcadeVector, compensation: Double) -> ArcadeVector {
        let steer = (direction * speed) - (velocity * compensation)
        return (steer / 250).clampedLength(1)
    }

    // MARK: Simulation

    private mutating func ingest(_ inputs: [PlayerID: ArcadeInput]) {
        for index in pucks.indices {
            guard let playerID = pucks[index].playerID else { continue }
            guard pucks[index].onBoard else {
                pucks[index].stick = .zero
                continue
            }
            let input = inputs[playerID] ?? .idle
            pucks[index].stick = input.vector.clampedLength(1)
            if input.pressed { dash(index) }
        }
    }

    private mutating func thinkDrones(delta: Double) {
        for index in pucks.indices where pucks[index].isDrone {
            pucks[index].thinkRemaining -= delta
            guard pucks[index].thinkRemaining <= 0 else { continue }
            pucks[index].thinkRemaining = Self.droneReaction
            guard pucks[index].onBoard else {
                pucks[index].stick = .zero
                continue
            }
            var stream = random
            let decision = plan(for: index, skill: .drone(at: elapsed), random: &stream)
            random = stream
            // Drones also thrust softer early on, so their bumps start gentle.
            pucks[index].stick = decision.stick * arcadeRamp(from: 0.75, to: 1, start: 5, end: 60, at: elapsed)
            if decision.dash { dash(index) }
        }
    }

    private mutating func dash(_ index: Int) {
        guard pucks[index].onBoard, pucks[index].dashReady else { return }
        let stick = pucks[index].stick
        let velocity = pucks[index].velocity
        let direction = if stick.length >= Self.stickDeadZone {
            stick.normalized()
        } else if velocity.length > 1 {
            velocity.normalized()
        } else {
            pucks[index].heading
        }
        pucks[index].velocity += direction * Self.dashImpulse
        pucks[index].heading = direction
        pucks[index].dashCooldownRemaining = Self.dashCooldown
        pucks[index].dashRemaining = Self.dashWindow
    }

    private mutating func simulate(_ delta: Double, events: inout [ArcadeEvent]) {
        elapsed += delta
        announceStage(events: &events)
        advanceTimers(delta)
        integrate(delta)
        collide(events: &events)
        resolveFalls(events: &events)
        for index in pucks.indices where !pucks[index].isDrone && pucks[index].alive {
            pucks[index].survivalTime += delta
        }
        if elapsed >= Self.duration { isFinished = true }
    }

    private mutating func announceStage(events: inout [ArcadeEvent]) {
        let stage = elapsed >= Self.finalRingTime ? 2 : elapsed >= Self.shrinkStart ? 1 : 0
        guard stage > announcedStage else { return }
        announcedStage = stage
        events.append(.banner(stage == 2 ? "FINAL RING" : "THE ICE IS MELTING"))
        events.append(.sound(.lightImpact))
    }

    private mutating func advanceTimers(_ delta: Double) {
        soundCooldown = max(0, soundCooldown - delta)
        for index in pucks.indices {
            var puck = pucks[index]
            puck.dashCooldownRemaining = max(0, puck.dashCooldownRemaining - delta)
            puck.dashRemaining = max(0, puck.dashRemaining - delta)
            puck.bumpCooldown = max(0, puck.bumpCooldown - delta)
            if puck.touchRemaining > 0 {
                puck.touchRemaining -= delta
                if puck.touchRemaining <= 0 {
                    puck.touchRemaining = 0
                    puck.lastToucher = nil
                }
            }
            if puck.fallRemaining > 0 {
                puck.fallRemaining -= delta
                if puck.fallRemaining <= 0 {
                    puck.fallRemaining = 0
                    pucks[index] = puck
                    if puck.alive { respawn(index) }
                    continue
                }
            } else if puck.ghostRemaining > 0 {
                puck.ghostRemaining -= delta
                if puck.ghostRemaining <= 0 {
                    if puck.ghostOverstay < Self.maximumGhostOverstay,
                       overlapsSolidPuck(at: puck.position, excluding: index) {
                        puck.ghostOverstay += delta
                        puck.ghostRemaining = 0.000_1
                    } else {
                        puck.ghostRemaining = 0
                        puck.ghostOverstay = 0
                    }
                }
            }
            pucks[index] = puck
        }
    }

    private mutating func integrate(_ delta: Double) {
        let decay = exp(-Self.drag * delta)
        for index in pucks.indices where pucks[index].onBoard || pucks[index].isFalling {
            var puck = pucks[index]
            if puck.onBoard {
                let before = puck.velocity.length
                var next = puck.velocity + (puck.stick * (Self.thrust * delta))
                let limit = max(Self.cruiseSpeed, before)
                if next.length > limit { next = next.normalized() * limit }
                puck.velocity = next
                if puck.stick.length >= Self.stickDeadZone { puck.heading = puck.stick.normalized() }
            }
            puck.velocity = puck.velocity * decay
            puck.position += puck.velocity * delta
            pucks[index] = puck
        }
    }

    private mutating func collide(events: inout [ArcadeEvent]) {
        let solid = pucks.indices.filter { pucks[$0].isSolid }
        let contact = Self.puckRadius * 2
        for (offset, first) in solid.enumerated() {
            for second in solid[(offset + 1)...] {
                let separation = pucks[second].position - pucks[first].position
                let distance = separation.length
                guard distance < contact else { continue }
                let normal = distance > 0.000_1 ? separation / distance : ArcadeVector(x: 1, y: 0)
                let push = normal * ((contact - distance) / 2)
                pucks[first].position -= push
                pucks[second].position += push
                let closing = (pucks[first].velocity - pucks[second].velocity).dot(normal)
                if closing > 0 {
                    let impulse = closing * (1 + Self.restitution) / 2
                    let onFirst = pucks[second].isDashing ? Self.dashKnockback : 1
                    let onSecond = pucks[first].isDashing ? Self.dashKnockback : 1
                    pucks[first].velocity -= normal * (impulse * onFirst)
                    pucks[second].velocity += normal * (impulse * onSecond)
                    bumpFeedback(first, second, closing: closing, events: &events)
                }
                pucks[first].lastToucher = second
                pucks[first].touchRemaining = Self.creditWindow
                pucks[second].lastToucher = first
                pucks[second].touchRemaining = Self.creditWindow
            }
        }
    }

    private mutating func bumpFeedback(_ first: Int, _ second: Int, closing: Double, events: inout [ArcadeEvent]) {
        guard closing >= Self.bumpSpeed else { return }
        for index in [first, second] where pucks[index].bumpCooldown <= 0 {
            pucks[index].bumpCooldown = Self.bumpFeedbackCooldown
            if let playerID = pucks[index].playerID { events.append(.haptic(playerID, .lightImpact)) }
        }
        if closing >= Self.hardHitSpeed, soundCooldown <= 0 {
            soundCooldown = 0.1
            events.append(.sound(.lightImpact))
        }
    }

    private mutating func resolveFalls(events: inout [ArcadeEvent]) {
        let radius = platformRadius
        var anyEliminated = false
        for index in pucks.indices where pucks[index].onBoard
            && pucks[index].position.distance(to: ArcadeArena.center) > radius {
            if fall(index, events: &events) { anyEliminated = true }
        }
        if anyEliminated { finishIfDecided(events: &events) }
    }

    /// Drops a puck off the ice. Returns true when that eliminated a player.
    private mutating func fall(_ index: Int, events: inout [ArcadeEvent]) -> Bool {
        var puck = pucks[index]
        let credit = puck.touchRemaining > 0 ? puck.lastToucher : nil
        puck.fallRemaining = Self.respawnDelay
        puck.ghostRemaining = 0
        puck.dashRemaining = 0
        puck.stick = .zero
        puck.lastToucher = nil
        puck.touchRemaining = 0
        puck.falls += 1
        var eliminated = false
        if let playerID = puck.playerID {
            puck.lives -= 1
            if puck.lives <= 0 {
                puck.lives = 0
                eliminationOrder.append(playerID)
                events.append(.eliminated(playerID))
                eliminated = true
            } else {
                events.append(.lostLife(playerID, remaining: puck.lives))
            }
        } else {
            events.append(.sound(.heavyImpact))
        }
        pucks[index] = puck
        if let credit, credit != index, pucks.indices.contains(credit), let creditID = pucks[credit].playerID {
            pucks[credit].kos += 1
            events.append(.cue(creditID, colorHex: ArcadeOutcomeBuilder.winnerColor, haptic: .success))
        }
        return eliminated
    }

    private mutating func respawn(_ index: Int) {
        let spot = freeSpawnPoint(excluding: index)
        pucks[index].position = spot
        pucks[index].velocity = .zero
        pucks[index].stick = .zero
        pucks[index].ghostRemaining = Self.ghostDuration
        pucks[index].ghostOverstay = 0
        pucks[index].dashCooldownRemaining = 0
        pucks[index].dashRemaining = 0
        pucks[index].lastToucher = nil
        pucks[index].touchRemaining = 0
        let toCenter = ArcadeArena.center - spot
        if toCenter.length > 1 { pucks[index].heading = toCenter.normalized() }
    }

    /// The point nearest the middle with room for a puck, else the roomiest one.
    private mutating func freeSpawnPoint(excluding index: Int) -> ArcadeVector {
        let others = pucks.indices.filter { $0 != index && pucks[$0].onBoard }.map { pucks[$0].position }
        let start = random.unit() * .pi * 2
        let reach = platformRadius * 0.6
        var best = ArcadeArena.center
        var bestScore = -Double.infinity
        for ring in [0.0, 70, 140] {
            let count = ring == 0 ? 1 : 8
            for slot in 0..<count {
                let angle = start + ((Double(slot) / Double(count)) * .pi * 2)
                let point = ArcadeArena.center + ArcadeVector(angle: angle, length: min(ring, reach))
                let clearance = others.map { $0.distance(to: point) }.min() ?? .infinity
                if clearance >= (Self.puckRadius * 2) + 30 { return point }
                let score = clearance - (ring * 0.25)
                if score > bestScore {
                    bestScore = score
                    best = point
                }
            }
        }
        return best
    }

    private func overlapsSolidPuck(at point: ArcadeVector, excluding index: Int) -> Bool {
        pucks.indices.contains { other in
            other != index && pucks[other].isSolid && pucks[other].position.distance(to: point) < Self.puckRadius * 2
        }
    }

    private mutating func finishIfDecided(events: inout [ArcadeEvent]) {
        let alive = pucks.count { !$0.isDrone && $0.alive }
        if alive == 0 || (multiplayer && alive <= 1) { isFinished = true }
    }

#if DEBUG
    /// Moves a player's puck onto the ice at `position`, clearing ghost and fall
    /// state but leaving its dash cooldown alone.
    mutating func placeForTesting(_ playerID: PlayerID, at position: ArcadeVector, velocity: ArcadeVector = .zero) {
        guard let index = indexByID[playerID] else { return }
        placeForTesting(index: index, at: position, velocity: velocity)
    }

    mutating func placeDroneForTesting(_ drone: Int, at position: ArcadeVector, velocity: ArcadeVector = .zero) {
        let indices = pucks.indices.filter { pucks[$0].isDrone }
        guard indices.indices.contains(drone) else { return }
        placeForTesting(index: indices[drone], at: position, velocity: velocity)
    }

    private mutating func placeForTesting(index: Int, at position: ArcadeVector, velocity: ArcadeVector) {
        pucks[index].position = position
        pucks[index].velocity = velocity
        pucks[index].fallRemaining = 0
        pucks[index].ghostRemaining = 0
    }

    mutating func setLivesForTesting(_ lives: Int, playerID: PlayerID) {
        guard let index = indexByID[playerID] else { return }
        pucks[index].lives = lives
    }

    mutating func setElapsedForTesting(_ elapsed: Double) {
        self.elapsed = elapsed
    }
#endif
}
