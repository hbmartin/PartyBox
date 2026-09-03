import Testing
@testable import PartyNet

@Suite("Winner-stays seating")
struct SeatQueueTests {
    @Test func firstFourAreActive() {
        let queue = SeatQueue(joinOrder: (0..<6).map { PlayerID(UInt8($0)) })
        #expect(queue.active == [PlayerID(0), PlayerID(1), PlayerID(2), PlayerID(3)])
        #expect(queue.waiting == [PlayerID(4), PlayerID(5)])
        #expect(queue.assignments.map(\.edge) == [.bottom, .top, .left, .right])
    }

    @Test func winnerStaysAndWaitersMoveAheadOfLosers() {
        var queue = SeatQueue(joinOrder: (0..<6).map { PlayerID(UInt8($0)) })
        queue.rotateAfterMatch(winner: PlayerID(2))
        #expect(queue.active == [PlayerID(2), PlayerID(4), PlayerID(5), PlayerID(0)])
        #expect(queue.waiting == [PlayerID(1), PlayerID(3)])
    }

    @Test func soloStaysWithoutWaiterButRotatesWithWaiter() {
        var solo = SeatQueue(joinOrder: [PlayerID(0)])
        solo.rotateAfterMatch(winner: nil)
        #expect(solo.active == [PlayerID(0)])

        var queued = SeatQueue(joinOrder: [PlayerID(0)])
        queued.joined(PlayerID(1))
        queued.joined(PlayerID(2))
        queued.joined(PlayerID(3))
        queued.joined(PlayerID(4))
        queued.rotateAfterMatch(winner: nil)
        #expect(queued.active == [PlayerID(4), PlayerID(0), PlayerID(1), PlayerID(2)])
        #expect(queued.waiting == [PlayerID(3)])
    }

    @Test func leavingFillsVacancy() {
        var queue = SeatQueue(joinOrder: (0..<5).map { PlayerID(UInt8($0)) })
        queue.left(PlayerID(1))
        #expect(queue.active == [PlayerID(0), PlayerID(2), PlayerID(3), PlayerID(4)])
    }

    @Test func lateJoinAndForfeitDoNotChangeActiveMatch() {
        var queue = SeatQueue(joinOrder: [PlayerID(0), PlayerID(1)])
        queue.joined(PlayerID(2), allowActive: false)
        #expect(queue.active == [PlayerID(0), PlayerID(1)])
        #expect(queue.waiting == [PlayerID(2)])
        queue.left(PlayerID(0), fillVacancy: false)
        #expect(queue.active == [PlayerID(1)])
        #expect(queue.waiting == [PlayerID(2)])
    }
}
