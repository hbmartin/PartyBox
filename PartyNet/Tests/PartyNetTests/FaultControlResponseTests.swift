import Foundation
import PartyNetTestSupport
import Testing

@Suite("Fault control response compatibility")
struct FaultControlResponseTests {
    private struct LegacyResponse: Encodable {
        let succeeded: Bool
        let message: String
        let metadata: FaultRigMetadata?
        let profile: FaultProfile?
        let metrics: FaultMetrics
    }

    @Test func missingHostInputActivityDecodesAsEmpty() throws {
        let legacy = LegacyResponse(
            succeeded: true,
            message: "ok",
            metadata: nil,
            profile: nil,
            metrics: FaultMetrics()
        )

        let response = try JSONDecoder().decode(
            FaultControlResponse.self,
            from: JSONEncoder().encode(legacy)
        )

        #expect(response.succeeded)
        #expect(response.hostInputActivity.isEmpty)
    }
}
