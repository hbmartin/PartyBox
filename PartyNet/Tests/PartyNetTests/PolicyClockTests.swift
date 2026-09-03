import Dependencies
import Foundation
import PartyNetTestSupport
import Testing

@testable import PartyNet

extension NetworkIntegrationTests {
  @Suite("Controllable policy clocks", .serialized)
  @MainActor
  struct PolicyClockTests {
    private enum ExpectedTimeout: Error, Sendable {
      case elapsed
    }

    @Test func sharedTimeoutUsesTheProvidedClockAndError() async {
      let clock = TestClock()
      let task = Task {
        try await withTimeout(
          .seconds(5),
          clock: AnyClock(clock),
          timeoutError: { ExpectedTimeout.elapsed }
        ) {
          try await clock.sleep(for: .seconds(30))
          return 1
        }
      }
      await settle()

      await clock.advance(by: .seconds(5))
      await #expect(throws: ExpectedTimeout.self) {
        try await task.value
      }
    }

    @Test func pingDeadlineTracksOldestUnansweredPing() async {
      let clock = TestClock()
      let erasedClock = AnyClock(clock)
      var watchdog = PingWatchdog()

      watchdog.record(nonce: 1, sentAt: erasedClock.now)
      await clock.advance(by: .seconds(2))
      watchdog.record(nonce: 2, sentAt: erasedClock.now)
      await clock.advance(by: .seconds(2))
      watchdog.record(nonce: 3, sentAt: erasedClock.now)

      #expect(!watchdog.hasTimedOut(at: erasedClock.now, after: .seconds(6)))
      await clock.advance(by: .seconds(2))
      #expect(watchdog.hasTimedOut(at: erasedClock.now, after: .seconds(6)))

      let acknowledgedOutstandingPing = watchdog.acknowledge(nonce: 2)
      #expect(acknowledgedOutstandingPing)
      #expect(watchdog.outstandingNonces == [3])
      #expect(watchdog.oldestUnansweredAt != nil)

      watchdog.record(nonce: 4, sentAt: erasedClock.now)
      let acknowledgedStalePing = watchdog.acknowledge(nonce: 2)
      #expect(!acknowledgedStalePing)
      await clock.advance(by: .seconds(4))
      #expect(watchdog.hasTimedOut(at: erasedClock.now, after: .seconds(6)))

      let acknowledgedNextPing = watchdog.acknowledge(nonce: 3)
      #expect(acknowledgedNextPing)
      #expect(watchdog.outstandingNonces == [4])
    }

    @Test func reconnectWindowExpiresAtExactlyThirtySeconds() async throws {
      let clock = TestClock()
      try await withDependencies {
        $0.continuousClock = clock
      } operation: {
        let client = PartyClient(displayName: "Clock")
        try client.beginReconnectForTesting(host: "127.0.0.1", port: 9)
        await settle()

        await clock.advance(by: .seconds(29) + .milliseconds(999))
        await settle()
        guard case .reconnecting = client.state else {
          Issue.record("Reconnect window expired before 30 seconds")
          return
        }

        await clock.advance(by: .milliseconds(1))
        await settle()
        #expect(client.state == .disconnected("Could not reconnect within 30 seconds."))
        await client.stop()
      }
    }

    @Test func hostGraceExpiresAtExactlyFifteenSeconds() async throws {
      let clock = TestClock()
      try await withDependencies {
        $0.continuousClock = clock
      } operation: {
        let host = PartyHost()
        let startTask = Task { try await host.start(hostName: "Clock Host", advertise: false) }
        for _ in 0..<20 where host.port == nil {
          await clock.advance(by: .milliseconds(10))
          await settle()
        }
        let port = try await startTask.value
        let client = PartyClient(displayName: "Grace Clock")
        await client.connect(host: "127.0.0.1", port: port)
        try await waitUntil { host.players.first?.isConnected == true }
        await client.interruptForTesting()
        try await waitUntil { host.players.first?.isConnected == false }

        await clock.advance(by: .seconds(14) + .milliseconds(999))
        await settle()
        #expect(host.players.count == 1)

        await clock.advance(by: .milliseconds(1))
        await settle()
        #expect(host.players.isEmpty)
        await client.stop()
        await host.stop()
      }
    }

    @Test func reconnectBeforeFifteenSecondsPreservesThePlayer() async throws {
      let clock = TestClock()
      try await withDependencies {
        $0.continuousClock = clock
      } operation: {
        let host = PartyHost()
        let startTask = Task {
          try await host.start(hostName: "Reconnect Clock Host", advertise: false)
        }
        for _ in 0..<20 where host.port == nil {
          await clock.advance(by: .milliseconds(10))
          await settle()
        }
        let port = try await startTask.value
        let controllerID = ControllerID(
          rawValue: UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
        )
        let first = PartyClient(controllerID: controllerID, displayName: "Grace")
        await first.connect(host: "127.0.0.1", port: port)
        try await waitUntil { host.players.first?.isConnected == true }
        await first.interruptForTesting()
        try await waitUntil { host.players.first?.isConnected == false }

        await clock.advance(by: .seconds(14) + .milliseconds(999))
        await settle()
        let replacement = PartyClient(controllerID: controllerID, displayName: "Grace Again")
        await replacement.connect(host: "127.0.0.1", port: port)
        try await waitUntil { host.players.first?.isConnected == true }

        await clock.advance(by: .milliseconds(1))
        await settle()
        #expect(host.players.count == 1)
        #expect(host.players.first?.id == PlayerID(0))
        await first.stop()
        await replacement.disconnect()
        await host.stop()
      }
    }

    @Test func changedInputAndRefreshUseDeterministicCadence() async throws {
      let clock = TestClock()
      try await withDependencies {
        $0.continuousClock = clock
      } operation: {
        let rig = FaultRig()
        let metadata = try await start(rig, advancing: clock)
        let client = PartyClient(displayName: "Cadence")
        await client.connect(host: metadata.host, port: metadata.tcpPort)

        client.setInput(axisX: 0.25)
        await settle()
        await clock.advance(by: .milliseconds(15))
        await settle()
        #expect(client.inputFramesSent == 0)

        await clock.advance(by: .milliseconds(1))
        try await waitUntil { client.inputFramesSent == 1 }
        try await waitUntil { rig.host.inputs.snapshot()[PlayerID(0)]?.axisX == 0.25 }

        client.setInput(axisX: 0.5)
        await settle()
        await clock.advance(by: .milliseconds(15))
        await settle()
        #expect(client.inputFramesSent == 1)

        await clock.advance(by: .milliseconds(1))
        try await waitUntil { client.inputFramesSent == 2 }
        let sentAfterChange = client.inputFramesSent

        await clock.advance(by: .milliseconds(199))
        await settle()
        #expect(client.inputFramesSent == sentAfterChange)

        // The 200 ms refresh is emitted on the next 16 ms input-loop tick.
        await clock.advance(by: .milliseconds(9))
        try await waitUntil { client.inputFramesSent == sentAfterChange + 1 }
        #expect(!client.usesTCPFallback)

        await client.disconnect()
        await rig.stop()
      }
    }

    @Test func acknowledgmentLossUsesTCPAndUDPProbesUntilRecovery() async throws {
      let clock = TestClock()
      try await withDependencies {
        $0.continuousClock = clock
      } operation: {
        let rig = FaultRig(profile: FaultProfile(udpDropPolicy: .rate(1)))
        let metadata = try await start(rig, advancing: clock)
        let client = PartyClient(displayName: "Fallback Clock")
        await client.connect(host: metadata.host, port: metadata.tcpPort)
        client.setInput(axisX: 0.75)
        await settle()

        await clock.advance(by: .milliseconds(999))
        await settle()
        #expect(!client.usesTCPFallback)

        await clock.advance(by: .milliseconds(9))
        try await waitUntil { client.usesTCPFallback }
        try await waitUntil {
          let metrics = await rig.proxy.currentMetrics()
          return metrics.tcpMessagesClientToHost > 0
        }
        let fallbackMetrics = await rig.proxy.currentMetrics()

        await clock.advance(by: .milliseconds(32))
        await settle()
        let limitedMetrics = await rig.proxy.currentMetrics()
        #expect(limitedMetrics.tcpMessagesClientToHost == fallbackMetrics.tcpMessagesClientToHost)
        #expect(limitedMetrics.udpReceived == fallbackMetrics.udpReceived)

        await clock.advance(by: .milliseconds(16))
        try await waitUntil {
          let metrics = await rig.proxy.currentMetrics()
          return metrics.tcpMessagesClientToHost == fallbackMetrics.tcpMessagesClientToHost + 1
            && metrics.udpReceived == fallbackMetrics.udpReceived + 1
        }

        await rig.proxy.setProfile(.stable)
        client.setInput(axisX: -0.5)
        await settle()
        await clock.advance(by: .milliseconds(199))
        await settle()
        #expect(client.usesTCPFallback)

        await clock.advance(by: .milliseconds(9))
        try await waitUntil { !client.usesTCPFallback }
        try await waitUntil { rig.host.inputs.snapshot()[PlayerID(0)]?.axisX == -0.5 }

        await client.disconnect()
        await rig.stop()
      }
    }

    private func start(
      _ rig: FaultRig,
      advancing clock: TestClock<Duration>
    ) async throws -> FaultRigMetadata {
      let startTask = Task { try await rig.start() }
      await settle()
      await clock.advance(by: .milliseconds(100))
      await settle()
      return try await startTask.value
    }

    private func waitUntil(
      attempts: Int = 200,
      condition: @escaping @MainActor () -> Bool
    ) async throws {
      for _ in 0..<attempts {
        if condition() { return }
        await settle()
        try await Task.sleep(nanoseconds: 1_000_000)
      }
      try #require(condition())
    }

    private func waitUntil(
      attempts: Int = 2_000,
      condition: @escaping @MainActor () async -> Bool
    ) async throws {
      for _ in 0..<attempts {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
      }
      try #require(await condition())
    }

    private func settle() async {
      for _ in 0..<10 { await Task.yield() }
    }
  }
}
