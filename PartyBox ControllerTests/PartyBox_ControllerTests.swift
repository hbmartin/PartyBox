import Dependencies
import Foundation
import PartyBoxCore
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
            let configuration = ControllerLaunchConfiguration(arguments: [
                "PartyBox Controller", "--ui-testing", "--disable-effects",
            ])

            let first = ControllerCoordinator(defaults: defaults, configuration: configuration)
            let controllerID = first.client.controllerID
            first.displayName = "  Ada    Lovelace  "
            await first.rename()

            let relaunched = ControllerCoordinator(defaults: defaults, configuration: configuration)
            #expect(relaunched.client.controllerID == controllerID)
            #expect(relaunched.displayName == "Ada Lovelace")
        }
    }

    @Test func invalidDebugHostSurfacesAnAddressError() async {
        await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let configuration = ControllerLaunchConfiguration(arguments: [
                "PartyBox Controller", "--ui-testing", "--disable-effects",
                "--host", "[not-an-ipv6]:49999",
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

    @Test func controllerKeepsMemoryOnlyHistoryVisibleAndReportsPersistenceFailure() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let blockedParent = directory.appendingPathComponent("not-a-directory")
            let url = blockedParent.appendingPathComponent("history.json")
            let suiteName = "PartyBoxControllerTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer {
                defaults.removePersistentDomain(forName: suiteName)
                try? FileManager.default.removeItem(at: directory)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("blocked".utf8).write(to: blockedParent)
            let coordinator = ControllerCoordinator(
                defaults: defaults,
                configuration: .init(arguments: ["PartyBox Controller", "--disable-effects"]),
                historyFileURL: url
            )
            let controllerID = coordinator.client.controllerID
            let match = MatchRecord(
                gameID: "pong",
                gameTitle: "Pong",
                endedAt: Date(timeIntervalSince1970: 10),
                durationSeconds: 5,
                modifierTitle: nil,
                participants: [
                    .init(controllerID: controllerID, displayName: "Ada", colorHex: "#32E6FF", outcome: .won),
                ],
                metrics: []
            )
            let record = PersonalMatchRecord(record: match, controllerID: controllerID)

            await coordinator.appendPersonalHistoryForTesting(record)
            await coordinator.appendPersonalHistoryForTesting(record)

            #expect(coordinator.personalHistory == [record])
            #expect(coordinator.historyPersistenceError?.isEmpty == false)

            await coordinator.clearPersonalHistory()

            #expect(coordinator.personalHistory == [record])
            #expect(coordinator.historyPersistenceError?.contains("could not be cleared") == true)
        }
    }

    @Test func sessionAndGameLayoutChangesClearPresentationAndNeutralizeInput() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let configuration = ControllerLaunchConfiguration(arguments: [
                "PartyBox Controller", "--ui-testing", "--scenario", "menu", "--disable-effects",
            ])
            let coordinator = ControllerCoordinator(configuration: configuration)
            let gameScreen = ControllerScreen(
                accessibilityID: "controller.layout.test",
                accentColorHex: "#32E6FF",
                components: [.axisSurface(.init(id: "axis", binding: .twoDimensional, instruction: "Move"))]
            )
            let gameLayout = PartyBoxCore.ControllerLayout.game(.init(
                gameID: "test", payload: try PartyBoxWireCodec.encode(gameScreen)
            ))
            let gamePresentation = try PartyBoxWireCodec.encode(HostPresentation.layout(gameLayout))
            let renamed = PlayerInfo(id: PlayerID(0), displayName: "Renamed", colorHex: "#32E6FF")
            let rosterPresentation = try PartyBoxWireCodec.encode(HostPresentation.roster([renamed]))

            await coordinator.start()
            coordinator.client.setInput(axisX: 0.8, axisY: -0.4, buttons: .primary)
            await coordinator.handleForTesting(.application(gamePresentation))

            #expect(coordinator.client.inputAxisX == 0)
            #expect(coordinator.client.inputAxisY == 0)
            #expect(coordinator.client.inputButtons.isEmpty)

            await coordinator.handleForTesting(.application(rosterPresentation))
            #expect(coordinator.currentPlayer?.displayName == "Renamed")

            await coordinator.handleForTesting(.sessionReset)
            #expect(coordinator.layout == .lobby)
            #expect(coordinator.roster.isEmpty)
            await coordinator.stop()
        }
    }
}
