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
    public static let maximumDelayMilliseconds = 60_000
    public static let maximumReorderWindow = 1_024

    public let seed: UInt64
    public let udpDropPolicy: UDPDropPolicy
    public let delayMilliseconds: Int
    public let jitterMilliseconds: Int
    public let reorderWindow: Int

    public init(
        seed: UInt64 = 1,
        udpDropPolicy: UDPDropPolicy = .none,
        delayMilliseconds: Int = 0,
        jitterMilliseconds: Int = 0,
        reorderWindow: Int = 1
    ) {
        self.seed = seed == 0 ? 1 : seed
        self.udpDropPolicy = udpDropPolicy.validated()
        self.delayMilliseconds = min(max(delayMilliseconds, 0), Self.maximumDelayMilliseconds)
        self.jitterMilliseconds = min(max(jitterMilliseconds, 0), Self.maximumDelayMilliseconds)
        self.reorderWindow = min(max(reorderWindow, 1), Self.maximumReorderWindow)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            seed: try container.decode(UInt64.self, forKey: .seed),
            udpDropPolicy: try container.decode(UDPDropPolicy.self, forKey: .udpDropPolicy),
            delayMilliseconds: try container.decode(Int.self, forKey: .delayMilliseconds),
            jitterMilliseconds: try container.decode(Int.self, forKey: .jitterMilliseconds),
            reorderWindow: try container.decode(Int.self, forKey: .reorderWindow)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seed, forKey: .seed)
        try container.encode(udpDropPolicy, forKey: .udpDropPolicy)
        try container.encode(delayMilliseconds, forKey: .delayMilliseconds)
        try container.encode(jitterMilliseconds, forKey: .jitterMilliseconds)
        try container.encode(reorderWindow, forKey: .reorderWindow)
    }

    @available(*, deprecated, message: "FaultProfile values are validated during initialization.")
    public func validated() -> Self { self }

    public static let stable = FaultProfile()

    private enum CodingKeys: String, CodingKey {
        case seed
        case udpDropPolicy
        case delayMilliseconds
        case jitterMilliseconds
        case reorderWindow
    }
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
