import Foundation
import Testing
@testable import PartyNet

@Suite("Control message coding")
struct MessagesTests {
    private let player = PlayerInfo(id: PlayerID(2), displayName: "Harold", colorHex: "#FFE44D")

    @Test func clientMessagesRoundTrip() throws {
        let frame = InputFrame(token: 9, sequence: 4, clientTimeMs: 12, axisX: 0.25, axisY: -0.5, buttons: .primary)
        let messages: [ClientMessage] = [
            .hello(Hello(controllerID: ControllerID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!), displayName: "Harold")),
            .rename("A new name"),
            .menu(.select),
            .input(frame),
            .ping(44),
            .leave,
        ]
        try assertRoundTrips(messages)
    }

    @Test func hostMessagesRoundTrip() throws {
        let welcome = Welcome(
            player: player,
            udpPort: 8080,
            sessionToken: 123,
            hostName: "Living Room",
            hostInstanceID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        let messages: [HostMessage] = [
            .welcome(welcome),
            .rejected(.full),
            .rejected(.versionMismatch(hostVersion: 3)),
            .rejected(.malformedHello),
            .rejected(.replaced),
            .roster([player]),
            .layout(.lobby),
            .layout(.menu(items: ["Pong"], selected: 0)),
            .layout(.paddle(PaddleLayout(edge: .left, colorHex: player.colorHex, label: "Player 3 · Left"))),
            .layout(.spectator(SpectatorLayout(queuePosition: 2))),
            .layout(.gameOver(title: "Winner!", subtitle: "Great rally")),
            .feedback(.won),
            .inputAck(sequence: 54),
            .pong(55),
        ]
        try assertRoundTrips(messages)
    }

    @Test func displayNameValidation() {
        #expect(DisplayName.sanitized("  Ada   Lovelace  ", fallback: "Player") == "Ada Lovelace")
        #expect(DisplayName.sanitized("Ada\nLovelace", fallback: "Player") == "Ada Lovelace")
        #expect(DisplayName.sanitized("\u{202E}Admin\u{0007}", fallback: "Player") == "Admin")
        #expect(DisplayName.sanitized("", fallback: "\u{202E}Player") == "Player")
        #expect(DisplayName.sanitized("   ", fallback: "Player 1") == "Player 1")
        #expect(DisplayName.sanitized(String(repeating: "x", count: 40), fallback: "Player").count == 24)
    }

    @Test func arcadePaletteParsesSharedHexColors() throws {
        let cyan = try #require(ArcadePalette.rgb(ArcadePalette.cyan))
        #expect(cyan.red == Double(0x32) / 255)
        #expect(cyan.green == Double(0xE6) / 255)
        #expect(cyan.blue == 1)
        #expect(PlayerPalette.colors[0] == ArcadePalette.cyan)
        #expect(PlayerPalette.colors[1] == ArcadePalette.magenta)
        #expect(PlayerPalette.colors[3] == ArcadePalette.lime)
        #expect(ArcadePalette.rgb("not-a-color") == nil)
    }

    private func assertRoundTrips<T: Codable & Equatable>(_ values: [T]) throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for value in values {
            let decoded = try decoder.decode(T.self, from: encoder.encode(value))
            #expect(decoded == value)
        }
    }
}
