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
            ("signal-snap", "controller.layout.signal-snap"),
            ("gravity-grab", "controller.layout.gravity-grab"),
            ("snake-pit", "controller.layout.snake-pit"),
            ("last-light", "controller.layout.last-light"),
            ("spectator", "controller.layout.spectator"),
            ("game-over", "controller.layout.gameOver"),
            ("history", "controller.layout.history"),
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
            } else if scenario == "signal-snap" {
                for direction in ["up", "down", "left", "right"] {
                    XCTAssertTrue(element("signal.direction.\(direction)", in: app).exists)
                }
            } else if scenario == "snake-pit" {
                XCTAssertTrue(element("snake.direction", in: app).exists)
            } else if scenario == "gravity-grab" {
                XCTAssertTrue(element("gravity.steer", in: app).exists)
            } else if scenario == "last-light" {
                XCTAssertTrue(element("light.steer", in: app).exists)
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
    func testCaptainMemberBotAndMarkControls() throws {
        var app = launch(scenario: "lobby")
        XCTAssertTrue(element("controller.layout.lobby", in: app).waitForExistence(timeout: 5))
        for mark in ["circle", "square", "triangle", "diamond", "star", "hexagon", "plus", "ring"] {
            XCTAssertTrue(element("controller.mark.\(mark)", in: app).exists, "Missing mark \(mark)")
        }
        app.swipeUp()
        XCTAssertTrue(element("controller.lobby.bots.decrease", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(element("controller.lobby.bots.decrease", in: app).isEnabled)
        XCTAssertTrue(element("controller.lobby.bots.increase", in: app).isEnabled)
        XCTAssertEqual(element("controller.lobby.botDifficulty", in: app).label, "DIFFICULTY  HARD")
        XCTAssertTrue(element("controller.lobby.openMenu", in: app).exists)
        app.terminate()

        app = launch(scenario: "lobby-member")
        XCTAssertTrue(element("controller.layout.lobby", in: app).waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertTrue(element("controller.lobby.bots.decrease", in: app).waitForExistence(timeout: 3))
        XCTAssertFalse(element("controller.lobby.bots.decrease", in: app).isEnabled)
        XCTAssertFalse(element("controller.lobby.bots.increase", in: app).isEnabled)
        XCTAssertFalse(element("controller.lobby.openMenu", in: app).exists)
        app.terminate()

        app = launch(scenario: "menu")
        XCTAssertTrue(element("controller.menu.select", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("controller.menu.back", in: app).exists)
        XCTAssertFalse(element("controller.menu.ready", in: app).exists)
        app.terminate()

        app = launch(scenario: "menu-member")
        let ready = element("controller.menu.ready", in: app)
        XCTAssertTrue(ready.waitForExistence(timeout: 5))
        XCTAssertEqual(ready.label, "CANCEL READY")
        XCTAssertFalse(element("controller.menu.select", in: app).exists)
        XCTAssertFalse(element("controller.menu.back", in: app).exists)
        app.terminate()

        app = launch(scenario: "game-over-member")
        let next = element("controller.gameOver.next", in: app)
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertEqual(next.label, "CANCEL READY")
        XCTAssertTrue(element("controller.gameOver.botDifficulty", in: app).exists)
        XCTAssertFalse(element("controller.gameOver.menu", in: app).exists)
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
        guard let address = ProcessInfo.processInfo.environment["PARTYFAULT_HOST"],
              !address.isEmpty,
              address != "$(PARTYFAULT_HOST)" else {
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
        let lobby = element("controller.layout.lobby", in: app)
        if host.waitForExistence(timeout: 3) {
            host.tap()
        }
        XCTAssertTrue(element("controller.state.connected", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(lobby.waitForExistence(timeout: 8))
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
