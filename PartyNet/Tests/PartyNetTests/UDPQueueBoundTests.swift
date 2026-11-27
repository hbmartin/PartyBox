import DependenciesTestSupport
import Network
import PartyNetTestSupport
import Testing

@testable import PartyNet

@Suite("UDP queue bound", .serialized, .dependency(\.continuousClock, ContinuousClock()))
@MainActor
struct UDPQueueBoundTests {
  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func delayedForwardsStayBounded(omitFirstDatagram: Bool) async throws {
    let rig = FaultRig(profile: FaultProfile(delayMilliseconds: 60_000))
    let metadata = try await rig.start()
    do {
      let host = NWEndpoint.Host(metadata.host)
      let tcpPort = try #require(NWEndpoint.Port(rawValue: metadata.tcpPort))
      let control = ClientControlConnection(
        to: .hostPort(host: host, port: tcpPort),
        using: .parameters { clientControlStack() }.peerToPeerIncluded(false)
      )
      defer { withExtendedLifetime(control) {} }
      try await control.send(.hello(Hello(controllerID: ControllerID(), displayName: "Bounded")))
      guard case let .welcome(welcome) = try await control.receive().content else {
        throw PartyClientError.unexpectedHandshake
      }
      let udpPort = try #require(NWEndpoint.Port(rawValue: metadata.udpPort))
      let udp = NetworkConnection<UDP>(
        to: .hostPort(host: host, port: udpPort),
        using: .parameters { UDP() }.peerToPeerIncluded(false)
      )
      let queueLimit = NetworkFaultProxy.maximumQueuedForwardsPerToken
      let requiredReceipts = queueLimit + 2
      let batchSize = 16
      let maximumAttempts = 2 * (queueLimit + batchSize)
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(10))
      var sequence = 0
      var metrics = await rig.proxy.currentMetrics()

      while metrics.udpReceived < requiredReceipts,
            sequence < maximumAttempts, clock.now < deadline {
        let expectedBatchProgress = metrics.udpReceived + batchSize / 2
        let batchEnd = min(sequence + batchSize, maximumAttempts)
        while sequence < batchEnd, clock.now < deadline {
          sequence += 1
          if omitFirstDatagram && sequence == 1 { continue }
          try await udp.send(InputFrame(
            token: welcome.sessionToken, sequence: UInt32(sequence),
            clientTimeMs: 0, axisX: 0, axisY: 0
          ).encode())
        }

        // Pace the sender by observed progress while allowing some ingress loss.
        let batchDeadline = min(deadline, clock.now.advanced(by: .milliseconds(250)))
        metrics = await rig.proxy.currentMetrics()
        while metrics.udpReceived < expectedBatchProgress, clock.now < batchDeadline {
          try await clock.sleep(for: .milliseconds(10))
          metrics = await rig.proxy.currentMetrics()
        }
        #expect(await rig.proxy.pendingUDPForwardCount() <= queueLimit + 1)
      }

      try #require(metrics.udpReceived >= requiredReceipts, "The proxy must receive enough packets to overflow its queue")
      #expect(metrics.udpRejected == 0)
      #expect(metrics.udpForwarded == 0)
      #expect(metrics.udpDropped > 0)
      await rig.stop()
    } catch {
      await rig.stop()
      throw error
    }
  }
}
