import DependenciesTestSupport
import Foundation
import PartyNet
import PartyNetTestSupport
import Testing

extension NetworkIntegrationTests {
  @Suite("UDP replay across controllers", .serialized, .dependency(\.continuousClock, ContinuousClock()))
  @MainActor
  struct UDPReplayIntegrationTests {
    private let firstID = ControllerID(rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
    private let secondID = ControllerID(rawValue: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)

    @Test func perControllerLossReplaysAcrossInterleavingJitterAndReconnect() async throws {
      let segmentLength = 12
      let baseline = FaultProfile(seed: 42, udpDropPolicy: .rate(0.5), lossScope: .perController, delayMilliseconds: 5)
      let (firstLosses, secondLosses) = try await UDPReplayRig.withRig(profile: baseline) { rig in
        let first = try await rig.connect(firstID)
        let second = try await rig.connect(secondID)
        var firstLosses: [Bool] = []
        var secondLosses: [Bool] = []
        for _ in 0..<(segmentLength * 2) {
          firstLosses.append(try await rig.send(first))
          secondLosses.append(try await rig.send(second))
        }
        return (firstLosses, secondLosses)
      }

      // These traces distinguish a new stream from a continuing one, and identify each peer.
      #expect(firstLosses.prefix(segmentLength) != firstLosses.suffix(segmentLength))
      #expect(secondLosses.prefix(segmentLength) != secondLosses.suffix(segmentLength))
      #expect(firstLosses.prefix(segmentLength) != secondLosses.prefix(segmentLength))

      let jittered = FaultProfile(
        seed: 42, udpDropPolicy: .rate(0.5), lossScope: .perController,
        delayMilliseconds: 5, jitterMilliseconds: 3
      )
      try await UDPReplayRig.withRig(profile: jittered) { rig in
        let second = try await rig.connect(secondID)
        var first = try await rig.connect(firstID)
        for index in secondLosses.indices {
          if index == segmentLength {
            let oldToken = first.token
            try await rig.disconnect(first)
            first = try await rig.connect(firstID)
            #expect(first.token != oldToken)
          }
          let secondDropped = try await rig.send(second)
          let firstDropped = try await rig.send(first)
          #expect(secondDropped == secondLosses[index], "Continuing controller, packet \(index + 1)")
          #expect(firstDropped == firstLosses[index % segmentLength], "Reconnecting controller, packet \(index + 1)")
        }

        await rig.proxy.setProfile(jittered)
        for index in 0..<segmentLength {
          let firstDropped = try await rig.send(first)
          let secondDropped = try await rig.send(second)
          #expect(firstDropped == firstLosses[index], "First controller after profile reset, packet \(index + 1)")
          #expect(secondDropped == secondLosses[index], "Second controller after profile reset, packet \(index + 1)")
        }
      }
    }

    @Test func sharedLossOrdinalSpansControllersAndReconnects() async throws {
      let profile = FaultProfile(udpDropPolicy: .every(3), lossScope: .shared)
      try await UDPReplayRig.withRig(profile: profile) { rig in
        let first = try await rig.connect(firstID)
        let second = try await rig.connect(secondID)
        var losses: [Bool] = []
        for peer in [first, second, first, second] {
          losses.append(try await rig.send(peer))
        }
        try await rig.disconnect(first)
        let reconnected = try await rig.connect(firstID)
        for peer in [second, reconnected, second] {
          losses.append(try await rig.send(peer))
        }
        #expect(losses == [false, false, true, false, false, true, false])
      }
    }
  }
}
