import Foundation
import PartyNet

@MainActor
public final class FaultRig {
    public private(set) var host: PartyHost
    public let proxy: NetworkFaultProxy
    public let hostName: String

    public init(hostName: String = "PartyBox Fault Rig", profile: FaultProfile = .stable) {
        self.hostName = hostName
        host = PartyHost()
        proxy = NetworkFaultProxy(profile: profile)
    }

    @discardableResult
    public func start() async throws -> FaultRigMetadata {
        let upstreamPort = try await host.start(hostName: hostName, advertise: false)
        let ports = try await proxy.start(upstreamTCPPort: upstreamPort)
        return FaultRigMetadata(
            tcpPort: ports.tcp,
            udpPort: ports.udp,
            hostInstanceID: host.hostInstanceID
        )
    }

    @discardableResult
    public func restartHost() async throws -> FaultRigMetadata {
        // Tear down proxy bridges while the upstream is still reachable. This
        // lets the typed Network API finish its structured connection handlers
        // before the listener itself is replaced.
        await proxy.cutTCP()
        await host.stop()
        host = PartyHost()
        let upstreamPort = try await host.start(hostName: hostName, advertise: false)
        try await proxy.updateUpstream(tcpPort: upstreamPort)
        await proxy.noteHostRestart()
        guard let tcpPort = await proxy.tcpPort, let udpPort = await proxy.udpPort else {
            throw PartyNetTransportError.stopped
        }
        return FaultRigMetadata(
            tcpPort: tcpPort,
            udpPort: udpPort,
            hostInstanceID: host.hostInstanceID
        )
    }

    public func stop() async {
        await proxy.stop()
        await host.stop()
    }
}
