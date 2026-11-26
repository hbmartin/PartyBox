import Foundation
import PartyBoxCore
import PartyGameRuntime
import PartyNet

// Shared building blocks for the arcade games. Each game supplies a pure,
// seeded `ArcadeSimulation` plus a SpriteKit `ArcadeRenderer`; the generic
// `ArcadeSession` (ArcadeSession.swift) wires them to the host.

// MARK: - Randomness

/// Deterministic splitmix-style generator. Simulations must draw every random
/// value from one of these so a seed fully determines a match.
struct ArcadeRandomNumberGenerator: Equatable, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 1 : seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var output = state
        output = (output ^ (output >> 30)) &* 0xBF58_476D_1CE4_E5B9
        output = (output ^ (output >> 27)) &* 0x94D0_49BB_1331_11EB
        return output ^ (output >> 31)
    }

    /// Uniform value in `0..<1`.
    mutating func unit() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    mutating func double(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + ((range.upperBound - range.lowerBound) * unit())
    }

    /// Uniform index in `0..<count` without modulo bias.
    mutating func index(below count: Int) -> Int {
        precondition(count > 0)
        return Int(next().multipliedFullWidth(by: UInt64(count)).high)
    }

    mutating func chance(_ probability: Double) -> Bool {
        unit() < probability
    }

    /// Derives an independent stream (for example one per bot) from a seed.
    static func mixed(_ seed: UInt64, _ salt: UInt64) -> UInt64 {
        var value = seed &+ (salt &* 0x9E37_79B9_7F4A_7C15)
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

// MARK: - Geometry

struct ArcadeVector: Equatable, Sendable {
    var x: Double
    var y: Double

    static let zero = ArcadeVector(x: 0, y: 0)

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(angle: Double, length: Double = 1) {
        x = cos(angle) * length
        y = sin(angle) * length
    }

    var length: Double { (x * x + y * y).squareRoot() }
    var lengthSquared: Double { x * x + y * y }
    var angle: Double { atan2(y, x) }

    func normalized() -> ArcadeVector {
        let magnitude = length
        guard magnitude > 0.000_001 else { return .zero }
        return ArcadeVector(x: x / magnitude, y: y / magnitude)
    }

    func clampedLength(_ maximum: Double) -> ArcadeVector {
        let magnitude = length
        guard magnitude > maximum, magnitude > 0 else { return self }
        return self * (maximum / magnitude)
    }

    func dot(_ other: ArcadeVector) -> Double { x * other.x + y * other.y }
    func distance(to other: ArcadeVector) -> Double { (self - other).length }

    /// Rotated 90° counter-clockwise.
    var perpendicular: ArcadeVector { ArcadeVector(x: -y, y: x) }

    static func + (lhs: ArcadeVector, rhs: ArcadeVector) -> ArcadeVector { .init(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
    static func - (lhs: ArcadeVector, rhs: ArcadeVector) -> ArcadeVector { .init(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
    static func * (lhs: ArcadeVector, rhs: Double) -> ArcadeVector { .init(x: lhs.x * rhs, y: lhs.y * rhs) }
    static func / (lhs: ArcadeVector, rhs: Double) -> ArcadeVector { .init(x: lhs.x / rhs, y: lhs.y / rhs) }
    static prefix func - (value: ArcadeVector) -> ArcadeVector { .init(x: -value.x, y: -value.y) }
    static func += (lhs: inout ArcadeVector, rhs: ArcadeVector) { lhs = lhs + rhs }
    static func -= (lhs: inout ArcadeVector, rhs: ArcadeVector) { lhs = lhs - rhs }
}

/// Shortest signed angle from `from` to `to`, in `-π...π`.
func arcadeAngleDifference(from: Double, to: Double) -> Double {
    atan2(sin(to - from), cos(to - from))
}

/// The shared TV arena every arcade game draws inside, in scene points.
enum ArcadeArena {
    static let sceneSize = CGSize(width: 1_920, height: 1_080)
    static let rect = CGRect(x: 250, y: 130, width: 1_420, height: 790)
    static let center = ArcadeVector(x: 960, y: 525)
    static var minX: Double { Double(rect.minX) }
    static var maxX: Double { Double(rect.maxX) }
    static var minY: Double { Double(rect.minY) }
    static var maxY: Double { Double(rect.maxY) }

    static func clamp(_ point: ArcadeVector, inset: Double) -> ArcadeVector {
        ArcadeVector(
            x: min(max(point.x, minX + inset), maxX - inset),
            y: min(max(point.y, minY + inset), maxY - inset)
        )
    }
}

enum ArcadeDirection: String, CaseIterable, Equatable, Sendable {
    case up, down, left, right

    var dx: Int {
        switch self {
        case .left: -1
        case .right: 1
        case .up, .down: 0
        }
    }

    var dy: Int {
        switch self {
        case .up: 1
        case .down: -1
        case .left, .right: 0
        }
    }

    var opposite: ArcadeDirection {
        switch self {
        case .up: .down
        case .down: .up
        case .left: .right
        case .right: .left
        }
    }

    var turnedLeft: ArcadeDirection {
        switch self {
        case .up: .left
        case .left: .down
        case .down: .right
        case .right: .up
        }
    }

    var turnedRight: ArcadeDirection { turnedLeft.opposite }

    var axes: (x: Float, y: Float) { (Float(dx), Float(dy)) }

    /// The dominant stick direction once it leaves the dead zone.
    static func dominant(x: Double, y: Double, threshold: Double = 0.58) -> ArcadeDirection? {
        guard max(abs(x), abs(y)) > threshold else { return nil }
        if abs(x) > abs(y) { return x > 0 ? .right : .left }
        return y > 0 ? .up : .down
    }
}

/// Linear difficulty ramp: `from` before `start`, `to` after `end`.
func arcadeRamp(from: Double, to: Double, start: Double, end: Double, at time: Double) -> Double {
    guard end > start else { return time >= end ? to : from }
    let progress = min(max((time - start) / (end - start), 0), 1)
    return from + ((to - from) * progress)
}

// MARK: - Input

struct ArcadeInput: Equatable, Sendable {
    var axisX: Double = 0
    var axisY: Double = 0
    /// True on the frame a tap (phone action button) or bot button press arrived.
    var pressed = false
    /// Steering sampled by the controller at the instant of a DASH press.
    var pressSteering: ArcadeVector?
    /// Direction-pad or swipe turns received since the previous frame, in order.
    var turns: [ArcadeDirection] = []

    static let idle = ArcadeInput()

    var vector: ArcadeVector { ArcadeVector(x: axisX, y: axisY) }
    var magnitude: Double { min(1, vector.length) }
}

/// Collects the latest analog frame for each player plus queued discrete
/// actions. Human taps arrive through `ControllerAction`s over the reliable
/// channel; bots press `Buttons.primary` in their input frames instead, so a
/// rising edge of that bit is also treated as a tap.
@MainActor
final class ArcadeInputSampler {
    private struct Press {
        let steering: ArcadeVector?
    }

    private let store: InputStore
    private var heldButtons: [PlayerID: Bool] = [:]
    private var queuedPresses: [PlayerID: Press] = [:]
    private var queuedTurns: [PlayerID: [ArcadeDirection]] = [:]

    init(store: InputStore) {
        self.store = store
    }

    func queuePress(for playerID: PlayerID, steering: ControllerSteering? = nil) {
        guard queuedPresses[playerID] == nil else { return }
        let aim = steering.flatMap { steering -> ArcadeVector? in
            guard steering.axisX.isFinite, steering.axisY.isFinite else { return nil }
            return ArcadeVector(
                x: min(max(Double(steering.axisX), -1), 1),
                y: min(max(Double(steering.axisY), -1), 1)
            )
        }
        queuedPresses[playerID] = Press(steering: aim)
    }

    func queueTurn(_ direction: ArcadeDirection, for playerID: PlayerID) {
        var turns = queuedTurns[playerID, default: []]
        turns.append(direction)
        if turns.count > 4 { turns.removeFirst(turns.count - 4) }
        queuedTurns[playerID] = turns
    }

    func sample(players: [PlayerID]) -> [PlayerID: ArcadeInput] {
        let frames = store.snapshot()
        var inputs: [PlayerID: ArcadeInput] = [:]
        for playerID in players {
            let frame = frames[playerID]
            let held = frame?.buttons.contains(.primary) ?? false
            let rising = held && !(heldButtons[playerID] ?? false)
            heldButtons[playerID] = held
            let press = queuedPresses[playerID]
            inputs[playerID] = ArcadeInput(
                axisX: Double(frame?.axisX ?? 0),
                axisY: Double(frame?.axisY ?? 0),
                pressed: rising || press != nil,
                pressSteering: press?.steering,
                turns: queuedTurns[playerID] ?? []
            )
        }
        queuedPresses.removeAll()
        queuedTurns.removeAll()
        return inputs
    }
}

// MARK: - Simulation contract

enum ArcadeEvent: Equatable, Sendable {
    /// TV sound effect.
    case sound(HapticPattern)
    /// Phone haptic only.
    case haptic(PlayerID, HapticPattern)
    /// Brief phone screen tint plus optional haptic.
    case cue(PlayerID, colorHex: String, haptic: HapticPattern?)
    case lostLife(PlayerID, remaining: Int)
    case eliminated(PlayerID)
    /// TV-only banner such as "FRENZY!"; never sent to phones.
    case banner(String)
}

struct ArcadeRankEntry: Equatable, Sendable {
    let playerID: PlayerID
    let score: Int
    let detail: String

    init(playerID: PlayerID, score: Int, detail: String = "") {
        self.playerID = playerID
        self.score = score
        self.detail = detail
    }
}

struct ArcadeBotDecision: Equatable, Sendable {
    var axisX: Double
    var axisY: Double
    var press: Bool

    init(axisX: Double = 0, axisY: Double = 0, press: Bool = false) {
        self.axisX = axisX.isFinite ? min(max(axisX, -1), 1) : 0
        self.axisY = axisY.isFinite ? min(max(axisY, -1), 1) : 0
        self.press = press
    }

    init(vector: ArcadeVector, press: Bool = false) {
        let clamped = vector.clampedLength(1)
        self.init(axisX: clamped.x, axisY: clamped.y, press: press)
    }

    static let idle = ArcadeBotDecision()
}

/// A pure, seeded game model. `step` must be deterministic for a given seed
/// and input sequence; rendering lives in an `ArcadeRenderer`.
protocol ArcadeSimulation: Sendable {
    var isFinished: Bool { get }
    /// Seconds left for the TV timer; `nil` hides it.
    var timeRemaining: Double? { get }
    func isActive(_ playerID: PlayerID) -> Bool
    mutating func step(deltaTime: Double, inputs: [PlayerID: ArcadeInput]) -> [ArcadeEvent]
    mutating func forfeit(_ playerID: PlayerID) -> [ArcadeEvent]
    /// Every participant, best first.
    func ranking() -> [ArcadeRankEntry]
    /// Short HUD text after the player number, e.g. "120  ◆◆◆".
    func scoreLine(for playerID: PlayerID) -> String
    var resultMetric: MatchMetric { get }
    /// Reads the current state and picks a stick/press for a bot. The session
    /// calls this once per reaction interval and holds the answer between calls.
    func botDecision(
        for playerID: PlayerID,
        difficulty: GameBotDifficulty,
        random: inout ArcadeRandomNumberGenerator
    ) -> ArcadeBotDecision
    static func botReactionInterval(for difficulty: GameBotDifficulty) -> Double
}

extension ArcadeSimulation {
    static func botReactionInterval(for difficulty: GameBotDifficulty) -> Double {
        switch difficulty {
        case .easy: 0.25
        case .normal: 0.15
        case .hard: 0.08
        }
    }
}

// MARK: - Outcome

enum ArcadeOutcomeBuilder {
    static let winnerColor = "#39FF88"
    static let hitColor = "#FF9F0A"
    static let eliminatedColor = "#FF375F"

    static func translate(_ event: ArcadeEvent) -> [GameEvent] {
        switch event {
        case .sound(let pattern):
            [.audio(pattern)]
        case let .haptic(playerID, pattern):
            [.haptic(playerID, pattern)]
        case let .cue(playerID, colorHex, haptic):
            [.deviceCue(playerID, .init(colorHex: colorHex, haptic: haptic))]
        case let .lostLife(playerID, _):
            [.audio(.heavyImpact), .deviceCue(playerID, .init(colorHex: hitColor, haptic: .heavyImpact))]
        case .eliminated(let playerID):
            [
                .audio(.error),
                .deviceCue(playerID, .init(colorHex: eliminatedColor, haptic: .error)),
                .eliminated(playerID),
            ]
        case .banner:
            []
        }
    }

    static func completionEvents(
        title: String,
        participants: [GameParticipant],
        ranking: [ArcadeRankEntry],
        metric: MatchMetric,
        forfeited: Set<PlayerID>
    ) -> [GameEvent] {
        let participantIDs = participants.map(\.player.id)
        var ordered = ranking.filter { participantIDs.contains($0.playerID) }
        var seen = Set(ordered.map(\.playerID))
        if seen.count != ordered.count {
            seen = []
            ordered = ordered.filter { seen.insert($0.playerID).inserted }
        }
        for playerID in participantIDs where !seen.contains(playerID) {
            ordered.append(ArcadeRankEntry(playerID: playerID, score: 0))
        }
        let solo = participants.count == 1
        let winnerID = solo ? nil : ordered.first(where: { !forfeited.contains($0.playerID) })?.playerID
        let winner = winnerID.flatMap { id in participants.first { $0.player.id == id }?.player }
        let standings = ordered.enumerated().map { index, entry in
            GameStanding(playerID: entry.playerID, rank: index + 1, score: entry.score, detail: entry.detail)
        }
        let outcomes = participants.map { participant in
            let outcome: MatchParticipantOutcome = if solo {
                .practice
            } else if forfeited.contains(participant.player.id) {
                .forfeited
            } else if participant.player.id == winnerID {
                .won
            } else {
                .lost
            }
            return PlayerMatchOutcome(playerID: participant.player.id, outcome: outcome)
        }
        let headline = if solo {
            "PRACTICE COMPLETE"
        } else if let winner {
            "P\(winner.number) \(winner.displayName) WINS"
        } else {
            "EVENT COMPLETE"
        }
        var events: [GameEvent] = [.audio(.success)]
        if let winner {
            events.append(.deviceCue(winner.id, .init(colorHex: winnerColor, haptic: .success)))
        }
        events.append(.completed(GameOutcome(
            title: headline,
            subtitle: "\(title.capitalized) complete",
            winner: winnerID,
            playerOutcomes: outcomes,
            metrics: [metric],
            standings: standings
        )))
        return events
    }
}

extension Duration {
    var arcadeSeconds: Double {
        let parts = components
        return max(0, Double(parts.seconds) + (Double(parts.attoseconds) / 1_000_000_000_000_000_000))
    }
}

/// Helpers simulations share for building `ranking()`.
enum ArcadeRanking {
    /// Survivors first (most lives, then score), then eliminated players with
    /// the latest elimination first, ties broken by score then player id.
    static func bySurvival<Player>(
        _ players: [Player],
        id: (Player) -> PlayerID,
        alive: (Player) -> Bool,
        lives: (Player) -> Int,
        score: (Player) -> Int,
        eliminationOrder: [PlayerID],
        detail: (Player) -> String
    ) -> [ArcadeRankEntry] {
        let sorted = players.sorted { lhs, rhs in
            let leftAlive = alive(lhs)
            let rightAlive = alive(rhs)
            if leftAlive != rightAlive { return leftAlive }
            if leftAlive {
                if lives(lhs) != lives(rhs) { return lives(lhs) > lives(rhs) }
            } else {
                let leftOut = eliminationOrder.firstIndex(of: id(lhs)) ?? -1
                let rightOut = eliminationOrder.firstIndex(of: id(rhs)) ?? -1
                if leftOut != rightOut { return leftOut > rightOut }
            }
            if score(lhs) != score(rhs) { return score(lhs) > score(rhs) }
            return id(lhs).rawValue < id(rhs).rawValue
        }
        return sorted.map { ArcadeRankEntry(playerID: id($0), score: score($0), detail: detail($0)) }
    }

    static func byScore<Player>(
        _ players: [Player],
        id: (Player) -> PlayerID,
        score: (Player) -> Int,
        detail: (Player) -> String
    ) -> [ArcadeRankEntry] {
        players.sorted { lhs, rhs in
            if score(lhs) != score(rhs) { return score(lhs) > score(rhs) }
            return id(lhs).rawValue < id(rhs).rawValue
        }
        .map { ArcadeRankEntry(playerID: id($0), score: score($0), detail: detail($0)) }
    }

    static func lives(_ count: Int) -> String {
        String(repeating: "◆", count: max(0, count))
    }
}
