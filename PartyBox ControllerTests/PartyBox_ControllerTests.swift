import Foundation
import PartyNet
import Testing
@testable import PartyBox_Controller

@Suite("Controller identity")
@MainActor
struct PartyBox_ControllerTests {
    @Test func identityAndSanitizedNamePersistAcrossLaunches() async throws {
        let suiteName = "PartyBoxControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = ControllerCoordinator(defaults: defaults)
        let controllerID = first.client.controllerID
        first.displayName = "  Ada    Lovelace  "
        await first.rename()

        let relaunched = ControllerCoordinator(defaults: defaults)
        #expect(relaunched.client.controllerID == controllerID)
        #expect(relaunched.displayName == "Ada Lovelace")
    }
}
