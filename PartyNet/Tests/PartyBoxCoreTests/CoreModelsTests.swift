import Dispatch
import Foundation
import PartyNet
import Testing
@testable import PartyBoxCore

@Suite("PartyBox application protocol")
struct CoreModelsTests {
    private enum DiagnosticsTestError: Error {
        case encodingTimedOut
        case removalFailed
    }

    private final class EncodingGate: @unchecked Sendable {
        let started = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
    }

    private struct BlockingReport: Encodable, Sendable {
        let gate: EncodingGate

        func encode(to encoder: Encoder) throws {
            gate.started.signal()
            guard gate.finish.wait(timeout: .now() + 2) == .success else {
                throw DiagnosticsTestError.encodingTimedOut
            }
            var container = encoder.singleValueContainer()
            try container.encode("complete")
        }
    }

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

    @Test(arguments: [(0, 4), (9, 9), (4, 3), (1, 9)])
    func invalidGamePlayerBoundsFailDecoding(minimumPlayers: Int, maximumPlayers: Int) {
        let data = Data(
            """
            {"id":"invalid","title":"Invalid","summary":"Invalid player bounds","minimumPlayers":\(minimumPlayers),"maximumPlayers":\(maximumPlayers)}
            """.utf8
        )

        #expect(throws: DecodingError.self) {
            try PartyBoxWireCodec.decode(GameDescriptor.self, from: data)
        }
    }

    @Test func wireDecodedDeviceCuesClampDurationsAndOlderControlStatusDefaultsSafely() throws {
        let identifier = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let longCue = Data(
            ##"{"id":"\##(identifier)","colorHex":"#39FF88","durationMilliseconds":999,"haptic":"success"}"##.utf8
        )
        let shortCue = Data(
            ##"{"id":"\##(identifier)","colorHex":"#39FF88","durationMilliseconds":-10,"haptic":null}"##.utf8
        )

        #expect(try PartyBoxWireCodec.decode(DeviceCue.self, from: longCue).durationMilliseconds == 250)
        #expect(try PartyBoxWireCodec.decode(DeviceCue.self, from: shortCue).durationMilliseconds == 80)

        let legacyControl = Data(
            #"{"captainID":null,"isCaptain":false,"isReady":false,"readyCount":1,"requiredReadyCount":2}"#.utf8
        )
        #expect(!(try PartyBoxWireCodec.decode(
            PartyControlStatus.self,
            from: legacyControl
        )).canToggleReady)
    }

    @Test func legacyMenusAndGameDescriptorsDecodeWithCompatibleDefaults() throws {
        let legacyMenu = Data(
            #"{"items":["PONG"],"details":["Winner stays"],"selected":0}"#.utf8
        )
        let menu = try PartyBoxWireCodec.decode(MenuLayout.self, from: legacyMenu)
        #expect(menu.kind == .gameSelection)
        #expect(menu.control == .uncontrolled)

        let legacyCupMenu = Data(
            #"{"items":["SIGNAL SNAP","START PARTY CUP"],"details":["Ready","3/3 events selected"],"selected":1}"#.utf8
        )
        #expect(try PartyBoxWireCodec.decode(MenuLayout.self, from: legacyCupMenu).kind == .cupSetup)

        let legacyGame = Data(
            #"{"id":"pong","title":"PONG","summary":"Winner stays","minimumPlayers":1,"maximumPlayers":4,"modifiers":[]}"#.utf8
        )
        let game = try PartyBoxWireCodec.decode(GameDescriptor.self, from: legacyGame)
        #expect(game.estimatedDurationSeconds == 90)
        #expect(game.supportsMotion)
        #expect(game.isCupEligible)

        let cupMenu = MenuLayout(
            kind: .cupSetup,
            items: ["START PARTY CUP"],
            details: ["3/3 events selected"],
            selected: 0
        )
        #expect(try PartyBoxWireCodec.decode(
            MenuLayout.self,
            from: PartyBoxWireCodec.encode(cupMenu)
        ) == cupMenu)

        let explicitGameMenu = MenuLayout(
            kind: .gameSelection,
            items: ["START PARTY CUP"],
            details: ["Choose a mode"],
            selected: 0
        )
        #expect(try PartyBoxWireCodec.decode(
            MenuLayout.self,
            from: PartyBoxWireCodec.encode(explicitGameMenu)
        ).kind == .gameSelection)
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

    @Test func diagnosticsExportsAreImmutableSnapshots() async throws {
        struct Report: Codable, Equatable {
            let value: String
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000.123)

        let firstExport = try await RedactedDiagnosticsExporter.write(
            Report(value: "first"), role: .host, directory: directory, now: now
        )
        let secondExport = try await RedactedDiagnosticsExporter.write(
            Report(value: "second"), role: .host, directory: directory, now: now
        )

        #expect(firstExport.url != secondExport.url)
        let filenames = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(filenames.count == 2)
        #expect(firstExport.url.lastPathComponent.hasPrefix("PartyBox-host-diagnostics-20231114T221320.123Z-"))
        #expect(secondExport.url.lastPathComponent.hasPrefix("PartyBox-host-diagnostics-20231114T221320.124Z-"))
        #expect(try JSONDecoder().decode(Report.self, from: Data(contentsOf: firstExport.url)) == .init(value: "first"))
        #expect(try JSONDecoder().decode(Report.self, from: Data(contentsOf: secondExport.url)) == .init(value: "second"))
        await firstExport.release()
        await secondExport.release()
    }

    @Test func diagnosticsRetentionIsBoundedAndRoleScoped() async throws {
        struct Report: Codable { let sequence: Int }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unrelatedURL = directory.appendingPathComponent("keep-me.txt")
        try Data("unrelated".utf8).write(to: unrelatedURL)
        let prefixedUnrelatedURL = directory.appendingPathComponent(
            "PartyBox-host-diagnostics-do-not-delete.json"
        )
        try Data("unrelated".utf8).write(to: prefixedUnrelatedURL)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let controllerExport = try await RedactedDiagnosticsExporter.write(
            Report(sequence: 0), role: .controller, directory: directory, now: baseDate
        )
        let controllerURL = controllerExport.url
        await controllerExport.release()

        var hostURLs: [URL] = []
        for index in 0..<7 {
            let export = try await RedactedDiagnosticsExporter.write(
                Report(sequence: index),
                role: .host,
                directory: directory,
                now: baseDate.addingTimeInterval(Double(index))
            )
            hostURLs.append(export.url)
            await export.release()
        }

        let remainingNames = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        let remainingHostNames = remainingNames.intersection(
            Set(hostURLs.map(\.lastPathComponent))
        )
        #expect(remainingHostNames == Set(hostURLs.suffix(5).map(\.lastPathComponent)))
        #expect(remainingNames.contains(controllerURL.lastPathComponent))
        #expect(remainingNames.contains(unrelatedURL.lastPathComponent))
        #expect(remainingNames.contains(prefixedUnrelatedURL.lastPathComponent))
    }

    @Test func diagnosticsRetentionCountsUnparseableMatchingTimestampsAsOldest() async throws {
        struct Report: Codable { let value: String }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let unknownAgeURL = directory.appendingPathComponent(
            "PartyBox-host-diagnostics-20261340T999999.999Z-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.json"
        )
        try Data("legacy".utf8).write(to: unknownAgeURL)

        let currentExport = try await RedactedDiagnosticsExporter.write(
            Report(value: "current"),
            role: .host,
            directory: directory,
            now: baseDate.addingTimeInterval(2),
            retentionLimit: 1
        )

        #expect(FileManager.default.fileExists(atPath: currentExport.url.path))
        #expect(!FileManager.default.fileExists(atPath: unknownAgeURL.path))
        await currentExport.release()
    }

    @Test func diagnosticsRetentionBootstrapsLegacyFilenamesAndSurvivesClockRollback() async throws {
        struct Report: Codable, Equatable { let sequence: Int }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let olderURL = directory.appendingPathComponent(
            "PartyBox-host-diagnostics-20330518T033320.000Z-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.json"
        )
        let newestLegacyURL = directory.appendingPathComponent(
            "PartyBox-host-diagnostics-20330518T033321.000Z-11111111-2222-3333-4444-555555555555.json"
        )
        try Data("older".utf8).write(to: olderURL)
        try Data("newest".utf8).write(to: newestLegacyURL)

        let currentExport = try await RedactedDiagnosticsExporter.write(
            Report(sequence: 1),
            role: .host,
            directory: directory,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            retentionLimit: 3
        )

        #expect(currentExport.url.lastPathComponent.hasPrefix("PartyBox-host-diagnostics-20330518T033321.001Z-"))
        #expect(FileManager.default.fileExists(atPath: olderURL.path))
        #expect(FileManager.default.fileExists(atPath: newestLegacyURL.path))
        await currentExport.release()
    }

    @Test func diagnosticsActiveHandlesSurviveLimitPressureUntilRelease() async throws {
        struct Report: Codable { let sequence: Int }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let firstExport = try await RedactedDiagnosticsExporter.write(
            Report(sequence: 1), role: .host, directory: directory, now: baseDate, retentionLimit: 1
        )
        let secondExport = try await RedactedDiagnosticsExporter.write(
            Report(sequence: 2),
            role: .host,
            directory: directory,
            now: baseDate.addingTimeInterval(1),
            retentionLimit: 1
        )

        #expect(FileManager.default.fileExists(atPath: firstExport.url.path))
        #expect(FileManager.default.fileExists(atPath: secondExport.url.path))

        await firstExport.release()
        await firstExport.release()
        #expect(!FileManager.default.fileExists(atPath: firstExport.url.path))
        #expect(FileManager.default.fileExists(atPath: secondExport.url.path))

        await secondExport.release()
        #expect(FileManager.default.fileExists(atPath: secondExport.url.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func diagnosticsConcurrentExportsRemainShareableUntilReleased() async throws {
        struct Report: Codable { let sequence: Int }
        for iteration in 0..<10 {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let exports = try await withThrowingTaskGroup(of: DiagnosticsExport.self) { group in
                for sequence in 0..<8 {
                    group.addTask {
                        try await RedactedDiagnosticsExporter.write(
                            Report(sequence: sequence),
                            role: .host,
                            directory: directory,
                            now: Date(timeIntervalSince1970: 1_700_000_000 + Double(iteration)),
                            retentionLimit: 1
                        )
                    }
                }
                var exports: [DiagnosticsExport] = []
                for try await export in group {
                    exports.append(export)
                }
                return exports
            }

            #expect(exports.count == 8)
            #expect(exports.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
            #expect(Set(exports.map(\.url)).count == 8)
            for export in exports {
                await export.release()
            }
            let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(remaining.count == 1)
        }
    }

    @Test func diagnosticsDeletionFailuresSucceedAndRetryLater() async throws {
        struct Report: Codable { let sequence: Int }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let oldExport = try await RedactedDiagnosticsExporter.write(
            Report(sequence: 1), role: .host, directory: directory, now: baseDate, retentionLimit: 1
        )
        let oldURL = oldExport.url
        await oldExport.release()

        let newExport = try await RedactedDiagnosticsExporter.write(
            Report(sequence: 2),
            role: .host,
            directory: directory,
            now: baseDate.addingTimeInterval(1),
            retentionLimit: 1,
            removeItem: { url in
                if url == oldURL { throw DiagnosticsTestError.removalFailed }
                try FileManager.default.removeItem(at: url)
            }
        )
        #expect(FileManager.default.fileExists(atPath: oldURL.path))
        #expect(FileManager.default.fileExists(atPath: newExport.url.path))

        let retryExport = try await RedactedDiagnosticsExporter.write(
            Report(sequence: 3),
            role: .host,
            directory: directory,
            now: baseDate.addingTimeInterval(2),
            retentionLimit: 1
        )
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(FileManager.default.fileExists(atPath: newExport.url.path))
        #expect(FileManager.default.fileExists(atPath: retryExport.url.path))

        await newExport.release()
        #expect(!FileManager.default.fileExists(atPath: newExport.url.path))
        await retryExport.release()
    }

    @Test @MainActor
    func diagnosticsEncodingRunsAwayFromTheMainActor() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let gate = EncodingGate()
        let exportTask = Task {
            try await RedactedDiagnosticsExporter.write(
                BlockingReport(gate: gate), role: .host, directory: directory
            )
        }

        let encodingStarted = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: gate.started.wait(timeout: .now() + 1) == .success)
            }
        }
        #expect(encodingStarted)
        var mainActorProgressed = false
        await Task { @MainActor in
            mainActorProgressed = true
        }.value
        #expect(mainActorProgressed)
        gate.finish.signal()

        let export = try await exportTask.value
        await export.release()
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
