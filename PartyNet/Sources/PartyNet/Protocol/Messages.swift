import Foundation

public struct Hello: Codable, Equatable, Sendable {
    public let protocolVersion: UInt16
    public let controllerID: ControllerID
    public let displayName: String
    public let preferredMark: PlayerMark?

    public init(
        protocolVersion: UInt16 = PartyNetConstants.protocolVersion,
        controllerID: ControllerID,
        displayName: String,
        preferredMark: PlayerMark? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.controllerID = controllerID
        self.displayName = displayName
        self.preferredMark = preferredMark
    }
}

public struct Welcome: Codable, Equatable, Sendable {
    public let player: PlayerInfo
    public let udpPort: UInt16
    public let sessionToken: UInt64
    public let hostName: String
    public let hostInstanceID: UUID
    public let protocolVersion: UInt16

    public init(
        player: PlayerInfo,
        udpPort: UInt16,
        sessionToken: UInt64,
        hostName: String,
        hostInstanceID: UUID,
        protocolVersion: UInt16 = PartyNetConstants.protocolVersion
    ) {
        self.player = player
        self.udpPort = udpPort
        self.sessionToken = sessionToken
        self.hostName = hostName
        self.hostInstanceID = hostInstanceID
        self.protocolVersion = protocolVersion
    }
}

public enum RejectReason: Codable, Equatable, Sendable {
    case full
    case versionMismatch(hostVersion: UInt16)
    case malformedHello
    case replaced

    public var message: String {
        switch self {
        case .full: "This PartyBox already has \(PartyNetConstants.maximumControllers) controllers."
        case let .versionMismatch(hostVersion): "Controller version is incompatible with host protocol \(hostVersion)."
        case .malformedHello: "The host could not understand this controller."
        case .replaced: "This controller was replaced by another connection using the same identity."
        }
    }
}

public enum ClientMessage: Codable, Equatable, Sendable {
    case hello(Hello)
    case rename(String)
    case application(Data)
    case input(InputFrame)
    case ping(UInt64)
    case leave
}

public enum HostMessage: Codable, Equatable, Sendable {
    case welcome(Welcome)
    case rejected(RejectReason)
    case application(Data)
    case inputAck(sequence: UInt32)
    case pingResponse(UInt64)
}
