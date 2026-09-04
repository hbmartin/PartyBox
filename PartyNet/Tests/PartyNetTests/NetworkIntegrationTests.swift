import Dependencies
import DependenciesTestSupport
import Testing

/// Network-backed suites share listener and connection resources, so keep them mutually
/// serialized. This is especially important when sanitizer instrumentation slows teardown.
@Suite("Network integration", .serialized, .dependencies)
struct NetworkIntegrationTests {}

private enum ControlledClockOperationTimeout: Error {
  case elapsed
}

@MainActor
func runWhileAdvancingTestClock<Value: Sendable>(
  _ clock: TestClock<Duration>,
  wallTimeout: Duration = .seconds(3),
  operation: @escaping @MainActor @Sendable () async throws -> Value
) async throws -> Value {
  try await withThrowingTaskGroup(of: Value.self) { group in
    group.addTask {
      try await operation()
    }
    group.addTask {
      let wallClock = ContinuousClock()
      let deadline = wallClock.now.advanced(by: wallTimeout)
      while wallClock.now < deadline {
        try Task.checkCancellation()
        await clock.advance(by: .milliseconds(10))
        try await wallClock.sleep(for: .milliseconds(5))
      }
      throw ControlledClockOperationTimeout.elapsed
    }
    defer { group.cancelAll() }
    return try await group.next()!
  }
}
