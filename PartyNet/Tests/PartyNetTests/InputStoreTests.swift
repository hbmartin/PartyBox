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

    @Test func snapshotIsIndependentAndRemovalWorks() {
        let store = InputStore()
        let player = PlayerID(0)
        store.update(frame(token: 1, sequence: 1, x: 0.4), for: player)
        let snapshot = store.snapshot()
        store.remove(player)
        #expect(snapshot[player]?.axisX == 0.4)
        #expect(store.snapshot().isEmpty)
    }

    private func frame(token: UInt64, sequence: UInt32, x: Float) -> InputFrame {
        InputFrame(token: token, sequence: sequence, clientTimeMs: 0, axisX: x, axisY: 0)
    }
}
