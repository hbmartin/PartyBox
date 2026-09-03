//
//  PartyBoxUITests.swift
//  PartyBoxUITests
//
//  Created by Harold Martin on 9/2/26.
//

import XCTest

final class PartyBoxUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFixturePhasesAndScreenshots() throws {
        for (scenario, identifier) in [
            ("empty-lobby", "host.phase.lobby"),
            ("four-player-lobby", "host.phase.lobby"),
            ("menu", "host.phase.menu"),
            ("four-way-match", "host.phase.playing"),
            ("game-over", "host.phase.gameOver"),
        ] {
            let app = launch(scenario: scenario)
            XCTAssertTrue(element(identifier, in: app).waitForExistence(timeout: 5), "Missing fixture \(scenario)")
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Host-\(scenario)"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    @MainActor
    func testFourPlayerLobbyMenuPongNavigation() throws {
        let app = launch(additional: ["--bot-count", "4", "--host-name", "Automation PartyBox"])
        XCTAssertTrue(element("host.lobby.start", in: app).waitForExistence(timeout: 10))
        activateSelect(in: app)
        XCTAssertTrue(element("host.phase.menu", in: app).waitForExistence(timeout: 5))
        activateSelect(in: app)
        XCTAssertTrue(element("host.arena", in: app).waitForExistence(timeout: 5))

        activateExit(in: app)
        XCTAssertTrue(element("host.arena", in: app).exists, "Menu/Exit must be ignored during a match")
        app.terminate()
    }

    @MainActor
    private func launch(scenario: String? = nil, additional: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--disable-animations", "--disable-effects", "--seed", "42"]
        if let scenario { app.launchArguments += ["--scenario", scenario] }
        app.launchArguments += additional
        app.launch()
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func activateSelect(in app: XCUIApplication) {
#if os(tvOS)
        XCUIRemote.shared.press(.select)
#else
        app.typeKey(.return, modifierFlags: [])
#endif
    }

    @MainActor
    private func activateExit(in app: XCUIApplication) {
#if os(tvOS)
        XCUIRemote.shared.press(.menu)
#else
        app.typeKey(.escape, modifierFlags: [])
#endif
    }
}
