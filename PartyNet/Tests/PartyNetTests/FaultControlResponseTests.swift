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

    private func udp(_ scope: UDPLossScope?) -> FaultControlRequest {
        .udp(dropRate: 0.5, delayMilliseconds: 0, jitterMilliseconds: 0, reorderWindow: 1, lossScope: scope)
    }

    @Test func explicitScopeRequiresConfirmationFromTheServer() {
        let response = FaultControlResponse(succeeded: true, message: "ok", profile: FaultProfile(lossScope: .perController))
        #expect(response.failureMessage(for: udp(.perController)) == nil)
        #expect(response.failureMessage(for: udp(.shared)) == "Requested UDP loss scope shared, but the server reported per-controller.")

        let missing = FaultControlResponse(succeeded: true, message: "ok")
        #expect(missing.failureMessage(for: udp(.perController)) == "Requested UDP loss scope per-controller, but the server reported no profile.")
        #expect(missing.failureMessage(for: udp(nil)) == nil)
        #expect(missing.failureMessage(for: .metrics) == nil)

        let failed = FaultControlResponse(succeeded: false, message: "update refused")
        #expect(failed.failureMessage(for: udp(.perController)) == "update refused")
    }

    @Test func legacyProfileConfirmsOnlySharedLoss() throws {
        let legacy = Data(#"{"seed":42,"udpDropPolicy":{"none":{}},"delayMilliseconds":0,"jitterMilliseconds":0,"reorderWindow":1}"#.utf8)
        let profile = try JSONDecoder().decode(FaultProfile.self, from: legacy)
        let response = FaultControlResponse(succeeded: true, message: "ok", profile: profile)
        #expect(response.failureMessage(for: udp(.shared)) == nil)
        #expect(response.failureMessage(for: udp(.perController)) == "Requested UDP loss scope per-controller, but the server reported shared.")
    }
}
