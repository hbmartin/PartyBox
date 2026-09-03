import Foundation

public enum PartyNetConstants {
    public static let serviceType = "_partybox._tcp"
    public static let protocolVersion: UInt16 = 2
    public static let maximumControllers = 8
    public static let reconnectGrace: Duration = .seconds(15)
    public static let clientReconnectWindow: Duration = .seconds(30)
    public static let helloTimeout: Duration = .seconds(5)
    public static let udpIdleTimeout: Duration = .seconds(5)
    public static let udpReadyTimeout: Duration = .seconds(1)
    public static let inputRefreshInterval: Duration = .milliseconds(200)
    public static let tcpFallbackInterval: Duration = .milliseconds(33)
    public static let pingInterval: Duration = .seconds(2)
    public static let pingTimeout: Duration = .seconds(6)
}
