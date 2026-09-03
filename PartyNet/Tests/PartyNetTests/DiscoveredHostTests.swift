import Testing
@testable import PartyNet

@Suite("Discovered host validation")
struct DiscoveredHostTests {
    @Test func rejectsPortZero() {
        #expect(throws: PartyClientError.self) {
            _ = try DiscoveredHost(host: "127.0.0.1", port: 0)
        }
    }
}
