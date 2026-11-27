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

  @Test func profileValidationAndSeededLossAreDeterministic() async throws {
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
}
