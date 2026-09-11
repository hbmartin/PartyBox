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
                .directionPad(.init(id: "direction", instruction: "Choose")),
            ]
        )
        let screenData = try PartyBoxWireCodec.encode(screen)
        let envelope = GameLayoutEnvelope(gameID: "motion-game", payload: screenData)
        #expect(envelope.schemaVersion == ControllerScreen.schemaVersion)
        #expect(envelope.validatedControllerScreen == screen)
        #expect(GameLayoutEnvelope(
            gameID: "motion-game",
            schemaVersion: ControllerScreen.schemaVersion + 1,
            payload: screenData
        ).validatedControllerScreen == nil)
        let presentation = HostPresentation.layout(.game(envelope))
        let encoded = try PartyBoxWireCodec.encode(presentation)
        #expect(try PartyBoxWireCodec.decode(HostPresentation.self, from: encoded) == presentation)

        let cue = HostPresentation.deviceCue(.init(colorHex: "#39FF88", durationMilliseconds: 999, haptic: .success))
        #expect(try PartyBoxWireCodec.decode(HostPresentation.self, from: PartyBoxWireCodec.encode(cue)) == cue)

        let nextEvent = HostPresentation.layout(.gameOver(.init(
            title: "EVENT COMPLETE",
            subtitle: "Party Cup continues",
            nextUp: "GRAVITY GRAB"
        )))
        #expect(try PartyBoxWireCodec.decode(
            HostPresentation.self,
            from: PartyBoxWireCodec.encode(nextEvent)
        ) == nextEvent)

        let command = ControllerCommand.game(.init(
            gameID: "motion-game",
            action: .init(id: "boost", value: .trigger)
        ))
        if case .game(let actionEnvelope) = command {
            #expect(actionEnvelope.schemaVersion == ControllerScreen.schemaVersion)
        }
        #expect(try PartyBoxWireCodec.decode(ControllerCommand.self, from: PartyBoxWireCodec.encode(command)) == command)
    }

    @Test func partyCupRecordsProducePrivatePersistentTrophiesWithoutDiscardingEvents() throws {
        let cup = CupRecord(
            endedAt: Date(timeIntervalSince1970: 100),
            gameIDs: ["pong", "signal-snap", "snake-pit", "ignored"],
            matchRecordIDs: [UUID()],
            standings: [
                .init(controllerID: secondID, displayName: "Grace", colorHex: "#FF3EC8", kind: .human, rank: 2, points: 14, eventWins: 1),
                .init(controllerID: firstID, displayName: "Ada", colorHex: "#32E6FF", kind: .human, rank: 1, points: 18, eventWins: 2),
            ]
        )
        let personal = try #require(PersonalCupRecord(record: cup, controllerID: firstID))
        #expect(cup.gameIDs == ["pong", "signal-snap", "snake-pit", "ignored"])
        #expect(cup.standings.first?.displayName == "Ada")
        #expect(personal.isChampion)
        #expect(HistoryAggregation.cups([personal]) == .init(played: 1, won: 1, podiums: 1))
        #expect(PersonalCupRecord(record: cup, controllerID: ControllerID()) == nil)
    }

    @Test func malformedCupRanksDoNotCountAsPodiums() throws {
        let cup = CupRecord(
            endedAt: Date(timeIntervalSince1970: 100),
            gameIDs: ["pong", "signal-snap", "snake-pit"],
            matchRecordIDs: [],
            standings: [
                .init(
                    controllerID: firstID,
                    displayName: "Ada",
                    colorHex: "#32E6FF",
                    kind: .human,
                    rank: 1,
                    points: 18,
                    eventWins: 2
                ),
            ]
        )
        let valid = try #require(PersonalCupRecord(record: cup, controllerID: firstID))
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any]
        )
        object["rank"] = 0
        object["isChampion"] = false
        let malformed = try JSONDecoder().decode(
            PersonalCupRecord.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(HistoryAggregation.cups([malformed]) == .init(played: 1, won: 0, podiums: 0))
    }

    @Test func diagnosticsExportReplacesItsStableRoleFile() throws {
        struct Report: Codable, Equatable {
            let value: String
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let firstURL = try RedactedDiagnosticsExporter.write(
            Report(value: "first"), role: .host, directory: directory
        )
        let secondURL = try RedactedDiagnosticsExporter.write(
            Report(value: "second"), role: .host, directory: directory
        )

        #expect(firstURL == secondURL)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [
            "PartyBox-host-diagnostics.json",
        ])
        #expect(try JSONDecoder().decode(Report.self, from: Data(contentsOf: secondURL)) == .init(value: "second"))
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

        for invalidColor in ["#ZZZZZZ", "1234567", "#12345G", " #12345"] {
            let malformed = ControllerScreen(
                accessibilityID: "bad-color",
                accentColorHex: invalidColor,
                components: []
            )
            #expect(!malformed.isValid)
        }
        #expect(ControllerScreen(
            accessibilityID: "lowercase-color",
            accentColorHex: "#a1b2c3",
            components: []
        ).isValid)
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
        #expect(await writer.append(record) == .inserted)
        #expect(await writer.append(record) == .duplicate)

        let reader = JSONRecordStore<MatchRecord>(fileURL: url)
        #expect(await reader.all() == [record])
        try await reader.clear()
        #expect(await reader.all().isEmpty)
        #expect(await JSONRecordStore<MatchRecord>(fileURL: url).all().isEmpty)
    }

    @Test func historyAppendDistinguishesDuplicatesFromPersistenceFailures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let blockedParent = directory.appendingPathComponent("not-a-directory")
        let url = blockedParent.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("blocked".utf8).write(to: blockedParent)
        let record = match()
        let store = JSONRecordStore<MatchRecord>(fileURL: url)

        let result = await store.append(record)

        #expect(result.wasInserted)
        #expect(result.persistenceErrorDescription?.isEmpty == false)
        #expect(await store.all() == [record])
        #expect(await store.append(record) == .duplicate)
    }

    @Test func failedHistoryClearKeepsTheAcceptedInMemoryRecords() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storageDirectory = directory.appendingPathComponent("store", isDirectory: true)
        let url = storageDirectory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = match()
        let store = JSONRecordStore<MatchRecord>(fileURL: url)
        #expect(await store.append(record) == .inserted)

        try FileManager.default.removeItem(at: storageDirectory)
        try Data("blocked".utf8).write(to: storageDirectory)

        await #expect(throws: (any Error).self) {
            try await store.clear()
        }
        #expect(await store.all() == [record])
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

    @Test func historySeparatesPracticeSoloAndPartyAndExcludesBotsFromLeaderboard() {
        let botID = ControllerID()
        let solo = MatchRecord(
            gameID: "pong", gameTitle: "Pong", endedAt: Date(timeIntervalSince1970: 30),
            durationSeconds: 10, modifierTitle: nil,
            participants: [
                .init(controllerID: firstID, displayName: "Ada", colorHex: "#FFFFFF", outcome: .won),
                .init(controllerID: botID, displayName: "Bot 1", colorHex: "#00FFFF", outcome: .lost, kind: .bot),
            ],
            metrics: []
        )
        let party = match()
        let practice = MatchRecord(
            gameID: "pong", gameTitle: "Pong", endedAt: Date(), durationSeconds: 1,
            modifierTitle: nil,
            participants: [.init(controllerID: firstID, displayName: "Ada", colorHex: "#FFFFFF", outcome: .practice)],
            metrics: []
        )

        #expect(practice.isPractice)
        #expect(solo.isSoloBotMatch)
        #expect(party.isPartyMatch)
        #expect(!HistoryAggregation.leaderboard([solo, party]).contains { $0.id == botID })
        let personal = [solo, party, practice].map { PersonalMatchRecord(record: $0, controllerID: firstID) }
        #expect(HistoryAggregation.personal(personal).played == 1)
        #expect(HistoryAggregation.solo(personal) == .init(played: 1, won: 1))
    }

    @Test func legacyVersionOneHistoryDefaultsMissingKindsToHuman() throws {
        let legacy = """
        {
          "controllerID": {"rawValue": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"},
          "displayName": "Ada",
          "colorHex": "#FFFFFF",
          "outcome": "won"
        }
        """.data(using: .utf8)!
        let participant = try JSONDecoder().decode(MatchParticipant.self, from: legacy)
        #expect(participant.kind == .human)
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
