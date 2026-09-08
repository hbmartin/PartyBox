import Synchronization

public struct InputActivity: Codable, Equatable, Sendable {
    public let playerID: PlayerID
    public let acceptedFrameCount: UInt64
    public let minimumAxisX: Float
    public let maximumAxisX: Float
    public let latestSequence: UInt32

    public init(
        playerID: PlayerID,
        acceptedFrameCount: UInt64,
        minimumAxisX: Float,
        maximumAxisX: Float,
        latestSequence: UInt32
    ) {
        self.playerID = playerID
        self.acceptedFrameCount = acceptedFrameCount
        self.minimumAxisX = minimumAxisX
        self.maximumAxisX = maximumAxisX
        self.latestSequence = latestSequence
    }
}

public final class InputStore: Sendable {
    private struct Activity: Sendable {
        var acceptedFrameCount: UInt64
        var minimumAxisX: Float
        var maximumAxisX: Float
        var latestSequence: UInt32
    }

    private struct State: Sendable {
        var frames: [PlayerID: InputFrame] = [:]
        var activity: [PlayerID: Activity] = [:]
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
            if var activity = state.activity[playerID] {
                activity.acceptedFrameCount &+= 1
                activity.minimumAxisX = min(activity.minimumAxisX, valid.axisX)
                activity.maximumAxisX = max(activity.maximumAxisX, valid.axisX)
                activity.latestSequence = valid.sequence
                state.activity[playerID] = activity
            } else {
                state.activity[playerID] = Activity(
                    acceptedFrameCount: 1,
                    minimumAxisX: valid.axisX,
                    maximumAxisX: valid.axisX,
                    latestSequence: valid.sequence
                )
            }
            return true
        }
    }

    public func snapshot() -> [PlayerID: InputFrame] {
        state.withLock { $0.frames }
    }

    /// Diagnostic counters for verification tools. Only frames that passed
    /// validation and ordering checks contribute to this activity.
    public func activitySnapshot() -> [InputActivity] {
        state.withLock { state in
            state.activity.map { playerID, activity in
                InputActivity(
                    playerID: playerID,
                    acceptedFrameCount: activity.acceptedFrameCount,
                    minimumAxisX: activity.minimumAxisX,
                    maximumAxisX: activity.maximumAxisX,
                    latestSequence: activity.latestSequence
                )
            }
            .sorted { $0.playerID.rawValue < $1.playerID.rawValue }
        }
    }

    public func forEachFrame(_ body: (PlayerID, InputFrame) -> Void) {
        state.withLock { state in
            for (playerID, frame) in state.frames {
                body(playerID, frame)
            }
        }
    }

    public func remove(_ playerID: PlayerID) {
        state.withLock { state in
            state.frames.removeValue(forKey: playerID)
            state.activity.removeValue(forKey: playerID)
        }
    }

    public func removeAll() {
        state.withLock {
            $0.frames.removeAll()
            $0.activity.removeAll()
        }
    }

    public func neutralize() {
        state.withLock { state in
            state.frames = state.frames.mapValues { frame in
                InputFrame(
                    token: frame.token,
                    sequence: frame.sequence,
                    clientTimeMs: frame.clientTimeMs,
                    axisX: 0,
                    axisY: 0,
                    orientation: frame.orientation,
                    flags: frame.flags
                )
            }
        }
    }

    private static func isNewer(_ candidate: UInt32, than existing: UInt32) -> Bool {
        let distance = candidate &- existing
        return distance != 0 && distance < (UInt32.max / 2) + 1
    }
}
