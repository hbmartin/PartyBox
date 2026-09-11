import PartyNet
import Testing
@testable import PartyBoxCore

@Suite("Game-defined turn order")
struct TurnOrderTests {
    @Test func gameCapacitySelectsOnlyTheRequestedPrefix() {
        let order = TurnOrder(joinOrder: (0..<8).map { PlayerID(UInt8($0)) })
        let connected = Set(order.players)
        #expect(order.participants(connected: connected, maximum: 4) == (0..<4).map { PlayerID(UInt8($0)) })
        #expect(order.participants(connected: connected, maximum: 8).count == 8)
    }

    @Test func newlyAdmittedConnectedPlayersAreAppendedOnceWithoutLosingOrder() {
        let order = TurnOrder(joinOrder: [PlayerID(0), PlayerID(1)])
        let connected = Set([PlayerID(0), PlayerID(1), PlayerID(2)])

        #expect(order.participants(
            connected: connected,
            maximum: 3,
            including: [PlayerID(2), PlayerID(2), PlayerID(1)]
        ) == [PlayerID(0), PlayerID(1), PlayerID(2)])
    }

    @Test func winnerStaysAndWaitersMoveAheadOfLosers() {
        var order = TurnOrder(joinOrder: (0..<6).map { PlayerID(UInt8($0)) })
        order.rotateAfterMatch(active: (0..<4).map { PlayerID(UInt8($0)) }, winner: PlayerID(2))
        #expect(order.players == [PlayerID(2), PlayerID(4), PlayerID(5), PlayerID(0), PlayerID(1), PlayerID(3)])
    }

    @Test func noWinnerRotatesEveryActivePlayerBehindWaiters() {
        var order = TurnOrder(joinOrder: (0..<6).map { PlayerID(UInt8($0)) })
        order.rotateAfterMatch(active: (0..<4).map { PlayerID(UInt8($0)) }, winner: nil)
        #expect(order.players == [PlayerID(4), PlayerID(5), PlayerID(0), PlayerID(1), PlayerID(2), PlayerID(3)])
    }

    @Test func departedActivePlayersAreNotReintroducedDuringRotation() {
        var order = TurnOrder(joinOrder: (0..<6).map { PlayerID(UInt8($0)) })
        order.left(PlayerID(1))

        order.rotateAfterMatch(active: (0..<4).map { PlayerID(UInt8($0)) }, winner: PlayerID(2))

        #expect(order.players == [PlayerID(2), PlayerID(4), PlayerID(5), PlayerID(0), PlayerID(3)])
        #expect(!order.players.contains(PlayerID(1)))
    }

    @Test func leavingAndJoiningPreserveFairOrder() {
        var order = TurnOrder(joinOrder: (0..<5).map { PlayerID(UInt8($0)) })
        order.left(PlayerID(1))
        order.joined(PlayerID(5))
        #expect(order.players == [PlayerID(0), PlayerID(2), PlayerID(3), PlayerID(4), PlayerID(5)])
        #expect(order.waitingPosition(of: PlayerID(5), active: [PlayerID(0), PlayerID(2)]) == 3)
    }
}
