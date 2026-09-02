import Foundation

public struct Hello: Codable, Equatable, Sendable {
    public let protocolVersion: UInt16
    public let controllerID: ControllerID
    public let displayName: String

    public init(
        protocolVersion: UInt16 = PartyNetConstants.protocolVersion,
        controllerID: ControllerID,
        displayName: String
    ) {
        self.protocolVersion = protocolVersion
        self.controllerID = controllerID
        self.displayName = displayName
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
        case .full: "This PartyBox already has eight controllers."
        case let .versionMismatch(hostVersion): "Controller version is incompatible with host protocol \(hostVersion)."
        case .malformedHello: "The host could not understand this controller."
        case .replaced: "This controller was replaced by another connection using the same identity."
        }
    }
}

public enum MenuAction: String, Codable, CaseIterable, Sendable {
    case up
    case down
    case left
    case right
    case select
    case back
}

public enum Feedback: String, Codable, Equatable, Sendable {
    case paddleHit
    case lostLife
    case eliminated
    case won
}

public enum ClientMessage: Codable, Equatable, Sendable {
    case hello(Hello)
    case rename(String)
    case menu(MenuAction)
    case input(InputFrame)
    case ping(UInt64)
    case leave
}

public enum HostMessage: Codable, Equatable, Sendable {
    case welcome(Welcome)
    case rejected(RejectReason)
    case roster([PlayerInfo])
    case layout(ControllerLayout)
    case feedback(Feedback)
    case pong(UInt64)
}
