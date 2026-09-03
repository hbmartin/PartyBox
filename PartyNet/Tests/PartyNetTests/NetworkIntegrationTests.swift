import DependenciesTestSupport
import Testing

/// Network-backed suites share listener and connection resources, so keep them mutually
/// serialized. This is especially important when sanitizer instrumentation slows teardown.
@Suite("Network integration", .serialized, .dependencies)
struct NetworkIntegrationTests {}
