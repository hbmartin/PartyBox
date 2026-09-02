import Synchronization

public final class InputStore: Sendable {
    private struct State: Sendable {
        var frames: [PlayerID: InputFrame] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    @discardableResult
    public func update(_ frame: InputFrame, for playerID: PlayerID) -> Bool {
        guard let valid = frame.validated else { return false }
        return state.withLock { state in
            if let existing = state.frames[playerID], existing.token == valid.token,
               valid.sequence <= existing.sequence {
                return false
            }
            state.frames[playerID] = valid
            return true
        }
    }

    public func snapshot() -> [PlayerID: InputFrame] {
        state.withLock { $0.frames }
    }

    public func remove(_ playerID: PlayerID) {
        state.withLock { state in
            _ = state.frames.removeValue(forKey: playerID)
        }
    }

    public func removeAll() {
        state.withLock { $0.frames.removeAll() }
    }
}
