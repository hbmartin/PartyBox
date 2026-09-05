import Dependencies
import DependenciesTestSupport
import Foundation
import Network
import Testing

@testable import PartyNet

extension NetworkIntegrationTests {
  @Suite("Host/client loopback", .serialized, .dependency(\.continuousClock, ContinuousClock()))
  @MainActor
  struct LoopbackSessionTests {
    private actor StalledHandshakeServer {
      private(set) var receivedHello = false
      private(set) var activeConnections = 0

      func handle(_ connection: HostControlConnection) async {
        activeConnections += 1
        defer { activeConnections -= 1 }
        do {
          let first = try await connection.receive().content
          guard case .hello = first else { return }
          receivedHello = true
          _ = try await connection.receive().content
        } catch {
          // Cancellation of the client handshake should close this flow promptly.
        }
      }
    }

    private actor WelcomingHandshakeServer {
      private(set) var receivedLeave = false

      func handle(_ connection: HostControlConnection) async {
        do {
          let first = try await connection.receive().content
          guard case .hello = first else { return }
          let welcome = Welcome(
            player: PlayerInfo(id: PlayerID(0), displayName: "Cancelled", colorHex: "#32E6FF"),
            udpPort: 9,
            sessionToken: 1,
            hostName: "Cancellation Host",
            hostInstanceID: UUID()
          )
          try await connection.send(.welcome(welcome))
          for try await message in connection.messages {
            if case .leave = message.content {
              receivedLeave = true
              return
            }
          }
        } catch {}
      }
    }

    private actor HandshakeResponseGate {
      private(set) var isPaused = false
      private var continuation: CheckedContinuation<Void, Never>?

      func pause() async {
        isPaused = true
        await withCheckedContinuation { continuation = $0 }
      }

      func resume() {
        continuation?.resume()
        continuation = nil
      }
    }

    private actor EventRecorder {
      private(set) var feedback: [Feedback] = []
      private(set) var menuActions: [MenuAction] = []
      private(set) var expiredPlayers: [PlayerInfo] = []

      func record(_ event: ClientEvent) {
        if case .feedback(let value) = event { feedback.append(value) }
      }

      func record(_ event: HostEvent) {
        switch event {
        case .menu(_, let action):
          menuActions.append(action)
        case .playerExpired(let player):
          expiredPlayers.append(player)
        default:
          break
        }
      }

      func contains(feedback expectedFeedback: [Feedback], menu expectedMenu: [MenuAction]) -> Bool
      {
        feedback == expectedFeedback && menuActions == expectedMenu
      }

      func containsExpiredPlayer(named name: String) -> Bool {
        expiredPlayers.contains { $0.displayName == name && !$0.isConnected }
      }
    }

    @Test func joinsRenamesStreamsInputAndLeaves() async throws {
      let host = PartyHost(reconnectGrace: .milliseconds(100))
      let port = try await host.start(hostName: "Test Host", advertise: false)
      let client = PartyClient(
        controllerID: ControllerID(
          rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!),
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

    @Test func rapidRenamesApplyImmediatelyThenCoalesceToTheLatestName() async throws {
      let clock = TestClock()
      try await withDependencies {
        $0.continuousClock = clock
      } operation: {
        let host = PartyHost(reconnectGrace: .milliseconds(100))
        let port = try await runWhileAdvancingTestClock(clock) {
          try await host.start(hostName: "Rename Host", advertise: false)
        }
        let client = PartyClient(displayName: "Original")
        await client.connect(host: "127.0.0.1", port: port)
        try await waitUntil { host.players.first?.displayName == "Original" }

        await client.rename(to: "First")
        try await waitUntil { host.players.first?.displayName == "First" }
        await settle()

        await client.rename(to: "Intermediate")
        await client.rename(to: "Final")
        let pingCount = client.rttSampleCount
        client.reconnectAfterForeground()
        try await waitUntil { client.rttSampleCount > pingCount }
        #expect(host.players.first?.displayName == "First")

        await clock.advance(by: .milliseconds(99))
        await settle()
        #expect(host.players.first?.displayName == "First")

        await clock.advance(by: .milliseconds(1))
        try await waitUntil { host.players.first?.displayName == "Final" }

        await client.disconnect()
        await host.stop()
      }
    }

    @Test func rejectsWrongProtocolVersion() async throws {
      let host = PartyHost()
      let port = try await host.start(hostName: "Version Host", advertise: false)
      let transport = ClientTransport()
      let target = try DiscoveredHost(host: "127.0.0.1", port: port)
      let hello = Hello(protocolVersion: 999, controllerID: ControllerID(), displayName: "Old")
      await #expect(throws: PartyClientError.self) {
        _ = try await transport.connect(to: target, hello: hello, attemptID: UUID())
      }
      await transport.stop()
      await host.stop()
    }

    @Test func disconnectCancelsAHandshakeWaitingForWelcome() async throws {
      let parameters = NWParametersBuilder.parameters { hostControlStack() }
        .localEndpoint(.hostPort(host: "127.0.0.1", port: .any))
        .localOnly(true)
        .peerToPeerIncluded(false)
      let listener = try NetworkListener<HostControlProtocol>(for: nil, using: parameters)
      let server = StalledHandshakeServer()
      let listenerTask = Task {
        try? await listener.run { connection in
          await server.handle(connection)
        }
      }
      defer { listenerTask.cancel() }
      try await waitUntilAsync { (listener.port?.rawValue ?? 0) != 0 }
      let port = try #require(listener.port?.rawValue)
      let client = PartyClient(displayName: "Cancelled Handshake")
      let connectTask = Task { await client.connect(host: "127.0.0.1", port: port) }

      try await waitUntilAsync { await server.receivedHello }
      await client.disconnect()
      await connectTask.value

      #expect(client.state == .browsing)
      try await waitUntilAsync(timeout: .seconds(1)) {
        await server.activeConnections == 0
      }
    }

    @Test func cancellationAfterWelcomeSendsLeave() async throws {
      let parameters = NWParametersBuilder.parameters { hostControlStack() }
        .localEndpoint(.hostPort(host: "127.0.0.1", port: .any))
        .localOnly(true)
        .peerToPeerIncluded(false)
      let listener = try NetworkListener<HostControlProtocol>(for: nil, using: parameters)
      let server = WelcomingHandshakeServer()
      let listenerTask = Task {
        try? await listener.run { connection in
          await server.handle(connection)
        }
      }
      defer { listenerTask.cancel() }
      try await waitUntilAsync { (listener.port?.rawValue ?? 0) != 0 }
      let port = try #require(listener.port?.rawValue)
      let gate = HandshakeResponseGate()
      let transport = ClientTransport(handshakeResponseHook: { response in
        guard case .welcome = response else { return }
        await gate.pause()
      })
      let target = try DiscoveredHost(host: "127.0.0.1", port: port)
      let attemptID = UUID()
      let connectTask = Task {
        try await transport.connect(
          to: target,
          hello: Hello(controllerID: ControllerID(), displayName: "Cancelled"),
          attemptID: attemptID
        )
      }
      defer {
        connectTask.cancel()
        Task {
          await gate.resume()
          await transport.stop()
        }
      }

      try await waitUntilAsync { await gate.isPaused }
      await transport.cancelConnectionAttempt(attemptID)
      await gate.resume()
      await #expect(throws: CancellationError.self) {
        try await connectTask.value
      }
      try await waitUntilAsync(timeout: .seconds(1)) { await server.receivedLeave }
      await transport.stop()
    }

    @Test func hostAndClientCanRestartWithFreshEventSubscriptions() async throws {
      let host = PartyHost(reconnectGrace: .milliseconds(100))
      let client = PartyClient(displayName: "Restarter")

      let firstPort = try await host.start(hostName: "First Lifecycle", advertise: false)
      await client.connect(host: "127.0.0.1", port: firstPort)
      try await waitUntil { host.players.count == 1 }
      await client.stop()
      await host.stop()

      let secondPort = try await host.start(hostName: "Second Lifecycle", advertise: false)
      await client.connect(host: "127.0.0.1", port: secondPort)
      try await waitUntil { host.players.count == 1 }

      #expect(host.players.first?.displayName == "Restarter")
      await client.stop()
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
      try await waitUntil { host.players.count == PartyNetConstants.maximumControllers }
      #expect(host.players.count == PartyNetConstants.maximumControllers)

      let ninth = PartyClient(displayName: "Ninth")
      await ninth.connect(host: "127.0.0.1", port: port)
      guard case .rejected = ninth.state else {
        Issue.record("Expected the ninth controller to be rejected")
        await host.stop()
        return
      }
      ninth.reconnectAfterForeground()
      try await Task.sleep(for: .milliseconds(100))
      guard case .rejected = ninth.state else {
        Issue.record("A rejected controller must not reconnect after foregrounding")
        await host.stop()
        return
      }

      for client in clients { await client.disconnect() }
      await ninth.disconnect()
      await host.stop()
    }

    @Test func admitsEightConcurrentControllersWithUniqueSlots() async throws {
      let host = PartyHost()
      let port = try await host.start(hostName: "Concurrent Capacity Host", advertise: false)
      let clients = (0..<PartyNetConstants.maximumControllers).map {
        PartyClient(displayName: "Concurrent \($0 + 1)")
      }

      await withTaskGroup(of: Void.self) { group in
        for client in clients {
          group.addTask { await client.connect(host: "127.0.0.1", port: port) }
        }
      }
      try await waitUntil { host.players.count == PartyNetConstants.maximumControllers }

      #expect(Set(host.players.map(\.id)).count == PartyNetConstants.maximumControllers)
      #expect(host.players.allSatisfy { $0.isConnected })
      for client in clients { await client.disconnect() }
      await host.stop()
    }

    @Test func propagatesRosterLayoutFeedbackMenuAndPing() async throws {
      let host = PartyHost()
      let port = try await host.start(hostName: "Propagation Host", advertise: false)
      let client = PartyClient(displayName: "Signals")
      let recorder = EventRecorder()
      let clientEvents = Task {
        for await event in client.events { await recorder.record(event) }
      }
      let hostEvents = Task {
        for await event in host.events { await recorder.record(event) }
      }
      defer {
        clientEvents.cancel()
        hostEvents.cancel()
      }

      await client.connect(host: "127.0.0.1", port: port)
      try await waitUntil { client.roster.count == 1 }
      let spectatorLayout = ControllerLayout.spectator(SpectatorLayout(queuePosition: 3))
      await host.send(.layout(spectatorLayout), to: PlayerID(0))
      await host.send(.feedback(.paddleHit), to: PlayerID(0))
      await client.sendMenu(.right)
      client.reconnectAfterForeground()

      try await waitUntil {
        client.layout == spectatorLayout && client.rttSampleCount > 0
      }
      try await waitUntilAsync {
        await recorder.contains(feedback: [.paddleHit], menu: [.right])
      }

      await client.disconnect()
      await host.stop()
    }

    @Test func repeatedPaddleLayoutNeutralizesTheObservableControllerAxis() async throws {
      let host = PartyHost()
      let port = try await host.start(hostName: "Paddle Reset Host", advertise: false)
      let client = PartyClient(displayName: "Paddle")
      await client.connect(host: "127.0.0.1", port: port)
      let layout = ControllerLayout.paddle(PaddleLayout(
        edge: .bottom,
        colorHex: "#32E6FF",
        label: "P1 Paddle"
      ))

      await host.send(.layout(layout), to: PlayerID(0))
      try await waitUntil { client.layout == layout }
      client.setInput(axisX: 0.75)
      #expect(client.inputAxisX == 0.75)

      await host.send(.layout(layout), to: PlayerID(0))
      try await waitUntil { client.inputAxisX == 0 }

      await client.disconnect()
      await host.stop()
    }

    @Test func expirationEventPreservesThePlayersDisplayName() async throws {
      let host = PartyHost()
      let recorder = EventRecorder()
      let stream = host.events
      let eventTask = Task {
        for await event in stream { await recorder.record(event) }
      }
      defer { eventTask.cancel() }
      let port = try await host.start(hostName: "Expiry Event Host", advertise: false)
      let client = PartyClient(displayName: "Named Departure")

      await client.connect(host: "127.0.0.1", port: port)
      try await waitUntil { host.players.count == 1 }
      await client.disconnect()
      try await waitUntilAsync {
        await recorder.containsExpiredPlayer(named: "Named Departure")
      }

      await host.stop()
    }

    @Test func bonjourPublishesServiceNameVersionAndInstanceID() async throws {
      let serviceName = "PartyBox Metadata \(UUID().uuidString.prefix(8))"
      let host = PartyHost()
      _ = try await host.start(hostName: serviceName, advertise: true)
      let client = PartyClient(displayName: "Browser")
      await client.startBrowsing()

      try await waitUntil(timeout: .seconds(8)) {
        client.hosts.contains { $0.instanceID == host.hostInstanceID }
      }
      let discovered = try #require(client.hosts.first { $0.instanceID == host.hostInstanceID })
      #expect(discovered.name == serviceName)
      #expect(discovered.protocolVersion == PartyNetConstants.protocolVersion)
      #expect(discovered.isCompatible)

      await client.stop()
      await host.stop()
    }

    @Test func rapidInputUpdatesPreserveTheLatestValue() async throws {
      let host = PartyHost()
      let port = try await host.start(hostName: "Ordered Input Host", advertise: false)
      let client = PartyClient(displayName: "Rapid Input", inputSendInterval: .milliseconds(1))
      await client.connect(host: "127.0.0.1", port: port)

      for index in 0..<500 {
        client.setInput(axisX: Float(index) / 500)
      }
      client.setInput(axisX: -0.875)

      try await waitUntil { host.inputs.snapshot()[PlayerID(0)]?.axisX == -0.875 }
      await client.disconnect()
      await host.stop()
    }

    @Test func duplicateIdentityReplacesConnectionAndKeepsPlayer() async throws {
      let host = PartyHost(reconnectGrace: .milliseconds(200))
      let port = try await host.start(hostName: "Duplicate Host", advertise: false)
      let controllerID = ControllerID(
        rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
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

    @Test func connectingToAnotherHostReplacesTheActiveSession() async throws {
      let firstHost = PartyHost(reconnectGrace: .milliseconds(100))
      let secondHost = PartyHost(reconnectGrace: .milliseconds(100))
      let firstPort = try await firstHost.start(hostName: "First Host", advertise: false)
      let secondPort = try await secondHost.start(hostName: "Second Host", advertise: false)
      let client = PartyClient(displayName: "Mover")

      await client.connect(host: "127.0.0.1", port: firstPort)
      try await waitUntil { firstHost.players.count == 1 }
      await client.connect(host: "127.0.0.1", port: secondPort)

      try await waitUntil { firstHost.players.isEmpty && secondHost.players.count == 1 }
      #expect(client.player?.id == PlayerID(0))
      await client.disconnect()
      await firstHost.stop()
      await secondHost.stop()
    }

    @Test func foregroundRecoveryProbesLiveConnectionButHonorsExplicitDisconnect() async throws {
      let host = PartyHost()
      let port = try await host.start(hostName: "Foreground Host", advertise: false)
      let client = PartyClient(displayName: "Foreground")
      await client.connect(host: "127.0.0.1", port: port)

      client.reconnectAfterForeground()
      try await waitUntil(timeout: .seconds(1)) { client.rttSampleCount > 0 }
      guard case .connected = client.state else {
        Issue.record("Expected a healthy foreground probe to preserve the connection")
        await host.stop()
        return
      }

      await client.disconnect()
      client.reconnectAfterForeground()
      try await Task.sleep(for: .milliseconds(100))
      #expect(client.state == .browsing)
      #expect(host.players.isEmpty)
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
      try #require(condition())
    }

    private func waitUntilAsync(
      timeout: Duration = .seconds(3),
      condition: @escaping @Sendable () async -> Bool
    ) async throws {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: timeout)
      while !(await condition()), clock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
      }
      try #require(await condition())
    }

    private func settle() async {
      for _ in 0..<10 { await Task.yield() }
    }
  }
}
