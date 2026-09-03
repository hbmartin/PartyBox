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
        #expect(Array(data) == [
            0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
            0x44, 0x33, 0x22, 0x11,
            0x88, 0x77, 0x66, 0x55,
            0x00, 0x00, 0x00, 0x3F,
            0x00, 0x00, 0x80, 0xBE,
            0x05, 0x00, 0x00, 0x00,
        ])
        #expect(InputFrame(data: data) == frame)
    }

    @Test func rejectsWrongLengthAndNonFiniteAxes() {
        for byteCount in [0, 27, 29, 64] {
            #expect(InputFrame(data: Data(repeating: 0, count: byteCount)) == nil)
        }

        let invalidAxes: [(Float, Float)] = [
            (.nan, 0), (0, .nan),
            (.infinity, 0), (-.infinity, 0),
            (0, .infinity), (0, -.infinity),
        ]
        for (axisX, axisY) in invalidAxes {
            let invalid = InputFrame(token: 1, sequence: 1, clientTimeMs: 0, axisX: axisX, axisY: axisY)
            #expect(invalid.validated == nil)
            #expect(InputFrame(data: invalid.encode()) == nil)
        }
    }

    @Test func clampsAxes() {
        let frame = InputFrame(token: 1, sequence: 1, clientTimeMs: 0, axisX: 4, axisY: -3)
        let decoded = InputFrame(data: frame.encode())
        #expect(decoded?.axisX == 1)
        #expect(decoded?.axisY == -1)
    }
}
