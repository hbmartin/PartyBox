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
      private(set) var receivedHelloCount = 0
      private let udpPort: UInt16

      init(udpPort: UInt16 = 9) {
        self.udpPort = udpPort
      }

      func handle(_ connection: HostControlConnection) async {
        do {
          let first = try await connection.receive().content
          guard case .hello = first else { return }
          receivedHelloCount += 1
          let welcome = Welcome(
            player: PlayerInfo(id: PlayerID(0), displayName: "Cancelled", colorHex: "#32E6FF"),
            udpPort: udpPort,
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

    private actor WriteProbe {
      private(set) var started = false
      private(set) var count = 0

      func markStarted() {
        started = true
        count += 1
      }

      func markStartedAndReturnCount() -> Int {
        started = true
        count += 1
        return count
      }
    }

    private actor CompletionProbe {
      private(set) var completed = false

      func markCompleted() {
        completed = true
      }
    }

    private actor WriteFault {
      private var enabled = false

      func enable() {
        enabled = true
      }

      func shouldFail() -> Bool {
        enabled
      }
    }

    private enum InjectedWriteError: Error {
      case failed
    }

    private actor EventRecorder {
      private(set) var clientPayloads: [Data] = []
      private(set) var hostPayloads: [Data] = []
      private(set) var expiredPlayers: [PlayerInfo] = []

      func record(_ event: ClientEvent) {
        if case .application(let value) = event { clientPayloads.append(value) }
      }

      func record(_ event: HostEvent) {
        switch event {
        case .application(_, let payload):
          hostPayloads.append(payload)
        case .playerExpired(let player, _):
          expiredPlayers.append(player)
        default:
          break
        }
      }

      func contains(client expectedClient: Data, host expectedHost: Data) -> Bool {
        clientPayloads.contains(expectedClient) && hostPayloads.contains(expectedHost)
      }

      func containsExpiredPlayer(named name: String) -> Bool {
        expiredPlayers.contains { $0.displayName == name && !$0.isConnected }
      }

      func contains(host payload: Data) -> Bool {
        hostPayloads.contains(payload)
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

    @Test func rejectsAWelcomeWithZeroUDPPort() async throws {
      let parameters = NWParametersBuilder.parameters { hostControlStack() }
        .localEndpoint(.hostPort(host: "127.0.0.1", port: .any))
        .localOnly(true)
        .peerToPeerIncluded(false)
      let listener = try NetworkListener<HostControlProtocol>(for: nil, using: parameters)
      let server = WelcomingHandshakeServer(udpPort: 0)
      let listenerTask = Task {
        try? await listener.run { connection in await server.handle(connection) }
      }
      defer { listenerTask.cancel() }
      try await waitUntilAsync { (listener.port?.rawValue ?? 0) != 0 }
      let transport = ClientTransport()
      let target = try DiscoveredHost(
        host: "127.0.0.1",
        port: try #require(listener.port?.rawValue)
      )

      await #expect(throws: PartyNetTransportError.self) {
        _ = try await transport.connect(
          to: target,
          hello: Hello(controllerID: ControllerID(), displayName: "Zero UDP"),
          attemptID: UUID()
        )
      }
      await transport.stop()
    }

    @Test func staleBrowserFailureCannotPoisonANewerBrowserGeneration() async throws {
      let transport = ClientTransport()
      await transport.startBrowsing()
      let staleGeneration = try #require(await transport.browserGenerationForTesting())
      await transport.restartBrowsing()
      let currentGeneration = try #require(await transport.browserGenerationForTesting())
      #expect(currentGeneration != staleGeneration)

      await transport.simulateDiscoveryFailureForTesting(generation: staleGeneration)
      #expect(await transport.discoveryFailurePublicationCountForTesting() == 0)
      await transport.simulateDiscoveryFailureForTesting(generation: currentGeneration)
      #expect(await transport.discoveryFailurePublicationCountForTesting() == 1)
      await transport.stop()
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
      let gate = NthCallGate(blockedCall: 1)
      let transport = ClientTransport(handshakeResponseHook: { response in
        guard case .welcome = response else { return }
        await gate.pauseIfNeeded()
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
          await gate.open()
          await transport.stop()
        }
      }

      try await waitUntilAsync { await gate.isBlocking }
      await transport.cancelConnectionAttempt(attemptID)
      await gate.open()
      await #expect(throws: CancellationError.self) {
        try await connectTask.value
      }
      try await waitUntilAsync(timeout: .seconds(1)) { await server.receivedLeave }
      await transport.stop()
    }

    @Test func stoppingPartyClientWaitsForItsLeaveWrite() async throws {
      let parameters = NWParametersBuilder.parameters { hostControlStack() }
        .localEndpoint(.hostPort(host: "127.0.0.1", port: .any))
        .localOnly(true)
        .peerToPeerIncluded(false)
      let listener = try NetworkListener<HostControlProtocol>(for: nil, using: parameters)
      let server = WelcomingHandshakeServer()
      let listenerTask = Task {
        try? await listener.run { connection in await server.handle(connection) }
      }
      defer { listenerTask.cancel() }
      try await waitUntilAsync { (listener.port?.rawValue ?? 0) != 0 }
      let client = PartyClient(displayName: "Graceful Stop")
      await client.connect(
        host: "127.0.0.1",
        port: try #require(listener.port?.rawValue)
      )

      await client.stop()

      try await waitUntilAsync(timeout: .seconds(1)) { await server.receivedLeave }
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

    @Test func reconnectStartsFreshHostInputActivity() async throws {
      let host = PartyHost(reconnectGrace: .seconds(2))
      let controllerID = ControllerID()
      let original = PartyClient(
        controllerID: controllerID,
        displayName: "Original",
        inputSendInterval: .milliseconds(5)
      )
      let replacement = PartyClient(
        controllerID: controllerID,
        displayName: "Replacement",
        inputSendInterval: .milliseconds(5)
      )
      let port = try await host.start(hostName: "Input Activity Host", advertise: false)

      do {
        await original.connect(host: "127.0.0.1", port: port)
        original.setInput(axisX: -0.8)
        try await waitUntil {
          host.inputs.activitySnapshot().first?.minimumAxisX == -0.8
        }
        original.setInput(axisX: 0.8)
        try await waitUntil {
          host.inputs.activitySnapshot().first?.maximumAxisX == 0.8
        }

        await original.interruptForTesting()
        try await waitUntil { host.players.first?.isConnected == false }
        await replacement.connect(host: "127.0.0.1", port: port)
        try await waitUntil {
          host.inputs.activitySnapshot().first != nil
        }

        let activity = try #require(host.inputs.activitySnapshot().first)
        #expect(activity.minimumAxisX == 0)
        #expect(activity.maximumAxisX == 0)

        await replacement.stop()
        await original.stop()
        await host.stop()
      } catch {
        await replacement.stop()
        await original.stop()
        await host.stop()
        throw error
      }
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

    @Test func propagatesOpaqueApplicationPayloadsAndPing() async throws {
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
      try await waitUntil { host.players.count == 1 }
      let hostPayload = Data("host presentation".utf8)
      let clientPayload = Data("controller command".utf8)
      await host.send(.application(hostPayload), to: PlayerID(0))
      #expect(await client.sendApplication(clientPayload))
      client.reconnectAfterForeground()

      try await waitUntil { client.rttSampleCount > 0 }
      try await waitUntilAsync {
        await recorder.contains(client: hostPayload, host: clientPayload)
      }

      await client.disconnect()
      await host.stop()
    }

    @Test func stalledPingResponseDoesNotBlockOtherHostEvents() async throws {
      let stalledResponse = WriteProbe()
      let host = PartyHost(transportFactory: { inputs in
        HostTransport(
          inputs: inputs,
          controlSender: { connection, message in
            if case .pingResponse = message {
              await stalledResponse.markStarted()
              try await Task.sleep(for: .seconds(30))
              return
            }
            try await connection.send(message)
          }
        )
      })
      let recorder = EventRecorder()
      let hostEvents = Task {
        for await event in host.events { await recorder.record(event) }
      }
      let port = try await host.start(hostName: "Nonblocking Events Host", advertise: false)
      let stalledClient = PartyClient(displayName: "Stalled Ping")
      let activeClient = PartyClient(displayName: "Active Sender")
      defer {
        hostEvents.cancel()
        Task {
          await stalledClient.stop()
          await activeClient.stop()
          await host.stop()
        }
      }
      await stalledClient.connect(host: "127.0.0.1", port: port)
      await activeClient.connect(host: "127.0.0.1", port: port)
      try await waitUntil { host.players.count == 2 }

      stalledClient.reconnectAfterForeground()
      try await waitUntilAsync { await stalledResponse.started }
      let payload = Data("not blocked".utf8)
      #expect(await activeClient.sendApplication(payload))

      try await waitUntilAsync(timeout: .seconds(1)) {
        await recorder.contains(host: payload)
      }

      await stalledClient.stop()
      await activeClient.stop()
      await host.stop()
      hostEvents.cancel()
    }

    @Test func stalledPingWriterPreservesEveryQueuedResponseNonce() async throws {
      let gate = NthCallGate(blockedCall: 1)
      let host = PartyHost(transportFactory: { inputs in
        HostTransport(
          inputs: inputs,
          controlSender: { connection, message in
            if message == .pingResponse(1) {
              await gate.pauseIfNeeded()
            }
            try await connection.send(message)
          }
        )
      })
      let port = try await host.start(hostName: "Queued Ping Host", advertise: false)
      do {
        let connection = ClientControlConnection(
          to: .hostPort(host: "127.0.0.1", port: try #require(.init(rawValue: port))),
          using: .parameters { clientControlStack() }.peerToPeerIncluded(false)
        )
        try await connection.send(
          .hello(
            Hello(
              controllerID: ControllerID(),
              displayName: "Probe Tester"
            )))
        guard case .welcome = try await connection.receive().content else {
          Issue.record("Expected the raw controller to be welcomed")
          await host.stop()
          return
        }

        try await connection.send(.ping(1))
        try await waitUntilAsync { await gate.isBlocking }
        try await connection.send(.ping(2))
        await gate.open()

        let first = try await withTimeout(.seconds(1), operationName: "receiving first ping echo") {
          try await connection.receive().content
        }
        let second = try await withTimeout(.seconds(1), operationName: "receiving second ping echo") {
          try await connection.receive().content
        }
        #expect(first == .pingResponse(1))
        #expect(second == .pingResponse(2))
        await gate.open()
        await host.stop()
      } catch {
        await gate.open()
        await host.stop()
        throw error
      }
    }

    @Test func excessControlHandlerIsClosedPromptly() async throws {
      let transport = HostTransport(inputs: InputStore())
      let stream = transport.eventStream(onOverflow: {})
      let eventConsumer = Task {
        for await _ in stream {}
      }
      let port = try await transport.start(
        hostName: "Handler Capacity Host",
        hostInstanceID: UUID(),
        advertise: false
      )
      let capacity = await transport.controlHandlerCapacityForTesting
      var heldConnections: [ClientControlConnection] = []
      for index in 0..<capacity {
        let connection = ClientControlConnection(
          to: .hostPort(host: "127.0.0.1", port: try #require(.init(rawValue: port))),
          using: .parameters { clientControlStack() }.peerToPeerIncluded(false)
        )
        try await connection.send(.hello(Hello(
          controllerID: ControllerID(),
          displayName: "Held \(index)"
        )))
        heldConnections.append(connection)
      }
      try await waitUntilAsync {
        await transport.controlHandlerCountForTesting == capacity
      }

      let overflow = ClientControlConnection(
        to: .hostPort(host: "127.0.0.1", port: try #require(.init(rawValue: port))),
        using: .parameters { clientControlStack() }.peerToPeerIncluded(false)
      )
      try await overflow.send(.hello(Hello(
        controllerID: ControllerID(),
        displayName: "Overflow"
      )))
      do {
        _ = try await withTimeout(
          .seconds(1),
          operationName: "waiting for an over-capacity connection to close"
        ) {
          try await overflow.receive().content
        }
        Issue.record("An over-capacity control connection unexpectedly remained usable")
      } catch let error as PartyNetTransportError {
        if case .timedOut = error {
          Issue.record("An over-capacity control connection hung until the test timeout")
        }
      } catch {
        // The rejected flow closed promptly, which is the required behavior.
      }

      _ = heldConnections
      await transport.stop()
      eventConsumer.cancel()
      await eventConsumer.value
    }

    @Test func stalledWelcomeDoesNotBlockAnotherControllerHandshake() async throws {
      let welcomeWrites = WriteProbe()
      let host = PartyHost(transportFactory: { inputs in
        HostTransport(
          inputs: inputs,
          controlSender: { connection, message in
            if case .welcome = message,
              await welcomeWrites.markStartedAndReturnCount() == 1
            {
              try await Task.sleep(for: .seconds(30))
              return
            }
            try await connection.send(message)
          }
        )
      })
      let port = try await host.start(hostName: "Nonblocking Welcome Host", advertise: false)
      let stalledClient = PartyClient(displayName: "Stalled Welcome")
      let activeClient = PartyClient(displayName: "Active Welcome")
      let stalledConnect = Task {
        await stalledClient.connect(host: "127.0.0.1", port: port)
      }
      defer {
        stalledConnect.cancel()
        Task {
          await stalledClient.stop()
          await activeClient.stop()
          await host.stop()
        }
      }
      try await waitUntilAsync { await welcomeWrites.started }

      let connectStarted = ContinuousClock().now
      await activeClient.connect(host: "127.0.0.1", port: port)

      #expect(connectStarted.duration(to: ContinuousClock().now) < .seconds(1))
      guard case .connected = activeClient.state else {
        Issue.record("A separate stalled welcome blocked the healthy controller handshake")
        return
      }
      #expect(host.players.contains { $0.displayName == "Active Welcome" })
      await stalledClient.stop()
      await activeClient.stop()
      await host.stop()
      stalledConnect.cancel()
      await stalledConnect.value
    }

    @Test func repeatedApplicationPayloadPreservesTheObservableControllerAxis() async throws {
      let host = PartyHost()
      let port = try await host.start(hostName: "Paddle Reset Host", advertise: false)
      let client = PartyClient(displayName: "Paddle")
      await client.connect(host: "127.0.0.1", port: port)
      let payload = Data("same presentation".utf8)
      await host.send(.application(payload), to: PlayerID(0))
      try await waitUntil { host.players.count == 1 }
      client.setInput(axisX: 0.75)
      #expect(client.inputAxisX == 0.75)

      let pingCount = client.rttSampleCount
      await host.send(.application(payload), to: PlayerID(0))
      await host.send(.pingResponse(DispatchTime.now().uptimeNanoseconds), to: PlayerID(0))
      try await Task.sleep(for: .milliseconds(100))
      #expect(client.rttSampleCount == pingCount)
      #expect(client.inputAxisX == 0.75)

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
      let firstHostPeer = PartyClient(displayName: "Old Host Peer")

      await client.connect(host: "127.0.0.1", port: firstPort)
      await firstHostPeer.connect(host: "127.0.0.1", port: firstPort)
      try await waitUntil { firstHost.players.count == 2 }
      client.setInput(axisX: 0.625)

      await client.connect(host: "127.0.0.1", port: secondPort)

      try await waitUntil {
        firstHost.players.count == 1 && secondHost.players.count == 1
      }
      #expect(client.player?.id == PlayerID(0))
      #expect(client.inputAxisX == 0)
      await firstHostPeer.disconnect()
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

      client.setInput(axisX: 0.5)
      await client.disconnect()
      client.reconnectAfterForeground()
      try await Task.sleep(for: .milliseconds(100))
      #expect(client.state == .browsing)
      #expect(client.rttMilliseconds == nil)
      #expect(client.rttSampleCount == 0)
      #expect(client.inputAxisX == 0)
      #expect(host.players.isEmpty)
      await host.stop()
    }

    @Test func activeHostTransportReleasesWithoutExplicitStop() async throws {
      weak var weakHostTransport: HostTransport?
      do {
        let transport = HostTransport(inputs: InputStore())
        weakHostTransport = transport
        _ = try await transport.start(
          hostName: "Transport Lifetime Host",
          hostInstanceID: UUID(),
          advertise: false
        )
      }
      try await waitUntil { weakHostTransport == nil }
    }

    @Test func handshakingHostTransportReleasesWithoutExplicitStop() async throws {
      weak var weakHandshakingTransport: HostTransport?
      do {
        let transport = HostTransport(inputs: InputStore())
        weakHandshakingTransport = transport
        let stream = transport.eventStream(onOverflow: {})
        let port = try await transport.start(
          hostName: "Handshake Lifetime Host",
          hostInstanceID: UUID(),
          advertise: false
        )
        let connection = ClientControlConnection(
          to: .hostPort(host: "127.0.0.1", port: try #require(.init(rawValue: port))),
          using: .parameters { clientControlStack() }.peerToPeerIncluded(false)
        )
        try await connection.send(.hello(Hello(
          controllerID: ControllerID(),
          displayName: "Pending Handshake"
        )))
        var iterator = stream.makeAsyncIterator()
        guard case .hello = await iterator.next() else {
          Issue.record("Expected the transport to receive the pending handshake")
          return
        }
      }
      try await waitUntil { weakHandshakingTransport == nil }
    }

    @Test func activeClientTransportReleasesWithoutExplicitStop() async throws {
      weak var weakClientTransport: ClientTransport?
      do {
        let transport = ClientTransport()
        weakClientTransport = transport
        await transport.startBrowsing()
      }
      try await waitUntil { weakClientTransport == nil }
    }

    @Test func activePartyHostReleasesWithoutExplicitStop() async throws {
      weak var weakHost: PartyHost?
      do {
        let host = PartyHost()
        weakHost = host
        _ = try await host.start(hostName: "Host Lifetime", advertise: false)
      }
      try await waitUntil { weakHost == nil }
    }

    @Test func activePartyClientReleasesWithoutExplicitStop() async throws {
      weak var weakClient: PartyClient?
      do {
        let client = PartyClient(displayName: "Client Lifetime")
        weakClient = client
        await client.startBrowsing()
      }
      try await waitUntil { weakClient == nil }
    }

    @Test func stoppingAHostTransportFinishesItsCurrentEventStream() async {
      let transport = HostTransport(inputs: InputStore())
      let stream = transport.eventStream(onOverflow: {})

      await transport.stop()

      var iterator = stream.makeAsyncIterator()
      #expect(await iterator.next() == nil)
    }

    @Test func stalledInputAcknowledgmentDoesNotBlockFollowingDatagrams() async throws {
      let acknowledgmentWrite = WriteProbe()
      let inputs = InputStore()
      let transport = HostTransport(
        inputs: inputs,
        controlSender: { connection, message in
          if case .inputAck = message {
            if await acknowledgmentWrite.markStartedAndReturnCount() == 1 {
              try await Task.sleep(for: .seconds(30))
              return
            }
          }
          try await connection.send(message)
        }
      )
      let stream = transport.eventStream(onOverflow: {})
      let tcpPort = try await transport.start(
        hostName: "Acknowledgment Test Host",
        hostInstanceID: UUID(),
        advertise: false
      )
      let controlConnection = ClientControlConnection(
        to: .hostPort(
          host: "127.0.0.1",
          port: try #require(.init(rawValue: tcpPort))
        ),
        using: .parameters { clientControlStack() }.peerToPeerIncluded(false)
      )
      try await controlConnection.send(.hello(Hello(
        controllerID: ControllerID(),
        displayName: "Input Tester"
      )))
      var eventIterator = stream.makeAsyncIterator()
      guard case .hello(let connectionID, _) = await eventIterator.next() else {
        Issue.record("Expected the transport to receive the controller hello")
        await transport.stop()
        return
      }
      let udpPortValue = try #require(await transport.udpPort)
      let token: UInt64 = 123
      let welcomed = await transport.respond(
        to: connectionID,
        with: .accept(Welcome(
          player: PlayerInfo(
            id: PlayerID(0),
            displayName: "Input Tester",
            colorHex: "#32E6FF"
          ),
          udpPort: udpPortValue,
          sessionToken: token,
          hostName: "Acknowledgment Test Host",
          hostInstanceID: UUID()
        ))
      )
      #expect(welcomed)
      _ = try await controlConnection.receive().content

      let datagramConnection = NetworkConnection<UDP>(
        to: .hostPort(
          host: "127.0.0.1",
          port: try #require(.init(rawValue: udpPortValue))
        ),
        using: .parameters { UDP() }.peerToPeerIncluded(false)
      )
      try await datagramConnection.send(InputFrame(
        token: token,
        sequence: 0,
        clientTimeMs: 0,
        axisX: 0.1,
        axisY: 0
      ).encode())
      try await waitUntilAsync { await acknowledgmentWrite.started }

      try await datagramConnection.send(InputFrame(
        token: token,
        sequence: 1,
        clientTimeMs: 1,
        axisX: 0.8,
        axisY: 0
      ).encode())
      try await waitUntilAsync {
        inputs.snapshot()[PlayerID(0)]?.axisX == 0.8
      }
      let acknowledgment = try await withTimeout(
        .seconds(1),
        operationName: "waiting for a coalesced input acknowledgment"
      ) {
        try await controlConnection.receive().content
      }
      #expect(acknowledgment == .inputAck(sequence: 1))
      await transport.stop()
    }

    @Test func terminalHostWriteErrorImmediatelyRetiresTheConnection() async throws {
      let writeFault = WriteFault()
      let transport = HostTransport(
        inputs: InputStore(),
        controlSender: { connection, message in
          if await writeFault.shouldFail() { throw InjectedWriteError.failed }
          try await connection.send(message)
        }
      )
      let stream = transport.eventStream(onOverflow: {})
      let port = try await transport.start(
        hostName: "Write Failure Host",
        hostInstanceID: UUID(),
        advertise: false
      )
      let connection = ClientControlConnection(
        to: .hostPort(host: "127.0.0.1", port: try #require(.init(rawValue: port))),
        using: .parameters { clientControlStack() }.peerToPeerIncluded(false)
      )
      try await connection.send(.hello(Hello(
        controllerID: ControllerID(),
        displayName: "Write Failure"
      )))
      var iterator = stream.makeAsyncIterator()
      guard case .hello(let connectionID, _) = await iterator.next() else {
        Issue.record("Expected the transport to receive the controller hello")
        await transport.stop()
        return
      }
      let udpPort = try #require(await transport.udpPort)
      #expect(await transport.respond(
        to: connectionID,
        with: .accept(Welcome(
          player: PlayerInfo(id: PlayerID(0), displayName: "Write Failure", colorHex: "#32E6FF"),
          udpPort: udpPort,
          sessionToken: 456,
          hostName: "Write Failure Host",
          hostInstanceID: UUID()
        ))
      ))
      _ = try await connection.receive().content
      await writeFault.enable()

      await #expect(throws: InjectedWriteError.self) {
        try await transport.send(.application(Data([1])), to: connectionID)
      }
      await #expect(throws: PartyNetTransportError.self) {
        try await transport.send(.application(Data([1])), to: connectionID)
      }
      await transport.stop()
    }

    @Test func stoppingTheHostCancelsInFlightBroadcastWrites() async throws {
      let broadcastWrites = WriteProbe()
      let completion = CompletionProbe()
      let host = PartyHost(transportFactory: { inputs in
        HostTransport(
          inputs: inputs,
          controlSender: { connection, message in
            if case .application = message {
              await broadcastWrites.markStarted()
              try await Task.sleep(for: .seconds(30))
              return
            }
            try await connection.send(message)
          }
        )
      })
      let port = try await host.start(hostName: "Broadcast Cancellation Host", advertise: false)
      let first = PartyClient(displayName: "First")
      let second = PartyClient(displayName: "Second")
      await first.connect(host: "127.0.0.1", port: port)
      await second.connect(host: "127.0.0.1", port: port)
      try await waitUntil { host.players.count == 2 }

      let broadcastTask = Task {
        await host.broadcast(.application(Data([1])))
        await completion.markCompleted()
      }
      defer { broadcastTask.cancel() }
      try await waitUntilAsync { await broadcastWrites.count == 2 }
      await host.stop()
      try await waitUntilAsync(timeout: .seconds(1)) { await completion.completed }
      await broadcastTask.value

      await first.stop()
      await second.stop()
    }

    @Test func foregroundProbeTrackingKeepsOnlyTheLatestNonce() async throws {
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
      let target = try DiscoveredHost(
        host: "127.0.0.1",
        port: try #require(listener.port?.rawValue)
      )
      let transport = ClientTransport()
      let (connectionID, _) = try await transport.connect(
        to: target,
        hello: Hello(controllerID: ControllerID(), displayName: "Probe Tracker"),
        attemptID: UUID()
      )

      try await transport.send(.ping(11), connectionID: connectionID)
      try await transport.send(.ping(22), connectionID: connectionID)

      #expect(await transport.explicitProbeNonceForTesting(connectionID: connectionID) == 22)
      await transport.disconnect(connectionID: connectionID, sendLeave: false)
      await transport.stop()
    }

    @Test func clientControlWriteTimesOutAndRetiresTheSession() async throws {
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
      let clock = TestClock()
      let stalledWrite = WriteProbe()

      try await withDependencies {
        $0.continuousClock = clock
      } operation: {
        let transport = ClientTransport(controlSender: { connection, message in
          if case .hello = message {
            try await connection.send(message)
            return
          }
          await stalledWrite.markStarted()
          try await clock.sleep(for: .seconds(30))
        })
        let target = try DiscoveredHost(host: "127.0.0.1", port: port)
        let (connectionID, _) = try await runWhileAdvancingTestClock(clock) {
          try await transport.connect(
            to: target,
            hello: Hello(controllerID: ControllerID(), displayName: "Timeout Tester"),
            attemptID: UUID()
          )
        }
        let sendTask = Task {
          try await transport.send(.application(Data([1])), connectionID: connectionID)
        }
        try await waitUntilAsync { await stalledWrite.started }
        await clock.advance(by: PartyNetConstants.helloTimeout)
        await settle()

        await #expect(throws: PartyNetTransportError.self) {
          try await sendTask.value
        }
        await #expect(throws: PartyNetTransportError.self) {
          try await transport.send(.application(Data([1])), connectionID: connectionID)
        }
        await transport.stop()
      }
    }

    @Test func replacingASessionDoesNotWaitForThePreviousLeaveWrite() async throws {
      let parameters = NWParametersBuilder.parameters { hostControlStack() }
        .localEndpoint(.hostPort(host: "127.0.0.1", port: .any))
        .localOnly(true)
        .peerToPeerIncluded(false)
      let listener = try NetworkListener<HostControlProtocol>(for: nil, using: parameters)
      let server = WelcomingHandshakeServer()
      let listenerTask = Task {
        try? await listener.run { connection in await server.handle(connection) }
      }
      defer { listenerTask.cancel() }
      try await waitUntilAsync { (listener.port?.rawValue ?? 0) != 0 }
      let target = try DiscoveredHost(
        host: "127.0.0.1",
        port: try #require(listener.port?.rawValue)
      )
      let stalledLeave = WriteProbe()
      let transport = ClientTransport(controlSender: { connection, message in
        if case .leave = message {
          await stalledLeave.markStarted()
          try await Task.sleep(for: .seconds(30))
          return
        }
        try await connection.send(message)
      })

      _ = try await transport.connect(
        to: target,
        hello: Hello(controllerID: ControllerID(), displayName: "First Session"),
        attemptID: UUID()
      )
      let replacement = Task {
        try await transport.connect(
          to: target,
          hello: Hello(controllerID: ControllerID(), displayName: "Replacement Session"),
          attemptID: UUID()
        )
      }
      defer { replacement.cancel() }

      try await waitUntilAsync { await stalledLeave.started }
      try await waitUntilAsync(timeout: .seconds(1)) { await server.receivedHelloCount == 2 }
      _ = try await replacement.value
      await transport.stop()
    }

    @Test func nonterminalPingWriteErrorDoesNotRetireTheSession() async throws {
      let parameters = NWParametersBuilder.parameters { hostControlStack() }
        .localEndpoint(.hostPort(host: "127.0.0.1", port: .any))
        .localOnly(true)
        .peerToPeerIncluded(false)
      let listener = try NetworkListener<HostControlProtocol>(for: nil, using: parameters)
      let server = WelcomingHandshakeServer()
      let listenerTask = Task {
        try? await listener.run { connection in await server.handle(connection) }
      }
      defer { listenerTask.cancel() }
      try await waitUntilAsync { (listener.port?.rawValue ?? 0) != 0 }
      let clock = TestClock()
      let failedPing = WriteProbe()

      try await withDependencies {
        $0.continuousClock = clock
      } operation: {
        let transport = ClientTransport(controlSender: { connection, message in
          if case .ping = message {
            await failedPing.markStarted()
            throw EncodingError.invalidValue(
              message,
              .init(codingPath: [], debugDescription: "Injected encoding failure")
            )
          }
          try await connection.send(message)
        })
        let target = try DiscoveredHost(
          host: "127.0.0.1",
          port: try #require(listener.port?.rawValue)
        )
        let (connectionID, _) = try await runWhileAdvancingTestClock(clock) {
          try await transport.connect(
            to: target,
            hello: Hello(controllerID: ControllerID(), displayName: "Encoding Tester"),
            attemptID: UUID()
          )
        }

        await clock.advance(by: PartyNetConstants.pingInterval)
        try await waitUntilAsync { await failedPing.started }
        await clock.advance(by: PartyNetConstants.pingInterval)
        try await waitUntilAsync { await failedPing.count >= 2 }
        try await transport.send(.application(Data([1])), connectionID: connectionID)
        await transport.stop()
      }
    }

    @Test func nonterminalTCPInputWriteErrorDoesNotStopTheInputLoop() async throws {
      let parameters = NWParametersBuilder.parameters { hostControlStack() }
        .localEndpoint(.hostPort(host: "127.0.0.1", port: .any))
        .localOnly(true)
        .peerToPeerIncluded(false)
      let listener = try NetworkListener<HostControlProtocol>(for: nil, using: parameters)
      let server = WelcomingHandshakeServer()
      let listenerTask = Task {
        try? await listener.run { connection in await server.handle(connection) }
      }
      defer { listenerTask.cancel() }
      try await waitUntilAsync { (listener.port?.rawValue ?? 0) != 0 }
      let clock = TestClock()
      let failedInput = WriteProbe()

      try await withDependencies {
        $0.continuousClock = clock
      } operation: {
        let transport = ClientTransport(controlSender: { connection, message in
          if case .input = message {
            await failedInput.markStarted()
            throw EncodingError.invalidValue(
              message,
              .init(codingPath: [], debugDescription: "Injected input encoding failure")
            )
          }
          try await connection.send(message)
        })
        let target = try DiscoveredHost(
          host: "127.0.0.1",
          port: try #require(listener.port?.rawValue)
        )
        let (connectionID, _) = try await runWhileAdvancingTestClock(clock) {
          try await transport.connect(
            to: target,
            hello: Hello(controllerID: ControllerID(), displayName: "Input Encoding Tester"),
            attemptID: UUID()
          )
        }

        await clock.advance(by: PartyNetConstants.udpReadyTimeout + .milliseconds(32))
        try await waitUntilAsync { await failedInput.started }
        let firstFailureCount = await failedInput.count
        await clock.advance(by: .milliseconds(16))
        try await waitUntilAsync { await failedInput.count > firstFailureCount }
        try await transport.send(.application(Data([1])), connectionID: connectionID)
        await transport.stop()
      }
    }

    @Test func clientOverflowPreservesTerminalStateAndPresentation() async {
      let client = PartyClient(displayName: "Terminal Client")
      let player = PlayerInfo(
        id: PlayerID(0),
        displayName: "Terminal Client",
        colorHex: "#32E6FF"
      )
      for state in [PartyClientState.rejected("Full"), .disconnected("Offline")] {
        client.configureFixture(state: state, player: player)
        await client.simulateTransportEventStreamOverflowForTesting()
        #expect(client.state == state)
        #expect(client.player == player)
      }
      await client.stop()
    }

    @Test func transportEventOverflowStopsTheHostAndAllowsARestart() async throws {
      let host = PartyHost()
      let failedStream = host.events
      _ = try await host.start(hostName: "Overflow Host", advertise: false)

      await host.simulateTransportEventStreamOverflowForTesting()
      try await waitUntil { host.port == nil }

      #expect(host.port == nil)
      #expect(host.errorMessage == "The host transport event stream could not keep up.")
      var failedIterator = failedStream.makeAsyncIterator()
      guard case .failure(let message) = await failedIterator.next() else {
        Issue.record("Expected the host to publish its transport-overflow failure")
        return
      }
      #expect(message == "The host transport event stream could not keep up.")
      #expect(await failedIterator.next() == nil)

      let restartedStream = host.events
      _ = try await host.start(hostName: "Restarted Host", advertise: false)
      #expect(host.port != nil)
      #expect(host.errorMessage == nil)
      await host.stop()
      var restartedIterator = restartedStream.makeAsyncIterator()
      #expect(await restartedIterator.next() == nil)
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

    private func settle() async {
      for _ in 0..<10 { await Task.yield() }
    }
  }
}
