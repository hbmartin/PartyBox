import Foundation
import Testing
@testable import PartyNet

@Suite("Host/client loopback", .serialized)
@MainActor
struct LoopbackSessionTests {
    @Test func joinsRenamesStreamsInputAndLeaves() async throws {
        let host = PartyHost(reconnectGrace: .milliseconds(100))
        let port = try await host.start(hostName: "Test Host", advertise: false)
        let client = PartyClient(
            controllerID: ControllerID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!),
            displayName: "Tester"
        )
        await client.connect(host: "127.0.0.1", port: port)

        #expect(client.player?.id == PlayerID(0))
        try await waitUntil { host.players.count == 1 }
        #expect(host.players.first?.displayName == "Tester")

        await client.rename(to: "Renamed")
        try await waitUntil { host.players.first?.displayName == "Renamed" }

        client.setInput(axisX: 0.75)
        try await waitUntil { host.inputs.snapshot()[PlayerID(0)]?.axisX == 0.75 }

        await client.disconnect()
        try await waitUntil { host.players.isEmpty }
        await host.stop()
    }

    @Test func rejectsWrongProtocolVersion() async throws {
        let host = PartyHost()
        let port = try await host.start(hostName: "Version Host", advertise: false)
        let transport = ClientTransport()
        let target = try DiscoveredHost(host: "127.0.0.1", port: port)
        let hello = Hello(protocolVersion: 999, controllerID: ControllerID(), displayName: "Old")
        await #expect(throws: PartyClientError.self) {
            _ = try await transport.connect(to: target, hello: hello)
        }
        await transport.stop()
        await host.stop()
    }

    @Test func ninthControllerIsRejected() async throws {
        let host = PartyHost()
        let port = try await host.start(hostName: "Capacity Host", advertise: false)
        var clients: [PartyClient] = []
        for index in 0..<PartyNetConstants.maximumControllers {
            let client = PartyClient(displayName: "Load \(index + 1)")
            await client.connect(host: "127.0.0.1", port: port)
            clients.append(client)
        }
        #expect(host.players.count == PartyNetConstants.maximumControllers)

        let ninth = PartyClient(displayName: "Ninth")
        await ninth.connect(host: "127.0.0.1", port: port)
        guard case .rejected = ninth.state else {
            Issue.record("Expected the ninth controller to be rejected")
            await host.stop()
            return
        }

        for client in clients { await client.disconnect() }
        await ninth.disconnect()
        await host.stop()
    }

    @Test func duplicateIdentityReplacesConnectionAndKeepsPlayer() async throws {
        let host = PartyHost(reconnectGrace: .milliseconds(200))
        let port = try await host.start(hostName: "Duplicate Host", advertise: false)
        let controllerID = ControllerID(rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
        let first = PartyClient(controllerID: controllerID, displayName: "First")
        let replacement = PartyClient(controllerID: controllerID, displayName: "Replacement")

        await first.connect(host: "127.0.0.1", port: port)
        await replacement.connect(host: "127.0.0.1", port: port)

        try await waitUntil { host.players.first?.displayName == "Replacement" }
        try await waitUntil {
            if case .rejected = first.state { return true }
            return false
        }
        #expect(host.players.count == 1)
        #expect(replacement.player?.id == PlayerID(0))
        await replacement.disconnect()
        await first.disconnect()
        await host.stop()
    }

    @Test func reconnectInsideGracePreservesSlotAndCancelsExpiry() async throws {
        let host = PartyHost(reconnectGrace: .milliseconds(180))
        let port = try await host.start(hostName: "Grace Host", advertise: false)
        let controllerID = ControllerID(rawValue: UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!)
        let first = PartyClient(controllerID: controllerID, displayName: "Grace")
        await first.connect(host: "127.0.0.1", port: port)
        await first.interruptForTesting()
        try await waitUntil { host.players.first?.isConnected == false }

        let reconnected = PartyClient(controllerID: controllerID, displayName: "Grace Again")
        await reconnected.connect(host: "127.0.0.1", port: port)
        try await waitUntil { host.players.first?.isConnected == true }
        try await Task.sleep(for: .milliseconds(240))

        #expect(host.players.count == 1)
        #expect(host.players.first?.id == PlayerID(0))
        await reconnected.disconnect()
        await host.stop()
    }

    @Test func expiredGraceReleasesPlayerSlot() async throws {
        let host = PartyHost(reconnectGrace: .milliseconds(80))
        let port = try await host.start(hostName: "Expiry Host", advertise: false)
        let client = PartyClient(displayName: "Gone")
        await client.connect(host: "127.0.0.1", port: port)

        await client.interruptForTesting()
        try await waitUntil(timeout: .seconds(1)) { host.players.isEmpty }

        #expect(host.inputs.snapshot().isEmpty)
        await host.stop()
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }
}
