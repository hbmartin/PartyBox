import Foundation
import PartyBoxCore
import PartyGameRuntime
import PartyNet
import Testing
@testable import PartyGames

@Suite("Controller screen JSON goldens")
@MainActor
struct ControllerScreenGoldenTests {
    @Test func gameAndSpectatorScreensMatchCommittedJSON() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let decoder = JSONDecoder()
        let records = fixtures()
        #expect(Set(records.map(\.name)).count == records.count)
        let recording = ProcessInfo.processInfo.environment["PARTYGAMES_RECORD_GOLDENS"] == "1"
        let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)

        for record in records {
            #expect(record.screen.isValid, "\(record.name) must be valid")
            let encoded = try encoder.encode(record.screen)
            let roundTrip = try decoder.decode(ControllerScreen.self, from: encoded)
            #expect(roundTrip == record.screen, "\(record.name) must round-trip")
            let wire = try PartyBoxWireCodec.encode(record.screen)
            #expect(try PartyBoxWireCodec.decode(ControllerScreen.self, from: wire) == record.screen)
            if recording {
                try encoded.write(to: sourceDirectory.appendingPathComponent("\(record.name).json"))
                continue
            }
            let fixtureURL = try #require(Bundle.module.url(forResource: record.name, withExtension: "json"))
            let expected = try Data(contentsOf: fixtureURL)
            #expect(encoded == expected, "\(record.name).json changed")
        }
    }

    private func fixtures() -> [(name: String, screen: ControllerScreen)] {
        let participants: [GameParticipant] = (0..<8).map { index in
            let id = PlayerID(UInt8(index))
            let uuid = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
            return GameParticipant(
                player: PlayerInfo(
                    id: id,
                    displayName: ["Ada", "Grace", "Lin", "Sam", "Jo", "Max", "Lee", "Kai"][index],
                    colorHex: PlayerPalette.color(for: id),
                    mark: PlayerMark.allCases[index]
                ),
                controllerID: ControllerID(rawValue: uuid)
            )
        }
        let games = PartyGames.all()
        var output: [(name: String, screen: ControllerScreen)] = []

        for game in games {
            let count = game.descriptor.id == "pong" ? 4 : 8
            let context = GameSessionContext(
                participants: Array(participants.prefix(count)),
                inputs: InputStore(), seed: 42, modifierID: nil
            )
            let session = game.makeSession(context: context, onEvents: { _ in })
            if game.descriptor.id == "pong" {
                for (index, edge) in ["bottom", "top", "left", "right"].enumerated() {
                    output.append(("pong-active-\(edge)", session.controllerScreen(for: participants[index].player.id)))
                }
                let qualifier = game.makeSession(context: .init(
                    participants: Array(participants.prefix(5)), inputs: InputStore(), seed: 42, modifierID: nil
                ), onEvents: { _ in })
                output.append(("pong-active-qualifier", qualifier.controllerScreen(for: participants[0].player.id)))
            } else {
                output.append(("\(game.descriptor.id)-active", session.controllerScreen(for: participants[0].player.id)))
            }

            let choices = game.availableModifiers(participantCount: count)
            let states: [(String, PlayerRole)] = [
                ("waiting", .waiting(position: 2)),
                ("eliminated", .eliminated),
                ("defensive-active", .active),
            ]
            for (name, role) in states {
                output.append(("\(game.descriptor.id)-spectator-\(name)", SpectatorScreenFactory.make(
                    game: game.descriptor,
                    state: .init(role: role, choices: choices, tallies: [:], selection: nil)
                )))
            }
        }

        let pong = games[0]
        let choices = pong.availableModifiers(participantCount: 4)
        output.append(("pong-spectator-vote-selected", SpectatorScreenFactory.make(
            game: pong.descriptor,
            state: .init(role: .waiting(position: 1), choices: choices,
                         tallies: ["fast-ball": 2, "big-paddles": 1], selection: "fast-ball")
        )))
        output.append(("pong-spectator-no-vote", SpectatorScreenFactory.make(
            game: pong.descriptor,
            state: .init(role: .waiting(position: 3),
                         choices: pong.availableModifiers(participantCount: 5), tallies: [:], selection: nil)
        )))
        return output
    }
}
