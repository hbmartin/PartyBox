public struct SeatAssignment: Codable, Equatable, Sendable {
    public let playerID: PlayerID
    public let edge: PaddleEdge

    public init(playerID: PlayerID, edge: PaddleEdge) {
        self.playerID = playerID
        self.edge = edge
    }
}

public struct SeatQueue: Equatable, Sendable {
    public static let activeSeatCount = PaddleEdge.allCases.count

    public private(set) var active: [PlayerID]
    public private(set) var waiting: [PlayerID]

    public init(joinOrder: [PlayerID] = []) {
        let unique = joinOrder.reduce(into: [PlayerID]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        active = Array(unique.prefix(Self.activeSeatCount))
        waiting = Array(unique.dropFirst(Self.activeSeatCount))
    }

    public var assignments: [SeatAssignment] {
        zip(active, PaddleEdge.allCases).map { SeatAssignment(playerID: $0, edge: $1) }
    }

    public mutating func joined(_ playerID: PlayerID, allowActive: Bool = true) {
        guard !active.contains(playerID), !waiting.contains(playerID) else { return }
        if allowActive, active.count < Self.activeSeatCount {
            active.append(playerID)
        } else {
            waiting.append(playerID)
        }
    }

    public mutating func left(_ playerID: PlayerID, fillVacancy: Bool = true) {
        active.removeAll { $0 == playerID }
        waiting.removeAll { $0 == playerID }
        if fillVacancy { fillVacancies() }
    }

    public mutating func rotateAfterMatch(winner: PlayerID?) {
        let priorActive = active
        if let winner, priorActive.contains(winner) {
            active = [winner]
            waiting.append(contentsOf: priorActive.filter { $0 != winner })
        } else if priorActive.count == 1, waiting.isEmpty {
            return
        } else {
            active = []
            waiting.append(contentsOf: priorActive)
        }
        fillVacancies()
    }

    public func waitingPosition(of playerID: PlayerID) -> Int? {
        waiting.firstIndex(of: playerID).map { $0 + 1 }
    }

    private mutating func fillVacancies() {
        while active.count < Self.activeSeatCount, !waiting.isEmpty {
            active.append(waiting.removeFirst())
        }
    }
}
