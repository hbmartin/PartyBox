import Foundation

public enum UDPDropPolicy: Codable, Equatable, Sendable {
    case none
    case rate(Double)
    case every(Int)

    public func validated() -> Self {
        switch self {
        case .none:
            return .none
        case let .rate(value):
            return .rate(min(max(value.isFinite ? value : 0, 0), 1))
        case let .every(value):
            return value > 0 ? .every(value) : .none
        }
    }
}

public struct FaultProfile: Codable, Equatable, Sendable {
    public var seed: UInt64
    public var udpDropPolicy: UDPDropPolicy
    public var delayMilliseconds: Int
    public var jitterMilliseconds: Int
    public var reorderWindow: Int

    public init(
        seed: UInt64 = 1,
        udpDropPolicy: UDPDropPolicy = .none,
        delayMilliseconds: Int = 0,
        jitterMilliseconds: Int = 0,
        reorderWindow: Int = 1
    ) {
        self.seed = seed == 0 ? 1 : seed
        self.udpDropPolicy = udpDropPolicy.validated()
        self.delayMilliseconds = max(delayMilliseconds, 0)
        self.jitterMilliseconds = max(jitterMilliseconds, 0)
        self.reorderWindow = max(reorderWindow, 1)
    }

    public static let stable = FaultProfile()
}

public struct FaultMetrics: Codable, Equatable, Sendable {
    public var tcpConnections = 0
    public var activeTCPBridges = 0
    public var activeTCPHandlers = 0
    public var activeUDPSessions = 0
    public var tcpMessagesClientToHost = 0
    public var tcpMessagesHostToClient = 0
    public var tcpCuts = 0
    public var hostRestarts = 0
    public var udpReceived = 0
    public var udpForwarded = 0
    public var udpDropped = 0
    public var udpDelayed = 0
    public var udpReordered = 0
    public var udpRejected = 0

    public init() {}
}

public struct FaultRigMetadata: Codable, Equatable, Sendable {
    public let host: String
    public let tcpPort: UInt16
    public let udpPort: UInt16
    public let controlPort: UInt16?
    public let hostInstanceID: UUID

    public init(
        host: String = "127.0.0.1",
        tcpPort: UInt16,
        udpPort: UInt16,
        controlPort: UInt16? = nil,
        hostInstanceID: UUID
    ) {
        self.host = host
        self.tcpPort = tcpPort
        self.udpPort = udpPort
        self.controlPort = controlPort
        self.hostInstanceID = hostInstanceID
    }
}
