import DependenciesTestSupport
import Foundation
import Network
import PartyNetTestSupport
import Testing

@testable import PartyNet

extension NetworkIntegrationTests {
  @Suite(
    "Protocol-aware network fault proxy", .serialized,
    .dependency(\.continuousClock, ContinuousClock()))
  @MainActor
  struct NetworkFaultProxyTests {
    private enum DatagramSendError: Error, Sendable {
      case failed
    }

    private enum DatagramSendOutcome: Equatable, Sendable {
      case cancelledFailure
      case cancelledSuccess
      case activeCancellation
      case failure
    }

    private actor DatagramSendGate {
      private let outcome: DatagramSendOutcome
      private(set) var isStarted = false
      private(set) var isFinished = false
      private(set) var sendCount = 0
      private(set) var usedFreshConnection = false
      private var firstConnection: ObjectIdentifier?
      private var continuation: CheckedContinuation<Void, Never>?

      init(outcome: DatagramSendOutcome) {
        self.outcome = outcome
      }

      func send(on connection: NetworkConnection<UDP>) async throws {
        sendCount += 1
        let connectionID = ObjectIdentifier(connection)
        if let firstConnection {
          usedFreshConnection = usedFreshConnection || firstConnection != connectionID
        } else {
          firstConnection = connectionID
        }
        isStarted = true
        defer { isFinished = true }
        switch outcome {
        case .cancelledFailure, .cancelledSuccess:
          await withCheckedContinuation { continuation = $0 }
          if outcome == .cancelledFailure { try Task.checkCancellation() }
        case .activeCancellation:
          if sendCount == 1 { throw CancellationError() }
        case .failure:
          throw DatagramSendError.failed
        }
      }

      func resume() {
        continuation?.resume()
        continuation = nil
      }
    }

    @Test func stableUDPIsAcknowledgedAndNeverFallsBack() async throws {
      let rig = FaultRig()
      let metadata = try await rig.start()
      let client = PartyClient(displayName: "Stable")
      await client.connect(host: metadata.host, port: metadata.tcpPort)

      client.setInput(axisX: 0.375)
      try await waitUntil { rig.host.inputs.snapshot()[PlayerID(0)]?.axisX == 0.375 }
      try await Task.sleep(for: PartyNetConstants.udpReadyTimeout + .milliseconds(250))

      #expect(!client.usesTCPFallback)
      let metrics = await rig.proxy.currentMetrics()
      #expect(metrics.udpForwarded > 0)
      await client.disconnect()
      await rig.stop()
    }

    @Test func completeUDPLossFallsBackThenRecoversFromProbes() async throws {
      let rig = FaultRig(profile: FaultProfile(udpDropPolicy: .rate(1)))
      let metadata = try await rig.start()
      let client = PartyClient(displayName: "Fallback")
      await client.connect(host: metadata.host, port: metadata.tcpPort)

      client.setInput(axisX: 0.625)
      try await waitUntil(timeout: .seconds(3)) {
        client.usesTCPFallback
          && rig.host.inputs.snapshot()[PlayerID(0)]?.axisX == 0.625
      }
      let failedMetrics = await rig.proxy.currentMetrics()
      #expect(failedMetrics.udpDropped > 0)
      #expect(failedMetrics.tcpMessagesClientToHost > 0)

      await rig.proxy.setProfile(.stable)
      client.setInput(axisX: -0.5)
      try await waitUntil(timeout: .seconds(3)) {
        !client.usesTCPFallback
          && rig.host.inputs.snapshot()[PlayerID(0)]?.axisX == -0.5
      }

      await client.disconnect()
      await rig.stop()
    }

    @Test func seededLossDelayJitterAndReorderingProduceMetricsAndValidInput() async throws {
      let rig = FaultRig(
        profile: FaultProfile(
          seed: 0xC0FFEE,
          udpDropPolicy: .rate(0.2),
          delayMilliseconds: 4,
          jitterMilliseconds: 2,
          reorderWindow: 2
        ))
      let metadata = try await rig.start()
      let client = PartyClient(displayName: "Fault Metrics")
      await client.connect(host: metadata.host, port: metadata.tcpPort)

      for index in 0..<40 {
        client.setInput(axisX: Float(index) / 40)
        try await Task.sleep(for: .milliseconds(20))
      }
      try await waitUntil {
        let metrics = await rig.proxy.currentMetrics()
        return metrics.udpDropped > 0
          && metrics.udpDelayed > 0
          && metrics.udpReordered > 0
          && metrics.udpForwarded > 0
      }

      let metrics = await rig.proxy.currentMetrics()
      #expect(metrics.udpReceived >= metrics.udpDropped + metrics.udpForwarded)
      // One datagram can be held by the reorder queue while the prior datagram is
      // sleeping for its injected delay. Neither has been dropped or forwarded yet.
      #expect(metrics.udpReceived - metrics.udpDropped - metrics.udpForwarded <= 2)
      #expect(rig.host.inputs.snapshot()[PlayerID(0)] != nil)
      await client.disconnect()
      await rig.stop()
    }

    @Test func UDPDelayAddsLatencyWithoutThrottlingIngress() async throws {
      let rig = FaultRig(profile: FaultProfile(delayMilliseconds: 50))
      let metadata = try await rig.start()
      let client = PartyClient(displayName: "Delayed", inputSendInterval: .milliseconds(8))
      await client.connect(host: metadata.host, port: metadata.tcpPort)

      for index in 0..<60 {
        client.setInput(axisX: Float(index % 20) / 10 - 1)
        try await Task.sleep(for: .milliseconds(8))
      }
      try await Task.sleep(for: .milliseconds(150))

      let metrics = await rig.proxy.currentMetrics()
      #expect(metrics.udpReceived >= 30)
      #expect(metrics.udpForwarded >= 25)
      #expect(metrics.udpDelayed >= metrics.udpForwarded)
      await client.disconnect()
      await rig.stop()
    }

    @Test func UDPDelayKeepsPendingWorkBoundedPerSession() async throws {
      let rig = FaultRig(profile: FaultProfile(delayMilliseconds: 60_000))
      let metadata = try await rig.start()
      let client = PartyClient(displayName: "Bounded", inputSendInterval: .milliseconds(1))
      await client.connect(host: metadata.host, port: metadata.tcpPort)

      for index in 0..<400 {
        client.setInput(axisX: index.isMultiple(of: 2) ? -1 : 1)
        try await Task.sleep(for: .milliseconds(1))
      }
      try await waitUntil { await rig.proxy.currentMetrics().udpReceived >= 300 }

      #expect(
        await rig.proxy.pendingUDPForwardCount()
          <= NetworkFaultProxy.maximumQueuedForwardsPerToken + 1
      )
      #expect(await rig.proxy.currentMetrics().udpDropped > 0)
      await client.disconnect()
      await rig.stop()
    }

    @Test func cancelledUDPFailureDoesNotCountAsRejected() async throws {
      let metrics = try await metricsAfterControlledSend(outcome: .cancelledFailure)
      #expect(metrics.after.udpForwarded == metrics.before.udpForwarded)
      #expect(metrics.after.udpRejected == metrics.before.udpRejected)
    }

    @Test func successfulUDPCompletionIsCountedAfterWorkerCancellation() async throws {
      let metrics = try await metricsAfterControlledSend(outcome: .cancelledSuccess)
      #expect(metrics.after.udpForwarded == metrics.before.udpForwarded + 1)
      #expect(metrics.after.udpRejected == metrics.before.udpRejected)
    }

    @Test func activeUDPFailureStillCountsAsRejected() async throws {
      let metrics = try await metricsAfterControlledSend(outcome: .failure)
      #expect(metrics.after.udpForwarded == metrics.before.udpForwarded)
      #expect(metrics.after.udpRejected == metrics.before.udpRejected + 1)
    }

    @Test func activeUDPCancellationErrorStillCountsAsRejected() async throws {
      let metrics = try await metricsAfterControlledSend(
        outcome: .activeCancellation,
        retryAfterFailure: true
      )
      #expect(metrics.after.udpForwarded == metrics.before.udpForwarded + 1)
      #expect(metrics.after.udpRejected == metrics.before.udpRejected + 1)
      #expect(metrics.usedFreshConnection)
    }

    @Test func TCPCutReconnectsToSameHostInstance() async throws {
      let rig = FaultRig()
      let metadata = try await rig.start()
      let client = PartyClient(displayName: "Reconnect")
      await client.connect(host: metadata.host, port: metadata.tcpPort)
      try await waitUntil { rig.host.players.first?.isConnected == true }

      let upstreamPort = try #require(rig.host.port)
      try await rig.proxy.updateUpstream(tcpPort: 9)
      await rig.proxy.cutTCP()
      try await waitUntil { rig.host.players.first?.isConnected == false }
      #expect(rig.host.players.first?.id == PlayerID(0))

      try await rig.proxy.updateUpstream(tcpPort: upstreamPort)
      try await waitUntil(timeout: .seconds(7)) {
        if case .connected = client.state { return client.player?.id == PlayerID(0) }
        return false
      }

      await client.disconnect()
      await rig.stop()
    }

    @Test func selectiveTCPCutLeavesOtherControllerBridgeIntact() async throws {
      let rig = FaultRig()
      let metadata = try await rig.start()
      let first = PartyClient(displayName: "Cut Me")
      let second = PartyClient(displayName: "Keep Me")
      await first.connect(host: metadata.host, port: metadata.tcpPort)
      await second.connect(host: metadata.host, port: metadata.tcpPort)
      try await waitUntil {
        await rig.proxy.connectedControllerIDs() == [first.controllerID, second.controllerID]
      }

      await rig.proxy.cutTCP(controllerID: first.controllerID)
      #expect(await rig.proxy.connectedControllerIDs() == [second.controllerID])
      try await waitUntil(timeout: .seconds(7)) {
        await rig.proxy.connectedControllerIDs() == [first.controllerID, second.controllerID]
      }
      guard case .connected = second.state else {
        Issue.record("The unselected controller should remain connected")
        return
      }

      await first.disconnect()
      await second.disconnect()
      await rig.stop()
    }

    @Test func upstreamRestartReturnsExistingControllerToPicker() async throws {
      let rig = FaultRig()
      let initial = try await rig.start()
      let client = PartyClient(displayName: "Restart")
      await client.connect(host: initial.host, port: initial.tcpPort)
      try await waitUntil { rig.host.players.count == 1 }

      let restarted = try await rig.restartHost()
      #expect(restarted.hostInstanceID != initial.hostInstanceID)
      try await waitUntil(timeout: .seconds(7)) { client.state == .browsing }
      #expect(client.player == nil)

      await client.disconnect()
      await rig.stop()
    }

    @Test func repeatedEightControllerWavesDoNotExhaustListenerBudget() async throws {
      let rig = FaultRig()
      let metadata = try await rig.start()
      let controllerIDs = (1...PartyNetConstants.maximumControllers).map { index in
        let value = String(format: "50415254-5942-4F58-9000-%012X", index)
        return ControllerID(rawValue: UUID(uuidString: value)!)
      }

      for wave in 1...3 {
        let clients = controllerIDs.enumerated().map { index, controllerID in
          PartyClient(controllerID: controllerID, displayName: "Wave \(wave)-\(index + 1)")
        }
        for client in clients {
          await client.connect(host: metadata.host, port: metadata.tcpPort)
          guard case .connected = client.state else {
            Issue.record("Wave \(wave) failed to connect \(client.displayName): \(client.state)")
            await rig.stop()
            return
          }
        }
        try await waitUntil {
          rig.host.players.count == PartyNetConstants.maximumControllers
        }

        for client in clients { await client.disconnect() }
        try await waitUntil {
          let metrics = await rig.proxy.currentMetrics()
          return rig.host.players.isEmpty
            && metrics.activeTCPBridges == 0
            && metrics.activeTCPHandlers == 0
            && metrics.activeUDPSessions == 0
        }
      }

      let metrics = await rig.proxy.currentMetrics()
      #expect(metrics.tcpConnections == PartyNetConstants.maximumControllers * 3)
      await rig.stop()
    }

    @Test func profileValidationAndSeededLossAreDeterministic() {
      #expect(FaultProfile(udpDropPolicy: .rate(-1)).udpDropPolicy == .rate(0))
      #expect(FaultProfile(udpDropPolicy: .rate(2)).udpDropPolicy == .rate(1))
      #expect(
        FaultProfile(delayMilliseconds: -1, jitterMilliseconds: -2, reorderWindow: 0)
          == FaultProfile(delayMilliseconds: 0, jitterMilliseconds: 0, reorderWindow: 1))
      #expect(
        FaultProfile(delayMilliseconds: .max, jitterMilliseconds: .max, reorderWindow: .max)
          == FaultProfile(
            delayMilliseconds: FaultProfile.maximumDelayMilliseconds,
            jitterMilliseconds: FaultProfile.maximumDelayMilliseconds,
            reorderWindow: FaultProfile.maximumReorderWindow
          ))
    }

    private func metricsAfterControlledSend(
      outcome: DatagramSendOutcome,
      retryAfterFailure: Bool = false
    ) async throws -> (before: FaultMetrics, after: FaultMetrics, usedFreshConnection: Bool) {
      let gate = DatagramSendGate(outcome: outcome)
      let host = PartyHost()
      let proxy = NetworkFaultProxy(udpSender: { connection, _ in
        try await gate.send(on: connection)
      })
      do {
        let upstreamPort = try await host.start(hostName: "Cancellation Host", advertise: false)
        let proxyPorts = try await proxy.start(upstreamTCPPort: upstreamPort)
        let proxyTCPPort = try #require(NWEndpoint.Port(rawValue: proxyPorts.tcp))
        let control = ClientControlConnection(
          to: .hostPort(host: "127.0.0.1", port: proxyTCPPort),
          using: .parameters { clientControlStack() }.peerToPeerIncluded(false)
        )
        try await control.send(.hello(Hello(controllerID: ControllerID(), displayName: "Gate")))
        guard case let .welcome(welcome) = try await control.receive().content else {
          throw PartyClientError.unexpectedHandshake
        }

        let proxyUDPPort = try #require(NWEndpoint.Port(rawValue: proxyPorts.udp))
        let udp = NetworkConnection<UDP>(
          to: .hostPort(host: "127.0.0.1", port: proxyUDPPort),
          using: .parameters { UDP() }.peerToPeerIncluded(false)
        )
        let before = await proxy.currentMetrics()
        try await udp.send(InputFrame(
          token: welcome.sessionToken,
          sequence: 1,
          clientTimeMs: 0,
          axisX: 0,
          axisY: 0
        ).encode())
        try await waitUntil { await gate.isStarted }

        if outcome == .cancelledFailure || outcome == .cancelledSuccess {
          try await proxy.updateUpstream(tcpPort: upstreamPort)
          await gate.resume()
        }
        try await waitUntil { await gate.isFinished }
        try await waitUntil { await proxy.activeUDPForwardCount() == 0 }
        if retryAfterFailure {
          try await udp.send(InputFrame(
            token: welcome.sessionToken,
            sequence: 2,
            clientTimeMs: 1,
            axisX: 0,
            axisY: 0
          ).encode())
          try await waitUntil { await gate.sendCount == 2 }
          try await waitUntil { await proxy.activeUDPForwardCount() == 0 }
        }
        let after = await proxy.currentMetrics()
        let usedFreshConnection = await gate.usedFreshConnection

        await proxy.stop()
        await host.stop()
        return (before, after, usedFreshConnection)
      } catch {
        await gate.resume()
        await proxy.stop()
        await host.stop()
        throw error
      }
    }

    private func waitUntil(
      timeout: Duration = .seconds(3),
      condition: @escaping @MainActor () async -> Bool
    ) async throws {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: timeout)
      while !(await condition()), clock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
      }
      try #require(await condition())
    }
  }
}
