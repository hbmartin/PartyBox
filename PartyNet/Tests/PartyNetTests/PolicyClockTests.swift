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

    @Test func sharedTimeoutUsesTheProvidedClockAndError() async throws {
      let clock = ManualTestClock()
      let start = clock.now
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
      defer { task.cancel() }
      let deadline = start.advanced(by: .seconds(5))
      try await clock.waitForSleep(until: deadline)
      try await clock.waitForSleep(until: start.advanced(by: .seconds(30)))

      clock.advance(to: deadline)
      await #expect(throws: ExpectedTimeout.self) {
        try await task.value
      }
    }

    @Test func reconnectWindowExpiresAtExactlyThirtySeconds() async throws {
      let clock = ManualTestClock()
      try await withDependencies {
        $0.continuousClock = clock
      } operation: {
        let client = PartyClient(displayName: "Clock")
        try client.beginReconnectForTesting(host: "127.0.0.1", port: 9)
        let start = clock.now
        try await clock.waitForSleep(until: start.advanced(by: .seconds(1)))
        clock.advance(to: start.advanced(by: .seconds(29)))
        let deadline = start.advanced(by: .seconds(30))
        try await clock.waitForSleep(until: deadline)

        clock.advance(to: deadline.advanced(by: .milliseconds(-1)))
        guard case .reconnecting = client.state else {
          Issue.record("Reconnect window expired before 30 seconds")
          return
        }

        clock.advance(to: deadline)
        try await waitUntil { client.state == .disconnected("Could not reconnect within 30 seconds.") }
        await client.stop()
      }
    }

    @Test func hostGraceExpiresAtExactlyFifteenSeconds() async throws {
      let clock = ManualTestClock()
      try await withDependencies {
        $0.continuousClock = clock
      } operation: {
        let host = hostWithLiveTransport()
        let port = try await host.start(hostName: "Clock Host", advertise: false)
        let client = PartyClient(displayName: "Grace Clock")
        await client.connect(host: "127.0.0.1", port: port)
        try await waitUntil { host.players.first?.isConnected == true }
        await client.interruptForTesting()
        try await waitUntil { host.players.first?.isConnected == false }

        let deadline = clock.now.advanced(by: .seconds(15))
        try await clock.waitForSleep(until: deadline)
        clock.advance(to: deadline.advanced(by: .milliseconds(-1)))
        #expect(host.players.count == 1)

        clock.advance(to: deadline)
        try await waitUntil { host.players.isEmpty }
        await client.stop()
        await host.stop()
      }
    }

    @Test func reconnectBeforeFifteenSecondsPreservesThePlayer() async throws {
      let clock = ManualTestClock()
      try await withDependencies {
        $0.continuousClock = clock
      } operation: {
        let host = hostWithLiveTransport()
        let port = try await host.start(hostName: "Reconnect Clock Host", advertise: false)
        let controllerID = ControllerID(
          rawValue: UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
        )
        let first = PartyClient(controllerID: controllerID, displayName: "Grace")
        await first.connect(host: "127.0.0.1", port: port)
        try await waitUntil { host.players.first?.isConnected == true }
        await first.interruptForTesting()
        try await waitUntil { host.players.first?.isConnected == false }

        let deadline = clock.now.advanced(by: .seconds(15))
        try await clock.waitForSleep(until: deadline)
        clock.advance(to: deadline.advanced(by: .milliseconds(-1)))
        let replacement = PartyClient(controllerID: controllerID, displayName: "Grace Again")
        await replacement.connect(host: "127.0.0.1", port: port)
        try await waitUntil { host.players.first?.isConnected == true }

        clock.advance(to: deadline)
        #expect(host.players.count == 1)
        #expect(host.players.first?.id == PlayerID(0))
        await first.stop()
        await replacement.disconnect()
        await host.stop()
      }
    }

    @Test func reconnectDuringRenameIntervalClearsPendingAndAppliesNextRenameImmediately() async throws {
      let clock = TestClock()
      try await withDependencies {
        $0.continuousClock = clock
      } operation: {
        let host = hostWithLiveTransport(reconnectGrace: .seconds(1))
        let port = try await host.start(hostName: "Rename Reconnect Host", advertise: false)
        let client = PartyClient(displayName: "Original")
        await client.connect(host: "127.0.0.1", port: port)
        try await waitUntil { host.players.first?.isConnected == true }

        await client.rename(to: "Before Interruption")
        try await waitUntil { host.players.first?.displayName == "Before Interruption" }
        await client.rename(to: "Stale Pending Rename")
        let pingCount = client.rttSampleCount
        client.reconnectAfterForeground()
        try await waitUntil { client.rttSampleCount > pingCount }
        #expect(host.players.first?.displayName == "Before Interruption")
        await client.interruptForTesting()
        try await waitUntil { host.players.first?.isConnected == false }

        await client.rename(to: "Reconnect Hello")
        await client.connect(host: "127.0.0.1", port: port)
        try await waitUntil {
          host.players.first?.isConnected == true
            && host.players.first?.displayName == "Reconnect Hello"
        }
        await client.rename(to: "Reconnected Rename")
        try await waitUntil {
          host.players.first?.displayName == "Reconnected Rename"
        }
        await clock.advance(by: PartyNetConstants.renameProcessingInterval)
        await settle()
        #expect(host.players.first?.displayName == "Reconnected Rename")

        await client.disconnect()
        await host.stop()
      }
    }

    @Test func replacementDuringRenameIntervalClearsPendingAndAppliesNextRenameImmediately() async throws {
      let clock = TestClock()
      try await withDependencies {
        $0.continuousClock = clock
      } operation: {
        let host = hostWithLiveTransport(reconnectGrace: .seconds(1))
        let port = try await host.start(hostName: "Rename Replacement Host", advertise: false)
        let controllerID = ControllerID(
          rawValue: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!)
        let first = PartyClient(controllerID: controllerID, displayName: "Original")
        let replacement = PartyClient(controllerID: controllerID, displayName: "Replacement")
        await first.connect(host: "127.0.0.1", port: port)
        try await waitUntil { host.players.first?.isConnected == true }

        await first.rename(to: "Before Replacement")
        try await waitUntil { host.players.first?.displayName == "Before Replacement" }
        await first.rename(to: "Stale Pending Rename")
        let pingCount = first.rttSampleCount
        first.reconnectAfterForeground()
        try await waitUntil { first.rttSampleCount > pingCount }
        #expect(host.players.first?.displayName == "Before Replacement")
        await replacement.connect(host: "127.0.0.1", port: port)
        try await waitUntil { host.players.first?.displayName == "Replacement" }

        await replacement.rename(to: "Replacement Rename")
        try await waitUntil {
          host.players.first?.displayName == "Replacement Rename"
        }
        await clock.advance(by: PartyNetConstants.renameProcessingInterval)
        await settle()
        #expect(host.players.first?.displayName == "Replacement Rename")

        await first.stop()
        await replacement.disconnect()
        await host.stop()
      }
    }

    @Test func changedInputAndRefreshUseDeterministicCadence() async throws {
      try await withInputRig(name: "Cadence") { client, rig, clock in
        var ticks = InputLoopTicks(clock)
        client.setAxes(axisX: 0.25)
        await client.waitForInputFlushForTesting()
        try await ticks.advance(to: .milliseconds(15))
        #expect(client.inputFramesSent == 0)

        try await ticks.advance(to: .milliseconds(16))
        try await waitUntil { client.inputFramesSent == 1 }
        try await waitUntil { rig.host.inputs.snapshot()[PlayerID(0)]?.axisX == 0.25 }

        client.setAxes(axisX: 0.5)
        await client.waitForInputFlushForTesting()
        try await ticks.advance(to: .milliseconds(31))
        #expect(client.inputFramesSent == 1)

        try await ticks.advance(to: .milliseconds(32))
        try await waitUntil { client.inputFramesSent == 2 }
        let sentAfterChange = client.inputFramesSent
        try await ticks.advance(to: .milliseconds(231))
        #expect(client.inputFramesSent == sentAfterChange)

        // The 200 ms refresh is emitted on the next 16 ms input-loop tick.
        try await ticks.advance(to: .milliseconds(240))
        try await waitUntil { client.inputFramesSent == sentAfterChange + 1 }
        #expect(!client.usesTCPFallback)
      }
    }

    @Test func unchangedMotionAvailabilityDoesNotEnqueueInput() async throws {
      try await withInputRig(name: "Motion Cadence") { client, _, clock in
        var ticks = InputLoopTicks(clock)
        try await ticks.advance(to: .milliseconds(16))
        try await waitUntil { client.inputFramesSent == 1 }
        let baselineSendCount = client.inputFramesSent
        let baselineEnqueueCount = client.inputEnqueueCountForTesting

        client.setOrientation(.identity, available: false)
        #expect(client.inputEnqueueCountForTesting == baselineEnqueueCount)
        try await ticks.advance(to: .milliseconds(32))
        #expect(client.inputFramesSent == baselineSendCount)

        let orientation = OrientationQuaternion(x: 0, y: 0, z: 1, w: 0)
        client.setOrientation(orientation)
        #expect(client.inputEnqueueCountForTesting == baselineEnqueueCount + 1)
        await client.waitForInputFlushForTesting()
        try await ticks.advance(to: .milliseconds(48))
        try await waitUntil { client.inputFramesSent == baselineSendCount + 1 }

        client.setOrientation(orientation)
        #expect(client.inputEnqueueCountForTesting == baselineEnqueueCount + 1)
        try await ticks.advance(to: .milliseconds(64))
        #expect(client.inputFramesSent == baselineSendCount + 1)
      }
    }

    @Test func acknowledgmentLossUsesTCPAndUDPProbesUntilRecovery() async throws {
      try await withInputRig(name: "Fallback Clock", profile: FaultProfile(udpDropPolicy: .rate(1))) { client, rig, clock in
        var ticks = InputLoopTicks(clock)
        client.setAxes(axisX: 0.75)
        await client.waitForInputFlushForTesting()

        try await ticks.advance(to: .milliseconds(999))
        #expect(!client.usesTCPFallback)

        try await ticks.advance(to: .milliseconds(1008))
        try await waitUntil {
          let metrics = await rig.proxy.currentMetrics()
          return client.usesTCPFallback && client.tcpInputFramesSent == 1
            && rig.host.inputs.snapshot()[PlayerID(0)]?.axisX == 0.75
            && metrics.udpReceived == client.udpInputFramesSent
            && metrics.tcpMessagesClientToHost > 0
        }
        let fallbackMetrics = await rig.proxy.currentMetrics()

        try await ticks.advance(to: .milliseconds(1040))
        let limitedMetrics = await rig.proxy.currentMetrics()
        #expect(client.tcpInputFramesSent == 1)
        #expect(limitedMetrics.tcpMessagesClientToHost == fallbackMetrics.tcpMessagesClientToHost)
        #expect(limitedMetrics.udpReceived == fallbackMetrics.udpReceived)

        try await ticks.advance(to: .milliseconds(1056))
        try await waitUntil {
          let metrics = await rig.proxy.currentMetrics()
          return metrics.tcpMessagesClientToHost == fallbackMetrics.tcpMessagesClientToHost + 1
            && metrics.udpReceived == fallbackMetrics.udpReceived + 1
        }

        await rig.proxy.setProfile(.stable)
        client.setAxes(axisX: -0.5)
        await client.waitForInputFlushForTesting()
        try await ticks.advance(to: .milliseconds(1255))
        #expect(client.usesTCPFallback)

        try await ticks.advance(to: .milliseconds(1264))
        try await waitUntil { !client.usesTCPFallback }
        try await waitUntil { rig.host.inputs.snapshot()[PlayerID(0)]?.axisX == -0.5 }
      }
    }

    private struct InputLoopTicks {
      let clock: ManualTestClock
      let start: ManualTestClock.Instant
      var nextTick: ManualTestClock.Instant

      init(_ clock: ManualTestClock) {
        self.clock = clock
        start = clock.now
        nextTick = start.advanced(by: .milliseconds(16))
      }

      mutating func advance(to elapsed: Duration, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let target = start.advanced(by: elapsed)
        while nextTick <= target {
          try await clock.waitForSleep(until: nextTick, sourceLocation: sourceLocation)
          clock.advance(to: nextTick)
          nextTick = nextTick.advanced(by: .milliseconds(16))
        }
        // The next sleep is registered only after all work from the previous tick returned.
        try await clock.waitForSleep(until: nextTick, sourceLocation: sourceLocation)
        clock.advance(to: target)
      }
    }

    private func withInputRig(
      name: String,
      profile: FaultProfile = .stable,
      operation: (PartyClient, FaultRig, ManualTestClock) async throws -> Void
    ) async throws {
      // Listener readiness and remote packet delivery use real time. Only the client policy is driven by ticks.
      try await withDependencies {
        $0.continuousClock = ContinuousClock()
      } operation: {
        let rig = FaultRig(profile: profile)
        let metadata = try await rig.start()
        let clock = ManualTestClock()
        try await withDependencies {
          $0.continuousClock = clock
        } operation: {
          let client = PartyClient(displayName: name)
          try await withAsyncCleanup {
            await client.connect(host: metadata.host, port: metadata.tcpPort)
            try #require(client.player != nil)
            try await operation(client, rig, clock)
          } cleanup: {
            await client.stop()
            await rig.stop()
          }
        }
      }
    }

    private func waitUntil(
      sourceLocation: SourceLocation = #_sourceLocation,
      condition: @escaping @MainActor () async -> Bool
    ) async throws {
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
      }
      try #require(await condition(), sourceLocation: sourceLocation)
    }

    private func settle() async {
      for _ in 0..<10 { await Task.yield() }
    }
  }
}
