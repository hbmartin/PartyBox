import Dependencies
import Foundation
import PartyBoxCore
import PartyGameRuntime
import PartyGames
import PartyNet
import Testing
@testable import PartyBox

@Suite("PartyBox host integration")
@MainActor
struct PartyBoxTests {
    private final class FixtureBundleMarker {}
    private let bottom = PlayerID(0)
    private let top = PlayerID(1)

    @MainActor
    private final class CleanupGate {
        private(set) var isWaiting = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            isWaiting = true
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    private enum InjectedDiagnosticsError: Error {
        case failed
    }

    @Test func hostLaunchArgumentsAreDeterministicAndBounded() {
        let configuration = HostLaunchConfiguration(arguments: [
            "PartyBox", "--ui-testing", "--scenario", "four-way-match",
            "--disable-animations", "--disable-effects", "--seed", "42",
            "--host-name", "Automation Host", "--bot-count", "99", "--fail-diagnostics-export",
        ])

        #expect(configuration.isUITesting)
        #expect(configuration.scenario == "four-way-match")
        #expect(configuration.disableAnimations)
        #expect(configuration.disableEffects)
        #expect(configuration.seed == 42)
        #expect(configuration.hostName == "Automation Host")
        #expect(configuration.botCount == PartyNetConstants.maximumControllers)
        #expect(configuration.failDiagnosticsExport)
    }

    @Test func hostLaunchArgumentsDoNotForceAProductionSeed() {
        let configuration = HostLaunchConfiguration(arguments: [
            "PartyBox", "--fail-diagnostics-export",
        ])
        #expect(configuration.seed == nil)
        #expect(!configuration.failDiagnosticsExport)
    }

    @Test func hostDiagnosticsExportPropagatesFailure() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let coordinator = HostCoordinator(
                configuration: .init(arguments: [
                    "PartyBox", "--ui-testing", "--disable-effects", "--fail-diagnostics-export",
                ]),
                diagnosticsExporter: { _ in throw InjectedDiagnosticsError.failed }
            )

            await #expect(throws: InjectedDiagnosticsError.self) {
                try await coordinator.makeRedactedDiagnosticsFile()
            }
            await coordinator.stop()
        }
    }

    @Test func hostDiagnosticsExportUsesTheDefaultExporter() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let coordinator = HostCoordinator(
                configuration: .init(arguments: ["PartyBox", "--ui-testing", "--disable-effects"])
            )
            let export = try await coordinator.makeRedactedDiagnosticsFile()
            defer { try? FileManager.default.removeItem(at: export.url) }

            #expect(FileManager.default.fileExists(atPath: export.url.path))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let report = try decoder.decode(
                HostCoordinator.DiagnosticsReport.self,
                from: Data(contentsOf: export.url)
            )
            #expect(report.role == "host")

            await export.release()
            await coordinator.stop()
        }
    }

    #if os(macOS)
    @Test func applicationLifecycleStopsTheHostFromAnUncancelledTask() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let coordinator = isolatedHostCoordinator()
            let lifecycle = PartyBoxApplicationLifecycle(coordinator: coordinator)
            lifecycle.start()
            try await waitUntil { coordinator.host.port != nil }

            await lifecycle.stop()

            #expect(coordinator.host.port == nil)
        }
    }

    @Test func applicationTerminationGateRepliesOnceAfterShutdown() async throws {
        let gate = ApplicationTerminationGate()
        let cleanup = CleanupGate()
        var replyCount = 0

        #expect(gate.begin(
            timeout: .seconds(1),
            shutdown: { await cleanup.wait() },
            reply: { replyCount += 1 }
        ) == .started)
        try await waitUntil { cleanup.isWaiting }
        #expect(gate.begin(
            timeout: .seconds(1),
            shutdown: {},
            reply: { replyCount += 100 }
        ) == .alreadyPending)

        cleanup.release()
        try await waitUntil { replyCount == 1 }
        #expect(gate.begin(
            timeout: .seconds(1),
            shutdown: {},
            reply: { replyCount += 100 }
        ) == .alreadyFinished)
        #expect(replyCount == 1)
    }

    @Test func applicationTerminationGateTimesOutHungShutdownAndRepliesOnce() async throws {
        let gate = ApplicationTerminationGate()
        let cleanup = CleanupGate()
        var replyCount = 0
        defer { cleanup.release() }

        #expect(gate.begin(
            timeout: .milliseconds(20),
            shutdown: { await cleanup.wait() },
            reply: { replyCount += 1 }
        ) == .started)
        try await waitUntil { cleanup.isWaiting }
        try await waitUntil { replyCount == 1 }

        cleanup.release()
        try await Task.sleep(for: .milliseconds(20))
        #expect(replyCount == 1)
    }
    #endif

    @Test func uiFixtureIsAppliedOnStartAndRestoredAfterRestart() async {
        let configuration = HostLaunchConfiguration(arguments: [
            "PartyBox", "--ui-testing", "--scenario", "menu", "--disable-effects",
        ])
        let coordinator = HostCoordinator(configuration: configuration)

        #expect(coordinator.phase == .lobby)
        #expect(coordinator.host.players.isEmpty)

        await coordinator.start()
        #expect(coordinator.phase == .gameMenu)
        #expect(coordinator.host.players.count == 4)

        await coordinator.stop()
        #expect(coordinator.phase == .lobby)
        #expect(coordinator.host.players.isEmpty)

        await coordinator.start()
        #expect(coordinator.phase == .gameMenu)
        #expect(coordinator.host.players.count == 4)
        await coordinator.stop()
    }

    @Test func cupCompleteUIFixtureIgnoresNavigationInput() async {
        let coordinator = HostCoordinator(configuration: .init(arguments: [
            "PartyBox", "--ui-testing", "--scenario", "cup-complete", "--freeze-scenario", "--disable-effects",
        ]))
        await coordinator.start()
        guard case .cupComplete = coordinator.phase else {
            Issue.record("Expected the Cup completion fixture")
            return
        }
        coordinator.perform(.back)
        coordinator.perform(.select)
        guard case .cupComplete = coordinator.phase else {
            Issue.record("Static UI fixture changed phase")
            return
        }
        await coordinator.stop()
    }

    @Test func unexpectedHostEventStreamEndingRestartsTheHost() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let coordinator = isolatedHostCoordinator()
            await coordinator.start()
            let originalInstanceID = coordinator.host.hostInstanceID
            try #require(coordinator.host.port != nil)

            await coordinator.simulateHostEventStreamEndingForTesting()

            try await waitUntil {
                coordinator.host.port != nil
                    && coordinator.host.hostInstanceID == originalInstanceID
            }
            #expect(coordinator.statusMessage == "Ready for controllers")
            await coordinator.stop()
        }
    }

    @Test func stopDuringStartCannotInstallAStaleHostConsumer() async throws {
        let coordinator = isolatedHostCoordinator()
        let gate = CleanupGate()
        coordinator.setStartCheckpointForTesting { await gate.wait() }
        let start = Task { await coordinator.start() }
        defer {
            gate.release()
            start.cancel()
        }
        try await waitUntil { gate.isWaiting }

        await coordinator.stop()
        gate.release()
        await start.value

        #expect(coordinator.phase == .lobby)
        #expect(coordinator.host.port == nil)
        #expect(!coordinator.hasHostEventConsumerForTesting)
    }

    @Test func staleStartFailureCannotOverwriteANewerSuccessfulStart() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let coordinator = isolatedHostCoordinator()
            let gate = CleanupGate()
            let staleFailure = Task {
                await coordinator.simulateSuspendedStartFailureForTesting {
                    await gate.wait()
                }
            }
            defer { staleFailure.cancel() }
            try await waitUntil { gate.isWaiting }

            await coordinator.start()
            #expect(coordinator.host.port != nil)
            #expect(coordinator.statusMessage == "Ready for controllers")

            gate.release()
            await staleFailure.value
            #expect(coordinator.statusMessage == "Ready for controllers")
            await coordinator.stop()
        }
    }

    @Test func unchangedVotesDoNotRecomputeTalliesAndModifierTitlesAreResolved() {
        let coordinator = isolatedHostCoordinator()
        let playerID = PlayerID(7)
        let now = ContinuousClock().now

        #expect(coordinator.storeVoteIfChanged("fast-ball", from: playerID, now: now))
        #expect(!coordinator.storeVoteIfChanged("fast-ball", from: playerID, now: now))
        #expect(!coordinator.storeVoteIfChanged("unknown", from: playerID, now: now))
        #expect(!coordinator.storeVoteIfChanged(
            "big-paddles", from: playerID, now: now.advanced(by: .milliseconds(249))
        ))
        #expect(coordinator.voteTallies == ["fast-ball": 1])
        #expect(coordinator.displayedVoteTallies == [
            VoteTallyPresentation(id: "fast-ball", title: "FAST BALL", count: 1),
        ])

        #expect(coordinator.storeVoteIfChanged(
            "big-paddles", from: playerID, now: now.advanced(by: .milliseconds(250))
        ))
        #expect(coordinator.displayedVoteTallies == [
            VoteTallyPresentation(id: "big-paddles", title: "BIG PADDLES", count: 1),
        ])
    }

    @Test func reactionCoordinatesAreStableForEachBurstIdentity() throws {
        let id = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let burst = ReactionBurst(id: id, emoji: "🔥")

        #expect(burst.positionOffsets.horizontal == 66)
        #expect(burst.positionOffsets.vertical == 5)
    }

    @Test func hostKeepsMemoryOnlyHistoryVisibleAndReportsPersistenceFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let blockedParent = directory.appendingPathComponent("not-a-directory")
        let url = blockedParent.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("blocked".utf8).write(to: blockedParent)
        let coordinator = HostCoordinator(
            configuration: .init(arguments: ["PartyBox", "--disable-effects"]),
            historyFileURL: url
        )
        let record = MatchRecord(
            gameID: "pong",
            gameTitle: "Pong",
            endedAt: Date(timeIntervalSince1970: 10),
            durationSeconds: 5,
            modifierTitle: nil,
            participants: [],
            metrics: []
        )

        await coordinator.appendHistoryForTesting(record)
        await coordinator.appendHistoryForTesting(record)

        #expect(coordinator.historyRecords == [record])
        #expect(coordinator.historyPersistenceError?.isEmpty == false)

        coordinator.requestHistoryClear()
        await coordinator.confirmHistoryClear()

        #expect(coordinator.historyRecords == [record])
        #expect(coordinator.historyPersistenceError?.contains("could not be cleared") == true)
    }

    @Test func successfulCupPersistenceDoesNotHideAMatchPersistenceFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let historyURL = directory.appendingPathComponent("history.json", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: historyURL, withIntermediateDirectories: true)
        let coordinator = HostCoordinator(
            configuration: .init(arguments: ["PartyBox", "--disable-effects"]),
            historyFileURL: historyURL
        )
        let controllerID = ControllerID()
        let match = MatchRecord(
            gameID: "pong",
            gameTitle: "Pong",
            endedAt: Date(timeIntervalSince1970: 20),
            durationSeconds: 5,
            modifierTitle: nil,
            participants: [
                .init(
                    controllerID: controllerID,
                    displayName: "Ada",
                    colorHex: "#32E6FF",
                    outcome: .won
                ),
            ],
            metrics: []
        )
        let cup = CupRecord(
            endedAt: Date(timeIntervalSince1970: 21),
            gameIDs: ["pong"],
            matchRecordIDs: [match.id],
            standings: [
                .init(
                    controllerID: controllerID,
                    displayName: "Ada",
                    colorHex: "#32E6FF",
                    kind: .human,
                    rank: 1,
                    points: 8,
                    eventWins: 1
                ),
            ]
        )

        await coordinator.appendHistoryForTesting(match)
        #expect(coordinator.matchHistoryPersistenceError != nil)
        await coordinator.appendCupHistoryForTesting(cup)

        #expect(coordinator.matchHistoryPersistenceError != nil)
        #expect(coordinator.cupHistoryPersistenceError == nil)
        #expect(coordinator.historyPersistenceError?.contains("match") == true)
    }

    @Test func oversizedNestedControllerLayoutFallsBackToASendableScreen() throws {
        let coordinator = isolatedHostCoordinator()
        let oversized = ControllerScreen(
            accessibilityID: "oversized",
            accentColorHex: "#32E6FF",
            components: [.text(.init(
                id: "oversized.text",
                text: String(repeating: "x", count: 50_000),
                style: .body
            ))]
        )
        let screenPayload = try PartyBoxWireCodec.encode(oversized)
        let layout = PartyBoxCore.ControllerLayout.game(.init(gameID: "oversized-game", payload: screenPayload))
        #expect(throws: PartyBoxWireError.self) {
            try PartyBoxWireCodec.encode(HostPresentation.layout(layout))
        }

        let payload = try #require(coordinator.encodedLayoutPresentation(layout))
        let presentation = try PartyBoxWireCodec.decode(HostPresentation.self, from: payload)
        guard case .layout(.game(let envelope)) = presentation else {
            Issue.record("Expected a game controller fallback")
            return
        }
        #expect(envelope.gameID == "oversized-game")
        #expect(envelope.validatedControllerScreen?.accessibilityID == "controller.layout.unavailable")
        let screen = try #require(envelope.validatedControllerScreen)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(screen)
        if let output = ProcessInfo.processInfo.environment["PARTYBOX_GOLDEN_OUTPUT_DIR"] {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoded.write(to: directory.appendingPathComponent("unavailable-screen.json"))
            Issue.record("Golden candidate generated; use scripts/record-goldens.sh to install and verify it")
            return
        }
        let url = try #require(Bundle(for: FixtureBundleMarker.self)
            .url(forResource: "unavailable-screen", withExtension: "json"))
        #expect(encoded == (try Data(contentsOf: url)))
    }

    @Test func stoppedCoordinatorCannotBeRevivedBySuspendedMatchCompletion() async throws {
        let coordinator = HostCoordinator(configuration: .init(arguments: [
            "PartyBox", "--ui-testing", "--scenario", "four-way-match", "--disable-effects",
        ]))
        await coordinator.start()
        let gate = CleanupGate()
        coordinator.setFinishMatchCheckpointForTesting { await gate.wait() }
        let outcome = GameOutcome(
            title: "MATCH OVER", subtitle: "Done", winner: bottom,
            playerOutcomes: [.init(playerID: bottom, outcome: .won)], metrics: []
        )
        let completion = Task { await coordinator.finishCurrentMatchForTesting(outcome) }
        defer {
            gate.release()
            completion.cancel()
        }
        try await waitUntil { gate.isWaiting }

        await coordinator.stop()
        gate.release()
        await completion.value

        #expect(coordinator.phase == .lobby)
        #expect(coordinator.currentScene == nil)
    }

    @Test func stoppedCoordinatorCannotBeRevivedBySuspendedCupCompletion() async throws {
        let coordinator = HostCoordinator(configuration: .init(arguments: [
            "PartyBox", "--ui-testing", "--scenario", "cup-final-match", "--disable-effects",
        ]))
        await coordinator.start()
        let gate = CleanupGate()
        coordinator.setFinishCupCheckpointForTesting { await gate.wait() }
        let players = coordinator.host.players
        let outcome = GameOutcome(
            title: "CUP COMPLETE",
            subtitle: "Done",
            winner: players.first?.id,
            playerOutcomes: players.map {
                .init(playerID: $0.id, outcome: $0.id == players.first?.id ? .won : .lost)
            },
            metrics: [],
            standings: players.enumerated().map {
                .init(playerID: $0.element.id, rank: $0.offset + 1, score: 100 - $0.offset)
            }
        )
        let completion = Task { await coordinator.finishCurrentMatchForTesting(outcome) }
        defer {
            gate.release()
            completion.cancel()
        }
        try await waitUntil { gate.isWaiting }

        await coordinator.stop()
        gate.release()
        await completion.value

        #expect(coordinator.phase == .lobby)
        #expect(coordinator.currentScene == nil)
        #expect(coordinator.cupRecords.isEmpty)
    }

    @Test func failedCupEventStartDoesNotAdvanceTheEventIndex() async {
        let coordinator = HostCoordinator(configuration: .init(arguments: [
            "PartyBox", "--ui-testing", "--scenario", "cup-standings", "--disable-effects",
        ]))
        await coordinator.start()
        #expect(coordinator.cupEventIndex == 0)

        coordinator.perform(.select)

        #expect(coordinator.cupEventIndex == 0)
        guard case .cupStandings = coordinator.phase else {
            Issue.record("A failed event start must leave the Cup on its standings screen")
            await coordinator.stop()
            return
        }
        await coordinator.stop()
    }

    @Test func centralizedGameStartEligibilityEnforcesMinimumAndMaximumPlayers() {
        let descriptor = GameDescriptor(
            id: "two-player", title: "Two Player", summary: "Test",
            minimumPlayers: 2, maximumPlayers: 2
        )
        let participants = (0..<3).map { index in
            let player = PlayerInfo(
                id: PlayerID(UInt8(index)),
                displayName: "P\(index)",
                colorHex: PlayerPalette.color(for: PlayerID(UInt8(index)))
            )
            return GameParticipant(player: player, controllerID: ControllerID())
        }

        #expect(HostCoordinator.participantsForStart(
            Array(participants.prefix(1)), descriptor: descriptor
        ) == nil)
        #expect(HostCoordinator.participantsForStart(
            participants, descriptor: descriptor
        ) == Array(participants.prefix(2)))
    }

    @Test func selectedPongModifierIsValidOnlyForFourOrFewerParticipants() throws {
        let game = try #require(PartyGames.all().first)
        let fastBall = try #require(game.descriptor.modifiers.first)
        #expect(HostCoordinator.applicableModifier(fastBall, for: game, participantCount: 4) == fastBall)
        #expect(HostCoordinator.applicableModifier(fastBall, for: game, participantCount: 5) == nil)
    }

    @Test func captainCanBuildAThreeEventCupAndScoreTheFirstEvent() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let coordinator = isolatedHostCoordinator()
            await coordinator.start()
            let port = try #require(coordinator.host.port)
            let captain = PartyClient(displayName: "Captain")
            let teammate = PartyClient(displayName: "Teammate")
            await captain.connect(host: "127.0.0.1", port: port)
            await teammate.connect(host: "127.0.0.1", port: port)
            try await waitUntil { coordinator.connectedHumanCount == 2 }
            let teammateID = try #require(teammate.player?.id)

            coordinator.perform(.select)
            for _ in 0..<5 { coordinator.perform(.down) }
            #expect(coordinator.menuItems[coordinator.menuSelection] == "PARTY CUP")
            #expect(!coordinator.controlStatusForTesting(teammateID).canToggleReady)
            coordinator.perform(.select)
            #expect(coordinator.phase == .cupSetup)
            #expect(!coordinator.controlStatusForTesting(teammateID).canToggleReady)

            coordinator.perform(.select)
            coordinator.perform(.down)
            coordinator.perform(.select)
            coordinator.perform(.down)
            coordinator.perform(.select)
            #expect(coordinator.selectedCupGameIDs.count == 3)
            #expect(coordinator.controlStatusForTesting(teammateID).canToggleReady)
            coordinator.perform(.select, source: .controller(teammateID))
            #expect(coordinator.phase == .playing)

            let players = coordinator.host.players
            let standings = players.enumerated().map {
                GameStanding(playerID: $0.element.id, rank: $0.offset + 1, score: 100 - $0.offset)
            }
            let winner = try #require(players.first?.id)
            await coordinator.finishCurrentMatchForTesting(.init(
                title: "EVENT COMPLETE",
                subtitle: "Done",
                winner: winner,
                playerOutcomes: players.map { .init(playerID: $0.id, outcome: $0.id == winner ? .won : .lost) },
                metrics: [],
                standings: standings
            ))
            guard case .cupStandings = coordinator.phase else {
                Issue.record("Expected cup standings after the first event")
                return
            }
            #expect(coordinator.cupLeaderboard.first?.points == 8)
            await teammate.stop()
            await captain.stop()
            await coordinator.stop()
        }
    }

    @Test func rejectedFourthCupEventClearsReadyVotes() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let coordinator = isolatedHostCoordinator()
            await coordinator.start()
            let port = try #require(coordinator.host.port)
            let clients = (1...4).map { PartyClient(displayName: "Human \($0)") }
            for client in clients { await client.connect(host: "127.0.0.1", port: port) }
            try await waitUntil { coordinator.connectedHumanCount == 4 }
            let ids = try clients.map { try #require($0.player?.id) }

            coordinator.perform(.select)
            for _ in 0..<PartyGames.all().count { coordinator.perform(.down) }
            coordinator.perform(.select)
            for index in 0..<3 {
                coordinator.perform(.select)
                if index < 2 { coordinator.perform(.down) }
            }
            let selected = coordinator.selectedCupGameIDs
            #expect(selected.count == 3)
            #expect(coordinator.requiredReadyCount == 3)

            coordinator.perform(.select, source: .controller(ids[1]))
            #expect(coordinator.readyPlayerIDs == [ids[1]])
            coordinator.perform(.down)
            try await waitUntil { !coordinator.layoutBroadcastInProgressForTesting }
            let broadcastsBeforeRejection = coordinator.layoutBroadcastCountForTesting
            coordinator.perform(.select)
            #expect(coordinator.selectedCupGameIDs == selected)
            #expect(coordinator.readyPlayerIDs.isEmpty)
            try await waitUntil {
                coordinator.layoutBroadcastCountForTesting > broadcastsBeforeRejection
            }

            coordinator.perform(.select, source: .controller(ids[2]))
            #expect(coordinator.readyPlayerIDs == [ids[2]])
            #expect(coordinator.phase == .cupSetup)
            for client in clients { await client.stop() }
            await coordinator.stop()
        }
    }

    @Test func leavingACompletedCupRestoresThePartyCupMenuSelection() async {
        let coordinator = HostCoordinator(configuration: .init(arguments: [
            "PartyBox", "--ui-testing", "--scenario", "cup-complete", "--disable-effects",
        ]))
        await coordinator.start()
        guard case .cupComplete = coordinator.phase else {
            Issue.record("Expected the completed Party Cup fixture")
            return
        }

        coordinator.perform(.back)

        #expect(coordinator.phase == .gameMenu)
        #expect(coordinator.menuItems[coordinator.menuSelection] == "PARTY CUP")
        #expect(coordinator.botDifficultyChange == nil)
        await coordinator.stop()
    }

    @Test func leavingGameOverClearsTheBotDifficultyChange() async {
        let coordinator = HostCoordinator(configuration: .init(arguments: [
            "PartyBox", "--ui-testing", "--scenario", "game-over", "--disable-effects",
        ]))
        await coordinator.start()
        guard case .gameOver = coordinator.phase else {
            Issue.record("Expected the game-over fixture")
            return
        }
        #expect(coordinator.botDifficultyChange != nil)

        coordinator.perform(.back)

        #expect(coordinator.phase == .gameMenu)
        #expect(coordinator.botDifficultyChange == nil)
        await coordinator.stop()
    }

    @Test func mixedMatchDifficultyMovesOneStepAndClamps() {
        let coordinator = isolatedHostCoordinator()
        let human = PlayerInfo(id: bottom, displayName: "Ada", colorHex: "#32E6FF")
        let bot = PlayerInfo(
            id: top, displayName: "Bot", colorHex: "#FF4FD8", kind: .bot
        )
        let participants = [human, bot].map {
            GameParticipant(player: $0, controllerID: ControllerID())
        }
        func outcome(winner: PlayerID?) -> GameOutcome {
            GameOutcome(title: "Done", subtitle: "", winner: winner, playerOutcomes: [], metrics: [])
        }

        coordinator.updateBotDifficultyForTesting(outcome: outcome(winner: bottom), participants: participants)
        #expect(coordinator.currentBotDifficulty == .hard)
        coordinator.updateBotDifficultyForTesting(outcome: outcome(winner: bottom), participants: participants)
        #expect(coordinator.currentBotDifficulty == .hard)
        coordinator.updateBotDifficultyForTesting(outcome: outcome(winner: top), participants: participants)
        #expect(coordinator.currentBotDifficulty == .normal)
        coordinator.setBotDifficultyForTesting(.easy)
        coordinator.updateBotDifficultyForTesting(outcome: outcome(winner: top), participants: participants)
        #expect(coordinator.currentBotDifficulty == .easy)
        coordinator.updateBotDifficultyForTesting(outcome: outcome(winner: nil), participants: participants)
        #expect(coordinator.currentBotDifficulty == .easy)
        coordinator.updateBotDifficultyForTesting(
            outcome: outcome(winner: bottom),
            participants: [participants[0]]
        )
        #expect(coordinator.currentBotDifficulty == .easy)
    }

    @Test func activeDepartureKeepsSurvivorEdgesAndNewMatchStartsNeutral() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let coordinator = isolatedHostCoordinator()
            await coordinator.start()
            let port = try #require(coordinator.host.port)
            let clients = [
                PartyClient(displayName: "Bottom"),
                PartyClient(displayName: "Top"),
                PartyClient(displayName: "Left"),
            ]
            for client in clients {
                await client.connect(host: "127.0.0.1", port: port)
            }
            try await waitUntil { coordinator.turnOrder.players.count == 3 }

            clients[0].setAxes(axisX: 0.75)
            try await waitUntil { coordinator.host.inputs.snapshot()[PlayerID(0)]?.axisX == 0.75 }
            coordinator.perform(.select)
            coordinator.perform(.select)

            #expect(coordinator.currentScene != nil)
            #expect(coordinator.host.inputs.snapshot()[PlayerID(0)]?.axisX == 0)
            try await waitUntil {
                self.paddleLayoutID(of: PlayerID(1), coordinator: coordinator) == "controller.layout.paddle.top"
                    && self.paddleLayoutID(of: PlayerID(2), coordinator: coordinator) == "controller.layout.paddle.left"
            }
            await clients[0].disconnect()
            try await waitUntil { coordinator.turnOrder.players.count == 2 }

            #expect(paddleLayoutID(of: PlayerID(1), coordinator: coordinator) == "controller.layout.paddle.top")
            #expect(paddleLayoutID(of: PlayerID(2), coordinator: coordinator) == "controller.layout.paddle.left")
            for client in clients.dropFirst() { await client.disconnect() }
            await coordinator.stop()
        }
    }

    @Test func captainAuthorizationCooldownsAndStrictMajorityReadiness() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let coordinator = isolatedHostCoordinator()
            await coordinator.start()
            let port = try #require(coordinator.host.port)
            let clients = (1...4).map { PartyClient(displayName: "Human \($0)") }
            for client in clients { await client.connect(host: "127.0.0.1", port: port) }
            try await waitUntil { coordinator.connectedHumanCount == 4 && coordinator.captainID != nil }
            let ids = try clients.map { try #require($0.player?.id) }
            #expect(coordinator.captainID == ids[0])
            #expect(coordinator.requiredReadyCount == 3)

            let now = ContinuousClock().now
            coordinator.perform(.select, source: .controller(ids[1]), now: now)
            #expect(coordinator.phase == .lobby)
            coordinator.perform(.select, source: .controller(ids[0]), now: now)
            #expect(coordinator.phase == .gameMenu)

            coordinator.perform(.down, source: .controller(ids[0]), now: now)
            #expect(coordinator.menuSelection == 1)
            coordinator.perform(.up, source: .controller(ids[0]), now: now.advanced(by: .milliseconds(149)))
            #expect(coordinator.menuSelection == 1)
            coordinator.perform(.up, source: .controller(ids[0]), now: now.advanced(by: .milliseconds(150)))
            #expect(coordinator.menuSelection == 0)

            coordinator.perform(.back, source: .controller(ids[1]), now: now.advanced(by: .seconds(1)))
            #expect(coordinator.phase == .gameMenu)
            coordinator.perform(.select, source: .controller(ids[1]), now: now.advanced(by: .seconds(1)))
            #expect(coordinator.readyCount == 2)
            #expect(coordinator.phase == .gameMenu)
            coordinator.perform(.select, source: .controller(ids[1]), now: now.advanced(by: .seconds(1.749)))
            #expect(coordinator.readyCount == 2)
            coordinator.perform(.select, source: .controller(ids[1]), now: now.advanced(by: .seconds(1.750)))
            #expect(coordinator.readyCount == 1)

            coordinator.perform(.down, source: .controller(ids[0]), now: now.advanced(by: .seconds(2)))
            #expect(coordinator.readyPlayerIDs.isEmpty)
            coordinator.perform(.up, source: .controller(ids[0]), now: now.advanced(by: .seconds(2.2)))
            #expect(coordinator.menuSelection == 0)
            coordinator.perform(.select, source: .controller(ids[1]), now: now.advanced(by: .seconds(3)))
            #expect(coordinator.readyCount == 2)

            let newcomer = PartyClient(displayName: "Human 5")
            await newcomer.connect(host: "127.0.0.1", port: port)
            try await waitUntil { coordinator.connectedHumanCount == 5 }
            #expect(coordinator.readyPlayerIDs.isEmpty)
            #expect(coordinator.requiredReadyCount == 3)
            #expect(coordinator.phase == .gameMenu)

            coordinator.perform(.select, source: .controller(ids[1]), now: now.advanced(by: .seconds(4)))
            coordinator.perform(.select, source: .controller(ids[2]), now: now.advanced(by: .seconds(4)))
            #expect(coordinator.phase == .playing)
            #expect(coordinator.readyPlayerIDs.isEmpty)

            await newcomer.stop()
            for client in clients { await client.stop() }
            await coordinator.stop()
        }
    }

    @Test func captainTransfersOnInterruptionAndPromotionSurvivesReconnect() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let coordinator = isolatedHostCoordinator()
            await coordinator.start()
            let port = try #require(coordinator.host.port)
            let first = PartyClient(displayName: "First")
            let second = PartyClient(displayName: "Second")
            let third = PartyClient(displayName: "Third")
            let fourth = PartyClient(displayName: "Fourth")
            await first.connect(host: "127.0.0.1", port: port)
            await second.connect(host: "127.0.0.1", port: port)
            await third.connect(host: "127.0.0.1", port: port)
            await fourth.connect(host: "127.0.0.1", port: port)
            try await waitUntil { coordinator.connectedHumanCount == 4 }
            let firstID = try #require(first.player?.id)
            let secondID = try #require(second.player?.id)
            #expect(coordinator.captainID == firstID)

            coordinator.perform(.select)
            coordinator.perform(.select, source: .controller(secondID), now: ContinuousClock().now)
            #expect(coordinator.readyPlayerIDs == [secondID])

            await first.interruptForTesting()
            try await waitUntil { coordinator.captainID == secondID }
            #expect(coordinator.readyPlayerIDs.isEmpty)
            first.reconnectAfterForeground()
            try await waitUntil(timeout: .seconds(5)) {
                if case .connected = first.state { return true }
                return false
            }
            #expect(coordinator.captainID == secondID)

            await first.stop()
            await second.stop()
            await third.stop()
            await fourth.stop()
            await coordinator.stop()
        }
    }

    @Test func releaseBotsFillSafelyAndSendRealInputFrames() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let coordinator = isolatedHostCoordinator()
            await coordinator.start()
            let port = try #require(coordinator.host.port)
            let captain = PartyClient(displayName: "Captain")
            await captain.connect(host: "127.0.0.1", port: port)
            try await waitUntil { coordinator.captainID == captain.player?.id }

            let botCommand = try PartyBoxWireCodec.encode(
                ControllerCommand.lobby(.setBotFillTarget(6))
            )
            #expect(await captain.sendApplication(botCommand))
            try await waitUntil(timeout: .seconds(5)) { coordinator.activeBotCount == 6 }
            #expect(Set(coordinator.host.players.map(\.mark)).count == coordinator.host.players.count)
            #expect(coordinator.connectedHumanCount == 1)
            #expect(coordinator.requiredReadyCount == 1)

            coordinator.perform(.select)
            coordinator.perform(.select)
            #expect(coordinator.phase == .playing)
            #expect(coordinator.botParticipantCountForTesting == 6)
            #expect(coordinator.readyBotClientCountForTesting == 6)
            let appliedBeforeBotControl = coordinator.botInputFramesAppliedForTesting
            try await waitUntil(timeout: .seconds(5)) {
                coordinator.botInputFramesAppliedForTesting > appliedBeforeBotControl
            }

            let newcomer = PartyClient(displayName: "New Human")
            await newcomer.connect(host: "127.0.0.1", port: port)
            try await waitUntil { coordinator.connectedHumanCount == 2 }
            #expect(coordinator.activeBotCount == 6)

            let humanID = try #require(captain.player?.id)
            await coordinator.finishCurrentMatchForTesting(.init(
                title: "DONE", subtitle: "", winner: humanID,
                playerOutcomes: [.init(playerID: humanID, outcome: .won)], metrics: []
            ))
            try await waitUntil(timeout: .seconds(5)) { coordinator.activeBotCount == 6 }

            await newcomer.stop()
            await captain.stop()
            await coordinator.stop()
        }
    }

    @Test func botFinishingConnectionDuringMatchRemainsAnActiveParticipant() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let coordinator = isolatedHostCoordinator()
            await coordinator.start()
            let port = try #require(coordinator.host.port)
            let captain = PartyClient(displayName: "Captain")
            await captain.connect(host: "127.0.0.1", port: port)
            try await waitUntil { coordinator.connectedHumanCount == 1 }
            let historyCount = coordinator.historyRecords.count
            let initialDifficulty = coordinator.currentBotDifficulty
            let gate = CleanupGate()
            coordinator.setBotConnectCheckpointForTesting { await gate.wait() }
            defer { gate.release() }

            let command = try PartyBoxWireCodec.encode(ControllerCommand.lobby(.setBotFillTarget(1)))
            #expect(await captain.sendApplication(command))
            try await waitUntil { gate.isWaiting && coordinator.activeBotCount == 1 }
            coordinator.perform(.select)
            coordinator.perform(.select)
            #expect(coordinator.phase == .playing)
            #expect(coordinator.botParticipantCountForTesting == 1)
            #expect(coordinator.currentScene != nil)

            gate.release()
            try await waitUntil(timeout: .seconds(5)) {
                coordinator.botReconciliationIDForTesting == nil
                    && coordinator.botInputFramesAppliedForTesting > 0
            }
            #expect(coordinator.activeBotCount == 1)
            #expect(coordinator.readyBotClientCountForTesting == 1)
            #expect(coordinator.phase == .playing)
            #expect(coordinator.historyRecords.count == historyCount)
            #expect(coordinator.currentBotDifficulty == initialDifficulty)
            #expect(coordinator.statusMessage != "A bot could not join")
            await coordinator.stop()
            await captain.stop()
        }
    }

    @Test func staleBotDrainCannotClearANewerReconciliation() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let coordinator = HostCoordinator(configuration: .init(arguments: [
                "PartyBox", "--ui-testing", "--disable-effects", "--bot-count", "1",
            ]))
            let oldGate = CleanupGate()
            coordinator.setBotConnectCheckpointForTesting { await oldGate.wait() }
            defer { oldGate.release() }
            await coordinator.start()
            try await waitUntil { oldGate.isWaiting }
            let oldID = try #require(coordinator.botReconciliationIDForTesting)

            await coordinator.stop()
            let newGate = CleanupGate()
            coordinator.setBotConnectCheckpointForTesting { await newGate.wait() }
            defer { newGate.release() }
            var oldDrainFinished = false
            coordinator.setBotDrainFinishedForTesting { oldDrainFinished = $0 == oldID || oldDrainFinished }
            await coordinator.start()
            try await waitUntil { newGate.isWaiting }
            let newID = try #require(coordinator.botReconciliationIDForTesting)
            #expect(newID != oldID)

            oldGate.release()
            try await waitUntil { oldDrainFinished }
            #expect(coordinator.botReconciliationIDForTesting == newID)
            newGate.release()
            try await waitUntil(timeout: .seconds(5)) {
                coordinator.botReconciliationIDForTesting == nil && coordinator.activeBotCount == 1
            }
            await coordinator.stop()
        }
    }

    @Test func recycledPlayerIDDoesNotAcquireThePreviousControllersMatchIdentity() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let host = PartyHost(reconnectGrace: .zero)
            let coordinator = HostCoordinator(
                configuration: .init(arguments: ["PartyBox", "--ui-testing", "--disable-effects"]),
                host: host
            )
            let originalControllerID = ControllerID()
            let original = PartyClient(controllerID: originalControllerID, displayName: "Original")
            let replacementControllerID = ControllerID()
            let replacement = PartyClient(controllerID: replacementControllerID, displayName: "Replacement")

            await coordinator.start()
            let port = try #require(host.port)
            await original.connect(host: "127.0.0.1", port: port)
            try await waitUntil { host.players.count == 1 }
            let player = try #require(host.players.first)
            let participant = GameParticipant(player: player, controllerID: originalControllerID)
            #expect(coordinator.isLiveParticipantForTesting(participant))

            await original.disconnect()
            try await waitUntil { host.players.isEmpty }
            await replacement.connect(host: "127.0.0.1", port: port)
            try await waitUntil { host.players.count == 1 }

            #expect(host.players.first?.id == player.id)
            #expect(host.controllerID(for: player.id) == replacementControllerID)
            #expect(!coordinator.isLiveParticipantForTesting(participant))

            await replacement.disconnect()
            await coordinator.stop()
        }
    }

    @MainActor
    private func isolatedHostCoordinator() -> HostCoordinator {
        HostCoordinator(configuration: .init(arguments: ["PartyBox", "--ui-testing", "--disable-effects"]))
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition())
    }

    @MainActor
    private func paddleLayoutID(of playerID: PlayerID, coordinator: HostCoordinator) -> String? {
        coordinator.currentGameControllerScreenForTesting(playerID)?.accessibilityID
    }


}
