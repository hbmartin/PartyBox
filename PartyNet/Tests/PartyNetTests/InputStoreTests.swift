import Testing
@testable import PartyNet

@Suite("Latest input store")
struct InputStoreTests {
    @Test func acceptsOnlyNewerSequenceForToken() {
        let store = InputStore()
        let player = PlayerID(0)
        #expect(store.update(frame(token: 1, sequence: 2, x: 0.2), for: player))
        #expect(!store.update(frame(token: 1, sequence: 2, x: 0.9), for: player))
        #expect(!store.update(frame(token: 1, sequence: 1, x: 0.8), for: player))
        #expect(store.snapshot()[player]?.axisX == 0.2)
    }

    @Test func newSessionTokenResetsSequence() {
        let store = InputStore()
        let player = PlayerID(0)
        #expect(store.update(frame(token: 1, sequence: 99, x: 0.2), for: player))
        #expect(store.update(frame(token: 2, sequence: 0, x: 0.7), for: player))
        #expect(store.snapshot()[player]?.axisX == 0.7)
    }

    @Test func sequenceWrapTreatsZeroAsNewer() {
        let store = InputStore()
        let player = PlayerID(0)
        #expect(store.update(frame(token: 1, sequence: .max - 1, x: 0.2), for: player))
        #expect(store.update(frame(token: 1, sequence: .max, x: 0.4), for: player))
        #expect(store.update(frame(token: 1, sequence: 0, x: 0.6), for: player))
        #expect(!store.update(frame(token: 1, sequence: .max, x: 0.8), for: player))
        #expect(store.snapshot()[player]?.axisX == 0.6)
    }

    @Test func snapshotIsIndependentAndRemovalWorks() {
        let store = InputStore()
        let player = PlayerID(0)
        store.update(frame(token: 1, sequence: 1, x: 0.4), for: player)
        let snapshot = store.snapshot()
        store.remove(player)
        #expect(snapshot[player]?.axisX == 0.4)
        #expect(store.snapshot().isEmpty)
    }

    @Test func neutralizePreservesOrderingWatermark() {
        let store = InputStore()
        let player = PlayerID(0)
        #expect(store.update(
            InputFrame(
                token: 7, sequence: 12, clientTimeMs: 34, axisX: 0.8, axisY: -0.4,
                buttons: .primary, orientation: .init(x: 0, y: 1, z: 0, w: 0), flags: .motionAvailable
            ),
            for: player
        ))

        store.neutralize()

        let neutral = store.snapshot()[player]
        #expect(neutral?.axisX == 0)
        #expect(neutral?.axisY == 0)
        #expect(neutral?.buttons == [])
        #expect(neutral?.orientation == OrientationQuaternion(x: 0, y: 1, z: 0, w: 0))
        #expect(neutral?.flags == .motionAvailable)
        #expect(neutral?.token == 7)
        #expect(neutral?.sequence == 12)
        #expect(!store.update(frame(token: 7, sequence: 11, x: 0.9), for: player))
    }

    @Test func activityCountsOnlyAcceptedChangingFramesAndClearsWithThePlayer() throws {
        let store = InputStore()
        let player = PlayerID(2)
        #expect(store.update(frame(token: 4, sequence: 1, x: -0.75), for: player))
        #expect(!store.update(frame(token: 4, sequence: 1, x: 0.9), for: player))
        #expect(store.update(frame(token: 4, sequence: 2, x: 0.6), for: player))

        let activity = try #require(store.activitySnapshot().first)
        #expect(activity.playerID == player)
        #expect(activity.acceptedFrameCount == 2)
        #expect(activity.minimumAxisX == -0.75)
        #expect(activity.maximumAxisX == 0.6)
        #expect(activity.latestSequence == 2)

        store.neutralize()
        #expect(store.activitySnapshot() == [activity])
        store.remove(player)
        #expect(store.activitySnapshot().isEmpty)
    }

    private func frame(token: UInt64, sequence: UInt32, x: Float) -> InputFrame {
        InputFrame(token: token, sequence: sequence, clientTimeMs: 0, axisX: x, axisY: 0)
    }
}
