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

public struct InputFlags: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let motionAvailable = InputFlags(rawValue: 1 << 0)
}

public struct OrientationQuaternion: Codable, Equatable, Sendable {
    public let x: Float
    public let y: Float
    public let z: Float
    public let w: Float

    public static let identity = OrientationQuaternion(x: 0, y: 0, z: 0, w: 1)

    public init(x: Float, y: Float, z: Float, w: Float) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    public var normalized: OrientationQuaternion? {
        guard x.isFinite, y.isFinite, z.isFinite, w.isFinite else { return nil }
        let magnitudeSquared = (x * x) + (y * y) + (z * z) + (w * w)
        guard magnitudeSquared.isFinite, magnitudeSquared > 0.000_001 else { return nil }
        let inverseMagnitude = 1 / sqrt(magnitudeSquared)
        return OrientationQuaternion(
            x: x * inverseMagnitude,
            y: y * inverseMagnitude,
            z: z * inverseMagnitude,
            w: w * inverseMagnitude
        )
    }

    /// Returns the unclamped left/right gravity projection used for calibration.
    public func horizontalTiltProjection() -> Float {
        tiltProjections?.horizontal ?? 0
    }

    /// Returns the unclamped forward/back gravity projection used for calibration.
    public func verticalTiltProjection() -> Float {
        tiltProjections?.vertical ?? 0
    }

    /// Maps the device's left/right lean to a normalized horizontal control axis.
    /// Calibration is applied before the dead zone and clamp so neutral offsets do
    /// not consume travel or create an off-center plateau.
    public func horizontalTiltAxis(sensitivity: Float = 1.5, neutral: Float = 0) -> Float {
        guard sensitivity.isFinite, sensitivity > 0, neutral.isFinite,
              let projection = tiltProjections?.horizontal else { return 0 }
        return Self.normalizedTiltAxis(projection: projection, neutral: neutral, sensitivity: sensitivity)
    }

    /// Maps the device's forward/back lean to a normalized vertical control axis.
    public func verticalTiltAxis(sensitivity: Float = 1.5, neutral: Float = 0) -> Float {
        guard sensitivity.isFinite, sensitivity > 0, neutral.isFinite,
              let projection = tiltProjections?.vertical else { return 0 }
        return Self.normalizedTiltAxis(projection: projection, neutral: neutral, sensitivity: sensitivity)
    }

    private static func normalizedTiltAxis(projection: Float, neutral: Float, sensitivity: Float) -> Float {
        let neutral = min(max(neutral, -1), 1)
        let centered = projection - neutral
        let availableTravel = centered >= 0 ? 1 - neutral : 1 + neutral
        guard availableTravel > 0 else { return 0 }
        let calibratedSensitivity = max(sensitivity, 1 / availableTravel)
        let scaled = centered * calibratedSensitivity
        guard scaled.isFinite, abs(scaled) >= 0.04 else { return 0 }
        return min(max(scaled, -1), 1)
    }

    private var tiltProjections: (horizontal: Float, vertical: Float)? {
        guard let normalized else { return nil }
        let gravityX = 2 * (
            (normalized.x * normalized.z) - (normalized.w * normalized.y)
        )
        let gravityY = 2 * (
            (normalized.y * normalized.z) + (normalized.w * normalized.x)
        )
        let horizontal = -gravityX
        guard horizontal.isFinite, gravityY.isFinite else { return nil }
        return (horizontal, gravityY)
    }
}

public struct InputFrame: Codable, Equatable, Sendable {
    public static let byteCount = 48

    public let token: UInt64
    public let sequence: UInt32
    public let clientTimeMs: UInt32
    public let axisX: Float
    public let axisY: Float
    public let buttons: Buttons
    public let orientation: OrientationQuaternion
    public let flags: InputFlags

    public init(
        token: UInt64,
        sequence: UInt32,
        clientTimeMs: UInt32,
        axisX: Float,
        axisY: Float,
        buttons: Buttons = [],
        orientation: OrientationQuaternion = .identity,
        flags: InputFlags = []
    ) {
        self.token = token
        self.sequence = sequence
        self.clientTimeMs = clientTimeMs
        self.axisX = axisX
        self.axisY = axisY
        self.buttons = buttons
        self.orientation = orientation
        self.flags = flags
    }

    public var validated: InputFrame? {
        guard axisX.isFinite, axisY.isFinite else { return nil }
        let validatedOrientation: OrientationQuaternion
        if flags.contains(.motionAvailable) {
            guard let normalized = orientation.normalized else { return nil }
            validatedOrientation = normalized
        } else {
            validatedOrientation = .identity
        }
        return InputFrame(
            token: token,
            sequence: sequence,
            clientTimeMs: clientTimeMs,
            axisX: min(max(axisX, -1), 1),
            axisY: min(max(axisY, -1), 1),
            buttons: buttons,
            orientation: validatedOrientation,
            flags: flags.intersection(.motionAvailable)
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
        data.appendLittleEndian(orientation.x.bitPattern)
        data.appendLittleEndian(orientation.y.bitPattern)
        data.appendLittleEndian(orientation.z.bitPattern)
        data.appendLittleEndian(orientation.w.bitPattern)
        data.appendLittleEndian(flags.rawValue)
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
            let buttonBits: UInt32 = data.readLittleEndian(at: &offset),
            let orientationXBits: UInt32 = data.readLittleEndian(at: &offset),
            let orientationYBits: UInt32 = data.readLittleEndian(at: &offset),
            let orientationZBits: UInt32 = data.readLittleEndian(at: &offset),
            let orientationWBits: UInt32 = data.readLittleEndian(at: &offset),
            let flagBits: UInt32 = data.readLittleEndian(at: &offset)
        else { return nil }

        let decoded = InputFrame(
            token: token,
            sequence: sequence,
            clientTimeMs: clientTimeMs,
            axisX: Float(bitPattern: xBits),
            axisY: Float(bitPattern: yBits),
            buttons: Buttons(rawValue: buttonBits),
            orientation: OrientationQuaternion(
                x: Float(bitPattern: orientationXBits),
                y: Float(bitPattern: orientationYBits),
                z: Float(bitPattern: orientationZBits),
                w: Float(bitPattern: orientationWBits)
            ),
            flags: InputFlags(rawValue: flagBits)
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
