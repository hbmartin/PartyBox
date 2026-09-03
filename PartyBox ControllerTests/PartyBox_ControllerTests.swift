import Dependencies
import Foundation
import PartyNet
import Testing
@testable import PartyBox_Controller

@Suite("Controller identity")
@MainActor
struct PartyBox_ControllerTests {
    @Test func controllerLaunchArgumentsParseStableIdentityAndHost() throws {
        let configuration = ControllerLaunchConfiguration(arguments: [
            "PartyBox Controller", "--ui-testing", "--scenario", "spectator",
            "--disable-animations", "--disable-effects", "--seed", "42",
            "--controller-id", "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "--display-name", "Ada", "--host", "127.0.0.1:49999",
            "--defaults-suite", "PartyBoxControllerTests.Launch",
        ])

        #expect(configuration.isUITesting)
        #expect(configuration.scenario == "spectator")
        #expect(configuration.disableAnimations)
        #expect(configuration.disableEffects)
        #expect(configuration.seed == 42)
        #expect(configuration.controllerID == UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        #expect(configuration.displayName == "Ada")
        #expect(configuration.hostAddress?.host == "127.0.0.1")
        #expect(configuration.hostAddress?.port == 49_999)
        #expect(configuration.defaultsSuite == "PartyBoxControllerTests.Launch")
    }

    @Test func identityAndSanitizedNamePersistAcrossLaunches() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
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
}
