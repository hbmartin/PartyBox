import Foundation
import Network
import Testing
@testable import PartyFault

@Suite("PartyFault impairment engine", .serialized)
struct PartyFaultTests {
    @Test func profileClampsUnsafeValues() {
        let udp = UDPImpairment(lossRate: 4, delayMilliseconds: -1, jitterMilliseconds: 90_000, duplicateRate: -0.5, reorderWindow: 0)
        #expect(udp.lossRate == 1)
        #expect(udp.delayMilliseconds == 0)
        #expect(udp.jitterMilliseconds == 60_000)
        #expect(udp.duplicateRate == 0)
        #expect(udp.reorderWindow == 1)
    }

    @Test func seededPlansAreDeterministic() async {
        let profile = FaultProfile(
            seed: 42,
            clientToServer: .init(udp: .init(lossRate: 0.3, delayMilliseconds: 20, jitterMilliseconds: 8, duplicateRate: 0.2))
        )
        let first = ImpairmentEngine(profile: profile)
        let second = ImpairmentEngine(profile: profile)
        for _ in 0..<100 {
            #expect(await first.udpPlan(direction: .clientToServer) == second.udpPlan(direction: .clientToServer))
        }
    }

    @Test func tcpThrottleContributesDelay() async {
        let engine = ImpairmentEngine(profile: .init(
            clientToServer: .init(tcp: .init(throttleBytesPerSecond: 1_000))
        ))
        #expect(await engine.tcpDecision(direction: .clientToServer, byteCount: 500) == .forward(after: .milliseconds(500)))
    }

    @Test func proxyRejectsAnUnspecifiedUpstreamPort() async {
        let proxy = GenericFaultProxy()
        await #expect(throws: PartyFaultError.self) {
            try await proxy.start(upstreamHost: "127.0.0.1", upstreamTCPPort: 0, upstreamUDPPort: 9_000)
        }
    }

    @Test func stableProxyForwardsTCPAndUDPAndRecordsMetrics() async throws {
        let tcpServer = try NetworkListener<TCP>(
            for: nil,
            using: NWParametersBuilder.parameters { TCP().noDelay(true) }
                .localEndpoint(.hostPort(host: "127.0.0.1", port: .any))
                .localOnly(true)
                .peerToPeerIncluded(false)
        )
        let udpServer = try NetworkListener<UDP>(
            for: nil,
            using: NWParametersBuilder.parameters { UDP() }
                .localEndpoint(.hostPort(host: "127.0.0.1", port: .any))
                .localOnly(true)
                .peerToPeerIncluded(false)
        )
        let tcpServerTask = Task {
            try await tcpServer.run { connection in
                let content = try await connection.receive(atMost: 4_096).content
                try await connection.send(content)
            }
        }
        let udpServerTask = Task {
            try await udpServer.run { connection in
                let content = try await connection.receive().content
                try await connection.send(content)
            }
        }
        defer {
            tcpServerTask.cancel()
            udpServerTask.cancel()
        }

        let tcpPort = try await boundPort(tcpServer)
        let udpPort = try await boundPort(udpServer)
        let proxy = GenericFaultProxy()
        let proxyPorts = try await proxy.start(
            upstreamHost: "127.0.0.1",
            upstreamTCPPort: tcpPort,
            upstreamUDPPort: udpPort
        )
        defer { Task { await proxy.stop() } }

        let payload = Data("PartyFault loopback".utf8)
        let tcpClient = NetworkConnection<TCP>(
            to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxyPorts.tcp)!),
            using: .parameters { TCP().noDelay(true) }.peerToPeerIncluded(false)
        )
        let tcpResponse = try await withTimeout {
            try await tcpClient.send(payload)
            return try await tcpClient.receive(atMost: 4_096).content
        }
        #expect(tcpResponse == payload)

        let udpClient = NetworkConnection<UDP>(
            to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxyPorts.udp)!),
            using: .parameters { UDP() }.peerToPeerIncluded(false)
        )
        let udpResponse = try await withTimeout {
            try await udpClient.send(payload)
            return try await udpClient.receive().content
        }
        #expect(udpResponse == payload)

        let metrics = await proxy.currentMetrics()
        #expect(metrics.acceptedTCPConnections == 1)
        #expect(metrics.acceptedUDPFlows == 1)
        #expect(metrics.clientToServer.tcpBytesForwarded == payload.count)
        #expect(metrics.serverToClient.tcpBytesForwarded == payload.count)
        #expect(metrics.clientToServer.udpDatagramsForwarded == 1)
        #expect(metrics.serverToClient.udpDatagramsForwarded == 1)
    }

    private func boundPort<P>(_ listener: NetworkListener<P>) async throws -> UInt16 {
        for _ in 0..<300 {
            if let port = listener.port?.rawValue, port != 0 { return port }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TestTimeout()
    }

    private func withTimeout<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                throw TestTimeout()
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    private struct TestTimeout: Error {}
}
