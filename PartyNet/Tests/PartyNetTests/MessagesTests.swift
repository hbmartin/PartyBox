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
        #expect(UnicodeSequenceData.emojiZWJVariationSequencesAreRegistered())
        #expect(DisplayName.sanitized("  Ada   Lovelace  ", fallback: "Player") == "Ada Lovelace")
        #expect(DisplayName.sanitized("Ada\nLovelace", fallback: "Player") == "Ada Lovelace")
        #expect(DisplayName.sanitized("\u{202E}Admin\u{0007}", fallback: "Player") == "Admin")
        #expect(DisplayName.sanitized("", fallback: "\u{202E}Player") == "Player")
        #expect(DisplayName.sanitized("   ", fallback: "Player 1") == "Player 1")
        #expect(DisplayName.sanitized("\u{200B}\u{2060}", fallback: "Player 1") == "Player 1")
        #expect(DisplayName.sanitized("A\u{200B}da", fallback: "Player") == "Ada")
        #expect(DisplayName.sanitized("👩‍💻", fallback: "Player") == "👩‍💻")
        let persian = "می\u{200C}روم"
        #expect(DisplayName.sanitized(persian, fallback: "Player") == persian)
        let scotland = "🏴\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}"
        #expect(DisplayName.sanitized(scotland, fallback: "Player") == scotland)
        #expect(DisplayName.sanitized("\u{200D}Ada\u{200D}", fallback: "Player") == "Ada")
        #expect(DisplayName.sanitized("A\u{200C}B", fallback: "Player") == "AB")
        #expect(DisplayName.sanitized("©\u{200D}®", fallback: "Player") == "©®")
        #expect(DisplayName.sanitized("A\u{E0067}da", fallback: "Player") == "Ada")
        #expect(DisplayName.sanitized("\u{FE0F}Ada", fallback: "Player") == "Ada")
        #expect(DisplayName.sanitized("A\u{FE0F}", fallback: "Player") == "A")
        #expect(DisplayName.sanitized("🐶‍🐱", fallback: "Player") == "🐶🐱")
        let validThenInvalidZWJ = "👩\u{200D}💻\u{200D}🐶"
        #expect(DisplayName.sanitized(validThenInvalidZWJ, fallback: "Player") == "👩\u{200D}💻🐶")
        let invalidThenValidZWJ = "🐶\u{200D}👩\u{200D}💻"
        #expect(DisplayName.sanitized(invalidThenValidZWJ, fallback: "Player") == "🐶👩\u{200D}💻")
        let standardizedVariant = "\u{2268}\u{FE00}"
        #expect(DisplayName.sanitized(standardizedVariant, fallback: "Player") == standardizedVariant)
        let tonedEmoji = "👩🏽‍💻"
        #expect(DisplayName.sanitized(tonedEmoji, fallback: "Player") == tonedEmoji)
        let familyEmoji = "👨‍👩‍👧‍👦"
        #expect(DisplayName.sanitized(familyEmoji, fallback: "Player") == familyEmoji)
        let longestZWJSequence = "👨🏻‍❤️‍💋‍👨🏻"
        #expect(longestZWJSequence.unicodeScalars.count == 10)
        #expect(DisplayName.sanitized(longestZWJSequence, fallback: "Player") == longestZWJSequence)
        let maximumMalformedZWJCluster = "👩" + String(repeating: "\u{200D}👩", count: 63)
        #expect(maximumMalformedZWJCluster.unicodeScalars.count == 127)
        #expect(
            DisplayName.sanitized(maximumMalformedZWJCluster, fallback: "Player")
                == String(repeating: "👩", count: 24)
        )
        let california = emojiTagSequence("usca")
        #expect(DisplayName.sanitized(california, fallback: "Player") == california)
        #expect(DisplayName.sanitized(emojiTagSequence("ushuh"), fallback: "Player") == "🏴")
        let overlong = emojiTagSequence(String(repeating: "a", count: 30))
        #expect(DisplayName.sanitized(overlong, fallback: "Player") == "🏴")
        let beyondAnalysisLimit = String(repeating: "\u{200B}", count: 128) + "Visible"
        #expect(DisplayName.sanitized(beyondAnalysisLimit, fallback: "Player") == "Player")
        #expect(DisplayName.sanitized(String(repeating: "x", count: 40), fallback: "Player").count == 24)
    }

    @Test func hostAddressParsingRequiresAnExplicitValidPortAndBracketedIPv6() throws {
        let named = try #require(HostAddress(parsing: "partybox.local:49999"))
        #expect(named.host == "partybox.local")
        #expect(named.port == 49_999)

        let ipv6 = try #require(HostAddress(parsing: "[fe80::1%en0]:65535"))
        #expect(ipv6.host == "fe80::1%en0")
        #expect(ipv6.port == 65_535)

        let maximumNumericScope = try #require(HostAddress(parsing: "[fe80::1%4294967295]:49999"))
        #expect(maximumNumericScope.host == "fe80::1%4294967295")

        #expect(HostAddress(parsing: "fe80::1:49999") == nil)
        #expect(HostAddress(parsing: ":49999") == nil)
        #expect(HostAddress(parsing: "partybox.local:0") == nil)
        #expect(HostAddress(parsing: "partybox.local:+49999") == nil)
        #expect(HostAddress(parsing: "partybox.local:65536") == nil)
        #expect(HostAddress(parsing: "partybox.local") == nil)
        #expect(HostAddress(parsing: "[not-an-ipv6]:49999") == nil)
        #expect(HostAddress(parsing: "[fe80:::1]:49999") == nil)
        #expect(HostAddress(parsing: "[fe80::1%]:49999") == nil)
        #expect(HostAddress(parsing: "[fe80::1%lo0%en0]:49999") == nil)
        #expect(HostAddress(parsing: "[fe80::1%not-an-interface]:49999") == nil)
        #expect(HostAddress(parsing: "[fe80::1%0]:49999") == nil)
        #expect(HostAddress(parsing: "[fe80::1%+1]:49999") == nil)
        #expect(HostAddress(parsing: "[fe80::1%١]:49999") == nil)
        #expect(HostAddress(parsing: "[fe80::1%4294967296]:49999") == nil)
        #expect(HostAddress(parsing: "[::1]:+49999") == nil)

        var attemptedInterfaceLookup = false
        #expect(!HostAddress.isValidScopeIdentifier(
            "4294967296",
            interfaceIndex: { _ in
                attemptedInterfaceLookup = true
                return 1
            }
        ))
        #expect(!attemptedInterfaceLookup)
    }

    @Test func eventHubFinishEndsCurrentStreamsAndAllowsFreshSubscriptions() async {
        let hub = EventHub<Int>()
        let firstStream = hub.stream()
        hub.finish()
        var firstIterator = firstStream.makeAsyncIterator()
        let finishedValue = await firstIterator.next()
        #expect(finishedValue == nil)

        let secondStream = hub.stream()
        hub.yield(42)
        var secondIterator = secondStream.makeAsyncIterator()
        let yieldedValue = await secondIterator.next()
        #expect(yieldedValue == 42)
        hub.finish()
        let secondFinishedValue = await secondIterator.next()
        #expect(secondFinishedValue == nil)
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
        #expect(ArcadePalette.rgb("(#32E6FF)") == nil)
        #expect(ArcadePalette.rgb("##32E6FF") == nil)
    }

    private func assertRoundTrips<T: Codable & Equatable>(_ values: [T]) throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for value in values {
            let decoded = try decoder.decode(T.self, from: encoder.encode(value))
            #expect(decoded == value)
        }
    }

    private func emojiTagSequence(_ payload: String) -> String {
        let tags = payload.unicodeScalars.compactMap { Unicode.Scalar($0.value + 0xE0000) }
        return "🏴" + String(String.UnicodeScalarView(tags)) + "\u{E007F}"
    }
}
