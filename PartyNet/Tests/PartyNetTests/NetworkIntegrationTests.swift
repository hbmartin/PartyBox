import Dependencies
import DependenciesTestSupport
import Testing

@testable import PartyNet

/// Network-backed suites share listener and connection resources, so keep them mutually
/// serialized. This is especially important when sanitizer instrumentation slows teardown.
@Suite("Network integration", .serialized, .dependencies)
struct NetworkIntegrationTests {}

/// Keep socket readiness on wall time while host policies use the test's injected clock.
@MainActor
func hostWithLiveTransport(reconnectGrace: Duration = PartyNetConstants.reconnectGrace) -> PartyHost {
  PartyHost(reconnectGrace: reconnectGrace, transportFactory: { inputs in
    withDependencies {
      $0.continuousClock = ContinuousClock()
    } operation: {
      HostTransport(inputs: inputs)
    }
  })
}
