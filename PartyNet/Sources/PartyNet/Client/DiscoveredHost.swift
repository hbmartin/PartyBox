import Foundation
import Network

public struct DiscoveredHost: Identifiable, Equatable, Sendable {
    enum Target: Sendable {
        case bonjour(Bonjour.Endpoint)
        case endpoint(NWEndpoint)
    }

    public let id: String
    public let name: String
    public let protocolVersion: UInt16?
    public let instanceID: UUID?
    let target: Target

    public var isCompatible: Bool {
        protocolVersion == nil || protocolVersion == PartyNetConstants.protocolVersion
    }

    init(endpoint: Bonjour.Endpoint) {
        id = endpoint.id
        name = endpoint.name
        protocolVersion = endpoint.txtRecord["v"].flatMap(UInt16.init)
        instanceID = endpoint.txtRecord["id"].flatMap(UUID.init(uuidString:))
        target = .bonjour(endpoint)
    }

    public init(host: String, port: UInt16, name: String? = nil) throws {
        guard port != 0, let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw PartyClientError.invalidAddress
        }
        id = "\(host):\(port)"
        self.name = name ?? id
        protocolVersion = nil
        instanceID = nil
        let nwHost: NWEndpoint.Host
        if let ipv4 = IPv4Address(host) {
            nwHost = .ipv4(ipv4)
        } else if let ipv6 = IPv6Address(host) {
            nwHost = .ipv6(ipv6)
        } else {
            nwHost = .name(host, nil)
        }
        target = .endpoint(.hostPort(host: nwHost, port: nwPort))
    }

    public static func == (lhs: DiscoveredHost, rhs: DiscoveredHost) -> Bool {
        lhs.id == rhs.id && lhs.protocolVersion == rhs.protocolVersion && lhs.instanceID == rhs.instanceID
    }
}
