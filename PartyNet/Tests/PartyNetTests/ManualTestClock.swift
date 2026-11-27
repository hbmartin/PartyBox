import Foundation
import Synchronization
import Testing

/// Virtual time for tests that must observe a worker parking before delivering its next tick.
final class ManualTestClock: Clock {
  typealias Instant = ContinuousClock.Instant

  private struct Sleeper {
    let deadline: Instant
    let continuation: AsyncStream<Void>.Continuation
  }

  private struct State {
    var now = Instant.now
    var sleepers: [UUID: Sleeper] = [:]
  }

  private let state = Mutex(State())
  var now: Instant { state.withLock { $0.now } }
  let minimumResolution: Duration = .nanoseconds(1)

  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    try Task.checkCancellation()
    let id = UUID()
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let shouldWait = state.withLock { state in
      guard deadline > state.now else { return false }
      state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
      return true
    }
    guard shouldWait else { return }

    // AsyncStream terminates the wait on cancellation, even if time never advances.
    defer { state.withLock { _ = $0.sleepers.removeValue(forKey: id) } }
    for await _ in stream {}
    try Task.checkCancellation()
  }

  func advance(to instant: Instant) {
    let due = state.withLock { state in
      precondition(instant >= state.now)
      state.now = instant
      let due = state.sleepers.filter { $0.value.deadline <= instant }
      for id in due.keys { state.sleepers.removeValue(forKey: id) }
      return Array(due.values)
    }
    for sleeper in due { sleeper.continuation.finish() }
  }

  func waitForSleep(until deadline: Instant, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let timeout = ContinuousClock.now.advanced(by: .seconds(5))
    while !hasSleeper(until: deadline), ContinuousClock.now < timeout {
      try await Task.sleep(for: .milliseconds(1))
    }
    try #require(hasSleeper(until: deadline), "No worker scheduled the expected sleep", sourceLocation: sourceLocation)
  }

  private func hasSleeper(until deadline: Instant) -> Bool {
    state.withLock { $0.sleepers.values.contains { $0.deadline == deadline } }
  }
}
