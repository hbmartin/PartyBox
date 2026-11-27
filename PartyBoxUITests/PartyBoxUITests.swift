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
    func testEmptyLobbyScreenshot() {
        assertFixture("empty-lobby", phase: "lobby")
    }

    @MainActor
    func testFourPlayerLobbyScreenshot() {
        assertFixture(
            "four-player-lobby", phase: "lobby",
            elements: ["host.lobby.captain", "host.lobby.botStatus", "host.lobby.botDifficulty"]
        )
    }

    @MainActor
    func testGameMenuScreenshot() {
        assertFixture("menu", phase: "menu", elements: ["host.ready.status"])
    }

    @MainActor
    func testFourWayPongScreenshot() {
        assertFixture("four-way-match", phase: "playing")
    }

    @MainActor
    func testSnakePitScreenshot() {
        assertFixture("snake-pit-match", phase: "playing")
    }

    @MainActor
    func testLastLightScreenshot() {
        assertFixture("last-light-match", phase: "playing")
    }

    @MainActor
    func testBumperBrawlScreenshot() {
        assertFixture("bumper-brawl-match", phase: "playing")
    }

    @MainActor
    func testPaintRushScreenshot() {
        assertFixture("paint-rush-match", phase: "playing")
    }

    @MainActor
    func testSkyHopScreenshot() {
        assertFixture("sky-hop-match", phase: "playing")
    }

    @MainActor
    func testHotFuseScreenshot() {
        assertFixture("hot-fuse-match", phase: "playing")
    }

    @MainActor
    func testTurboLoopScreenshot() {
        assertFixture("turbo-loop-match", phase: "playing")
    }

    @MainActor
    func testCupSetupScreenshot() {
        assertFixture("cup-setup", phase: "cupSetup")
    }

    @MainActor
    func testCupStandingsScreenshot() {
        assertFixture("cup-standings", phase: "cupStandings")
    }

    @MainActor
    func testCupCompleteScreenshot() {
        assertFixture("cup-complete", phase: "cupComplete")
    }

    @MainActor
    func testGameOverScreenshot() {
        assertFixture(
            "game-over", phase: "gameOver",
            elements: ["host.gameOver.botDifficulty", "host.ready.status"]
        )
    }

    @MainActor
    func testHistoryScreenshot() {
        assertFixture("history", phase: "history")
    }

    @MainActor
    private func assertFixture(_ scenario: String, phase: String, elements: [String] = []) {
        let app = launch(scenario: scenario)
        defer { app.terminate() }
        XCTAssertTrue(element("host.phase.\(phase)", in: app).waitForExistence(timeout: 5), "Missing fixture \(scenario)")
        for identifier in elements {
            XCTAssertTrue(element(identifier, in: app).exists, "Missing \(identifier) in \(scenario)")
        }
#if os(macOS)
        let screenshot = app.windows.firstMatch.screenshot()
#else
        let screenshot = app.screenshot()
#endif
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Host-\(scenario)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testCupHistoryShowsFallbackForMissingChampions() {
        let app = launch(scenario: "cup-history")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Cup complete"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testHostNavigationRevealsOffscreenMenuCards() {
#if os(macOS)
        // Each step sends a real key and synchronizes the window before and after delivery.
        executionTimeAllowance = 180
#endif
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
    }

    @MainActor
    func testHostNavigationRevealsOffscreenCupCards() {
        let app = launch(scenario: "cup-setup", freezeScenario: false, additional: ["--compact-host-window"])
        defer { app.terminate() }
        XCTAssertTrue(element("host.phase.cupSetup", in: app).waitForExistence(timeout: 5))
        // The fixture opens on the third game. Navigate to the start card at index eight.
        for _ in 2..<8 { moveSelection(forward: true, in: app) }
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
        app.windows.firstMatch.typeKey(forward ? .rightArrow : .leftArrow, modifierFlags: [])
#endif
    }

    @MainActor
    private func activateSelect(in app: XCUIApplication) {
#if os(tvOS)
        XCUIRemote.shared.press(.select)
#else
        app.windows.firstMatch.typeKey(.return, modifierFlags: [])
#endif
    }

    @MainActor
    private func activateExit(in app: XCUIApplication) {
#if os(tvOS)
        XCUIRemote.shared.press(.menu)
#else
        app.windows.firstMatch.typeKey(.escape, modifierFlags: [])
#endif
    }
}
