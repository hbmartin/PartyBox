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
            buttons: [.primary, .menu],
            orientation: .init(x: 0.1, y: 0.2, z: 0.3, w: 0.92736185),
            flags: .motionAvailable
        )
        let data = frame.encode()
        #expect(Array(data) == [
            0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
            0x44, 0x33, 0x22, 0x11,
            0x88, 0x77, 0x66, 0x55,
            0x00, 0x00, 0x00, 0x3F,
            0x00, 0x00, 0x80, 0xBE,
            0x05, 0x00, 0x00, 0x00,
            0xCD, 0xCC, 0xCC, 0x3D,
            0xCD, 0xCC, 0x4C, 0x3E,
            0x9A, 0x99, 0x99, 0x3E,
            0x96, 0x67, 0x6D, 0x3F,
            0x01, 0x00, 0x00, 0x00,
        ])
        #expect(InputFrame(data: data) == frame)
    }

    @Test func rejectsWrongLengthAndNonFiniteAxes() {
        for byteCount in [0, 28, 47, 49, 64] {
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

    @Test func normalizesAvailableOrientationAndSuppressesUnavailableMotion() throws {
        let available = InputFrame(
            token: 1, sequence: 2, clientTimeMs: 3, axisX: 0, axisY: 0,
            orientation: .init(x: 0, y: 0, z: 0, w: 2), flags: .motionAvailable
        )
        let decoded = try #require(InputFrame(data: available.encode()))
        #expect(decoded.orientation == .identity)
        #expect(decoded.flags == .motionAvailable)

        let unavailable = InputFrame(
            token: 1, sequence: 2, clientTimeMs: 3, axisX: 0, axisY: 0,
            orientation: .init(x: 1, y: 0, z: 0, w: 0)
        )
        #expect(InputFrame(data: unavailable.encode())?.orientation == .identity)
    }

    @Test func rejectsInvalidAvailableOrientation() {
        let invalid = InputFrame(
            token: 1, sequence: 2, clientTimeMs: 3, axisX: 0, axisY: 0,
            orientation: .init(x: .nan, y: 0, z: 0, w: 1), flags: .motionAvailable
        )
        #expect(invalid.validated == nil)
        #expect(InputFrame(data: invalid.encode()) == nil)
    }

    @Test func horizontalTiltAxisIsCenteredSymmetricAndBounded() {
        #expect(OrientationQuaternion.identity.horizontalTiltAxis() == 0)

        let halfAngle = Float.pi / 12
        let right = OrientationQuaternion(
            x: 0,
            y: sin(halfAngle),
            z: 0,
            w: cos(halfAngle)
        ).horizontalTiltAxis()
        let left = OrientationQuaternion(
            x: 0,
            y: -sin(halfAngle),
            z: 0,
            w: cos(halfAngle)
        ).horizontalTiltAxis()

        #expect(abs(right - 0.75) < 0.001)
        #expect(abs(left + 0.75) < 0.001)
        #expect(OrientationQuaternion(x: 0, y: 1, z: 0, w: 1).horizontalTiltAxis() == 1)
        #expect(OrientationQuaternion.identity.horizontalTiltAxis(sensitivity: .nan) == 0)
    }

    @Test func verticalTiltAxisIsCenteredSymmetricAndBounded() {
        #expect(OrientationQuaternion.identity.verticalTiltAxis() == 0)
        let halfAngle = Float.pi / 12
        let forward = OrientationQuaternion(x: sin(halfAngle), y: 0, z: 0, w: cos(halfAngle)).verticalTiltAxis()
        let backward = OrientationQuaternion(x: -sin(halfAngle), y: 0, z: 0, w: cos(halfAngle)).verticalTiltAxis()
        #expect(abs(forward - 0.75) < 0.001)
        #expect(abs(backward + 0.75) < 0.001)
        #expect(OrientationQuaternion(x: 1, y: 0, z: 0, w: 1).verticalTiltAxis() == 1)
        #expect(OrientationQuaternion(x: -1, y: 0, z: 0, w: 1).verticalTiltAxis() == -1)

        let insideDeadZone = OrientationQuaternion(x: sin(0.01), y: 0, z: 0, w: cos(0.01))
        #expect(insideDeadZone.verticalTiltAxis() == 0)
        #expect(OrientationQuaternion.identity.verticalTiltAxis(sensitivity: 0) == 0)
        #expect(OrientationQuaternion.identity.verticalTiltAxis(sensitivity: .infinity) == 0)
        #expect(OrientationQuaternion.identity.verticalTiltAxis(sensitivity: .nan) == 0)
        #expect(OrientationQuaternion(x: .nan, y: 0, z: 0, w: 1).verticalTiltAxis() == 0)
    }
}
