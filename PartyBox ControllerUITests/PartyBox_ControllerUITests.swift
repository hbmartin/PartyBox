import XCTest

final class PartyBox_ControllerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testHostPickerCompatibilityAndNamePersistence() throws {
        let suite = "PartyBoxControllerUITests.\(UUID().uuidString)"
        var app = launch(scenario: "populated-picker", additional: [
            "--defaults-suite", suite,
            "--controller-id", "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "--display-name", "Initial",
        ])
        let compatible = element("controller.host.127.0.0.1:49999", in: app)
        let incompatible = element("controller.host.127.0.0.1:49998", in: app)
        XCTAssertTrue(compatible.waitForExistence(timeout: 5))
        XCTAssertTrue(compatible.isEnabled)
        XCTAssertTrue(incompatible.exists)
        XCTAssertFalse(incompatible.isEnabled)

        let name = element("controller.name.field", in: app)
        replaceText(in: name, with: "Ada Lovelace")
        let save = element("controller.name.save", in: app)
        save.tap()
        let saved = NSPredicate(format: "value == %@", "Saved Ada Lovelace")
        expectation(for: saved, evaluatedWith: save)
        waitForExpectations(timeout: 3)
        app.terminate()

        app = launch(scenario: "empty-picker", additional: ["--defaults-suite", suite])
        XCTAssertEqual(element("controller.name.field", in: app).value as? String, "Ada Lovelace")
    }

    @MainActor
    func testEveryControllerLayoutAndErrors() throws {
        let expected: [(String, String)] = [
            ("lobby", "controller.layout.lobby"),
            ("menu", "controller.layout.menu"),
            ("paddle-bottom", "controller.layout.paddle.bottom"),
            ("paddle-top", "controller.layout.paddle.top"),
            ("paddle-left", "controller.layout.paddle.left"),
            ("paddle-right", "controller.layout.paddle.right"),
            ("spectator", "controller.layout.spectator"),
            ("game-over", "controller.layout.gameOver"),
            ("connecting", "controller.state.connecting"),
            ("reconnecting", "controller.state.reconnecting"),
            ("full-rejection", "controller.state.rejected"),
            ("version-rejection", "controller.state.rejected"),
            ("connection-loss", "controller.state.disconnected"),
            ("local-network-denial", "controller.discovery.help"),
        ]
        for (scenario, identifier) in expected {
            let app = launch(scenario: scenario)
            XCTAssertTrue(element(identifier, in: app).waitForExistence(timeout: 5), "Missing fixture \(scenario)")
            if scenario == "spectator" {
                XCTAssertEqual(element("controller.spectator.position", in: app).label, "#2 IN QUEUE")
            } else if scenario == "game-over" {
                XCTAssertTrue(element("controller.gameOver.next", in: app).exists)
                XCTAssertTrue(element("controller.gameOver.menu", in: app).exists)
            }
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Controller-\(scenario)"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    @MainActor
    func testPaddleEndpointsUpdateLocalValueImmediately() throws {
        let app = launch(scenario: "paddle-left")
        let track = element("controller.paddle.track", in: app)
        XCTAssertTrue(track.waitForExistence(timeout: 5))
        track.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: track.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)))
        XCTAssertNotEqual(track.value as? String, "0.000")

        track.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: track.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)))
        XCTAssertTrue((track.value as? String)?.hasPrefix("-") == true)
    }

    @MainActor
    func testConnectionErrorRecoversToPicker() throws {
        let app = launch(scenario: "connection-loss")
        let back = element("controller.error.back", in: app)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(element("controller.hostPicker", in: app).waitForExistence(timeout: 5))
    }

    @MainActor
    func testLiveConnectionThroughPartyFault() throws {
        guard let address = ProcessInfo.processInfo.environment["PARTYFAULT_HOST"] else {
            throw XCTSkip("scripts/verify.sh supplies PARTYFAULT_HOST for the live smoke flow")
        }
        let app = launch(additional: [
            "--host", address,
            "--defaults-suite", "PartyBoxControllerUITests.Live",
            "--controller-id", "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF",
            "--display-name", "Live Tester",
        ])
        addUIInterruptionMonitor(withDescription: "Local Network") { alert in
            for title in ["Allow", "OK"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        app.tap()
        let host = element("controller.host.\(address)", in: app)
        XCTAssertTrue(host.waitForExistence(timeout: 8))
        host.tap()
        XCTAssertTrue(element("controller.layout.lobby", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(element("controller.roster.player.1", in: app).exists)
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
    private func replaceText(in element: XCUIElement, with value: String) {
        element.tap()
        let current = (element.value as? String)?.count ?? 24
        element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current))
        element.typeText(value)
    }
}
