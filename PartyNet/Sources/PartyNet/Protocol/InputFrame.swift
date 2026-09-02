import Foundation

public struct Buttons: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let primary = Buttons(rawValue: 1 << 0)
    public static let secondary = Buttons(rawValue: 1 << 1)
    public static let menu = Buttons(rawValue: 1 << 2)
}

public struct InputFrame: Codable, Equatable, Sendable {
    public static let byteCount = 28

    public let token: UInt64
    public let sequence: UInt32
    public let clientTimeMs: UInt32
    public let axisX: Float
    public let axisY: Float
    public let buttons: Buttons

    public init(
        token: UInt64,
        sequence: UInt32,
        clientTimeMs: UInt32,
        axisX: Float,
        axisY: Float,
        buttons: Buttons = []
    ) {
        self.token = token
        self.sequence = sequence
        self.clientTimeMs = clientTimeMs
        self.axisX = axisX
        self.axisY = axisY
        self.buttons = buttons
    }

    public var validated: InputFrame? {
        guard axisX.isFinite, axisY.isFinite else { return nil }
        return InputFrame(
            token: token,
            sequence: sequence,
            clientTimeMs: clientTimeMs,
            axisX: min(max(axisX, -1), 1),
            axisY: min(max(axisY, -1), 1),
            buttons: buttons
        )
    }

    public func encode() -> Data {
        var data = Data(capacity: Self.byteCount)
        data.appendLittleEndian(token)
        data.appendLittleEndian(sequence)
        data.appendLittleEndian(clientTimeMs)
        data.appendLittleEndian(axisX.bitPattern)
        data.appendLittleEndian(axisY.bitPattern)
        data.appendLittleEndian(buttons.rawValue)
        return data
    }

    public init?(data: Data) {
        guard data.count == Self.byteCount else { return nil }
        var offset = 0
        guard
            let token: UInt64 = data.readLittleEndian(at: &offset),
            let sequence: UInt32 = data.readLittleEndian(at: &offset),
            let clientTimeMs: UInt32 = data.readLittleEndian(at: &offset),
            let xBits: UInt32 = data.readLittleEndian(at: &offset),
            let yBits: UInt32 = data.readLittleEndian(at: &offset),
            let buttonBits: UInt32 = data.readLittleEndian(at: &offset)
        else { return nil }

        let decoded = InputFrame(
            token: token,
            sequence: sequence,
            clientTimeMs: clientTimeMs,
            axisX: Float(bitPattern: xBits),
            axisY: Float(bitPattern: yBits),
            buttons: Buttons(rawValue: buttonBits)
        )
        guard let valid = decoded.validated else { return nil }
        self = valid
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        for shift in stride(from: 0, to: T.bitWidth, by: 8) {
            append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }

    func readLittleEndian<T: FixedWidthInteger>(at offset: inout Int) -> T? {
        let size = MemoryLayout<T>.size
        guard offset + size <= count else { return nil }
        var value: T = 0
        for byteOffset in 0..<size {
            let index = index(startIndex, offsetBy: offset + byteOffset)
            value |= T(self[index]) << (byteOffset * 8)
        }
        offset += size
        return value
    }
}
