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
               !Self.isNewer(valid.sequence, than: existing.sequence) {
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

    public func neutralize() {
        state.withLock { state in
            state.frames = state.frames.mapValues { frame in
                InputFrame(
                    token: frame.token,
                    sequence: frame.sequence,
                    clientTimeMs: frame.clientTimeMs,
                    axisX: 0,
                    axisY: 0
                )
            }
        }
    }

    private static func isNewer(_ candidate: UInt32, than existing: UInt32) -> Bool {
        let distance = candidate &- existing
        return distance != 0 && distance < (UInt32.max / 2) + 1
    }
}
