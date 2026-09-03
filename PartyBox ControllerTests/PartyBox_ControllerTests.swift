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
        #expect(configuration.hostAddressError == nil)
        #expect(configuration.defaultsSuite == "PartyBoxControllerTests.Launch")
    }

    @Test func controllerLaunchArgumentsRequireBracketsForIPv6Hosts() {
        let bracketed = ControllerLaunchConfiguration(arguments: [
            "PartyBox Controller", "--host", "[::1]:49999",
        ])
        #expect(bracketed.hostAddress?.host == "::1")
        #expect(bracketed.hostAddress?.port == 49_999)

        let unbracketed = ControllerLaunchConfiguration(arguments: [
            "PartyBox Controller", "--host", "fe80::1:49999",
        ])
        #expect(unbracketed.hostAddress == nil)
        #expect(unbracketed.hostAddressError?.localizedDescription == PartyClientError.invalidAddress.localizedDescription)

        let malformed = ControllerLaunchConfiguration(arguments: [
            "PartyBox Controller", "--host", "[not-an-ipv6]:49999",
        ])
        #expect(malformed.hostAddress == nil)
        #expect(malformed.hostAddressError?.localizedDescription == PartyClientError.invalidAddress.localizedDescription)
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

    @Test func invalidDebugHostSurfacesAnAddressError() async {
        await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let configuration = ControllerLaunchConfiguration(arguments: [
                "PartyBox Controller", "--host", "[not-an-ipv6]:49999",
            ])
            let coordinator = ControllerCoordinator(configuration: configuration)

            await coordinator.start()
            #expect(
                coordinator.client.state
                    == .disconnected(PartyClientError.invalidAddress.localizedDescription)
            )
            await coordinator.stop()
        }
    }
}
