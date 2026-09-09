import Foundation
import Testing

actor NthCallGate {
  private let blockedCall: Int
  private var callCount = 0
  private var isOpen = false
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var isBlocking = false

  init(blockedCall: Int) {
    precondition(blockedCall > 0)
    self.blockedCall = blockedCall
  }

  func pauseIfNeeded() async {
    callCount += 1
    guard callCount == blockedCall, !isOpen else { return }
    isBlocking = true
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation = $0 }
    } onCancel: {
      Task { await self.open() }
    }
  }

  func open() {
    isOpen = true
    continuation?.resume()
    continuation = nil
    isBlocking = false
  }
}

func waitUntilAsync(
  timeout: Duration = .seconds(3),
  condition: @escaping @Sendable () async -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while !(await condition()), clock.now < deadline {
    try await Task.sleep(for: .milliseconds(20))
  }
  try #require(await condition())
}

@MainActor
func withAsyncCleanup<Result>(
  operation: () async throws -> Result,
  cleanup: () async -> Void
) async throws -> Result {
  do {
    let result = try await operation()
    await cleanup()
    return result
  } catch {
    await cleanup()
    throw error
  }
}
