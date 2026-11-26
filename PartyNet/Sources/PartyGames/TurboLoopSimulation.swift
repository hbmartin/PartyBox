import Foundation
import PartyBoxCore
import PartyGameRuntime
import PartyNet

// MARK: - Track

/// The fixed Turbo Loop circuit. It is traced from straights and arcs so
/// every corner radius is exact and the loop closes by symmetry. Cars drive
/// clockwise: the start/finish line sits on the top straight, then a sweeping
/// right corner, the right hairpin, the infield dip (an S-bend in and an
/// S-bend out), the left hairpin, and back up to the line. Arc length
/// `s = 0` is the start/finish line.
struct TurboLoopTrack: Sendable {
    enum Piece: Equatable, Sendable {
        case straight(Double)
        /// Signed sweep in radians: positive bends left (counter-clockwise).
        case arc(radius: Double, sweep: Double)

        var length: Double {
            switch self {
            case .straight(let length): length
            case let .arc(radius, sweep): radius * abs(sweep)
            }
        }
    }

    struct Pose: Equatable, Sendable {
        var position: ArcadeVector
        var heading: Double
        /// Signed curvature (1 / radius); positive bends left.
        var curvature: Double
    }

    struct Sample: Equatable, Sendable {
        let position: ArcadeVector
        let tangent: ArcadeVector
        /// Unit vector pointing to the left of the direction of travel.
        let normal: ArcadeVector
        /// Arc length from the start/finish line.
        let distance: Double
        let curvature: Double
    }

    struct BoostPad: Equatable, Sendable {
        let id: Int
        let distance: Double
        /// Offset from the centerline along the sample normal.
        let lateral: Double
        let position: ArcadeVector
        let heading: Double
    }

    static let sampleCount = 360
    static let halfWidth = 95.0
    static let padHalfLength = 38.0
    static let padHalfWidth = 34.0
    static let startPosition = ArcadeVector(x: 837, y: 855)
    static let startHeading = 0.0
    static let checkpointFractions = [0.25, 0.5, 0.75]
    static let standard = TurboLoopTrack()

    private static let topCornerRadius = 200.0
    private static let hairpinRadius = 135.0
    private static let innerCornerRadius = 130.0
    private static let dipRadius = 110.0
    private static let dipSweep = 70.0 * .pi / 180
    private static let dipEntry = 40.0
    private static let dipDiagonal = 120.0
    /// Width of the infield run between the two inner corners (x 1303 → 617).
    private static let infieldSpan = 686.0

    /// The circuit, starting on the start/finish line heading right.
    static let pieces: [Piece] = {
        let quarter = Double.pi / 2
        let dipFlat = infieldSpan - (2 * dipEntry) - (4 * dipRadius * sin(dipSweep)) - (2 * dipDiagonal * cos(dipSweep))
        return [
            .straight(666),
            .arc(radius: topCornerRadius, sweep: -quarter),
            .straight(310),
            .arc(radius: hairpinRadius, sweep: -.pi),
            .straight(140),
            .arc(radius: innerCornerRadius, sweep: quarter),
            .straight(dipEntry),
            .arc(radius: dipRadius, sweep: dipSweep),
            .straight(dipDiagonal),
            .arc(radius: dipRadius, sweep: -dipSweep),
            .straight(dipFlat),
            .arc(radius: dipRadius, sweep: -dipSweep),
            .straight(dipDiagonal),
            .arc(radius: dipRadius, sweep: dipSweep),
            .straight(dipEntry),
            .arc(radius: innerCornerRadius, sweep: quarter),
            .straight(140),
            .arc(radius: hairpinRadius, sweep: -.pi),
            .straight(310),
            .arc(radius: topCornerRadius, sweep: -quarter),
            .straight(420),
        ]
    }()

    /// Boost pads as (piece index, fraction along that piece, lateral offset).
    private static let padLayout: [(piece: Int, fraction: Double, lateral: Double)] = [
        (0, 0.5, -35),
        (10, 0.5, 0),
        (18, 0.55, 35),
    ]

    let samples: [Sample]
    let length: Double
    let spacing: Double
    let pads: [BoostPad]
    /// Gate positions in passing order: the three checkpoints, then the line.
    let gates: [Double]
    let gatePoses: [Pose]
    private let pieceStarts: [Double]
    private let pieceStartPoses: [Pose]

    init() {
        let pieces = Self.pieces
        var poses: [Pose] = []
        var starts: [Double] = []
        var pose = Pose(position: Self.startPosition, heading: Self.startHeading, curvature: 0)
        var total = 0.0
        for piece in pieces {
            poses.append(pose)
            starts.append(total)
            pose = Self.advance(pose, along: piece, by: piece.length)
            total += piece.length
        }
        pieceStartPoses = poses
        pieceStarts = starts
        length = total
        spacing = total / Double(Self.sampleCount)

        var samples: [Sample] = []
        samples.reserveCapacity(Self.sampleCount)
        for index in 0..<Self.sampleCount {
            let distance = Double(index) * spacing
            let pose = Self.pose(atDistance: distance, pieces: pieces, starts: starts, poses: poses)
            let tangent = ArcadeVector(angle: pose.heading)
            samples.append(Sample(
                position: pose.position,
                tangent: tangent,
                normal: tangent.perpendicular,
                distance: distance,
                curvature: pose.curvature
            ))
        }
        self.samples = samples

        pads = Self.padLayout.enumerated().map { id, layout in
            let distance = starts[layout.piece] + (pieces[layout.piece].length * layout.fraction)
            let pose = Self.pose(atDistance: distance, pieces: pieces, starts: starts, poses: poses)
            let normal = ArcadeVector(angle: pose.heading).perpendicular
            return BoostPad(
                id: id,
                distance: distance,
                lateral: layout.lateral,
                position: pose.position + (normal * layout.lateral),
                heading: pose.heading
            )
        }
        let gateDistances = Self.checkpointFractions.map { $0 * total } + [0]
        gates = gateDistances
        gatePoses = gateDistances.map {
            Self.pose(atDistance: $0, pieces: pieces, starts: starts, poses: poses)
        }
    }

    /// Exact pose `distance` along the circuit.
    func pose(atDistance distance: Double) -> Pose {
        Self.pose(atDistance: wrap(distance), pieces: Self.pieces, starts: pieceStarts, poses: pieceStartPoses)
    }

    /// Pose reached after tracing every piece; equals the start pose when the loop closes.
    static func closingPose() -> Pose {
        pieces.reduce(Pose(position: startPosition, heading: startHeading, curvature: 0)) { pose, piece in
            advance(pose, along: piece, by: piece.length)
        }
    }

    static func advance(_ pose: Pose, along piece: Piece, by distance: Double) -> Pose {
        switch piece {
        case .straight:
            return Pose(
                position: pose.position + ArcadeVector(angle: pose.heading, length: distance),
                heading: pose.heading,
                curvature: 0
            )
        case let .arc(radius, sweep):
            let turn: Double = sweep >= 0 ? 1 : -1
            let center = pose.position + (ArcadeVector(angle: pose.heading).perpendicular * (turn * radius))
            let heading = pose.heading + (turn * distance / radius)
            return Pose(
                position: center - (ArcadeVector(angle: heading).perpendicular * (turn * radius)),
                heading: heading,
                curvature: turn / radius
            )
        }
    }

    private static func pose(atDistance distance: Double, pieces: [Piece], starts: [Double], poses: [Pose]) -> Pose {
        var index = pieces.count - 1
        while index > 0, starts[index] > distance { index -= 1 }
        let local = min(max(distance - starts[index], 0), pieces[index].length)
        return advance(poses[index], along: pieces[index], by: local)
    }

    // MARK: Queries

    func wrap(_ distance: Double) -> Double {
        let value = distance.truncatingRemainder(dividingBy: length)
        return value < 0 ? value + length : value
    }

    func wrapIndex(_ index: Int) -> Int {
        let count = samples.count
        return ((index % count) + count) % count
    }

    /// Shortest signed arc length from `from` to `to`.
    func gap(from: Double, to: Double) -> Double {
        var delta = wrap(to - from)
        if delta > length / 2 { delta -= length }
        return delta
    }

    /// Nearest sample index, searching only `window` samples either side of
    /// `index` so a car never snaps to a parallel stretch of the track.
    func nearestIndex(to point: ArcadeVector, near index: Int, window: Int) -> Int {
        var best = wrapIndex(index)
        var bestDistance = Double.infinity
        for offset in -window...window {
            let candidate = wrapIndex(index + offset)
            let distance = (samples[candidate].position - point).lengthSquared
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        return best
    }

    /// Nearest sample over the whole loop (for placing cars).
    func globalNearestIndex(to point: ArcadeVector) -> Int {
        nearestIndex(to: point, near: samples.count / 2, window: samples.count / 2)
    }

    /// Arc length of `point` around sample `index`, and its signed distance
    /// from the centerline there (positive to the left). The distance is
    /// measured to the local foot point, so a car tracked against a far-away
    /// stretch (after cutting across the grass) reads as far off track.
    func locate(_ point: ArcadeVector, at index: Int) -> (distance: Double, lateral: Double) {
        let sample = samples[index]
        let offset = point - sample.position
        let along = min(max(offset.dot(sample.tangent), -spacing), spacing)
        let gap = (offset - (sample.tangent * along)).length
        return (wrap(sample.distance + along), offset.dot(sample.normal) < 0 ? -gap : gap)
    }

    /// Centerline point `distance` along the loop, interpolated between samples.
    func position(at distance: Double) -> ArcadeVector {
        let exact = wrap(distance) / spacing
        let lower = wrapIndex(Int(exact))
        let upper = wrapIndex(lower + 1)
        let fraction = exact - floor(exact)
        return samples[lower].position + ((samples[upper].position - samples[lower].position) * fraction)
    }

    func sample(at distance: Double) -> Sample {
        samples[wrapIndex(Int((wrap(distance) / spacing).rounded()))]
    }

    func gateCrossings(from start: ArcadeVector, to end: ArcadeVector)
        -> [(gate: Int, fraction: Double, forward: Bool)] {
        gatePoses.enumerated().compactMap { index, gate -> (Int, Double, Bool)? in
            let tangent = ArcadeVector(angle: gate.heading)
            let before = (start - gate.position).dot(tangent)
            let after = (end - gate.position).dot(tangent)
            guard (before < 0) != (after < 0) else { return nil }
            let fraction = before / (before - after)
            let crossing = start + ((end - start) * fraction)
            let lateral = (crossing - gate.position).dot(tangent.perpendicular)
            guard abs(lateral) <= Self.halfWidth else { return nil }
            return (index, fraction, before < 0)
        }.sorted { $0.1 < $1.1 }
    }
}

// MARK: - Simulation

/// Five-lap top-down race on `TurboLoopTrack`, whole circuit on screen.
struct TurboLoopSimulation: ArcadeSimulation {
    static let laps = 5
    static let raceCap = 120.0
    static let finishWindow = 8.0
    static let carRadius = 20.0
    static let acceleration = 950.0
    static let topSpeed = 620.0
    static let offTrackTopSpeed = 260.0
    static let boostMultiplier = 1.45
    static let boostDuration = 1.0
    /// Instant shove on hitting a pad, on top of the raised cap.
    static let boostKick = 120.0
    static let turnRate = 4.0
    static let stickDeadZone = 0.25
    static let coastDeceleration = 380.0
    static let offTrackDeceleration = 1_300.0
    static let wrongWayDot = -0.3
    static let wrongWayDelay = 0.7
    static let searchWindow = 20
    /// Beyond half-width + this, a car is "lost" and its tracked position may
    /// only creep along the loop (see `follow`).
    static let lostMargin = 40.0
    static let lostCreepSpeed = 240.0
    static let contactRestitution = 0.35
    static let boostColor = "#FF9F0A"
    static let lapColor = "#32E6FF"
    static let sceneInset = 30.0

    struct Car: Equatable, Sendable {
        let playerID: PlayerID
        /// Grid slot, 0 = pole.
        let slot: Int
        var position: ArcadeVector
        var heading: Double
        /// Speed along the heading.
        var forwardSpeed = 0.0
        /// Sideways slip that builds while turning and decays with grip.
        var slipSpeed = 0.0
        var trackIndex: Int
        var trackDistance: Double
        var lateralOffset: Double
        /// 0...2 are the checkpoints, 3 is the finish line.
        var nextGate = 3
        /// Race time of each forward line crossing that still counts. The
        /// first is the start of lap 1, so completed laps = count - 1.
        var lineTimes: [Double] = []
        var boostRemaining = 0.0
        var padContact: Int?
        var wrongWayTime = 0.0
        var finishTime: Double?
        var forfeited = false
        var bumpCooldown = 0.0

        /// Completed laps; -1 while still behind the line on the grid.
        var lap: Int { lineTimes.count - 1 }
        var lapsCompleted: Int { max(0, lap) }
        var currentLap: Int { min(TurboLoopSimulation.laps, max(1, lap + 1)) }
        var lapTimes: [Double] { zip(lineTimes, lineTimes.dropFirst()).map { $1 - $0 } }
        var bestLap: Double? { lapTimes.min() }
        var progress: Double { (Double(lap) * TurboLoopTrack.standard.length) + trackDistance }
        var isOnTrack: Bool { abs(lateralOffset) <= TurboLoopTrack.halfWidth }
        var isFinished: Bool { finishTime != nil }
        var isRacing: Bool { !forfeited && finishTime == nil }
        var isBoosting: Bool { boostRemaining > 0 }
        var isWrongWay: Bool { isRacing && wrongWayTime >= TurboLoopSimulation.wrongWayDelay }
        var direction: ArcadeVector { ArcadeVector(angle: heading) }
        var velocity: ArcadeVector { (direction * forwardSpeed) + (direction.perpendicular * slipSpeed) }
        var speed: Double { velocity.length }

        var speedCap: Double {
            let base = isOnTrack ? TurboLoopSimulation.topSpeed : TurboLoopSimulation.offTrackTopSpeed
            return base * (isBoosting ? TurboLoopSimulation.boostMultiplier : 1)
        }

        mutating func setVelocity(_ velocity: ArcadeVector) {
            forwardSpeed = velocity.dot(direction)
            slipSpeed = velocity.dot(direction.perpendicular)
        }
    }

    private(set) var cars: [Car]
    private(set) var elapsed = 0.0
    private(set) var isFinished = false
    private var finishDeadline: Double?
    /// Current running order, leader first.
    private(set) var order: [PlayerID] = []
    private var announcedFinalLap = false
    private let indexByID: [PlayerID: Int]
    private let multiplayer: Bool

    var track: TurboLoopTrack { .standard }

    init(players: [PlayerID], seed: UInt64) {
        multiplayer = players.count > 1
        indexByID = Dictionary(players.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        // The seed shuffles the grid so pole position is not always P1.
        var random = ArcadeRandomNumberGenerator(seed: ArcadeRandomNumberGenerator.mixed(seed, 0x7A3B))
        var slots = Array(players.indices)
        if slots.count > 1 {
            for index in stride(from: slots.count - 1, to: 0, by: -1) {
                slots.swapAt(index, random.index(below: index + 1))
            }
        }
        let track = TurboLoopTrack.standard
        cars = players.enumerated().map { index, playerID in
            let slot = slots[index]
            let grid = Self.gridSlot(slot)
            let pose = track.pose(atDistance: grid.distance)
            let position = pose.position + (ArcadeVector(angle: pose.heading).perpendicular * grid.lateral)
            let trackIndex = track.globalNearestIndex(to: position)
            let located = track.locate(position, at: trackIndex)
            return Car(
                playerID: playerID,
                slot: slot,
                position: position,
                heading: pose.heading,
                trackIndex: trackIndex,
                trackDistance: located.distance,
                lateralOffset: located.lateral
            )
        }
        order = rankedCars().map(\.playerID)
    }

    /// Staggered two-wide grid behind the start line.
    static func gridSlot(_ slot: Int) -> (distance: Double, lateral: Double) {
        let row = Double(slot / 2)
        let side = slot % 2
        return (-(60 + (row * 80) + (Double(side) * 30)), side == 0 ? 42 : -42)
    }

    // MARK: ArcadeSimulation

    var timeRemaining: Double? {
        max(0, raceDeadline - elapsed)
    }

    private var raceDeadline: Double { min(Self.raceCap, finishDeadline ?? Self.raceCap) }

    func isActive(_ playerID: PlayerID) -> Bool {
        indexByID[playerID].map { !cars[$0].forfeited } ?? false
    }

    func car(for playerID: PlayerID) -> Car? {
        indexByID[playerID].map { cars[$0] }
    }

    /// 1-based race position.
    func position(of playerID: PlayerID) -> Int {
        (order.firstIndex(of: playerID) ?? order.count) + 1
    }

    mutating func step(deltaTime: Double, inputs: [PlayerID: ArcadeInput]) -> [ArcadeEvent] {
        guard !isFinished else { return [] }
        let delta = min(max(deltaTime, 0), 0.05, max(0, raceDeadline - elapsed))
        var events: [ArcadeEvent] = []
        elapsed += delta
        let starts = cars.map(\.position)
        for index in cars.indices where !cars[index].forfeited {
            let input = cars[index].isRacing ? inputs[cars[index].playerID] ?? .idle : .idle
            drive(index, input: input, delta: delta)
        }
        resolveContacts(events: &events)
        for index in cars.indices where !cars[index].forfeited {
            follow(index, from: starts[index], delta: delta, events: &events)
        }
        let ranking = rankedCars()
        order = ranking.map(\.playerID)
        if finishDeadline == nil, let first = ranking.first, let finishTime = first.finishTime {
            finishDeadline = finishTime + Self.finishWindow
            events.append(.banner("P\(Int(first.playerID.rawValue) + 1) FINISHES!"))
        }
        let running = cars.filter { !$0.forfeited }
        if running.allSatisfy(\.isFinished) || elapsed >= raceDeadline {
            isFinished = true
        }
        return events
    }

    mutating func forfeit(_ playerID: PlayerID) -> [ArcadeEvent] {
        guard !isFinished, let index = indexByID[playerID], cars[index].isRacing else { return [] }
        cars[index].forfeited = true
        cars[index].forwardSpeed = 0
        cars[index].slipSpeed = 0
        let running = cars.filter { !$0.forfeited }
        if running.allSatisfy(\.isFinished) || (multiplayer && running.count <= 1) {
            isFinished = true
        }
        order = rankedCars().map(\.playerID)
        return [.eliminated(playerID)]
    }

    func ranking() -> [ArcadeRankEntry] {
        rankedCars().map { car in
            ArcadeRankEntry(playerID: car.playerID, score: score(for: car), detail: detail(for: car))
        }
    }

    func scoreLine(for playerID: PlayerID) -> String {
        guard let car = car(for: playerID) else { return "" }
        if car.forfeited { return "DNF" }
        let place = Self.ordinal(position(of: playerID))
        if let finishTime = car.finishTime { return "\(place)  \(Self.formatTime(finishTime))" }
        return "LAP \(car.currentLap)/\(Self.laps)  \(place)"
    }

    var resultMetric: MatchMetric {
        let best = cars.compactMap(\.bestLap).min()
        return .init(id: "best-lap", label: "Best lap", value: best.map(Self.formatTime) ?? "—")
    }

    static func botReactionInterval(for difficulty: GameBotDifficulty) -> Double {
        switch difficulty {
        case .easy: 0.12
        case .normal: 0.08
        case .hard: 0.05
        }
    }

    /// Pure pursuit toward the centerline point `lookahead` ahead, offset into
    /// the bot's lane, with a throttle that lifts for tight corners ahead.
    func botDecision(
        for playerID: PlayerID,
        difficulty: GameBotDifficulty,
        random: inout ArcadeRandomNumberGenerator
    ) -> ArcadeBotDecision {
        guard let index = indexByID[playerID], cars[index].isRacing else { return .idle }
        let car = cars[index]
        let (lookahead, baseThrottle): (Double, Double) = switch difficulty {
        case .easy: (160, 0.82)
        case .normal: (200, 0.92)
        case .hard: (240, 1.0)
        }
        var lane = Self.botLane(forPlayerIndex: index)
        if difficulty == .hard, let pad = nextPad(after: car.trackDistance, within: 420) {
            lane = pad.lateral
        }
        if difficulty == .easy {
            lane += random.double(in: -40...40)
        }
        let aheadDistance = car.trackDistance + lookahead
        let target = track.position(at: aheadDistance) + (track.sample(at: aheadDistance).normal * lane)
        let toTarget = target - car.position

        let cornerLimit = cornerSpeed(from: car.trackIndex, span: 140 + (car.speed * 0.45))
        var throttle = min(baseThrottle, cornerLimit / max(car.speedCap, 1))
        if abs(arcadeAngleDifference(from: car.heading, to: toTarget.angle)) > 1.1 {
            throttle = min(throttle, 0.55)
        }
        if difficulty == .easy {
            throttle *= random.double(in: 0.9...1)
        }
        return ArcadeBotDecision(vector: toTarget.normalized() * max(0.4, throttle))
    }

    // MARK: Driving

    private mutating func drive(_ index: Int, input: ArcadeInput, delta: Double) {
        var car = cars[index]
        let magnitude = input.magnitude
        let throttle = magnitude > Self.stickDeadZone ? magnitude : 0
        var turned = 0.0
        if throttle > 0 {
            let difference = arcadeAngleDifference(from: car.heading, to: input.vector.angle)
            let limit = Self.turnRate * delta
            turned = min(max(difference, -limit), limit)
            car.heading = remainder(car.heading + turned, 2 * .pi)
        }

        let cap = car.speedCap
        let target = cap * throttle
        if car.forwardSpeed < target {
            let gain = max(Self.acceleration * throttle, car.forwardSpeed < 0 ? Self.coastDeceleration : 0)
            car.forwardSpeed = min(target, car.forwardSpeed + (gain * delta))
        } else {
            let braking = !car.isOnTrack && car.forwardSpeed > cap ? Self.offTrackDeceleration : Self.coastDeceleration
            car.forwardSpeed = max(target, car.forwardSpeed - (braking * delta))
        }

        let slipGain = car.isOnTrack ? 0.22 : 0.4
        let grip = car.isOnTrack ? 7.0 : 3.5
        car.slipSpeed -= car.forwardSpeed * turned * slipGain
        car.slipSpeed *= exp(-grip * delta)
        car.boostRemaining = max(0, car.boostRemaining - delta)
        car.bumpCooldown = max(0, car.bumpCooldown - delta)
        car.position += car.velocity * delta
        keepOnScreen(&car)
        cars[index] = car
    }

    private func keepOnScreen(_ car: inout Car) {
        let size = ArcadeArena.sceneSize
        let minimum = ArcadeVector(x: Self.sceneInset, y: Self.sceneInset)
        let maximum = ArcadeVector(x: Double(size.width) - Self.sceneInset, y: Double(size.height) - Self.sceneInset)
        var velocity = car.velocity
        var clamped = false
        if car.position.x < minimum.x || car.position.x > maximum.x {
            car.position.x = min(max(car.position.x, minimum.x), maximum.x)
            velocity.x = 0
            clamped = true
        }
        if car.position.y < minimum.y || car.position.y > maximum.y {
            car.position.y = min(max(car.position.y, minimum.y), maximum.y)
            velocity.y = 0
            clamped = true
        }
        if clamped { car.setVelocity(velocity) }
    }

    /// Cars push apart and trade speed along the contact normal.
    private mutating func resolveContacts(events: inout [ArcadeEvent]) {
        let racers = cars.indices.filter { cars[$0].isRacing }
        let minimum = Self.carRadius * 2
        for (offset, first) in racers.enumerated() {
            for second in racers.dropFirst(offset + 1) {
                let separation = cars[first].position - cars[second].position
                let distance = separation.length
                guard distance < minimum else { continue }
                let normal = distance > 0.001 ? separation / distance : cars[second].direction.perpendicular
                let push = (minimum - distance) / 2
                cars[first].position += normal * push
                cars[second].position -= normal * push
                let firstVelocity = cars[first].velocity
                let secondVelocity = cars[second].velocity
                let closing = (firstVelocity - secondVelocity).dot(normal)
                guard closing < 0 else { continue }
                let impulse = -(1 + Self.contactRestitution) * closing / 2
                cars[first].setVelocity(firstVelocity + (normal * impulse))
                cars[second].setVelocity(secondVelocity - (normal * impulse))
                if -closing > 140 {
                    for index in [first, second] where cars[index].bumpCooldown <= 0 {
                        cars[index].bumpCooldown = 0.35
                        events.append(.haptic(cars[index].playerID, .lightImpact))
                    }
                }
            }
        }
    }

    // MARK: Progress

    /// Re-tracks the car's nearest centerline sample with a local search. A
    /// car far off the tarmac is "lost": its tracked position may then move no
    /// faster than the car itself (plus a slow creep), so cutting across the
    /// infield to a later stretch never gains ground and reads as off track
    /// until the tracked point catches up.
    private mutating func follow(_ index: Int, from start: ArcadeVector, delta: Double, events: inout [ArcadeEvent]) {
        var car = cars[index]
        let previousDistance = car.trackDistance
        let candidate = track.nearestIndex(to: car.position, near: car.trackIndex, window: Self.searchWindow)
        var located = track.locate(car.position, at: candidate)
        if abs(located.lateral) <= TurboLoopTrack.halfWidth + Self.lostMargin {
            car.trackIndex = candidate
        } else {
            let allowance = car.position.distance(to: start) + (Self.lostCreepSpeed * delta)
            let step = min(max(track.gap(from: previousDistance, to: located.distance), -allowance), allowance)
            let distance = track.wrap(previousDistance + step)
            car.trackIndex = track.wrapIndex(Int((distance / track.spacing).rounded()))
            located = (distance, track.locate(car.position, at: car.trackIndex).lateral)
        }
        car.trackDistance = located.distance
        car.lateralOffset = located.lateral
        guard car.isRacing else {
            cars[index] = car
            return
        }
        crossGates(&car, from: start, delta: delta, events: &events)
        if car.isRacing {
            touchPads(&car, events: &events)
            updateWrongWay(&car, delta: delta, events: &events)
        } else {
            car.boostRemaining = 0
            car.wrongWayTime = 0
        }
        cars[index] = car
    }

    /// Gates must be passed in order (checkpoints, then the line). Backing
    /// over the last gate passed un-passes it, so reversing across the line
    /// takes the lap back and driving forward again only restores it.
    private mutating func crossGates(
        _ car: inout Car,
        from start: ArcadeVector,
        delta: Double,
        events: inout [ArcadeEvent]
    ) {
        let finishGate = track.gates.count - 1
        for (gate, fraction, forward) in track.gateCrossings(from: start, to: car.position) where car.isRacing {
            if forward {
                guard gate == car.nextGate else { continue }
                car.nextGate = (gate + 1) % track.gates.count
                if gate == finishGate {
                    let crossedAt = elapsed - (delta * (1 - fraction))
                    car.lineTimes.append(crossedAt)
                    completeLap(&car, at: crossedAt, events: &events)
                }
            } else {
                let lastPassed = (car.nextGate + track.gates.count - 1) % track.gates.count
                guard car.lap >= 0, gate == lastPassed else { continue }
                car.nextGate = gate
                if gate == finishGate, !car.lineTimes.isEmpty {
                    car.lineTimes.removeLast()
                }
            }
        }
    }

    private mutating func completeLap(_ car: inout Car, at time: Double, events: inout [ArcadeEvent]) {
        if car.lap >= Self.laps {
            car.finishTime = time
            car.forwardSpeed = min(car.forwardSpeed, Self.topSpeed)
            events.append(.sound(.success))
            events.append(.cue(car.playerID, colorHex: ArcadeOutcomeBuilder.winnerColor, haptic: .success))
        } else if car.lap >= 1 {
            events.append(.cue(car.playerID, colorHex: Self.lapColor, haptic: .lightImpact))
            if car.lap == Self.laps - 1, !announcedFinalLap {
                announcedFinalLap = true
                events.append(.banner("FINAL LAP"))
                events.append(.sound(.lightImpact))
            }
        }
    }

    private func touchPads(_ car: inout Car, events: inout [ArcadeEvent]) {
        let tangent = track.samples[car.trackIndex].tangent
        let touching = track.pads.first { pad in
            abs(track.gap(from: pad.distance, to: car.trackDistance)) <= TurboLoopTrack.padHalfLength + 6
                && abs(car.lateralOffset - pad.lateral) <= TurboLoopTrack.padHalfWidth + 8
        }?.id
        if let touching, car.padContact != touching, car.direction.dot(tangent) > 0 {
            car.forwardSpeed = max(
                car.forwardSpeed,
                min(car.forwardSpeed + Self.boostKick, Self.topSpeed * Self.boostMultiplier)
            )
            events.append(.cue(car.playerID, colorHex: Self.boostColor, haptic: .lightImpact))
            events.append(.sound(.lightImpact))
        }
        if touching != nil, car.direction.dot(tangent) > 0 {
            car.boostRemaining = Self.boostDuration
        }
        car.padContact = touching
    }

    private func updateWrongWay(_ car: inout Car, delta: Double, events: inout [ArcadeEvent]) {
        let facing = car.direction.dot(track.samples[car.trackIndex].tangent)
        guard facing < Self.wrongWayDot else {
            car.wrongWayTime = 0
            return
        }
        let wasWrongWay = car.isWrongWay
        car.wrongWayTime += delta
        if !wasWrongWay, car.isWrongWay {
            events.append(.haptic(car.playerID, .error))
        }
    }

    // MARK: Ranking

    private func rankedCars() -> [Car] {
        cars.sorted { lhs, rhs in
            if lhs.forfeited != rhs.forfeited { return !lhs.forfeited }
            switch (lhs.finishTime, rhs.finishTime) {
            case let (left?, right?):
                if left != right { return left < right }
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case (nil, nil):
                if lhs.progress != rhs.progress { return lhs.progress > rhs.progress }
            }
            return lhs.playerID.rawValue < rhs.playerID.rawValue
        }
    }

    /// Monotone with the ranking: laps × 1000 plus percent through the current
    /// lap; every finisher scores laps × 1000 and DNFs score 0.
    private func score(for car: Car) -> Int {
        if car.forfeited { return 0 }
        if car.isFinished { return Self.laps * 1_000 }
        guard car.lap >= 0 else { return 0 }
        let percent = min(99, Int(car.trackDistance / track.length * 100))
        return (car.lapsCompleted * 1_000) + percent
    }

    private func detail(for car: Car) -> String {
        if let finishTime = car.finishTime { return Self.formatTime(finishTime) }
        if car.forfeited { return "DNF" }
        return "Lap \(car.currentLap)/\(Self.laps)"
    }

    static func formatTime(_ seconds: Double) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        return "\(tenths / 600):" + String(format: "%02d.%d", (tenths / 10) % 60, tenths % 10)
    }

    static func ordinal(_ place: Int) -> String {
        switch place {
        case 1: "1ST"
        case 2: "2ND"
        case 3: "3RD"
        default: "\(place)TH"
        }
    }

    // MARK: Bot helpers

    /// Lane offsets of ±30 and ±10, derived from the player index.
    static func botLane(forPlayerIndex index: Int) -> Double {
        [30, -30, 10, -10][index % 4]
    }

    private func nextPad(after distance: Double, within range: Double) -> TurboLoopTrack.BoostPad? {
        track.pads
            .map { ($0, track.wrap($0.distance - distance)) }
            .filter { $0.1 > 10 && $0.1 < range }
            .min { $0.1 < $1.1 }?.0
    }

    /// Fastest speed that still makes the tightest bend in the next `span`.
    private func cornerSpeed(from index: Int, span: Double) -> Double {
        let count = max(1, Int(span / track.spacing))
        var curvature = 0.0
        for offset in 0...count {
            curvature = max(curvature, abs(track.samples[track.wrapIndex(index + offset)].curvature))
        }
        guard curvature > 0 else { return .infinity }
        return Self.turnRate / curvature * 1.2
    }

#if DEBUG
    /// Puts a car on the centerline `distance` along the loop (plus `lateral`),
    /// facing along the track (or backwards), without crossing any gate.
    mutating func placeForTesting(
        _ playerID: PlayerID,
        distance: Double,
        lateral: Double = 0,
        speed: Double = 0,
        reversed: Bool = false
    ) {
        let pose = track.pose(atDistance: distance)
        let position = pose.position + (ArcadeVector(angle: pose.heading).perpendicular * lateral)
        placeForTesting(playerID, at: position, heading: pose.heading + (reversed ? .pi : 0), speed: speed)
    }

    mutating func placeForTesting(_ playerID: PlayerID, at position: ArcadeVector, heading: Double, speed: Double) {
        guard let index = indexByID[playerID] else { return }
        cars[index].position = position
        cars[index].heading = remainder(heading, 2 * .pi)
        cars[index].forwardSpeed = speed
        cars[index].slipSpeed = 0
        cars[index].trackIndex = track.globalNearestIndex(to: position)
        let located = track.locate(position, at: cars[index].trackIndex)
        cars[index].trackDistance = located.distance
        cars[index].lateralOffset = located.lateral
        cars[index].padContact = nil
        cars[index].wrongWayTime = 0
    }

    /// Sets lap bookkeeping directly: `completedLaps` (-1 = on the grid) and
    /// the next gate to pass (3 = all checkpoints done, line next).
    mutating func setLapStateForTesting(_ playerID: PlayerID, completedLaps: Int, nextGate: Int, lapSeconds: Double = 10) {
        guard let index = indexByID[playerID] else { return }
        let crossings = max(0, completedLaps + 1)
        cars[index].lineTimes = (0..<crossings).map { Double($0) * lapSeconds }
        cars[index].nextGate = nextGate
    }

    mutating func finishForTesting(_ playerID: PlayerID, at time: Double) {
        guard let index = indexByID[playerID] else { return }
        setLapStateForTesting(playerID, completedLaps: Self.laps, nextGate: 0, lapSeconds: time / Double(Self.laps))
        cars[index].finishTime = time
        order = rankedCars().map(\.playerID)
    }
#endif
}
