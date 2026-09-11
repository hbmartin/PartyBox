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

    @Test func legacyEndpointMetadataDefaultsTheControlSocketToLoopback() throws {
        let data = Data(#"{"host":"0.0.0.0","tcpPort":9000,"udpPort":9001,"controlPort":9900}"#.utf8)
        let endpoints = try JSONDecoder().decode(ProxyEndpoints.self, from: data)

        #expect(endpoints.host == "0.0.0.0")
        #expect(endpoints.controlHost == "127.0.0.1")
        #expect(PartyFaultNetworkSupport.isLoopback(endpoints.controlHost))
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

        let tcpPort = try await PartyFaultNetworkSupport.waitForBoundPort(tcpServer, attempts: 300)
        let udpPort = try await PartyFaultNetworkSupport.waitForBoundPort(udpServer, attempts: 300)
        let proxy = GenericFaultProxy()
        let proxyPorts = try await proxy.start(
            upstreamHost: "127.0.0.1",
            upstreamTCPPort: tcpPort,
            upstreamUDPPort: udpPort
        )
        try await withAsyncCleanup {
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

            let metrics = try await waitForMetrics(proxy) {
                $0.clientToServer.udpDatagramsForwarded == 1
                    && $0.serverToClient.udpDatagramsForwarded == 1
            }
            #expect(metrics.acceptedTCPConnections == 1)
            #expect(metrics.acceptedUDPFlows == 1)
            #expect(metrics.clientToServer.tcpBytesForwarded == payload.count)
            #expect(metrics.serverToClient.tcpBytesForwarded == payload.count)
            #expect(metrics.clientToServer.udpDatagramsForwarded == 1)
            #expect(metrics.serverToClient.udpDatagramsForwarded == 1)
        } cleanup: {
            await proxy.stop()
        }
    }

    @Test func partialUDPReorderWindowFlushesAfterIdle() async throws {
        let tcpServer = try NetworkListener<TCP>(
            for: nil,
            using: NWParametersBuilder.parameters { TCP().noDelay(true) }
                .localEndpoint(.hostPort(host: "127.0.0.1", port: .any))
                .localOnly(true)
                .peerToPeerIncluded(false)
        )
        let udpServer = try NetworkListener<UDP>(
            for: nil,
            using: .parameters { UDP() }
                .localEndpoint(.hostPort(host: "127.0.0.1", port: .any))
                .localOnly(true)
                .peerToPeerIncluded(false)
        )
        let tcpServerTask = Task {
            try await tcpServer.run { _ in }
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

        let tcpPort = try await PartyFaultNetworkSupport.waitForBoundPort(tcpServer, attempts: 300)
        let udpPort = try await PartyFaultNetworkSupport.waitForBoundPort(udpServer, attempts: 300)
        let reordered = LinkImpairment(udp: .init(reorderWindow: 3))
        let proxy = GenericFaultProxy(profile: .init(
            clientToServer: reordered,
            serverToClient: reordered
        ))
        let proxyPorts = try await proxy.start(
            upstreamHost: "127.0.0.1",
            upstreamTCPPort: tcpPort,
            upstreamUDPPort: udpPort
        )
        try await withAsyncCleanup {
            let payload = Data("partial reorder window".utf8)
            let client = NetworkConnection<UDP>(
                to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxyPorts.udp)!),
                using: .parameters { UDP() }.peerToPeerIncluded(false)
            )
            let response = try await withTimeout {
                try await client.send(payload)
                return try await client.receive().content
            }

            #expect(response == payload)
            let metrics = try await waitForMetrics(proxy) {
                $0.clientToServer.udpDatagramsForwarded == 1
                    && $0.serverToClient.udpDatagramsForwarded == 1
            }
            #expect(metrics.clientToServer.udpDatagramsReceived == 1)
            #expect(metrics.serverToClient.udpDatagramsReceived == 1)
        } cleanup: {
            await proxy.stop()
        }
    }

    @Test func udpFullLossDropsTheDatagramAndRecordsIt() async throws {
        let tcpServer = try NetworkListener<TCP>(
            for: nil,
            using: .parameters { TCP().noDelay(true) }
                .localEndpoint(.hostPort(host: "127.0.0.1", port: .any))
                .localOnly(true)
                .peerToPeerIncluded(false)
        )
        let udpServer = try NetworkListener<UDP>(
            for: nil,
            using: .parameters { UDP() }
                .localEndpoint(.hostPort(host: "127.0.0.1", port: .any))
                .localOnly(true)
                .peerToPeerIncluded(false)
        )
        let tcpServerTask = Task { try await tcpServer.run { _ in } }
        let udpServerTask = Task { try await udpServer.run { _ in } }
        defer {
            tcpServerTask.cancel()
            udpServerTask.cancel()
        }

        let tcpPort = try await PartyFaultNetworkSupport.waitForBoundPort(tcpServer, attempts: 300)
        let udpPort = try await PartyFaultNetworkSupport.waitForBoundPort(udpServer, attempts: 300)
        let proxy = GenericFaultProxy(profile: .init(
            clientToServer: .init(udp: .init(lossRate: 1))
        ))
        let proxyPorts = try await proxy.start(
            upstreamHost: "127.0.0.1",
            upstreamTCPPort: tcpPort,
            upstreamUDPPort: udpPort
        )

        try await withAsyncCleanup {
            let client = NetworkConnection<UDP>(
                to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxyPorts.udp)!),
                using: .parameters { UDP() }.peerToPeerIncluded(false)
            )
            try await client.send(Data("drop me".utf8))
            let metrics = try await waitForMetrics(proxy) {
                $0.clientToServer.udpDatagramsReceived == 1
                    && $0.clientToServer.udpDatagramsDropped == 1
            }
            #expect(metrics.clientToServer.udpDatagramsForwarded == 0)
            await #expect(throws: TestTimeout.self) {
                try await withTimeout(duration: .milliseconds(250)) {
                    try await client.receive().content
                }
            }
        } cleanup: {
            await proxy.stop()
        }
    }

    @Test func duplicatedUDPDelaysRunConcurrentlyFromArrivalTime() async throws {
        let tcpServer = try NetworkListener<TCP>(
            for: nil,
            using: .parameters { TCP().noDelay(true) }
                .localEndpoint(.hostPort(host: "127.0.0.1", port: .any))
                .localOnly(true)
                .peerToPeerIncluded(false)
        )
        let udpServer = try NetworkListener<UDP>(
            for: nil,
            using: .parameters { UDP() }
                .localEndpoint(.hostPort(host: "127.0.0.1", port: .any))
                .localOnly(true)
                .peerToPeerIncluded(false)
        )
        let tcpServerTask = Task { try await tcpServer.run { _ in } }
        let udpServerTask = Task {
            try await udpServer.run { connection in
                for _ in 0..<2 {
                    let content = try await connection.receive().content
                    try await connection.send(content)
                }
            }
        }
        defer {
            tcpServerTask.cancel()
            udpServerTask.cancel()
        }

        let tcpPort = try await PartyFaultNetworkSupport.waitForBoundPort(tcpServer, attempts: 300)
        let udpPort = try await PartyFaultNetworkSupport.waitForBoundPort(udpServer, attempts: 300)
        let proxy = GenericFaultProxy(profile: .init(
            clientToServer: .init(udp: .init(delayMilliseconds: 400, duplicateRate: 1))
        ))
        let proxyPorts = try await proxy.start(
            upstreamHost: "127.0.0.1",
            upstreamTCPPort: tcpPort,
            upstreamUDPPort: udpPort
        )

        try await withAsyncCleanup {
            let payload = Data("duplicate without cumulative delay".utf8)
            let client = NetworkConnection<UDP>(
                to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxyPorts.udp)!),
                using: .parameters { UDP() }.peerToPeerIncluded(false)
            )
            try await client.send(payload)
            let responses = try await withTimeout(duration: .milliseconds(650)) {
                let first = try await client.receive().content
                let second = try await client.receive().content
                return [first, second]
            }

            #expect(responses == [payload, payload])
            let metrics = try await waitForMetrics(proxy) {
                $0.clientToServer.udpDatagramsDuplicated == 1
                    && $0.clientToServer.udpDatagramsForwarded == 2
            }
            #expect(metrics.clientToServer.delayedUnits == 2)
        } cleanup: {
            await proxy.stop()
        }
    }

    @Test func tcpCutAndResetProfilesTerminateActiveFlows() async throws {
        let tcpServer = try NetworkListener<TCP>(
            for: nil,
            using: .parameters { TCP().noDelay(true) }
                .localEndpoint(.hostPort(host: "127.0.0.1", port: .any))
                .localOnly(true)
                .peerToPeerIncluded(false)
        )
        let udpServer = try NetworkListener<UDP>(
            for: nil,
            using: .parameters { UDP() }
                .localEndpoint(.hostPort(host: "127.0.0.1", port: .any))
                .localOnly(true)
                .peerToPeerIncluded(false)
        )
        let tcpServerTask = Task {
            try await tcpServer.run { connection in
                _ = try? await connection.receive(atMost: 4_096)
            }
        }
        let udpServerTask = Task { try await udpServer.run { _ in } }
        defer {
            tcpServerTask.cancel()
            udpServerTask.cancel()
        }

        let tcpPort = try await PartyFaultNetworkSupport.waitForBoundPort(tcpServer, attempts: 300)
        let udpPort = try await PartyFaultNetworkSupport.waitForBoundPort(udpServer, attempts: 300)
        let proxy = GenericFaultProxy()
        let proxyPorts = try await proxy.start(
            upstreamHost: "127.0.0.1",
            upstreamTCPPort: tcpPort,
            upstreamUDPPort: udpPort
        )

        try await withAsyncCleanup {
            for (index, failure) in [TCPFailureMode.cut, .reset].enumerated() {
                await proxy.setProfile(.init(
                    clientToServer: .init(tcp: .init(failure: failure))
                ))
                let client = NetworkConnection<TCP>(
                    to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxyPorts.tcp)!),
                    using: .parameters { TCP().noDelay(true) }.peerToPeerIncluded(false)
                )
                try await client.send(Data("terminate".utf8))
                let terminated = try await withTimeout {
                    do {
                        let message = try await client.receive(atMost: 4_096)
                        return message.content.isEmpty || message.metadata.endOfStream
                    } catch {
                        return true
                    }
                }
                #expect(terminated)
                let metrics = try await waitForMetrics(proxy) {
                    $0.acceptedTCPConnections == UInt64(index + 1)
                        && $0.activeTCPConnections == 0
                }
                #expect(metrics.clientToServer.tcpBytesReceived > 0)
            }
        } cleanup: {
            await proxy.stop()
        }
    }

    private func withTimeout<Value: Sendable>(
        duration: Duration = .seconds(3),
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: duration)
                throw TestTimeout()
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    private func waitForMetrics(
        _ proxy: GenericFaultProxy,
        timeout: Duration = .seconds(3),
        until predicate: (FaultMetrics) -> Bool
    ) async throws -> FaultMetrics {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            let metrics = await proxy.currentMetrics()
            if predicate(metrics) { return metrics }
            try await Task.sleep(for: .milliseconds(20))
        } while clock.now < deadline
        throw TestTimeout()
    }

    private func withAsyncCleanup<Value>(
        operation: () async throws -> Value,
        cleanup: () async -> Void
    ) async rethrows -> Value {
        do {
            let value = try await operation()
            await cleanup()
            return value
        } catch {
            await cleanup()
            throw error
        }
    }

    private struct TestTimeout: Error {}
}
