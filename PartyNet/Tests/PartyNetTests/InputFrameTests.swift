import Foundation
import Testing
@testable import PartyNet

@Suite("Input frame binary format")
struct InputFrameTests {
    @Test func roundTripAndLittleEndianLayout() throws {
        let frame = InputFrame(
            token: 0x0102030405060708,
            sequence: 0x11223344,
            clientTimeMs: 0x55667788,
            axisX: 0.5,
            axisY: -0.25,
            buttons: [.primary, .menu]
        )
        let data = frame.encode()
        #expect(data.count == 28)
        #expect(Array(data.prefix(8)) == [8, 7, 6, 5, 4, 3, 2, 1])
        #expect(InputFrame(data: data) == frame)
    }

    @Test func rejectsWrongLengthAndNonFiniteAxes() {
        #expect(InputFrame(data: Data(repeating: 0, count: 27)) == nil)
        let invalid = InputFrame(token: 1, sequence: 1, clientTimeMs: 0, axisX: .nan, axisY: 0)
        #expect(invalid.validated == nil)
        #expect(InputFrame(data: invalid.encode()) == nil)
    }

    @Test func clampsAxes() {
        let frame = InputFrame(token: 1, sequence: 1, clientTimeMs: 0, axisX: 4, axisY: -3)
        let decoded = InputFrame(data: frame.encode())
        #expect(decoded?.axisX == 1)
        #expect(decoded?.axisY == -1)
    }
}
