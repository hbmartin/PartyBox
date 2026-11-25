import Foundation
import PartyBoxCore
import PartyGameRuntime
import PartyNet

/// Bomb tag with elimination rounds. One player carries a bomb on a hidden
/// fuse; touching someone passes it. Whoever holds it at the boom is out, and
/// the next fuse starts on the survivor nearest the blast. Solo play is the
/// "DEFUSE DRILL": tag fleeing drones to restart an ever-shorter fuse.
struct HotFuseSimulation: ArcadeSimulation, Equatable {
    static let fieldInset = 30.0
    static let playerRadius = 32.0
    static let bumperRadius = 60.0
    static let bumpers: [ArcadeVector] = [
        ArcadeArena.center + ArcadeVector(x: -355, y: -200),
        ArcadeArena.center + ArcadeVector(x: 355, y: -200),
        ArcadeArena.center + ArcadeVector(x: -355, y: 200),
        ArcadeArena.center + ArcadeVector(x: 355, y: 200),
    ]
    static let runSpeed = 500.0
    static let carrierSpeedMultiplier = 1.1
    static let deadZone = 0.12
    static let firstFuseWindow = 7.0...11.0
    static let fuseShrinkPerRound = 0.8
    static let fuseFloorWindow = 4.0...6.0
    static let tagBackImmunity = 0.6
    static let intermissionDuration = 1.2
    static let passBounceSpeed = 380.0
    static let bounceDecayRate = 9.0
    /// Resting contact (exactly touching) still counts as a tag.
    static let contactSlop = 1.0
    static let droneCount = 3
    static let droneRadius = 26.0
    static let drillFuseFactor = 0.9
    static let botLeadTime = 0.3
    static let bombColor = "#FF375F"
    static let tagColor = "#39FF88"
    static let nextFuseBanner = "NEXT FUSE"
    static let drillBanner = "DEFUSE DRILL"

    /// Start positions relative to the arena center, clear of every bumper and
    /// ordered so small lobbies still spread out.
    static let spawnOffsets: [ArcadeVector] = [
        ArcadeVector(x: -540, y: 0),
        ArcadeVector(x: 540, y: 0),
        ArcadeVector(x: 0, y: 270),
        ArcadeVector(x: 0, y: -270),
        ArcadeVector(x: -580, y: 290),
        ArcadeVector(x: 580, y: -290),
        ArcadeVector(x: 580, y: 290),
        ArcadeVector(x: -580, y: -290),
    ]

    struct Player: Equatable, Sendable {
        let playerID: PlayerID
        var position: ArcadeVector
        /// Effective velocity over the last step, used by bots to lead targets.
        var velocity: ArcadeVector = .zero
        /// Decaying knockback from a pass.
        var bounce: ArcadeVector = .zero
        var immunityRemaining = 0.0
        var passes = 0
        var lives = 1
        var alive = true
        var eliminatedInRound: Int?

        var isImmune: Bool { immunityRemaining > 0 }
    }

    struct Drone: Equatable, Sendable {
        let id: Int
        var position: ArcadeVector
        var velocity: ArcadeVector = .zero
        /// Increments whenever the drone is tagged and relocates.
        var generation = 0
    }

    /// The most recent boom, for the renderer's blast effect.
    struct Blast: Equatable, Sendable {
        let playerID: PlayerID
        let position: ArcadeVector
        let generation: Int
    }

    /// The most recent bomb hand-off (or drone tag), for the renderer.
    struct Pass: Equatable, Sendable {
        let position: ArcadeVector
        let generation: Int
    }

    private(set) var players: [Player]
    private(set) var drones: [Drone] = []
    /// Who holds the bomb; `nil` during the between-rounds intermission.
    private(set) var carrier: PlayerID?
    private(set) var round = 1
    /// Hidden fuse length for the current bomb.
    private(set) var fuseLength: Double
    private(set) var fuseElapsed = 0.0
    /// Accumulated pulse angle for the TV bomb; its rate rises with fuse progress.
    private(set) var pulsePhase = 0.0
    private(set) var intermissionRemaining = 0.0
    private(set) var blastPoint: ArcadeVector
    private(set) var lastBlast: Blast?
    private(set) var lastPass: Pass?
    private(set) var elapsed = 0.0
    private(set) var isFinished = false
    let isDrill: Bool
    private var random: ArcadeRandomNumberGenerator
    private var opened = false
    private var blastCount = 0
    private var passCount = 0
    private var eliminationOrder: [PlayerID] = []
    /// The player who just survived a boom; the next bomb skips them if anyone else is left.
    private var sparedFromNextBomb: PlayerID?
    private let indexByID: [PlayerID: Int]

    init(players playerIDs: [PlayerID], seed: UInt64) {
        var random = ArcadeRandomNumberGenerator(seed: ArcadeRandomNumberGenerator.mixed(seed, 0xF05E))
        // Round 1: a seeded random carrier and fuse length.
        carrier = playerIDs.isEmpty ? nil : playerIDs[random.index(below: playerIDs.count)]
        fuseLength = random.double(in: Self.fuseWindow(forRound: 1))
        self.random = random
        isDrill = playerIDs.count == 1
        indexByID = Dictionary(playerIDs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        blastPoint = ArcadeArena.center
        if playerIDs.count == 1 {
            players = [Player(playerID: playerIDs[0], position: ArcadeArena.center)]
            drones = (0..<Self.droneCount).map { index in
                Drone(id: index, position: ArcadeArena.center + Self.spawnOffsets[index])
            }
        } else {
            let lives = Self.startingLives(playerCount: playerIDs.count)
            players = playerIDs.enumerated().map { index, playerID in
                Player(
                    playerID: playerID,
                    position: ArcadeArena.center + Self.spawnOffsets[index % Self.spawnOffsets.count],
                    lives: lives
                )
            }
        }
    }

    // MARK: Tuning

    /// Small groups get extra booms so a duel is a short series, not one 10s round.
    static func startingLives(playerCount: Int) -> Int {
        switch playerCount {
        case ...2: 3
        case 3...4: 2
        default: 1
        }
    }

    /// The hidden fuse range for a multiplayer round: 7–11s in round 1, shifted
    /// down 0.8s per later round, never below 4–6s.
    static func fuseWindow(forRound round: Int) -> ClosedRange<Double> {
        let shift = Double(max(0, round - 1)) * fuseShrinkPerRound
        let lower = max(fuseFloorWindow.lowerBound, firstFuseWindow.lowerBound - shift)
        let upper = max(fuseFloorWindow.upperBound, firstFuseWindow.upperBound - shift)
        return lower...upper
    }

    /// Pulses per second for the TV bomb. It depends only on the elapsed
    /// fraction, so the screen never shows the exact time left.
    static func pulseRate(progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        return 1.2 + (7.0 * clamped * clamped)
    }

    var fuseProgress: Double {
        guard carrier != nil, fuseLength > 0 else { return 0 }
        return min(1, fuseElapsed / fuseLength)
    }

    /// Drones get quicker as the drill goes on.
    var droneSpeed: Double {
        arcadeRamp(from: 320, to: 450, start: 0, end: 12, at: Double(players.first?.passes ?? 0))
    }

    // MARK: ArcadeSimulation

    var timeRemaining: Double? { nil }

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
        open(events: &events)
        advanceTimers(delta: delta)
        if carrier != nil {
            burnFuse(delta: delta, events: &events)
        } else if intermissionRemaining > 0 {
            intermissionRemaining -= delta
            if intermissionRemaining <= 0 { startNextRound(events: &events) }
        }
        guard !isFinished else { return events }
        let previous = players.map(\.position)
        movePlayers(delta: delta, inputs: inputs)
        moveDrones(delta: delta)
        resolveTag(events: &events)
        separatePlayers()
        if delta > 0 {
            for index in players.indices {
                players[index].velocity = (players[index].position - previous[index]) / delta
            }
        }
        return events
    }

    mutating func forfeit(_ playerID: PlayerID) -> [ArcadeEvent] {
        guard !isFinished, let index = indexByID[playerID], players[index].alive else { return [] }
        var events: [ArcadeEvent] = []
        let wasCarrier = carrier == playerID
        eliminate(index, events: &events)
        if wasCarrier {
            carrier = nil
            finishIfDecided()
            if !isFinished { beginIntermission(at: players[index].position, events: &events) }
        } else {
            finishIfDecided()
        }
        return events
    }

    func ranking() -> [ArcadeRankEntry] {
        ArcadeRanking.bySurvival(
            players,
            id: \.playerID,
            alive: \.alive,
            lives: \.lives,
            score: \.passes,
            eliminationOrder: eliminationOrder,
            detail: { player in
                let passes = player.passes == 1 ? "1 pass" : "\(player.passes) passes"
                if let round = player.eliminatedInRound { return "\(passes) • out in round \(round)" }
                return "\(passes) • survived"
            }
        )
    }

    func scoreLine(for playerID: PlayerID) -> String {
        guard let player = player(for: playerID) else { return "" }
        let lives = players.contains { $0.lives > 1 } || player.lives > 1
            ? "\(ArcadeRanking.lives(player.alive ? player.lives : 0))  " : ""
        return carrier == playerID ? "\(lives)\(player.passes)  💣" : "\(lives)\(player.passes)"
    }

    var resultMetric: MatchMetric {
        .init(id: "most-passes", label: "Most passes", value: "\(players.map(\.passes).max() ?? 0)")
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
        guard !isFinished, let me = player(for: playerID), me.alive else { return .idle }
        let speedFactor = switch difficulty {
        case .easy: 0.85
        case .normal: 0.95
        case .hard: 1.0
        }
        var steering: ArcadeVector
        if carrier == playerID {
            steering = pursuitSteering(for: me)
        } else if let carrierID = carrier, let threat = player(for: carrierID) {
            steering = Self.fleeSteering(at: me.position, radius: Self.playerRadius, threat: threat.position)
        } else if intermissionRemaining > 0 {
            // The next bomb lands on whoever is nearest the blast: get clear.
            steering = Self.fleeSteering(at: me.position, radius: Self.playerRadius, threat: blastPoint)
        } else {
            steering = .zero
        }
        if difficulty == .easy {
            steering += ArcadeVector(angle: random.double(in: 0...(2 * .pi)), length: 0.45)
        }
        return ArcadeBotDecision(vector: steering.clampedLength(1) * speedFactor)
    }

    // MARK: Simulation

    private mutating func open(events: inout [ArcadeEvent]) {
        guard !opened else { return }
        opened = true
        if isDrill { events.append(.banner(Self.drillBanner)) }
        if let carrier { announceCarrier(carrier, events: &events) }
    }

    private mutating func advanceTimers(delta: Double) {
        let decay = exp(-Self.bounceDecayRate * delta)
        for index in players.indices {
            if players[index].immunityRemaining > 0 {
                players[index].immunityRemaining = max(0, players[index].immunityRemaining - delta)
            }
            players[index].bounce = players[index].bounce * decay
            if players[index].bounce.lengthSquared < 1 { players[index].bounce = .zero }
        }
    }

    private mutating func burnFuse(delta: Double, events: inout [ArcadeEvent]) {
        guard let carrierID = carrier else { return }
        let before = fuseLength - fuseElapsed
        fuseElapsed += delta
        pulsePhase += delta * 2 * .pi * Self.pulseRate(progress: fuseProgress)
        let after = fuseLength - fuseElapsed
        if after <= 0 {
            explode(events: &events)
        } else if ceil(after) < ceil(before) {
            events.append(.haptic(carrierID, .lightImpact))
        }
    }

    private mutating func explode(events: inout [ArcadeEvent]) {
        guard let carrierID = carrier, let index = indexByID[carrierID] else { return }
        let point = players[index].position
        carrier = nil
        blastCount += 1
        lastBlast = Blast(playerID: carrierID, position: point, generation: blastCount)
        if players[index].lives > 1 {
            players[index].lives -= 1
            events.append(.lostLife(carrierID, remaining: players[index].lives))
        } else {
            players[index].lives = 0
            eliminate(index, events: &events)
            events.append(.sound(.heavyImpact))
        }
        finishIfDecided()
        if !isFinished {
            beginIntermission(at: point, events: &events)
            if players[index].alive { sparedFromNextBomb = carrierID }
        }
    }

    private mutating func beginIntermission(at point: ArcadeVector, events: inout [ArcadeEvent]) {
        blastPoint = point
        sparedFromNextBomb = nil
        intermissionRemaining = Self.intermissionDuration
        fuseElapsed = 0
        events.append(.banner(Self.nextFuseBanner))
    }

    private mutating func startNextRound(events: inout [ArcadeEvent]) {
        intermissionRemaining = 0
        let point = blastPoint
        let alive = players.indices.filter { players[$0].alive }
        let others = alive.filter { players[$0].playerID != sparedFromNextBomb }
        let survivors = others.isEmpty ? alive : others
        sparedFromNextBomb = nil
        guard let next = survivors.min(by: {
            players[$0].position.distance(to: point) < players[$1].position.distance(to: point)
        }) else { return }
        round += 1
        for index in players.indices { players[index].immunityRemaining = 0 }
        carrier = players[next].playerID
        fuseLength = random.double(in: Self.fuseWindow(forRound: round))
        fuseElapsed = 0
        pulsePhase = 0
        announceCarrier(players[next].playerID, events: &events)
    }

    private func announceCarrier(_ playerID: PlayerID, events: inout [ArcadeEvent]) {
        events.append(.cue(playerID, colorHex: Self.bombColor, haptic: .heavyImpact))
        events.append(.sound(.lightImpact))
    }

    private mutating func eliminate(_ index: Int, events: inout [ArcadeEvent]) {
        players[index].alive = false
        players[index].eliminatedInRound = round
        players[index].immunityRemaining = 0
        players[index].bounce = .zero
        players[index].velocity = .zero
        eliminationOrder.append(players[index].playerID)
        events.append(.eliminated(players[index].playerID))
    }

    private mutating func finishIfDecided() {
        let alive = players.count(where: \.alive)
        if alive == 0 || (!isDrill && alive <= 1) {
            isFinished = true
            carrier = nil
            intermissionRemaining = 0
        }
    }

    private mutating func movePlayers(delta: Double, inputs: [PlayerID: ArcadeInput]) {
        for index in players.indices where players[index].alive {
            let input = inputs[players[index].playerID] ?? .idle
            var stick = input.vector.clampedLength(1)
            if stick.length < Self.deadZone { stick = .zero }
            let speed = Self.runSpeed * (carrier == players[index].playerID ? Self.carrierSpeedMultiplier : 1)
            let velocity = (stick * speed) + players[index].bounce
            players[index].position = Self.resolveObstacles(
                players[index].position + (velocity * delta),
                radius: Self.playerRadius
            )
        }
    }

    private mutating func moveDrones(delta: Double) {
        guard isDrill, let runner = players.first, runner.alive else { return }
        let speed = droneSpeed
        let positions = drones.map(\.position)
        for index in drones.indices {
            var steering = Self.fleeSteering(at: drones[index].position, radius: Self.droneRadius, threat: runner.position)
            for (other, position) in positions.enumerated() where other != index {
                let offset = drones[index].position - position
                let distance = offset.length
                if distance < 140 {
                    let normal = distance > 0.001 ? offset / distance : ArcadeVector(angle: Double(index))
                    steering += normal * ((1 - (distance / 140)) * 1.2)
                }
            }
            let urgency = min(1, max(0.35, steering.length))
            let direction = steering.lengthSquared > 0.000_1 ? steering.normalized() : drones[index].velocity.normalized()
            drones[index].velocity = direction * (speed * urgency)
            drones[index].position = Self.resolveObstacles(
                drones[index].position + (drones[index].velocity * delta),
                radius: Self.droneRadius
            )
        }
    }

    private mutating func resolveTag(events: inout [ArcadeEvent]) {
        guard let carrierID = carrier, let holder = indexByID[carrierID], players[holder].alive else { return }
        if isDrill {
            tagDrone(by: holder, events: &events)
            return
        }
        let origin = players[holder].position
        let reach = (Self.playerRadius * 2) + Self.contactSlop
        var best: (index: Int, distance: Double)?
        for index in players.indices where index != holder && players[index].alive && !players[index].isImmune {
            let distance = players[index].position.distance(to: origin)
            if distance < reach, distance < (best?.distance ?? .infinity) {
                best = (index, distance)
            }
        }
        guard let target = best?.index else { return }
        let offset = players[target].position - origin
        let normal = offset.lengthSquared > 0.000_1 ? offset.normalized() : ArcadeVector(x: 1, y: 0)
        players[holder].bounce = -normal * Self.passBounceSpeed
        players[target].bounce = normal * Self.passBounceSpeed
        players[holder].immunityRemaining = Self.tagBackImmunity
        players[holder].passes += 1
        carrier = players[target].playerID
        passCount += 1
        lastPass = Pass(position: origin + (offset / 2), generation: passCount)
        events.append(.cue(players[target].playerID, colorHex: Self.bombColor, haptic: .heavyImpact))
        events.append(.sound(.lightImpact))
    }

    private mutating func tagDrone(by holder: Int, events: inout [ArcadeEvent]) {
        let origin = players[holder].position
        let reach = Self.playerRadius + Self.droneRadius + Self.contactSlop
        var best: (index: Int, distance: Double)?
        for index in drones.indices {
            let distance = drones[index].position.distance(to: origin)
            if distance < reach, distance < (best?.distance ?? .infinity) {
                best = (index, distance)
            }
        }
        guard let tagged = best?.index else { return }
        passCount += 1
        lastPass = Pass(position: drones[tagged].position, generation: passCount)
        players[holder].passes += 1
        fuseLength *= Self.drillFuseFactor
        fuseElapsed = 0
        pulsePhase = 0
        relocateDrone(tagged, awayFrom: origin)
        events.append(.cue(players[holder].playerID, colorHex: Self.tagColor, haptic: .heavyImpact))
        events.append(.sound(.lightImpact))
    }

    /// Moves a tagged drone to the farthest of a few random open spots.
    private mutating func relocateDrone(_ index: Int, awayFrom point: ArcadeVector) {
        let others = drones.indices.filter { $0 != index }.map { drones[$0].position }
        var best: (position: ArcadeVector, score: Double)?
        for _ in 0..<12 {
            let raw = ArcadeVector(
                x: random.double(in: (ArcadeArena.minX + 100)...(ArcadeArena.maxX - 100)),
                y: random.double(in: (ArcadeArena.minY + 100)...(ArcadeArena.maxY - 100))
            )
            let candidate = Self.resolveObstacles(raw, radius: Self.droneRadius)
            let crowding = others.map { $0.distance(to: candidate) }.min() ?? 1_000
            let score = candidate.distance(to: point) + (min(crowding, 200) * 0.5)
            if score > (best?.score ?? -.infinity) { best = (candidate, score) }
        }
        drones[index].position = best?.position ?? ArcadeArena.center
        drones[index].velocity = .zero
        drones[index].generation += 1
    }

    /// Soft positional separation so tokens never stack.
    private mutating func separatePlayers() {
        let minimum = Self.playerRadius * 2
        var moved = false
        for first in players.indices where players[first].alive {
            for second in players.indices where second > first && players[second].alive {
                let offset = players[second].position - players[first].position
                let distance = offset.length
                guard distance < minimum else { continue }
                let normal = distance > 0.000_1 ? offset / distance : ArcadeVector(x: 1, y: 0)
                let push = (minimum - distance) / 2
                players[first].position -= normal * push
                players[second].position += normal * push
                moved = true
            }
        }
        guard moved else { return }
        for index in players.indices where players[index].alive {
            players[index].position = Self.resolveObstacles(players[index].position, radius: Self.playerRadius)
        }
    }

    // MARK: Geometry and steering

    /// Keeps a body inside the field and outside every bumper (sliding off).
    static func resolveObstacles(_ position: ArcadeVector, radius: Double) -> ArcadeVector {
        var point = ArcadeArena.clamp(position, inset: fieldInset + radius)
        for bumper in bumpers {
            let offset = point - bumper
            let minimum = bumperRadius + radius
            let distance = offset.length
            guard distance < minimum else { continue }
            let normal = distance > 0.000_1 ? offset / distance : ArcadeVector(x: 0, y: 1)
            point = bumper + (normal * minimum)
        }
        return ArcadeArena.clamp(point, inset: fieldInset + radius)
    }

    /// Run away from `threat` (weighted 1/distance), pushed off walls and
    /// bumpers, with a tangential swirl toward open floor so fleeing bodies
    /// circle instead of cornering themselves. Length reflects urgency.
    static func fleeSteering(at position: ArcadeVector, radius: Double, threat: ArcadeVector) -> ArcadeVector {
        let away = position - threat
        let distance = max(away.length, 1)
        let awayDirection = away.lengthSquared > 0.000_1 ? away / distance : (ArcadeArena.center - position).normalized()
        let urgency = 260 / distance
        var steering = awayDirection * urgency
        var tangent = awayDirection.perpendicular
        if tangent.dot(ArcadeArena.center - position) < 0 { tangent = -tangent }
        steering += tangent * (0.45 * min(urgency, 1.5))

        let inset = fieldInset + radius
        let margin = 170.0
        let push = 1.8
        let left = position.x - (ArcadeArena.minX + inset)
        let right = (ArcadeArena.maxX - inset) - position.x
        let bottom = position.y - (ArcadeArena.minY + inset)
        let top = (ArcadeArena.maxY - inset) - position.y
        if left < margin { steering.x += (1 - (max(left, 0) / margin)) * push }
        if right < margin { steering.x -= (1 - (max(right, 0) / margin)) * push }
        if bottom < margin { steering.y += (1 - (max(bottom, 0) / margin)) * push }
        if top < margin { steering.y -= (1 - (max(top, 0) / margin)) * push }

        let reach = 110.0
        for bumper in bumpers {
            let offset = position - bumper
            let gap = offset.length - bumperRadius - radius
            guard gap < reach else { continue }
            steering += offset.normalized() * ((1 - (max(gap, 0) / reach)) * 1.6)
        }
        return steering
    }

    /// Carrier pursuit: the nearest non-immune target, led by its velocity.
    private func pursuitSteering(for me: Player) -> ArcadeVector {
        var targets: [(position: ArcadeVector, velocity: ArcadeVector)]
        if isDrill {
            targets = drones.map { ($0.position, $0.velocity) }
        } else {
            let others = players.filter { $0.alive && $0.playerID != me.playerID }
            let open = others.filter { !$0.isImmune }
            targets = (open.isEmpty ? others : open).map { ($0.position, $0.velocity) }
        }
        guard let target = targets.min(by: {
            $0.position.distance(to: me.position) < $1.position.distance(to: me.position)
        }) else { return .zero }
        let aim = ArcadeArena.clamp(
            target.position + (target.velocity * Self.botLeadTime),
            inset: Self.fieldInset + Self.playerRadius
        )
        let direction = (aim - me.position).normalized()
        return (direction + Self.bumperDetour(from: me.position, toward: aim)).normalized()
    }

    /// Sideways nudge around any bumper sitting on the straight path to `goal`.
    static func bumperDetour(from start: ArcadeVector, toward goal: ArcadeVector) -> ArcadeVector {
        let path = goal - start
        let length = path.length
        guard length > 1 else { return .zero }
        let direction = path / length
        let clearance = bumperRadius + playerRadius + 24
        var detour = ArcadeVector.zero
        for bumper in bumpers {
            let offset = bumper - start
            let along = offset.dot(direction)
            guard along > 0, along < length + bumperRadius else { continue }
            let lateral = offset - (direction * along)
            let gap = lateral.length
            guard gap < clearance else { continue }
            let side = gap > 0.001 ? -(lateral / gap) : direction.perpendicular
            let nearness = max(0.25, 1 - (along / 600))
            detour += side * (((clearance - gap) / clearance) * 1.5 * nearness)
        }
        return detour
    }

#if DEBUG
    mutating func placeForTesting(_ playerID: PlayerID, at position: ArcadeVector) {
        guard let index = indexByID[playerID] else { return }
        players[index].position = position
        players[index].velocity = .zero
        players[index].bounce = .zero
    }

    mutating func setCarrierForTesting(_ playerID: PlayerID?) {
        carrier = playerID
        intermissionRemaining = 0
    }

    mutating func setFuseForTesting(length: Double, elapsed: Double = 0) {
        fuseLength = length
        fuseElapsed = elapsed
    }

    mutating func setLivesForTesting(_ lives: Int, playerID: PlayerID) {
        guard let index = indexByID[playerID] else { return }
        players[index].lives = lives
    }

    mutating func setRoundForTesting(_ round: Int) {
        self.round = round
    }

    mutating func placeDroneForTesting(_ index: Int, at position: ArcadeVector) {
        guard drones.indices.contains(index) else { return }
        drones[index].position = position
        drones[index].velocity = .zero
    }
#endif
}
