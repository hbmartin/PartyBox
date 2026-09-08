import Foundation
import PartyNet
import Testing
@testable import PartyBoxCore

@Suite("PartyBox application protocol")
struct CoreModelsTests {
    private let firstID = ControllerID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
    private let secondID = ControllerID(rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)

    @Test func applicationMessagesRoundTripOverOpaqueData() throws {
        let screen = ControllerScreen(
            accessibilityID: "game.controller",
            accentColorHex: "#32E6FF",
            requestedInputs: .orientation,
            components: [
                .text(.init(id: "title", text: "Tilt", style: .title)),
                .axisSurface(.init(id: "move", binding: .twoDimensional, instruction: "Move")),
            ]
        )
        let screenData = try PartyBoxWireCodec.encode(screen)
        let presentation = HostPresentation.layout(.game(.init(gameID: "motion-game", payload: screenData)))
        let encoded = try PartyBoxWireCodec.encode(presentation)
        #expect(try PartyBoxWireCodec.decode(HostPresentation.self, from: encoded) == presentation)

        let command = ControllerCommand.game(.init(
            gameID: "motion-game",
            action: .init(id: "boost", value: .trigger)
        ))
        #expect(try PartyBoxWireCodec.decode(ControllerCommand.self, from: PartyBoxWireCodec.encode(command)) == command)
    }

    @Test func schemaRejectsDuplicateAndExcessiveComponentIDs() {
        let duplicate = ControllerScreen(
            accessibilityID: "duplicate", accentColorHex: "#FFFFFF",
            components: [
                .text(.init(id: "same", text: "One", style: .body)),
                .status(.init(id: "same", label: "Two", value: "2")),
            ]
        )
        #expect(!duplicate.isValid)
        let tooMany = ControllerScreen(
            accessibilityID: "large", accentColorHex: "#FFFFFF",
            components: (0...32).map { .text(.init(id: "\($0)", text: "x", style: .body)) }
        )
        #expect(!tooMany.isValid)
    }

    @Test func spectatorScreenIncludesCompetitiveReactionsAndSeededVoteState() throws {
        let modifier = GameModifierDescriptor(id: "fast", title: "Fast", detail: "+25%")
        let game = GameDescriptor(
            id: "pong", title: "Pong", summary: "Winner stays",
            minimumPlayers: 1, maximumPlayers: 4, modifiers: [modifier]
        )
        let screen = SpectatorScreenFactory.make(
            game: game,
            state: .init(role: .waiting(position: 2), choices: [modifier], tallies: ["fast": 3], selection: "fast")
        )
        #expect(screen.isValid)
        #expect(SpectatorScreenFactory.reactions == ["🔥", "👏", "😤", "😱", "💀", "🧂"])
        #expect(screen.components.contains { component in
            guard case .choiceGroup(let group) = component else { return false }
            return group.selection == "fast" && group.choices.first?.tally == 3
        })
    }

    @Test func historyPersistsDatesDeduplicatesAndClears() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = match(id: UUID(uuidString: "99999999-2222-3333-4444-555555555555")!)

        let writer = JSONRecordStore<MatchRecord>(fileURL: url)
        #expect(try await writer.append(record))
        #expect(!(try await writer.append(record)))

        let reader = JSONRecordStore<MatchRecord>(fileURL: url)
        #expect(await reader.all() == [record])
        try await reader.clear()
        #expect(await reader.all().isEmpty)
        #expect(await JSONRecordStore<MatchRecord>(fileURL: url).all().isEmpty)
    }

    @Test func malformedHistoryIsPreservedAsCorruptBackup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)

        let store = JSONRecordStore<MatchRecord>(fileURL: url)
        #expect(await store.all().isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.contains { $0.hasPrefix("history.corrupt-") && $0.hasSuffix(".json") })
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func leaderboardAndPersonalStatisticsIgnorePracticeRounds() {
        let competitive = match()
        let practice = MatchRecord(
            gameID: "pong", gameTitle: "Pong", endedAt: Date(timeIntervalSince1970: 20),
            durationSeconds: 10, modifierTitle: nil,
            participants: [.init(controllerID: firstID, displayName: "Ada", colorHex: "#FFFFFF", outcome: .practice)],
            metrics: []
        )
        let board = HistoryAggregation.leaderboard([practice, competitive])
        #expect(board.map(\.statistics.played) == [1, 1])
        #expect(board.first?.displayName == "Ada")
        #expect(board.first?.statistics.won == 1)

        let personal = [competitive, practice].map { PersonalMatchRecord(record: $0, controllerID: firstID) }
        #expect(HistoryAggregation.personal(personal) == .init(played: 1, won: 1))
    }

    private func match(id: UUID = UUID()) -> MatchRecord {
        MatchRecord(
            id: id, gameID: "pong", gameTitle: "Pong",
            endedAt: Date(timeIntervalSince1970: 10), durationSeconds: 45,
            modifierTitle: "Fast Ball",
            participants: [
                .init(controllerID: firstID, displayName: "Ada", colorHex: "#32E6FF", outcome: .won),
                .init(controllerID: secondID, displayName: "Grace", colorHex: "#FF3EC8", outcome: .lost),
            ],
            metrics: [.init(id: "rally", label: "Rally", value: "12")]
        )
    }
}
