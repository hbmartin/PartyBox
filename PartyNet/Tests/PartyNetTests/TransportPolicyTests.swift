import Dependencies
import DependenciesTestSupport
import Foundation
import PartyNetTestSupport
import Testing

@testable import PartyNet

@Suite("Transport policies", .dependency(\.continuousClock, ContinuousClock()))
struct TransportPolicyTests {
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

  @Test func profileValidationNormalizesBounds() async throws {
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

    let decoded = try JSONDecoder().decode(
      FaultProfile.self,
      from: Data(
        #"{"seed":0,"udpDropPolicy":{"every":{"_0":0}},"delayMilliseconds":-1,"jitterMilliseconds":70000,"reorderWindow":2000}"#.utf8
      )
    )
    let proxy = NetworkFaultProxy(profile: decoded)
    #expect(
      await proxy.currentProfile()
        == FaultProfile(
          seed: 1,
          udpDropPolicy: .none,
          delayMilliseconds: 0,
          jitterMilliseconds: FaultProfile.maximumDelayMilliseconds,
          reorderWindow: FaultProfile.maximumReorderWindow
        ))

    let decodedReplacement = try JSONDecoder().decode(
      FaultProfile.self,
      from: Data(
        #"{"seed":0,"udpDropPolicy":{"every":{"_0":0}},"delayMilliseconds":70000,"jitterMilliseconds":-1,"reorderWindow":0}"#.utf8
      )
    )
    await proxy.setProfile(decodedReplacement)
    #expect(
      await proxy.currentProfile()
        == FaultProfile(
          seed: 1,
          udpDropPolicy: .none,
          delayMilliseconds: FaultProfile.maximumDelayMilliseconds,
          jitterMilliseconds: 0,
          reorderWindow: 1
        ))
  }

  @Test func lossScopeIsCompatibleWithEarlierProfilesAndControlMessages() throws {
    let decoder = JSONDecoder()
    let legacy = Data(#"{"udp":{"dropRate":0.5,"delayMilliseconds":2,"jitterMilliseconds":1,"reorderWindow":1}}"#.utf8)
    #expect(try decoder.decode(FaultControlRequest.self, from: legacy)
      == .udp(dropRate: 0.5, delayMilliseconds: 2, jitterMilliseconds: 1, reorderWindow: 1))
    let profile = FaultProfile(lossScope: .perController)
    #expect(try decoder.decode(FaultProfile.self, from: JSONEncoder().encode(profile)) == profile)
    let request = FaultControlRequest.udp(dropRate: 0.5, delayMilliseconds: 2, jitterMilliseconds: 1,
                                          reorderWindow: 1, lossScope: .perController)
    #expect(try decoder.decode(FaultControlRequest.self, from: JSONEncoder().encode(request)) == request)
  }

  @Test(arguments: [UDPLossScope.shared, .perController])
  func everyOtherPacketUsesTheSelectedLossScope(scope: UDPLossScope) {
    let profile = FaultProfile(udpDropPolicy: .every(2), lossScope: scope)
    var shared = UDPDecisionStream(profile: profile)
    var first = UDPSessionDecisions(profile: profile, controllerID: ControllerID())
    var second = UDPSessionDecisions(profile: profile, controllerID: ControllerID())
    var drops: [Bool] = []
    for _ in 0..<2 {
      drops.append(first.consumeDropDecision(shared: &shared))
      drops.append(second.consumeDropDecision(shared: &shared))
    }
    #expect(drops == (scope == .shared ? [false, true, false, true] : [false, false, true, true]))
  }

  @Test func seededPacketLossIsReproducible() {
    func dropDecisions(seed: UInt64, jitter: Int = 0) -> [Bool] {
      var stream = UDPDecisionStream(profile: FaultProfile(seed: seed, udpDropPolicy: .rate(0.5), jitterMilliseconds: jitter))
      return (0..<64).map { _ in
        let dropped = stream.consumeDropDecision()
        if !dropped { _ = stream.nextDelayMilliseconds() }
        return dropped
      }
    }

    let original = dropDecisions(seed: 42)
    // Historical shared-mode decisions for the first eight packets at seed 42.
    #expect(Array(original.prefix(8)) == [false, true, true, false, false, true, true, true])
    #expect(original == dropDecisions(seed: 42))
    #expect(original == dropDecisions(seed: 42, jitter: 2))
    #expect(original != dropDecisions(seed: 43))
  }
}
