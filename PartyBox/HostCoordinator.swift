import Foundation
import Observation
import OSLog
import PartyBoxCore
import PartyGameRuntime
import PartyGames
import PartyNet
import SpriteKit

struct ReactionBurst: Identifiable, Equatable {
    let id: UUID
    let emoji: String

    init(id: UUID = UUID(), emoji: String) {
        self.id = id
        self.emoji = emoji
    }

    var positionOffsets: (horizontal: Int, vertical: Int) {
        let bytes = id.uuid
        let horizontalSeed = (Int(bytes.0) << 8) | Int(bytes.1)
        let verticalSeed = (Int(bytes.8) << 8) | Int(bytes.9)
        return (horizontalSeed % 76, verticalSeed % 62)
    }
}

struct VoteTallyPresentation: Identifiable, Equatable {
    let id: String
    let title: String
    let count: Int
}

@MainActor
@Observable
final class HostCoordinator {
    typealias DiagnosticsActivity = HostRecords.DiagnosticsActivity
    typealias DiagnosticsReport = HostRecords.DiagnosticsReport
    typealias DiagnosticsExporter = HostRecords.DiagnosticsExporter

    let host: PartyHost
    let configuration: HostLaunchConfiguration
    private(set) var phase: HostPhase {
        get { flow.phase }
        set { flow.phase = newValue }
    }
    private(set) var turnOrder = TurnOrder()
    private(set) var statusMessage = "Starting local party…"
    private(set) var menuSelection: Int {
        get { flow.menuSelection }
        set { flow.menuSelection = newValue }
    }
    private(set) var currentScene: SKScene?
    private(set) var reactionBursts: [ReactionBurst] = []
    private(set) var voteTallies: [String: Int] = [:]
    var historyRecords: [MatchRecord] { records.historyRecords }
    var cupRecords: [CupRecord] { records.cupRecords }
    var matchHistoryPersistenceError: String? { records.matchHistoryPersistenceError }
    var cupHistoryPersistenceError: String? { records.cupHistoryPersistenceError }
    var historyPersistenceError: String? { records.historyPersistenceError }
    private(set) var historySelection: Int {
        get { records.historySelection }
        set { records.historySelection = newValue }
    }
    private(set) var confirmsHistoryClear: Bool {
        get { records.confirmsHistoryClear }
        set { records.confirmsHistoryClear = newValue }
    }
    private(set) var captainID: PlayerID? {
        get { flow.captainID }
        set { flow.captainID = newValue }
    }
    private(set) var readyPlayerIDs: Set<PlayerID> {
        get { flow.readyPlayerIDs }
        set { flow.readyPlayerIDs = newValue }
    }
    private(set) var botFillTarget: Int {
        get { botDirector.botFillTarget }
        set { botDirector.botFillTarget = newValue }
    }
    private(set) var botDifficultyChange: String? {
        get { botDirector.botDifficultyChange }
        set { botDirector.botDifficultyChange = newValue }
    }
    private(set) var cupSetupSelection: Int {
        get { cup.cupSetupSelection }
        set { cup.cupSetupSelection = newValue }
    }
    private(set) var selectedCupGameIDs: [String] {
        get { cup.selectedCupGameIDs }
        set { cup.selectedCupGameIDs = newValue }
    }
    private(set) var cupEventIndex: Int {
        get { cup.cupEventIndex }
        set { cup.cupEventIndex = newValue }
    }
    private(set) var cupPoints: [ControllerID: Int] {
        get { cup.cupPoints }
        set { cup.cupPoints = newValue }
    }
    private(set) var cupEventWins: [ControllerID: Int] {
        get { cup.cupEventWins }
        set { cup.cupEventWins = newValue }
    }
    private(set) var cupParticipants: [GameParticipant] {
        get { cup.cupParticipants }
        set { cup.cupParticipants = newValue }
    }
    private(set) var cupMatchRecordIDs: [UUID] {
        get { cup.cupMatchRecordIDs }
        set { cup.cupMatchRecordIDs = newValue }
    }
    private(set) var currentMatchIsCup: Bool {
        get { cup.currentMatchIsCup }
        set { cup.currentMatchIsCup = newValue }
    }

    @ObservationIgnored private let games: [any PartyGame]
    @ObservationIgnored private let menuLayout: HostMenuLayout
    @ObservationIgnored private var sounds: ArcadeSoundPlayer?
    private let records: HostRecords
    private let cup = HostCupDirector()
    private let botDirector = HostBotDirector()
    private let flow = HostFlow()
    @ObservationIgnored private let logger = Logger(subsystem: "PartyBox", category: "HostCoordinator")
    @ObservationIgnored private var currentSession: (any PartyGameSession)?
    private var bots: [ControllerID: PartyClient] { botDirector.bots }
    @ObservationIgnored private var hostEventsTask: Task<Void, Never>?
    @ObservationIgnored private var botInputTask: Task<Void, Never>?
    @ObservationIgnored private var botReconciliationOperation: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var soundPreparationTask: Task<Void, Never>?
    private var botsNeedReconciliation: Bool {
        get { botDirector.needsReconciliation }
        set { botDirector.needsReconciliation = newValue }
    }
    @ObservationIgnored private var reactionTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var lifecycleGeneration = UUID()
    @ObservationIgnored private var currentParticipants: [GameParticipant] = []
    @ObservationIgnored private var currentMatchID: UUID?
    @ObservationIgnored private var pendingGameEventBatches: [[GameEvent]] = []
    @ObservationIgnored private var gameEventOperation: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var layoutBroadcastOperation: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var layoutsNeedBroadcast = false
    @ObservationIgnored private var rosterBroadcastOperation: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var pendingRosterBroadcast: [PlayerInfo]?
    @ObservationIgnored private var latestRequestedRoster: [PlayerInfo]?
    @ObservationIgnored private var eliminatedControllers: Set<ControllerID> = []
    @ObservationIgnored private var votes: [PlayerID: String] = [:]
    @ObservationIgnored private var lastReactionAt: [PlayerID: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var lastVoteAt: [PlayerID: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var currentMatchSeed: UInt64 = 1
    @ObservationIgnored private var matchStartedAt = Date()
    @ObservationIgnored private var appliedModifier: GameModifierDescriptor?
    @ObservationIgnored private var pendingModifier: GameModifierDescriptor?
#if DEBUG
    @ObservationIgnored private(set) var layoutBroadcastCountForTesting = 0
    var layoutBroadcastInProgressForTesting: Bool { layoutBroadcastOperation != nil }
    @ObservationIgnored private var startCheckpointForTesting: (@MainActor () async -> Void)?
    @ObservationIgnored private var finishMatchCheckpointForTesting: (@MainActor () async -> Void)?
    @ObservationIgnored private var finishCupCheckpointForTesting: (@MainActor () async -> Void)?
    @ObservationIgnored private var botDrainFinishedForTesting: (@MainActor (UUID) -> Void)?
#endif

    var menuItems: [String] { games.map { $0.descriptor.title } + ["PARTY CUP", "HISTORY & LEADERBOARD"] }
    var menuDetails: [String] { games.map { $0.descriptor.summary } + ["Captain picks three events  •  One champion", "All-time results and match details"] }
    var cupEligibleGames: [GameDescriptor] { games.map(\.descriptor).filter(\.isCupEligible) }
    var cupSetupItems: [String] {
        cupEligibleGames.map { descriptor in
            selectedCupGameIDs.contains(descriptor.id) ? "✓  \(descriptor.title)" : "○  \(descriptor.title)"
        } + ["START PARTY CUP"]
    }
    var cupSetupDetails: [String] {
        cupEligibleGames.map(\.summary) + ["\(selectedCupGameIDs.count)/3 events selected"]
    }
    var cupLeaderboard: [CupStandingRecord] { makeCupStandings() }
    var currentGameTitle: String {
        games.indices.contains(menuSelection) ? games[menuSelection].descriptor.title : "PARTYBOX"
    }
    var leaderboard: [LeaderboardEntry] { records.leaderboard }
    var displayedVoteTallies: [VoteTallyPresentation] {
        let modifiers = games.indices.contains(menuSelection)
            ? games[menuSelection].availableModifiers(participantCount: currentParticipants.count)
            : []
        return voteTallies.keys.sorted().map { modifierID in
            VoteTallyPresentation(
                id: modifierID,
                title: modifiers.first(where: { $0.id == modifierID })?.title ?? modifierID,
                count: voteTallies[modifierID, default: 0]
            )
        }
    }
    var connectedCount: Int { host.players.filter(\.isConnected).count }
    private var matchReadyPlayers: [PlayerInfo] {
        host.players.filter { player in
            guard player.isConnected else { return false }
            guard player.kind == .bot else { return true }
            guard let controllerID = host.controllerID(for: player.id) else { return false }
            return bots[controllerID]?.player?.id == player.id
        }
    }
    var connectedHumanCount: Int {
        host.players.filter { $0.isConnected && $0.kind == .human }.count
    }
    var activeBotCount: Int {
        host.players.filter { $0.isConnected && $0.kind == .bot }.count
    }
    var currentBotDifficulty: GameBotDifficulty {
        botDirector.difficulty(for: games.indices.contains(menuSelection)
            ? games[menuSelection].descriptor.id : nil)
    }
    var requiredReadyCount: Int { flow.requiredReadyCount(connectedHumanCount: connectedHumanCount) }
    var readyCount: Int { flow.readyCount(players: host.players) }
    var canStart: Bool {
        switch phase {
        case .lobby: return connectedCount > 0
        case .cupSetup: return selectedCupGameIDs.count == 3 && connectedCount > 0
        case .cupStandings: return cupEventIndex + 1 < selectedCupGameIDs.count
        case .gameMenu, .gameOver:
            guard games.indices.contains(menuSelection) else { return menuSelection == menuLayout.cupMenuIndex && !matchReadyPlayers.isEmpty }
            return matchReadyPlayers.count >= games[menuSelection].descriptor.minimumPlayers
        case .playing, .cupComplete, .history: return false
        }
    }

    init(
        configuration suppliedConfiguration: HostLaunchConfiguration? = nil,
        historyFileURL: URL? = nil,
        host suppliedHost: PartyHost? = nil,
        diagnosticsExporter: DiagnosticsExporter? = nil
    ) {
        let configuration = suppliedConfiguration ?? .current
        self.configuration = configuration
        host = suppliedHost ?? PartyHost()
        records = HostRecords(
            configuration: configuration,
            historyFileURL: historyFileURL,
            diagnosticsExporter: diagnosticsExporter
        )
        let loadedGames = PartyGames.all()
        games = loadedGames
        menuLayout = HostMenuLayout(
            gameCount: loadedGames.count,
            cupEligibleCount: loadedGames.count { $0.descriptor.isCupEligible }
        )
        sounds = nil
        botFillTarget = min(configuration.botCount, PartyNetConstants.maximumControllers)
    }

    func start() async {
        await start(preservingHostInstanceID: nil)
    }

    private func start(preservingHostInstanceID: UUID?) async {
        guard !isStarted else { return }
        let generation = UUID()
        lifecycleGeneration = generation
        isStarted = true
#if DEBUG
        if let checkpoint = startCheckpointForTesting { await checkpoint() }
#endif
        let (storedHistory, storedCups) = await records.load()
        guard isStarted, lifecycleGeneration == generation else { return }
        records.installLoaded(matches: storedHistory, cups: storedCups)
#if DEBUG
        if let scenario = configuration.scenario {
            applyFixture(scenario: scenario)
            statusMessage = "UI test fixture"
            return
        }
#endif
        let stream = host.eventStream { [weak self] in
            Task { @MainActor [weak self] in
                await self?.recoverFromHostEventStreamEnding(generation: generation, cancelConsumer: true)
            }
        }
        hostEventsTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event, generation: generation)
            }
            await self?.recoverFromHostEventStreamEnding(generation: generation, cancelConsumer: false)
        }
        do {
            let name: String
            if let configuredName = configuration.hostName {
                name = configuredName
            } else {
                name = await Task.detached(priority: .utility) {
                    ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
                }.value + "'s PartyBox"
            }
            guard isStarted, lifecycleGeneration == generation else { return }
            _ = try await host.start(
                hostName: name,
                hostInstanceID: preservingHostInstanceID
            )
            guard isStarted, lifecycleGeneration == generation else { return }
            statusMessage = "Ready for controllers"
            prepareSounds(generation: generation)
            startBotInputLoop(generation: generation)
            requestBotReconciliation()
        } catch {
            await handleStartFailure(error, generation: generation) { [host] in
                await host.stop()
            }
        }
    }

    private func handleStartFailure(
        _ error: any Error,
        generation: UUID,
        cleanup: @MainActor () async -> Void
    ) async {
        guard lifecycleGeneration == generation else { return }
        isStarted = false
        let failureGeneration = UUID()
        lifecycleGeneration = failureGeneration
        hostEventsTask?.cancel()
        hostEventsTask = nil
        await cleanup()
        guard !Task.isCancelled,
              !isStarted,
              lifecycleGeneration == failureGeneration else { return }
        statusMessage = "Could not start: \(error.localizedDescription)"
    }

    private var desiredBotCount: Int {
        botDirector.desiredCount(
            configuredCount: configuration.botCount,
            connectedHumanCount: connectedHumanCount
        )
    }

    private func requestBotReconciliation() {
        botsNeedReconciliation = true
        guard isStarted, phase != .playing, host.port != nil, botReconciliationOperation == nil else { return }
        let generation = lifecycleGeneration
        let operationID = UUID()
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainBotReconciliation(operationID: operationID, generation: generation)
        }
        botReconciliationOperation = (operationID, task)
    }

    private func drainBotReconciliation(operationID: UUID, generation: UUID) async {
        defer {
            if botReconciliationOperation?.id == operationID {
                botReconciliationOperation = nil
                if botsNeedReconciliation, phase != .playing { requestBotReconciliation() }
            }
#if DEBUG
            botDrainFinishedForTesting?(operationID)
#endif
        }
        while botsNeedReconciliation,
              !Task.isCancelled,
              isStarted,
              lifecycleGeneration == generation,
              botReconciliationOperation?.id == operationID,
              phase != .playing,
              let port = host.port {
            botsNeedReconciliation = false
            let result = await botDirector.reconcile(
                host: host, port: port, desired: desiredBotCount,
                isCurrentLifecycle: { [weak self] in
                    guard let self else { return false }
                    return !Task.isCancelled && self.isStarted
                        && self.lifecycleGeneration == generation
                        && self.botReconciliationOperation?.id == operationID
                },
                canChangeRoster: { [weak self] in
                    guard let self else { return false }
                    return self.phase != .playing
                },
                isMatchParticipant: { [weak self] controllerID in
                    guard let self, self.phase == .playing else { return false }
                    return self.currentParticipants.contains { $0.controllerID == controllerID }
                }
            )
            switch result {
            case .completed: break
            case .joinFailed: statusMessage = "A bot could not join"
            case .cancelled: return
            }
            requestLayoutBroadcast()
        }
    }

    private func startBotInputLoop(generation: UUID) {
        botInputTask?.cancel()
        botInputTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1.0 / 60.0)) }
                catch { return }
                guard let self,
                      self.isStarted,
                      self.lifecycleGeneration == generation else { return }
                self.driveBots(deltaTime: 1.0 / 60.0)
            }
        }
    }

    private func driveBots(deltaTime: TimeInterval) {
        guard phase == .playing, let currentSession else { return }
        botDirector.drive(
            session: currentSession, participants: currentParticipants,
            difficulty: currentBotDifficulty, deltaTime: deltaTime
        )
    }

    func stop() async {
        isStarted = false
        lifecycleGeneration = UUID()
        hostEventsTask?.cancel()
        hostEventsTask = nil
        let botsToStop = prepareRuntimeForShutdown()
        await host.stop()
        await stopBotsConcurrently(botsToStop)
    }

    func perform(
        _ action: PartyBoxCore.MenuAction,
        source: HostInputSource = .local,
        now suppliedNow: ContinuousClock.Instant? = nil
    ) {
        // Screenshot fixtures can opt out of navigation caused by stray focus or keyboard events.
        if configuration.freezeScenario { return }
        let context = HostFlow.Context(
            players: host.players,
            menuLayout: menuLayout,
            connectedHumanCount: connectedHumanCount,
            cupSetupSelection: cupSetupSelection,
            selectedCupGameCount: selectedCupGameIDs.count,
            canStart: canStart,
            historySelection: historySelection,
            historyRecordCount: historyRecords.count
        )
        execute(flow.apply(action, source: source, now: suppliedNow, context: context))
    }

    private func execute(_ intents: [HostFlow.Intent]) {
        for intent in intents {
            switch intent {
            case .requestLayout: requestLayoutBroadcast()
            case .reconcileBots: requestBotReconciliation()
            case .clearBotDifficulty: botDifficultyChange = nil
            case .clearCupSelection: cup.clearSelection()
            case .setCupSelection(let selection): cupSetupSelection = selection
            case .toggleCupGame(let index): toggleCupGame(at: index)
            case .startSelectedGame: startSelectedGame()
            case .startCup: startCup()
            case .startNextCupEvent: startNextCupEvent()
            case .resetCup: resetCup()
            case .clearPendingModifier: pendingModifier = nil
            case .setHistorySelection(let selection): historySelection = selection
            case .cancelHistoryClear: confirmsHistoryClear = false
            }
        }
    }

    private func toggleCupGame(at index: Int) {
        let eligibleGames = cupEligibleGames
        guard eligibleGames.indices.contains(index) else { return }
        _ = cup.toggleGame(at: index, eligibleGames: eligibleGames)
        clearReadiness()
        requestLayoutBroadcast()
    }

    private func startCup() {
        guard phase == .cupSetup, selectedCupGameIDs.count == 3,
              readyCount >= requiredReadyCount else { return }
        let participants = connectedParticipants(maximum: PartyBoxRuntimeLimits.releasePartySize)
        guard !participants.isEmpty else { return }
        cup.begin(participants: participants)
        guard startCupEvent(at: 0) else {
            cup.abortFirstEvent()
            return
        }
    }

    private func startNextCupEvent() {
        let nextEventIndex = cupEventIndex + 1
        guard case .cupStandings = phase, nextEventIndex < selectedCupGameIDs.count else { return }
        guard startCupEvent(at: nextEventIndex) else { return }
        cupEventIndex = nextEventIndex
    }

    @discardableResult
    private func startCupEvent(at eventIndex: Int) -> Bool {
        reconcileCupParticipants()
        guard selectedCupGameIDs.indices.contains(eventIndex),
              let gameIndex = games.firstIndex(where: { $0.descriptor.id == selectedCupGameIDs[eventIndex] }) else { return false }
        let live = cupParticipants.filter { livePlayer(for: $0)?.isConnected == true }
        return startGame(at: gameIndex, participants: live, isCupEvent: true)
    }

    private func reconcileCupParticipants() {
        let current = matchReadyPlayers.compactMap { player -> GameParticipant? in
            guard let controllerID = host.controllerID(for: player.id) else { return nil }
            return GameParticipant(player: player, controllerID: controllerID)
        }
        cup.reconcileParticipants(current)
    }

    private func connectedParticipants(maximum: Int) -> [GameParticipant] {
        let connectedPlayers = matchReadyPlayers
        let connected = Set(connectedPlayers.map(\.id))
        let ids = turnOrder.participants(
            connected: connected,
            maximum: maximum,
            including: connectedPlayers.map(\.id)
        )
        let playersByID = Dictionary(uniqueKeysWithValues: connectedPlayers.map { ($0.id, $0) })
        var participants: [GameParticipant] = []
        participants.reserveCapacity(ids.count)
        for id in ids {
            guard let player = playersByID[id],
                  let controllerID = host.controllerID(for: id) else { return [] }
            participants.append(GameParticipant(player: player, controllerID: controllerID))
        }
        return participants
    }

    private func clearReadiness() {
        flow.clearReadiness()
    }

    func requestHistoryClear() { records.confirmsHistoryClear = true }
    func cancelHistoryClear() { records.confirmsHistoryClear = false }

    func makeRedactedDiagnosticsFile() async throws -> DiagnosticsExport {
        let phaseName: String = switch phase {
        case .lobby: "lobby"
        case .gameMenu: "gameMenu"
        case .cupSetup: "cupSetup"
        case .playing: "playing"
        case .gameOver: "gameOver"
        case .cupStandings: "cupStandings"
        case .cupComplete: "cupComplete"
        case .history: "history"
        }
        let generatedAt = Date()
        let report = DiagnosticsReport(
            generatedAt: generatedAt,
            role: "host",
            protocolVersion: PartyNetConstants.protocolVersion,
            phase: phaseName,
            connectedPlayers: connectedCount,
            connectedHumans: connectedHumanCount,
            activeBots: activeBotCount,
            currentGame: phase == .playing ? currentGameTitle : nil,
            inputActivity: host.inputs.activitySnapshot().map {
                DiagnosticsActivity(
                    acceptedFrames: $0.acceptedFrameCount,
                    minimumAxis: $0.minimumAxisX,
                    maximumAxis: $0.maximumAxisX
                )
            },
            historyPersistenceHealthy: historyPersistenceError == nil
        )
        return try await records.export(report)
    }

    func confirmHistoryClear(source: HostInputSource = .local) async {
        guard source == .local, records.confirmsHistoryClear else { return }
        await records.clear()
    }

    private func handle(_ event: HostEvent, generation: UUID) async {
        guard isStarted, lifecycleGeneration == generation else { return }
        switch event {
        case .rosterChanged(let roster):
            updateConnectedHumanRoster(roster)
            requestRosterBroadcast(roster)
            requestLayoutBroadcast()
            requestBotReconciliation()
        case .playerJoined(let player):
            turnOrder.joined(player.id)
            if player.kind == .human, let controllerID = host.controllerID(for: player.id) {
                if !flow.humanConnectionOrder.contains(controllerID) { flow.humanConnectionOrder.append(controllerID) }
                if captainID == nil { captainID = player.id }
            }
            statusMessage = player.kind == .bot
                ? "\(player.displayName) is ready"
                : "\(player.displayName) joined"
            requestLayoutBroadcast()
        case .playerReconnected(let player):
            statusMessage = "\(player.displayName) reconnected"
            requestLayoutBroadcast()
            if case .cupComplete(let record) = phase,
               let controllerID = host.controllerID(for: player.id),
               let personalRecord = PersonalCupRecord(record: record, controllerID: controllerID) {
                await send(
                    .cupCompleted(personalRecord),
                    to: player.id
                )
            }
        case .playerDisconnected(let player):
            if player.kind == .human, captainID == player.id { promoteCaptain() }
            statusMessage = "Waiting 15 seconds for \(player.displayName)…"
            requestLayoutBroadcast()
        case .playerExpired(let player, let controllerID):
            turnOrder.left(player.id)
            if votes.removeValue(forKey: player.id) != nil {
                updateVoteTallies()
            }
            lastReactionAt.removeValue(forKey: player.id)
            lastVoteAt.removeValue(forKey: player.id)
            flow.forgetInput(from: player.id)
            flow.humanConnectionOrder.removeAll { $0 == controllerID }
            if player.kind == .bot, let bot = botDirector.bots.removeValue(forKey: controllerID) {
                host.unregisterLocalBot(controllerID: controllerID)
                Task { await bot.stop() }
            }
            if captainID == player.id { promoteCaptain() }
            if phase == .playing,
               currentParticipants.contains(where: {
                   $0.player.id == player.id && $0.controllerID == controllerID
               }) {
                currentSession?.forfeit(player.id)
            }
            statusMessage = host.players.isEmpty ? "Ready for controllers" : "\(player.displayName) left the party"
            requestLayoutBroadcast()
            requestBotReconciliation()
        case let .application(playerID, payload):
            guard let command = try? PartyBoxWireCodec.decode(ControllerCommand.self, from: payload) else { return }
            await handle(command, from: playerID)
        case .failure(let message):
            statusMessage = message
        }
    }

    private func handle(_ command: ControllerCommand, from playerID: PlayerID) async {
        switch command {
        case .lobby(let action):
            guard let player = flow.authorizedLobbyPlayer(for: playerID, players: host.players) else { return }
            switch action {
            case .selectMark(let mark):
                if host.assignMark(mark, to: player.id) {
                    clearReadiness()
                    requestLayoutBroadcast()
                }
            case .setBotFillTarget(let target):
                guard flow.authorizesBotFillChange(from: player.id,
                                                   configuredBotCount: configuration.botCount) else { return }
                let clamped = min(
                    max(target, 0),
                    PartyBoxRuntimeLimits.maximumLobbyBots
                )
                guard clamped != botFillTarget else { return }
                botFillTarget = clamped
                clearReadiness()
                requestLayoutBroadcast()
                requestBotReconciliation()
            }
        case .menu(let action): perform(action, source: .controller(playerID))
        case .game(let envelope):
            guard flow.authorizesGameAction(
                gameID: envelope.gameID,
                currentGameID: games.indices.contains(menuSelection) ? games[menuSelection].descriptor.id : nil,
                schemaVersion: envelope.schemaVersion,
                participant: currentParticipant(for: playerID),
                eliminatedControllers: eliminatedControllers
            ) else { return }
            currentSession?.handle(action: envelope.action, from: playerID)
        case .spectator(let action):
            guard isEligibleSpectator(playerID) else { return }
            switch action {
            case .reaction(let emoji): addReaction(emoji, from: playerID)
            case .vote(let modifierID):
                guard storeVoteIfChanged(modifierID, from: playerID) else { return }
                requestLayoutBroadcast()
            }
        }
    }

    private func updateConnectedHumanRoster(_ roster: [PlayerInfo]) {
        let connected = Set(roster.compactMap { player -> ControllerID? in
            guard player.isConnected, player.kind == .human else { return nil }
            return host.controllerID(for: player.id)
        })
        flow.updateConnectedHumans(connected)
    }

    private func promoteCaptain() {
        let connectedByController = Dictionary(uniqueKeysWithValues: host.players.compactMap {
            player -> (ControllerID, PlayerID)? in
            guard player.isConnected, player.kind == .human,
                  let controllerID = host.controllerID(for: player.id) else { return nil }
            return (controllerID, player.id)
        })
        guard flow.promoteCaptain(connectedByController: connectedByController) else { return }
        if let promoted = captainID,
           let player = host.players.first(where: { $0.id == promoted }) {
            statusMessage = "\(player.displayName) is now party captain"
        }
        requestLayoutBroadcast()
    }

    private func startSelectedGame() {
        guard phase != .playing, games.indices.contains(menuSelection) else { return }
        let game = games[menuSelection]
        let participants = connectedParticipants(maximum: game.descriptor.maximumPlayers)
        _ = startGame(at: menuSelection, participants: participants, isCupEvent: false)
    }

    static func participantsForStart(
        _ participants: [GameParticipant],
        descriptor: GameDescriptor
    ) -> [GameParticipant]? {
        let eligible = Array(participants.prefix(descriptor.maximumPlayers))
        return eligible.count >= descriptor.minimumPlayers ? eligible : nil
    }

    @discardableResult
    private func startGame(at gameIndex: Int, participants: [GameParticipant], isCupEvent: Bool) -> Bool {
        guard phase != .playing, games.indices.contains(gameIndex) else { return false }
        let game = games[gameIndex]
        guard let participants = Self.participantsForStart(
            participants,
            descriptor: game.descriptor
        ) else { return false }
        menuSelection = gameIndex
        let modifier = Self.applicableModifier(
            isCupEvent ? nil : pendingModifier,
            for: game,
            participantCount: participants.count
        )
        pendingModifier = nil
        appliedModifier = modifier
        botDifficultyChange = nil
        clearReadiness()
        currentParticipants = participants
        currentMatchIsCup = isCupEvent
        let matchID = UUID()
        currentMatchID = matchID
        pendingGameEventBatches = []
        gameEventOperation?.task.cancel()
        gameEventOperation = nil
        eliminatedControllers = []
        votes = [:]
        lastVoteAt = [:]
        voteTallies = [:]
        currentMatchSeed = configuration.seed ?? UInt64.random(in: 1...UInt64.max)
        matchStartedAt = Date()
        host.inputs.neutralize()
        let context = GameSessionContext(
            participants: participants,
            inputs: host.inputs,
            seed: currentMatchSeed,
            modifierID: modifier?.id
        )
        currentSession = game.makeSession(context: context) { [weak self] events in
            self?.handleGame(events, matchID: matchID)
        }
        currentScene = currentSession?.scene
        phase = .playing
        statusMessage = "Match in progress"
        requestLayoutBroadcast()
        return true
    }

    private func handleGame(_ events: [GameEvent], matchID: UUID) {
        guard phase == .playing, currentMatchID == matchID, !events.isEmpty else { return }
        pendingGameEventBatches.append(events)
        guard gameEventOperation == nil else { return }
        let operationID = UUID()
        let lifecycleGeneration = lifecycleGeneration
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainGameEvents(
                operationID: operationID,
                matchID: matchID,
                lifecycleGeneration: lifecycleGeneration
            )
        }
        gameEventOperation = (operationID, task)
    }

    private func drainGameEvents(operationID: UUID, matchID: UUID, lifecycleGeneration: UUID) async {
        while !Task.isCancelled,
              gameEventOperation?.id == operationID,
              isCurrentMatch(matchID, lifecycleGeneration: lifecycleGeneration),
              !pendingGameEventBatches.isEmpty {
            let events = pendingGameEventBatches.removeFirst()
            await processGameEvents(events, matchID: matchID, lifecycleGeneration: lifecycleGeneration)
        }
        if gameEventOperation?.id == operationID { gameEventOperation = nil }
    }

    private func processGameEvents(_ events: [GameEvent], matchID: UUID, lifecycleGeneration: UUID) async {
        guard isCurrentMatch(matchID, lifecycleGeneration: lifecycleGeneration) else { return }
        var needsLayout = false
        var completion: GameOutcome?
        var haptics: [(PlayerID, HapticPattern)] = []
        var deviceCues: [(PlayerID, DeviceCue)] = []
        for event in events {
            switch event {
            case .audio(let cue):
                sounds?.play(cue)
            case let .haptic(playerID, pattern):
                haptics.append((playerID, pattern))
            case let .deviceCue(playerID, cue):
                deviceCues.append((playerID, cue))
            case .eliminated(let playerID):
                if let participant = currentParticipants.first(where: { $0.player.id == playerID }) {
                    eliminatedControllers.insert(participant.controllerID)
                }
                needsLayout = true
            case .completed(let outcome):
                completion = outcome
            }
        }
        for (playerID, pattern) in haptics {
            guard isCurrentMatch(matchID, lifecycleGeneration: lifecycleGeneration) else { return }
            guard let participant = currentParticipants.first(where: { $0.player.id == playerID }),
                  livePlayer(for: participant)?.isConnected == true else { continue }
            await send(.haptic(pattern), to: playerID)
        }
        for (playerID, cue) in deviceCues {
            guard isCurrentMatch(matchID, lifecycleGeneration: lifecycleGeneration) else { return }
            guard let participant = currentParticipants.first(where: { $0.player.id == playerID }),
                  livePlayer(for: participant)?.isConnected == true else { continue }
            await send(.deviceCue(cue), to: playerID)
        }
        guard isCurrentMatch(matchID, lifecycleGeneration: lifecycleGeneration) else { return }
        if let completion {
            await finishMatch(completion, matchID: matchID, lifecycleGeneration: lifecycleGeneration)
        } else if needsLayout {
            requestLayoutBroadcast()
        }
    }

    private func finishMatch(_ outcome: GameOutcome, matchID: UUID, lifecycleGeneration: UUID) async {
        guard isCurrentMatch(matchID, lifecycleGeneration: lifecycleGeneration),
              games.indices.contains(menuSelection) else { return }
        let game = games[menuSelection]
        let participants = currentParticipants
        pendingModifier = currentMatchIsCup ? nil : resolveVote(in: game)
        let endedAt = Date()
        let participantRecords = participants.map { participant in
            let value = outcome.playerOutcomes.first { $0.playerID == participant.player.id }?.outcome ?? .lost
            return MatchParticipant(
                controllerID: participant.controllerID,
                displayName: livePlayer(for: participant)?.displayName ?? participant.player.displayName,
                colorHex: participant.player.colorHex,
                outcome: value,
                kind: participant.player.kind
            )
        }
        let record = MatchRecord(
            gameID: game.descriptor.id,
            gameTitle: game.descriptor.title,
            endedAt: endedAt,
            durationSeconds: endedAt.timeIntervalSince(matchStartedAt),
            modifierTitle: appliedModifier?.title,
            participants: participantRecords,
            metrics: outcome.metrics
        )
        let historyResult = await records.appendMatch(record)
#if DEBUG
        if let checkpoint = finishMatchCheckpointForTesting { await checkpoint() }
#endif
        guard isCurrentMatch(matchID, lifecycleGeneration: lifecycleGeneration) else { return }
        records.applyMatchAppend(record, result: historyResult)
        for participant in participants {
            guard isCurrentMatch(matchID, lifecycleGeneration: lifecycleGeneration) else { return }
            guard livePlayer(for: participant)?.isConnected == true else { continue }
            await send(.matchCompleted(PersonalMatchRecord(record: record, controllerID: participant.controllerID)), to: participant.player.id)
        }
        guard isCurrentMatch(matchID, lifecycleGeneration: lifecycleGeneration) else { return }
        if currentMatchIsCup {
            scoreCupEvent(outcome)
            cup.recordMatch(record.id)
        }
        let identityMatchedParticipants = participants.filter { livePlayer(for: $0) != nil }
        let identityMatchedIDs = identityMatchedParticipants.map { $0.player.id }
        let identityMatchedWinner = outcome.winner.flatMap { winner in
            identityMatchedParticipants.contains(where: { $0.player.id == winner }) ? winner : nil
        }
        turnOrder.rotateAfterMatch(active: identityMatchedIDs, winner: identityMatchedWinner)
        updateBotDifficulty(after: outcome, participants: participants, gameID: game.descriptor.id)
        currentMatchID = nil
        pendingGameEventBatches = []
        currentSession = nil
        currentScene = nil
        appliedModifier = nil
        if currentMatchIsCup {
            currentMatchIsCup = false
            if cupEventIndex + 1 >= selectedCupGameIDs.count {
                guard await finishCup(lifecycleGeneration: lifecycleGeneration) else { return }
            } else {
                phase = .cupStandings(outcome)
            }
        } else {
            phase = .gameOver(outcome)
        }
        clearReadiness()
        requestLayoutBroadcast()
        requestBotReconciliation()
    }

    private func scoreCupEvent(_ outcome: GameOutcome) {
        cup.score(outcome, participants: currentParticipants)
    }

    private func liveCupPlayers() -> [ControllerID: PlayerInfo] {
        Dictionary(uniqueKeysWithValues: cupParticipants.compactMap { participant in
            livePlayer(for: participant).map { (participant.controllerID, $0) }
        })
    }

    private func makeCupStandings() -> [CupStandingRecord] {
        cup.standings(livePlayers: liveCupPlayers())
    }

    private func finishCup(lifecycleGeneration: UUID) async -> Bool {
        let record = cup.makeRecord(livePlayers: liveCupPlayers())
        let result = await records.appendCup(record)
#if DEBUG
        if let checkpoint = finishCupCheckpointForTesting { await checkpoint() }
#endif
        guard isCurrentLifecycle(lifecycleGeneration) else { return false }
        records.applyCupAppend(record, result: result)
        for participant in cupParticipants {
            guard isCurrentLifecycle(lifecycleGeneration) else { return false }
            guard let live = livePlayer(for: participant), live.isConnected else { continue }
            guard let personalRecord = PersonalCupRecord(record: record, controllerID: participant.controllerID) else { continue }
            await send(.cupCompleted(personalRecord), to: live.id)
        }
        guard isCurrentLifecycle(lifecycleGeneration) else { return false }
        phase = .cupComplete(record)
        statusMessage = record.standings.first.map { "\($0.displayName) won the Party Cup" } ?? "Party Cup complete"
        return true
    }

    private func resetCup() {
        cup.reset()
    }

    private func updateBotDifficulty(
        after outcome: GameOutcome,
        participants: [GameParticipant],
        gameID: String
    ) {
        if let message = botDirector.updateDifficulty(after: outcome, participants: participants, gameID: gameID) {
            statusMessage = message
        }
    }

    private func isCurrentMatch(_ matchID: UUID, lifecycleGeneration: UUID) -> Bool {
        isStarted && self.lifecycleGeneration == lifecycleGeneration
            && currentMatchID == matchID && phase == .playing
    }

    private func isCurrentLifecycle(_ lifecycleGeneration: UUID) -> Bool {
        isStarted && self.lifecycleGeneration == lifecycleGeneration
    }

    private func livePlayer(for participant: GameParticipant) -> PlayerInfo? {
        guard host.controllerID(for: participant.player.id) == participant.controllerID else { return nil }
        return host.players.first { $0.id == participant.player.id }
    }

    private func currentParticipant(for playerID: PlayerID) -> GameParticipant? {
        currentParticipants.first { participant in
            participant.player.id == playerID && livePlayer(for: participant) != nil
        }
    }

    private func resolveVote(in game: any PartyGame) -> GameModifierDescriptor? {
        guard !votes.isEmpty else { return nil }
        let counts = Dictionary(grouping: votes.values, by: { $0 }).mapValues(\.count)
        guard let maximum = counts.values.max() else { return nil }
        let tied = game.availableModifiers(participantCount: currentParticipants.count)
            .filter { counts[$0.id] == maximum }
        guard !tied.isEmpty else { return nil }
        return tied[Int(currentMatchSeed % UInt64(tied.count))]
    }

    static func applicableModifier(
        _ candidate: GameModifierDescriptor?,
        for game: any PartyGame,
        participantCount: Int
    ) -> GameModifierDescriptor? {
        guard let candidate,
              game.availableModifiers(participantCount: participantCount).contains(where: {
                  $0.id == candidate.id
              }) else { return nil }
        return candidate
    }

    private func isEligibleSpectator(_ playerID: PlayerID) -> Bool {
        flow.authorizesSpectatorAction(
            isConnected: host.players.contains(where: { $0.id == playerID && $0.isConnected }),
            participant: currentParticipant(for: playerID),
            eliminatedControllers: eliminatedControllers
        )
    }

    private func addReaction(_ emoji: String, from playerID: PlayerID) {
        guard SpectatorScreenFactory.reactions.contains(emoji) else { return }
        let now = ContinuousClock().now
        if let previous = lastReactionAt[playerID], previous.duration(to: now) < .seconds(1) { return }
        lastReactionAt[playerID] = now
        let burst = ReactionBurst(emoji: emoji)
        reactionBursts.append(burst)
        if reactionBursts.count > 12 { reactionBursts.removeFirst(reactionBursts.count - 12) }
        reactionTasks[burst.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            self?.reactionBursts.removeAll { $0.id == burst.id }
            self?.reactionTasks.removeValue(forKey: burst.id)
        }
    }

    private func updateVoteTallies() {
        voteTallies = Dictionary(grouping: votes.values, by: { $0 }).mapValues(\.count)
    }

    @discardableResult
    func storeVoteIfChanged(
        _ modifierID: String,
        from playerID: PlayerID,
        now suppliedNow: ContinuousClock.Instant? = nil
    ) -> Bool {
        guard games.indices.contains(menuSelection),
              games[menuSelection].availableModifiers(
                  participantCount: currentParticipants.count
              ).contains(where: { $0.id == modifierID }),
              votes[playerID] != modifierID else { return false }
        let now = suppliedNow ?? ContinuousClock().now
        if let previous = lastVoteAt[playerID], previous.duration(to: now) < .milliseconds(250) {
            return false
        }
        lastVoteAt[playerID] = now
        votes[playerID] = modifierID
        updateVoteTallies()
        return true
    }

    private func appendHistory(_ record: MatchRecord) async {
        let result = await records.appendMatch(record)
        records.applyMatchAppend(record, result: result)
    }

    private func layout(for playerID: PlayerID) -> PartyBoxCore.ControllerLayout {
        switch phase {
        case .lobby:
            return lobbyLayout(for: playerID)
        case .gameMenu:
            return .menu(.init(
                items: menuItems,
                details: menuDetails,
                selected: menuSelection,
                control: controlStatus(for: playerID)
            ))
        case .cupSetup:
            return .menu(.init(
                kind: .cupSetup,
                items: cupSetupItems,
                details: cupSetupDetails,
                selected: cupSetupSelection,
                control: controlStatus(for: playerID)
            ))
        case .history: return .historyNavigation
        case .gameOver(let outcome):
            return .gameOver(.init(
                title: outcome.title,
                subtitle: outcome.subtitle,
                nextUp: pendingModifier?.title,
                control: controlStatus(for: playerID),
                botDifficultyChange: botDifficultyChange
            ))
        case .cupStandings:
            let leader = cupLeaderboard.first
            return .gameOver(.init(
                title: "EVENT \(cupEventIndex + 1) COMPLETE",
                subtitle: leader.map { "\($0.displayName) leads with \($0.points) points" } ?? "Party Cup continues",
                nextUp: selectedCupGameIDs.indices.contains(cupEventIndex + 1)
                    ? games.first(where: { $0.descriptor.id == selectedCupGameIDs[cupEventIndex + 1] })?.descriptor.title
                    : nil,
                control: controlStatus(for: playerID)
            ))
        case .cupComplete(let record):
            let own = record.standings.first { standing in
                host.controllerID(for: playerID) == standing.controllerID
            }
            return .gameOver(.init(
                title: own?.rank == 1 ? "YOU WON THE PARTY CUP" : "PARTY CUP COMPLETE",
                subtitle: own.map { "#\($0.rank)  •  \($0.points) POINTS  •  \($0.eventWins) EVENT WINS" } ?? "See the final standings on the TV",
                control: controlStatus(for: playerID)
            ))
        case .playing:
            guard games.indices.contains(menuSelection) else { return lobbyLayout(for: playerID) }
            let game = games[menuSelection]
            let active = currentParticipants.compactMap { participant in
                livePlayer(for: participant) == nil ? nil : participant.player.id
            }
            let screen: ControllerScreen
            if let participant = currentParticipant(for: playerID),
               !eliminatedControllers.contains(participant.controllerID) {
                screen = currentSession?.controllerScreen(for: playerID) ?? SpectatorScreenFactory.make(
                    game: game.descriptor,
                    state: .init(role: .active, choices: [], tallies: [:], selection: nil)
                )
            } else {
                let role: PlayerRole = currentParticipant(for: playerID).map {
                    eliminatedControllers.contains($0.controllerID)
                } == true
                    ? .eliminated
                    : .waiting(position: turnOrder.waitingPosition(of: playerID, active: active) ?? 1)
                screen = SpectatorScreenFactory.make(
                    game: game.descriptor,
                    state: .init(
                        role: role,
                        choices: game.availableModifiers(participantCount: currentParticipants.count),
                        tallies: voteTallies,
                        selection: votes[playerID]
                    )
                )
            }
            do {
                return .game(.init(gameID: game.descriptor.id, payload: try PartyBoxWireCodec.encode(screen)))
            } catch {
                logger.error("Controller screen for \(game.descriptor.id, privacy: .public) is too large or invalid: \(error.localizedDescription, privacy: .public)")
                return unavailableGameLayout(gameID: game.descriptor.id)
            }
        }
    }

    private func lobbyLayout(for playerID: PlayerID) -> PartyBoxCore.ControllerLayout {
        .lobby(.init(
            captainID: captainID,
            isCaptain: playerID == captainID,
            botFillTarget: botFillTarget,
            activeBotCount: activeBotCount,
            maximumBotCount: PartyBoxRuntimeLimits.maximumLobbyBots,
            botDifficulty: currentBotDifficulty.title
        ))
    }

    private func controlStatus(for playerID: PlayerID) -> PartyControlStatus {
        PartyControlStatus(
            captainID: captainID,
            isCaptain: playerID == captainID,
            isReady: readyPlayerIDs.contains(playerID),
            readyCount: readyCount,
            requiredReadyCount: requiredReadyCount,
            canToggleReady: playerID != captainID && canToggleReadiness
        )
    }

    private var canToggleReadiness: Bool {
        guard canStart else { return false }
        switch phase {
        case .gameMenu:
            return games.indices.contains(menuSelection)
        case .cupSetup, .gameOver, .cupStandings:
            return true
        case .lobby, .playing, .history, .cupComplete:
            return false
        }
    }

    private func unavailableGameLayout(gameID: String) -> PartyBoxCore.ControllerLayout {
        let screen = ControllerScreen(
            accessibilityID: "controller.layout.unavailable",
            accentColorHex: "#FF9F0A",
            components: [
                .text(.init(id: "unavailable", text: "CONTROLLER UNAVAILABLE", style: .title)),
                .text(.init(id: "detail", text: "This game sent a controller screen that was too large.", style: .body)),
            ]
        )
        return .game(.init(gameID: gameID, payload: (try? PartyBoxWireCodec.encode(screen)) ?? Data()))
    }

    func encodedLayoutPresentation(_ layout: PartyBoxCore.ControllerLayout) -> Data? {
        do {
            return try PartyBoxWireCodec.encode(HostPresentation.layout(layout))
        } catch {
            logger.error("Controller layout exceeded the application payload limit: \(error.localizedDescription, privacy: .public)")
            let fallback: PartyBoxCore.ControllerLayout
            if case .game(let envelope) = layout {
                fallback = unavailableGameLayout(gameID: envelope.gameID)
            } else {
                fallback = lobbyLayout(for: captainID ?? PlayerID(0))
            }
            do {
                return try PartyBoxWireCodec.encode(HostPresentation.layout(fallback))
            } catch {
                logger.fault("Could not encode the controller layout fallback: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    private func requestLayoutBroadcast() {
        layoutsNeedBroadcast = true
        guard layoutBroadcastOperation == nil else { return }
        let operationID = UUID()
        let generation = lifecycleGeneration
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainLayoutBroadcasts(operationID: operationID, generation: generation)
        }
        layoutBroadcastOperation = (operationID, task)
    }

    private func drainLayoutBroadcasts(operationID: UUID, generation: UUID) async {
        while !Task.isCancelled,
              isStarted,
              lifecycleGeneration == generation,
              layoutBroadcastOperation?.id == operationID,
              layoutsNeedBroadcast {
            layoutsNeedBroadcast = false
            let pending = host.players.filter(\.isConnected).compactMap { player -> (PlayerID, Data)? in
                guard let payload = encodedLayoutPresentation(layout(for: player.id)) else { return nil }
                return (player.id, payload)
            }
            await withTaskGroup(of: Void.self) { group in
                for (playerID, payload) in pending {
                    group.addTask { [host] in _ = await host.sendApplication(payload, to: playerID) }
                }
            }
#if DEBUG
            layoutBroadcastCountForTesting += 1
#endif
        }
        if layoutBroadcastOperation?.id == operationID { layoutBroadcastOperation = nil }
    }

    private func requestRosterBroadcast(_ roster: [PlayerInfo]) {
        guard latestRequestedRoster != roster else { return }
        latestRequestedRoster = roster
        pendingRosterBroadcast = roster
        guard rosterBroadcastOperation == nil else { return }
        let operationID = UUID()
        let generation = lifecycleGeneration
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainRosterBroadcasts(operationID: operationID, generation: generation)
        }
        rosterBroadcastOperation = (operationID, task)
    }

    private func drainRosterBroadcasts(operationID: UUID, generation: UUID) async {
        while !Task.isCancelled,
              isStarted,
              lifecycleGeneration == generation,
              rosterBroadcastOperation?.id == operationID,
              let roster = pendingRosterBroadcast {
            pendingRosterBroadcast = nil
            await broadcast(.roster(roster))
        }
        if rosterBroadcastOperation?.id == operationID { rosterBroadcastOperation = nil }
    }

    private func send(_ presentation: HostPresentation, to playerID: PlayerID) async {
        guard let payload = try? PartyBoxWireCodec.encode(presentation) else { return }
        _ = await host.sendApplication(payload, to: playerID)
    }

    private func broadcast(_ presentation: HostPresentation) async {
        guard let payload = try? PartyBoxWireCodec.encode(presentation) else { return }
        await host.broadcast(.application(payload))
    }

    private func recoverFromHostEventStreamEnding(generation: UUID, cancelConsumer: Bool) async {
        guard isStarted, lifecycleGeneration == generation else { return }
        let preservedHostInstanceID = host.hostInstanceID
        isStarted = false
        let recoveryGeneration = UUID()
        lifecycleGeneration = recoveryGeneration
        let consumer = hostEventsTask
        hostEventsTask = nil
        if cancelConsumer { consumer?.cancel() }
        let botsToStop = prepareRuntimeForShutdown()
        statusMessage = "Restarting after a host event overload…"
        await host.stop()
        await stopBotsConcurrently(botsToStop)
        guard !isStarted, lifecycleGeneration == recoveryGeneration else { return }
        await start(preservingHostInstanceID: preservedHostInstanceID)
    }

    private func stopBotsConcurrently(_ bots: [PartyClient]) async {
        await withTaskGroup(of: Void.self) { group in
            for bot in bots {
                group.addTask { await bot.stop() }
            }
        }
    }

    private func prepareRuntimeForShutdown() -> [PartyClient] {
        botInputTask?.cancel()
        botInputTask = nil
        botReconciliationOperation?.task.cancel()
        botReconciliationOperation = nil
        soundPreparationTask?.cancel()
        soundPreparationTask = nil
        sounds?.shutdown()
        sounds = nil
        let botsToStop = botDirector.takeBotsForShutdown()
        resetRuntime()
        return botsToStop
    }

    private func resetRuntime() {
        flow.reset()
        reactionTasks.values.forEach { $0.cancel() }
        reactionTasks.removeAll()
        gameEventOperation?.task.cancel()
        gameEventOperation = nil
        pendingGameEventBatches = []
        layoutBroadcastOperation?.task.cancel()
        layoutBroadcastOperation = nil
        layoutsNeedBroadcast = false
        rosterBroadcastOperation?.task.cancel()
        rosterBroadcastOperation = nil
        pendingRosterBroadcast = nil
        latestRequestedRoster = nil
        turnOrder = TurnOrder()
        currentSession = nil
        currentScene = nil
        currentMatchID = nil
        statusMessage = "Starting local party…"
        currentParticipants = []
        resetCup()
        botsNeedReconciliation = false
        eliminatedControllers = []
        votes = [:]
        lastVoteAt = [:]
        voteTallies = [:]
        pendingModifier = nil
        appliedModifier = nil
        reactionBursts = []
        botDifficultyChange = nil
        confirmsHistoryClear = false
#if DEBUG
        startCheckpointForTesting = nil
        finishMatchCheckpointForTesting = nil
        finishCupCheckpointForTesting = nil
#endif
    }

    private func prepareSounds(generation: UUID) {
        guard !configuration.disableEffects,
              sounds == nil,
              soundPreparationTask == nil else { return }
        soundPreparationTask = Task { @MainActor [weak self] in
            let prepared = await ArcadeSoundPlayer.prepare()
            guard let self,
                  !Task.isCancelled,
                  self.isStarted,
                  self.lifecycleGeneration == generation else { return }
            self.sounds = prepared
            self.soundPreparationTask = nil
        }
    }

#if DEBUG
    private struct SimulatedStartFailure: LocalizedError {
        var errorDescription: String? { "Simulated start failure" }
    }

    func simulateSuspendedStartFailureForTesting(
        cleanup: @escaping @MainActor () async -> Void
    ) async {
        let generation = UUID()
        lifecycleGeneration = generation
        isStarted = true
        await handleStartFailure(
            SimulatedStartFailure(),
            generation: generation,
            cleanup: cleanup
        )
    }

    func simulateHostEventStreamEndingForTesting() async {
        await host.simulateTransportEventStreamOverflowForTesting()
    }

    func appendHistoryForTesting(_ record: MatchRecord) async {
        await appendHistory(record)
    }

    func appendCupHistoryForTesting(_ record: CupRecord) async {
        let result = await records.appendCup(record)
        records.applyCupAppend(record, result: result)
    }

    func setStartCheckpointForTesting(_ checkpoint: (@MainActor () async -> Void)?) {
        startCheckpointForTesting = checkpoint
    }

    var hasHostEventConsumerForTesting: Bool {
        hostEventsTask != nil
    }

    func setFinishMatchCheckpointForTesting(_ checkpoint: (@MainActor () async -> Void)?) {
        finishMatchCheckpointForTesting = checkpoint
    }

    func setFinishCupCheckpointForTesting(_ checkpoint: (@MainActor () async -> Void)?) {
        finishCupCheckpointForTesting = checkpoint
    }

    func setBotConnectCheckpointForTesting(_ checkpoint: (@MainActor () async -> Void)?) {
        botDirector.afterConnectForTesting = checkpoint
    }

    func setBotDrainFinishedForTesting(_ callback: (@MainActor (UUID) -> Void)?) {
        botDrainFinishedForTesting = callback
    }

    var botReconciliationIDForTesting: UUID? {
        botReconciliationOperation?.id
    }

    func finishCurrentMatchForTesting(_ outcome: GameOutcome) async {
        guard let currentMatchID else { return }
        await finishMatch(outcome, matchID: currentMatchID, lifecycleGeneration: lifecycleGeneration)
    }

    func isLiveParticipantForTesting(_ participant: GameParticipant) -> Bool {
        livePlayer(for: participant) != nil
    }

    func controlStatusForTesting(_ playerID: PlayerID) -> PartyControlStatus {
        controlStatus(for: playerID)
    }

    func currentGameControllerScreenForTesting(_ playerID: PlayerID) -> ControllerScreen? {
        currentSession?.controllerScreen(for: playerID)
    }

    var botInputFramesSentForTesting: UInt64 {
        bots.values.reduce(0) { $0 + $1.inputFramesSent }
    }

    var botParticipantCountForTesting: Int {
        currentParticipants.count { $0.player.kind == .bot }
    }

    var readyBotClientCountForTesting: Int {
        bots.values.count { $0.player?.kind == .bot }
    }

    var botInputFramesAppliedForTesting: UInt64 {
        let botIDs = Set(currentParticipants.filter { $0.player.kind == .bot }.map { $0.player.id })
        return host.inputs.activitySnapshot()
            .filter { botIDs.contains($0.playerID) }
            .reduce(0) { $0 + $1.acceptedFrameCount }
    }

    func updateBotDifficultyForTesting(
        outcome: GameOutcome,
        participants: [GameParticipant],
        gameID: String = "pong"
    ) {
        updateBotDifficulty(after: outcome, participants: participants, gameID: gameID)
    }

    func setBotDifficultyForTesting(_ difficulty: GameBotDifficulty, gameID: String = "pong") {
        botDirector.setDifficulty(difficulty, for: gameID)
    }

    private func applyFixture(scenario: String) {
        resetRuntime()
        let names = ["Ada", "Grace", "Katherine", "Bot 1"]
        let players = names.indices.map { index in
            let id = PlayerID(UInt8(index))
            return PlayerInfo(
                id: id,
                displayName: names[index],
                colorHex: PlayerPalette.color(for: id),
                kind: index == 3 ? .bot : .human
            )
        }
        let fixturePlayers = scenario == "empty-lobby" ? [] : players
        host.configureFixture(hostName: configuration.hostName ?? "UI Test PartyBox", players: fixturePlayers)
        fixturePlayers.forEach { turnOrder.joined($0.id) }
        captainID = fixturePlayers.first(where: { $0.kind == .human })?.id
        botFillTarget = fixturePlayers.contains(where: { $0.kind == .bot }) ? 1 : 0
        readyPlayerIDs = Set(fixturePlayers.filter { $0.kind == .human && $0.id != captainID }.prefix(1).map(\.id))
        let fixtureParticipants = fixturePlayers.map { player in
            GameParticipant(player: player, controllerID: ControllerID())
        }
        switch scenario {
        case "menu": phase = .gameMenu
        case "four-way-match", "signal-snap-match", "gravity-grab-match", "snake-pit-match", "last-light-match", "cup-final-match":
            let gameID = [
                "four-way-match": "pong",
                "signal-snap-match": "signal-snap",
                "gravity-grab-match": "gravity-grab",
                "snake-pit-match": "snake-pit",
                "last-light-match": "last-light",
                "cup-final-match": "gravity-grab",
            ][scenario]
            guard let gameID, let gameIndex = games.firstIndex(where: { $0.descriptor.id == gameID }) else {
                assertionFailure("Missing game for UI fixture \(scenario)")
                return
            }
            menuSelection = gameIndex
            currentParticipants = fixtureParticipants
            currentMatchID = UUID()
            let context = GameSessionContext(
                participants: currentParticipants, inputs: host.inputs,
                seed: configuration.seed ?? 42, modifierID: nil
            )
            currentSession = games[gameIndex].makeSession(context: context, onEvents: { _ in })
            currentScene = currentSession?.scene
            phase = .playing
            if scenario == "cup-final-match" {
                selectedCupGameIDs = ["pong", "signal-snap", "gravity-grab"]
                cupParticipants = fixtureParticipants
                cupEventIndex = selectedCupGameIDs.count - 1
                cupPoints = Dictionary(uniqueKeysWithValues: fixtureParticipants.map { ($0.controllerID, 0) })
                cupEventWins = Dictionary(uniqueKeysWithValues: fixtureParticipants.map { ($0.controllerID, 0) })
                currentMatchIsCup = true
            }
        case "cup-setup":
            selectedCupGameIDs = ["pong", "signal-snap"]
            cupSetupSelection = 2
            phase = .cupSetup
        case "cup-standings":
            selectedCupGameIDs = ["pong", "signal-snap", "gravity-grab"]
            cupParticipants = fixtureParticipants
            for (index, participant) in fixtureParticipants.enumerated() {
                cupPoints[participant.controllerID] = 8 - index
                cupEventWins[participant.controllerID] = index == 0 ? 1 : 0
            }
            phase = .cupStandings(.init(
                title: "EVENT 1 COMPLETE", subtitle: "Signal Snap complete",
                winner: fixturePlayers.first?.id,
                playerOutcomes: fixturePlayers.map {
                    .init(playerID: $0.id, outcome: $0.id == fixturePlayers.first?.id ? .won : .lost)
                },
                metrics: []
            ))
        case "cup-complete":
            menuSelection = menuLayout.cupMenuIndex
            botDifficultyChange = "BOT DIFFICULTY INCREASED TO HARD"
            let standings = fixtureParticipants.enumerated().map { index, participant in
                CupStandingRecord(
                    controllerID: participant.controllerID,
                    displayName: participant.player.displayName,
                    colorHex: participant.player.colorHex,
                    kind: participant.player.kind,
                    rank: index + 1,
                    points: 18 - (index * 3),
                    eventWins: index == 0 ? 2 : 0
                )
            }
            phase = .cupComplete(.init(
                endedAt: Date(),
                gameIDs: ["pong", "signal-snap", "gravity-grab"],
                matchRecordIDs: [],
                standings: standings
            ))
        case "game-over":
            botDifficultyChange = "BOT DIFFICULTY INCREASED TO HARD"
            phase = .gameOver(.init(
                title: "P1 ADA WINS", subtitle: "Select to play again", winner: PlayerID(0),
                playerOutcomes: fixturePlayers.map { .init(playerID: $0.id, outcome: $0.id == PlayerID(0) ? .won : .lost) },
                metrics: [.init(id: "paddle-hits", label: "Paddle hits", value: "27")]
            ))
        case "history": phase = .history
        default: phase = .lobby
        }
    }
#endif
}
