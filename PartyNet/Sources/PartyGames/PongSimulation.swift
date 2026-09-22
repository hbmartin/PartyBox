import Foundation
import PartyNet

enum PaddleEdge: String, Codable, CaseIterable, Hashable, Sendable {
    case bottom, top, left, right
}

struct SeatAssignment: Equatable, Sendable {
    let playerID: PlayerID
    let edge: PaddleEdge
}

struct PongRules: Equatable, Sendable {
    var startingSpeed = 560.0
    var maximumSpeed = 1_150.0
    var paddleLength = 220.0
    var initialLives = 3
}

struct PongPoint: Equatable, Sendable {
    var x: Double
    var y: Double

    static let zero = PongPoint(x: 0, y: 0)

    var length: Double { sqrt((x * x) + (y * y)) }

    func normalized() -> PongPoint {
        let magnitude = length
        guard magnitude > 0 else { return .zero }
        return PongPoint(x: x / magnitude, y: y / magnitude)
    }

    static func + (lhs: PongPoint, rhs: PongPoint) -> PongPoint {
        PongPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    static func * (lhs: PongPoint, rhs: Double) -> PongPoint {
        PongPoint(x: lhs.x * rhs, y: lhs.y * rhs)
    }
}

struct PongPlayer: Equatable, Sendable {
    let playerID: PlayerID
    let edge: PaddleEdge
    var paddlePosition: Double = 0
    var lives: Int

    var isActive: Bool { lives > 0 }
}

enum PongEvent: Equatable, Sendable {
    case paddleHit(PlayerID)
    case lostLife(PlayerID, remaining: Int)
    case eliminated(PlayerID)
    case forfeited(PlayerID)
    case gameOver(winner: PlayerID?, rally: Int)
}

struct PongSimulation: Sendable {
    static let arenaHalfExtent = 500.0
    static let ballRadius = 18.0
    static let paddleThickness = 24.0

    private(set) var players: [PaddleEdge: PongPlayer]
    private(set) var ballPosition = PongPoint.zero
    private(set) var ballVelocity = PongPoint.zero
    private(set) var respawnRemaining = 1.0
    private(set) var rallyCount = 0
    private(set) var isFinished = false

    let rules: PongRules

    private let multiplayer: Bool
    private var randomState: UInt64
    private let edgeByPlayerID: [PlayerID: PaddleEdge]

    init(
        assignments: [SeatAssignment],
        seed: UInt64 = 0x5041_5254_5942_4F58,
        rules: PongRules = PongRules()
    ) {
        self.rules = rules
        players = Dictionary(uniqueKeysWithValues: assignments.map {
            ($0.edge, PongPlayer(playerID: $0.playerID, edge: $0.edge, lives: rules.initialLives))
        })
        edgeByPlayerID = Dictionary(uniqueKeysWithValues: assignments.map { ($0.playerID, $0.edge) })
        multiplayer = assignments.count > 1
        randomState = seed == 0 ? 1 : seed
    }

    var activePlayers: [PongPlayer] {
        PaddleEdge.allCases.compactMap { edge in
            guard let player = players[edge], player.isActive else { return nil }
            return player
        }
    }

    var countdown: Int? {
        guard !isFinished, respawnRemaining > 0 else { return nil }
        return max(1, Int(ceil(respawnRemaining)))
    }

    mutating func setPaddle(for playerID: PlayerID, normalizedPosition: Double) {
        guard let edge = edgeByPlayerID[playerID] else { return }
        players[edge]?.paddlePosition = min(max(normalizedPosition, -1), 1)
    }

    func edge(for playerID: PlayerID) -> PaddleEdge? { edgeByPlayerID[playerID] }

    func botTarget(for playerID: PlayerID) -> Double? {
        guard let edge = edgeByPlayerID[playerID],
              players[edge]?.isActive == true,
              respawnRemaining <= 0,
              ballVelocity != .zero else { return nil }
        let boundary = Self.arenaHalfExtent - Self.ballRadius
        let collisionTime: Double
        switch edge {
        case .bottom:
            guard ballVelocity.y < 0 else { return nil }
            collisionTime = (-boundary - ballPosition.y) / ballVelocity.y
        case .top:
            guard ballVelocity.y > 0 else { return nil }
            collisionTime = (boundary - ballPosition.y) / ballVelocity.y
        case .left:
            guard ballVelocity.x < 0 else { return nil }
            collisionTime = (-boundary - ballPosition.x) / ballVelocity.x
        case .right:
            guard ballVelocity.x > 0 else { return nil }
            collisionTime = (boundary - ballPosition.x) / ballVelocity.x
        }
        guard collisionTime >= 0 else { return nil }
        let firstCollision = nextCollision(within: collisionTime + 0.000_001)
        guard firstCollision?.edge == edge else { return nil }
        let tangent = switch edge {
        case .bottom, .top: ballPosition.x + (ballVelocity.x * collisionTime)
        case .left, .right: ballPosition.y + (ballVelocity.y * collisionTime)
        }
        let travel = Self.arenaHalfExtent - (rules.paddleLength / 2)
        guard travel > 0 else { return 0 }
        return min(max(tangent / travel, -1), 1)
    }

    func paddlePosition(for playerID: PlayerID) -> Double? {
        guard let edge = edgeByPlayerID[playerID] else { return nil }
        return players[edge]?.paddlePosition
    }

#if DEBUG
    mutating func setBallForTesting(position: PongPoint, velocity: PongPoint) {
        ballPosition = position
        ballVelocity = velocity
        respawnRemaining = 0
    }

    mutating func launchTargetForTesting() -> PaddleEdge? {
        launchBall()
        guard ballVelocity != .zero else { return nil }
        if abs(ballVelocity.x) > abs(ballVelocity.y) {
            return ballVelocity.x < 0 ? .left : .right
        }
        return ballVelocity.y < 0 ? .bottom : .top
    }
#endif

    mutating func forfeit(_ playerID: PlayerID) -> [PongEvent] {
        guard !isFinished,
              let edge = edgeByPlayerID[playerID], players[edge]?.isActive == true
        else { return [] }
        players[edge]?.lives = 0
        var events: [PongEvent] = [.forfeited(playerID)]
        finishIfNeeded(events: &events)
        return events
    }

    mutating func step(deltaTime rawDelta: Double) -> [PongEvent] {
        guard !isFinished else { return [] }
        var delta = min(max(rawDelta, 0), 1.0 / 20.0)
        guard delta > 0 else { return [] }

        if respawnRemaining > 0 {
            let countdownTime = min(respawnRemaining, delta)
            respawnRemaining -= countdownTime
            delta -= countdownTime
            guard respawnRemaining <= 0 else { return [] }
            launchBall()
            guard delta > 0.000_001 else { return [] }
        }

        var events: [PongEvent] = []
        var remaining = delta
        var collisionBudget = 4
        while remaining > 0.000_001, collisionBudget > 0, !isFinished, respawnRemaining <= 0 {
            collisionBudget -= 1
            let collision = nextCollision(within: remaining)
            guard let collision else {
                ballPosition = ballPosition + (ballVelocity * remaining)
                break
            }
            ballPosition = ballPosition + (ballVelocity * collision.time)
            remaining -= collision.time
            resolve(collision.edge, events: &events)
        }
        return events
    }

    private struct Collision {
        let time: Double
        let edge: PaddleEdge
    }

    private func nextCollision(within duration: Double) -> Collision? {
        let boundary = Self.arenaHalfExtent - Self.ballRadius
        var candidates: [Collision] = []
        if ballVelocity.x > 0 {
            candidates.append(Collision(time: (boundary - ballPosition.x) / ballVelocity.x, edge: .right))
        } else if ballVelocity.x < 0 {
            candidates.append(Collision(time: (-boundary - ballPosition.x) / ballVelocity.x, edge: .left))
        }
        if ballVelocity.y > 0 {
            candidates.append(Collision(time: (boundary - ballPosition.y) / ballVelocity.y, edge: .top))
        } else if ballVelocity.y < 0 {
            candidates.append(Collision(time: (-boundary - ballPosition.y) / ballVelocity.y, edge: .bottom))
        }
        return candidates
            .filter { $0.time >= -0.000_001 && $0.time <= duration }
            .min { $0.time < $1.time }
    }

    private mutating func resolve(_ edge: PaddleEdge, events: inout [PongEvent]) {
        guard let player = players[edge], player.isActive else {
            reflectFromWall(edge)
            return
        }

        let tangent = edge == .top || edge == .bottom ? ballPosition.x : ballPosition.y
        let travel = Self.arenaHalfExtent - (rules.paddleLength / 2)
        let center = player.paddlePosition * travel
        let offset = tangent - center
        if abs(offset) <= (rules.paddleLength / 2) + Self.ballRadius {
            reflectFromPaddle(edge, offset: offset / (rules.paddleLength / 2))
            rallyCount += 1
            events.append(.paddleHit(player.playerID))
        } else {
            miss(edge, events: &events)
        }
    }

    private mutating func reflectFromWall(_ edge: PaddleEdge) {
        switch edge {
        case .bottom, .top: ballVelocity.y *= -1
        case .left, .right: ballVelocity.x *= -1
        }
        nudgeInside(edge)
    }

    private mutating func reflectFromPaddle(_ edge: PaddleEdge, offset: Double) {
        switch edge {
        case .bottom, .top:
            ballVelocity.y *= -1
            ballVelocity.x += offset * abs(ballVelocity.y) * 0.7
        case .left, .right:
            ballVelocity.x *= -1
            ballVelocity.y += offset * abs(ballVelocity.x) * 0.7
        }
        let accelerated = min(ballVelocity.length * 1.04, rules.maximumSpeed)
        ballVelocity = ballVelocity.normalized() * accelerated
        nudgeInside(edge)
    }

    private mutating func nudgeInside(_ edge: PaddleEdge) {
        let boundary = Self.arenaHalfExtent - Self.ballRadius - 0.001
        switch edge {
        case .bottom: ballPosition.y = -boundary
        case .top: ballPosition.y = boundary
        case .left: ballPosition.x = -boundary
        case .right: ballPosition.x = boundary
        }
    }

    private mutating func miss(_ edge: PaddleEdge, events: inout [PongEvent]) {
        guard var player = players[edge] else { return }
        player.lives = max(0, player.lives - 1)
        players[edge] = player
        events.append(.lostLife(player.playerID, remaining: player.lives))
        if player.lives == 0 { events.append(.eliminated(player.playerID)) }
        finishIfNeeded(events: &events)
        if !isFinished {
            ballPosition = .zero
            ballVelocity = .zero
            respawnRemaining = 1
        }
    }

    private mutating func finishIfNeeded(events: inout [PongEvent]) {
        let survivors = activePlayers
        if multiplayer, survivors.count <= 1 {
            isFinished = true
            ballVelocity = .zero
            respawnRemaining = 0
            events.append(.gameOver(winner: survivors.first?.playerID, rally: rallyCount))
        } else if !multiplayer, survivors.isEmpty {
            isFinished = true
            ballVelocity = .zero
            respawnRemaining = 0
            events.append(.gameOver(winner: nil, rally: rallyCount))
        }
    }

    private mutating func launchBall() {
        guard let target = randomActiveEdge() else { return }
        let tangent = (nextRandomUnit() * 0.7) - 0.35
        let direction: PongPoint
        switch target {
        case .bottom: direction = PongPoint(x: tangent, y: -1)
        case .top: direction = PongPoint(x: tangent, y: 1)
        case .left: direction = PongPoint(x: -1, y: tangent)
        case .right: direction = PongPoint(x: 1, y: tangent)
        }
        ballPosition = .zero
        ballVelocity = direction.normalized() * rules.startingSpeed
        respawnRemaining = 0
    }

    private mutating func randomActiveEdge() -> PaddleEdge? {
        let edges = PaddleEdge.allCases.filter { players[$0]?.isActive == true }
        guard !edges.isEmpty else { return nil }
        let bounded = nextRandom().multipliedFullWidth(by: UInt64(edges.count)).high
        return edges[Int(bounded)]
    }

    private mutating func nextRandomUnit() -> Double {
        Double(nextRandom() & 0xFFFF) / Double(0xFFFF)
    }

    private mutating func nextRandom() -> UInt64 {
        randomState &+= 0x9E37_79B9_7F4A_7C15
        var value = randomState
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
