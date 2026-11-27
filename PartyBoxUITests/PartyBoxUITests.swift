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
            ("snake-pit-match", "host.phase.playing"),
            ("last-light-match", "host.phase.playing"),
            ("bumper-brawl-match", "host.phase.playing"),
            ("paint-rush-match", "host.phase.playing"),
            ("sky-hop-match", "host.phase.playing"),
            ("hot-fuse-match", "host.phase.playing"),
            ("turbo-loop-match", "host.phase.playing"),
            ("cup-setup", "host.phase.cupSetup"),
            ("cup-standings", "host.phase.cupStandings"),
            ("cup-complete", "host.phase.cupComplete"),
            ("game-over", "host.phase.gameOver"),
            ("history", "host.phase.history"),
        ] {
            let app = launch(scenario: scenario)
            XCTAssertTrue(element(identifier, in: app).waitForExistence(timeout: 5), "Missing fixture \(scenario)")
            if scenario == "four-player-lobby" {
                XCTAssertTrue(element("host.lobby.captain", in: app).exists)
                XCTAssertTrue(element("host.lobby.botStatus", in: app).exists)
                XCTAssertTrue(element("host.lobby.botDifficulty", in: app).exists)
            } else if scenario == "menu" {
                XCTAssertTrue(element("host.ready.status", in: app).exists)
            } else if scenario == "game-over" {
                XCTAssertTrue(element("host.gameOver.botDifficulty", in: app).exists)
                XCTAssertTrue(element("host.ready.status", in: app).exists)
            }
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Host-\(scenario)"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    @MainActor
    func testCupHistoryShowsFallbackForMissingChampions() {
        let app = launch(scenario: "cup-history")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Cup complete"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testHostNavigationRevealsOffscreenMenuAndCupCards() {
        let app = launch(scenario: "menu", freezeScenario: false, additional: ["--compact-host-window"])
        defer { app.terminate() }
        XCTAssertTrue(element("host.phase.menu", in: app).waitForExistence(timeout: 5))
        for _ in 0..<9 { moveSelection(forward: true, in: app) }
        XCTAssertTrue(element("host.menu.action.9", in: app).isHittable)
        activateSelect(in: app)
        XCTAssertTrue(element("host.phase.history", in: app).waitForExistence(timeout: 5))

        activateExit(in: app)
        XCTAssertTrue(element("host.phase.menu", in: app).waitForExistence(timeout: 5))
        moveSelection(forward: false, in: app)
        XCTAssertTrue(element("host.menu.action.8", in: app).isHittable)
        activateSelect(in: app)
        XCTAssertTrue(element("host.phase.cupSetup", in: app).waitForExistence(timeout: 5))

        for _ in 0..<8 { moveSelection(forward: true, in: app) }
        XCTAssertTrue(element("host.cupSetup.action.8", in: app).isHittable)
        XCTAssertTrue(element("host.ready.status", in: app).isHittable)
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

#if os(macOS)
    @MainActor
    func testDiagnosticsExportFailureShowsLocalizedReason() throws {
        let app = launch(scenario: "history", additional: ["--fail-diagnostics-export"])
        defer { app.terminate() }
        let prepare = element("host.history.diagnostics.prepare", in: app)
        XCTAssertTrue(prepare.waitForExistence(timeout: 5))
        for _ in 0..<5 {
            if prepare.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(prepare.isHittable)
        prepare.click()

        let failure = element("host.history.diagnostics.error", in: app)
        XCTAssertTrue(failure.waitForExistence(timeout: 5))
        let failureText = [failure.label, failure.value as? String ?? ""].joined(separator: " ")
        XCTAssertTrue(
            failureText.contains("Diagnostics couldn’t be prepared:")
                && failureText.localizedCaseInsensitiveContains("permission"),
            "Unexpected diagnostics error: \(failureText)"
        )
    }
#endif

    @MainActor
    private func launch(
        scenario: String? = nil,
        freezeScenario: Bool = true,
        additional: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--disable-animations", "--disable-effects", "--seed", "42"]
        if let scenario {
            app.launchArguments += ["--scenario", scenario]
            if freezeScenario { app.launchArguments.append("--freeze-scenario") }
        }
        app.launchArguments += additional
        app.launch()
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func moveSelection(forward: Bool, in app: XCUIApplication) {
#if os(tvOS)
        XCUIRemote.shared.press(forward ? .right : .left)
#else
        app.typeKey(forward ? .rightArrow : .leftArrow, modifierFlags: [])
#endif
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
