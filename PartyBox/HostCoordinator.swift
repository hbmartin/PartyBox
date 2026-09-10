import Foundation
import Observation
import OSLog
import PartyBoxCore
import PartyGameRuntime
import PartyNet
import SpriteKit

enum HostPhase: Equatable {
    case lobby
    case gameMenu
    case playing
    case gameOver(GameOutcome)
    case history
}

enum HostInputSource: Equatable {
    case local
    case controller(PlayerID)
}

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
    let host: PartyHost
    let configuration: HostLaunchConfiguration
    private(set) var phase: HostPhase = .lobby
    private(set) var turnOrder = TurnOrder()
    private(set) var statusMessage = "Starting local party…"
    private(set) var menuSelection = 0
    private(set) var currentScene: SKScene?
    private(set) var reactionBursts: [ReactionBurst] = []
    private(set) var voteTallies: [String: Int] = [:]
    private(set) var historyRecords: [MatchRecord] = []
    private(set) var historyPersistenceError: String?
    private(set) var historySelection = 0
    private(set) var confirmsHistoryClear = false
    private(set) var captainID: PlayerID?
    private(set) var readyPlayerIDs: Set<PlayerID> = []
    private(set) var botFillTarget = 0
    private(set) var botDifficultyChange: String?

    @ObservationIgnored private let games: [any PartyGame]
    @ObservationIgnored private var sounds: ArcadeSoundPlayer?
    @ObservationIgnored private let historyStore: JSONRecordStore<MatchRecord>
    @ObservationIgnored private let logger = Logger(subsystem: "PartyBox", category: "HostCoordinator")
    @ObservationIgnored private var currentSession: (any PartyGameSession)?
    @ObservationIgnored private var bots: [ControllerID: PartyClient] = [:]
    @ObservationIgnored private var hostEventsTask: Task<Void, Never>?
    @ObservationIgnored private var botInputTask: Task<Void, Never>?
    @ObservationIgnored private var botReconciliationTask: Task<Void, Never>?
    @ObservationIgnored private var soundPreparationTask: Task<Void, Never>?
    @ObservationIgnored private var botsNeedReconciliation = false
    @ObservationIgnored private var nextBotNumber = 1
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
    @ObservationIgnored private var lastDirectionAt: [PlayerID: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var lastDecisionAt: [PlayerID: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var humanConnectionOrder: [ControllerID] = []
    @ObservationIgnored private var connectedHumanControllers: Set<ControllerID> = []
    @ObservationIgnored private var difficultyByGameID: [String: GameBotDifficulty] = [:]
    @ObservationIgnored private var currentMatchSeed: UInt64 = 1
    @ObservationIgnored private var matchStartedAt = Date()
    @ObservationIgnored private var appliedModifier: GameModifierDescriptor?
    @ObservationIgnored private var pendingModifier: GameModifierDescriptor?
#if DEBUG
    @ObservationIgnored private var startCheckpointForTesting: (@MainActor () async -> Void)?
    @ObservationIgnored private var finishMatchCheckpointForTesting: (@MainActor () async -> Void)?
#endif

    var menuItems: [String] { games.map { $0.descriptor.title } + ["HISTORY & LEADERBOARD"] }
    var menuDetails: [String] { games.map { $0.descriptor.summary } + ["All-time results and match details"] }
    var leaderboard: [LeaderboardEntry] { HistoryAggregation.leaderboard(historyRecords) }
    var displayedVoteTallies: [VoteTallyPresentation] {
        let modifiers = games.indices.contains(menuSelection) ? games[menuSelection].descriptor.modifiers : []
        return voteTallies.keys.sorted().map { modifierID in
            VoteTallyPresentation(
                id: modifierID,
                title: modifiers.first(where: { $0.id == modifierID })?.title ?? modifierID,
                count: voteTallies[modifierID, default: 0]
            )
        }
    }
    var connectedCount: Int { host.players.filter(\.isConnected).count }
    var connectedHumanCount: Int {
        host.players.filter { $0.isConnected && $0.kind == .human }.count
    }
    var activeBotCount: Int {
        host.players.filter { $0.isConnected && $0.kind == .bot }.count
    }
    var currentBotDifficulty: GameBotDifficulty {
        guard games.indices.contains(menuSelection) else { return .normal }
        return difficultyByGameID[games[menuSelection].descriptor.id] ?? .normal
    }
    var requiredReadyCount: Int {
        connectedHumanCount == 0 ? 0 : (connectedHumanCount / 2) + 1
    }
    var readyCount: Int {
        let connected = Set(host.players.filter { $0.isConnected && $0.kind == .human }.map(\.id))
        let captainVote = captainID.map { connected.contains($0) } == true ? 1 : 0
        return captainVote + readyPlayerIDs.intersection(connected).count
    }
    var canStart: Bool {
        if phase == .lobby { return connectedCount > 0 }
        guard games.indices.contains(menuSelection) else { return false }
        return connectedCount >= games[menuSelection].descriptor.minimumPlayers
    }

    init(
        configuration suppliedConfiguration: HostLaunchConfiguration? = nil,
        historyFileURL: URL? = nil,
        host suppliedHost: PartyHost? = nil
    ) {
        let configuration = suppliedConfiguration ?? .current
        self.configuration = configuration
        host = suppliedHost ?? PartyHost()
        games = [PongGame()]
        sounds = nil
        let defaultURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PartyBox", isDirectory: true)
            .appendingPathComponent("history-v1.json")
        historyStore = JSONRecordStore(fileURL: configuration.isUITesting ? nil : (historyFileURL ?? defaultURL))
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
        let storedHistory = await historyStore.all().sorted { $0.endedAt > $1.endedAt }
        guard isStarted, lifecycleGeneration == generation else { return }
        historyRecords = storedHistory
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
        if configuration.botCount > 0 {
            return min(configuration.botCount, max(0, PartyNetConstants.maximumControllers - connectedHumanCount))
        }
        return min(
            botFillTarget,
            max(0, PartyBoxRuntimeLimits.releasePartySize - connectedHumanCount)
        )
    }

    private func requestBotReconciliation() {
        botsNeedReconciliation = true
        guard isStarted, phase != .playing, host.port != nil, botReconciliationTask == nil else { return }
        let generation = lifecycleGeneration
        botReconciliationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainBotReconciliation(generation: generation)
        }
    }

    private func drainBotReconciliation(generation: UUID) async {
        defer {
            botReconciliationTask = nil
            if botsNeedReconciliation, phase != .playing { requestBotReconciliation() }
        }
        while botsNeedReconciliation,
              isStarted,
              lifecycleGeneration == generation,
              phase != .playing,
              let port = host.port {
            botsNeedReconciliation = false
            let desired = desiredBotCount

            while bots.count > desired,
                  isStarted,
                  lifecycleGeneration == generation,
                  phase != .playing,
                  let entry = bots.sorted(by: {
                      $0.value.displayName.localizedStandardCompare($1.value.displayName) == .orderedDescending
                  }).first {
                bots.removeValue(forKey: entry.key)
                await entry.value.stop()
                host.unregisterLocalBot(controllerID: entry.key)
            }

            while bots.count < desired,
                  isStarted,
                  lifecycleGeneration == generation,
                  phase != .playing {
                let controllerID = ControllerID()
                let number = nextBotNumber
                nextBotNumber += 1
                let preferred = PlayerMark.allCases[(number - 1) % PlayerMark.allCases.count]
                let bot = PartyClient(
                    controllerID: controllerID,
                    displayName: "Bot \(number)",
                    preferredMark: preferred,
                    inputSendInterval: .seconds(1.0 / 60.0)
                )
                host.registerLocalBot(controllerID: controllerID)
                bots[controllerID] = bot
                await bot.connect(host: "127.0.0.1", port: port)
                guard isStarted, lifecycleGeneration == generation else {
                    bots.removeValue(forKey: controllerID)
                    await bot.stop()
                    host.unregisterLocalBot(controllerID: controllerID)
                    return
                }
                guard bot.player != nil else {
                    bots.removeValue(forKey: controllerID)
                    await bot.stop()
                    host.unregisterLocalBot(controllerID: controllerID)
                    statusMessage = "A bot could not join"
                    break
                }
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
        let difficulty = currentBotDifficulty
        for bot in bots.values {
            guard let player = bot.player,
                  player.kind == .bot,
                  currentParticipants.contains(where: { $0.player.id == player.id }),
                  let input = currentSession.botInput(
                      for: player.id,
                      difficulty: difficulty,
                      deltaTime: .seconds(deltaTime)
                  ) else { continue }
            bot.setInput(axisX: input.axisX, axisY: input.axisY, buttons: input.buttons)
        }
    }

    func stop() async {
        isStarted = false
        lifecycleGeneration = UUID()
        hostEventsTask?.cancel()
        hostEventsTask = nil
        let botsToStop = prepareRuntimeForShutdown()
        await host.stop()
        for bot in botsToStop { await bot.stop() }
    }

    func perform(
        _ action: PartyBoxCore.MenuAction,
        source: HostInputSource = .local,
        now suppliedNow: ContinuousClock.Instant? = nil
    ) {
        guard accepts(action, from: source, now: suppliedNow) else { return }
        switch phase {
        case .lobby:
            if action == .select, canStart {
                transition(to: .gameMenu)
            }
        case .gameMenu:
            switch action {
            case .up, .left:
                setMenuSelection(max(0, menuSelection - 1))
            case .down, .right:
                setMenuSelection(min(menuItems.count - 1, menuSelection + 1))
            case .select:
                if games.indices.contains(menuSelection) {
                    if isCaptainControl(source) {
                        startSelectedGame()
                    } else if case let .controller(playerID) = source {
                        toggleReadiness(for: playerID)
                    }
                }
                else {
                    transition(to: .history)
                }
            case .back:
                transition(to: .lobby)
            }
        case .playing:
            break
        case .gameOver:
            switch action {
            case .select:
                if isCaptainControl(source) {
                    startSelectedGame()
                } else if case let .controller(playerID) = source {
                    toggleReadiness(for: playerID)
                }
            case .back:
                pendingModifier = nil
                transition(to: .gameMenu)
            default: break
            }
        case .history:
            switch action {
            case .up: historySelection = max(0, historySelection - 1)
            case .down: historySelection = min(max(0, historyRecords.count - 1), historySelection + 1)
            case .back:
                confirmsHistoryClear = false
                transition(to: .gameMenu)
            default: break
            }
        }
    }

    private func accepts(
        _ action: PartyBoxCore.MenuAction,
        from source: HostInputSource,
        now suppliedNow: ContinuousClock.Instant?
    ) -> Bool {
        guard case let .controller(playerID) = source else { return true }
        guard let player = host.players.first(where: {
            $0.id == playerID && $0.isConnected && $0.kind == .human
        }) else { return false }

        let isAuthorized: Bool
        if action == .select {
            switch phase {
            case .gameMenu:
                isAuthorized = games.indices.contains(menuSelection) || player.id == captainID
            case .gameOver:
                isAuthorized = true
            case .lobby, .history:
                isAuthorized = player.id == captainID
            case .playing:
                isAuthorized = false
            }
        } else {
            isAuthorized = player.id == captainID
        }
        guard isAuthorized else { return false }

        let now = suppliedNow ?? ContinuousClock().now
        let isDecision = action == .select || action == .back
        let previous = isDecision ? lastDecisionAt[player.id] : lastDirectionAt[player.id]
        let cooldown: Duration = isDecision ? .milliseconds(750) : .milliseconds(150)
        guard previous.map({ $0.duration(to: now) >= cooldown }) ?? true else { return false }
        if isDecision { lastDecisionAt[player.id] = now }
        else { lastDirectionAt[player.id] = now }
        return true
    }

    private func isCaptainControl(_ source: HostInputSource) -> Bool {
        if source == .local { return true }
        if case let .controller(playerID) = source { return playerID == captainID }
        return false
    }

    private func setMenuSelection(_ selection: Int) {
        guard selection != menuSelection else { return }
        menuSelection = selection
        clearReadiness()
        botDifficultyChange = nil
        requestLayoutBroadcast()
    }

    private func transition(to newPhase: HostPhase) {
        guard phase != newPhase else { return }
        phase = newPhase
        clearReadiness()
        requestLayoutBroadcast()
        requestBotReconciliation()
    }

    private func toggleReadiness(for playerID: PlayerID) {
        guard canStart, playerID != captainID,
              host.players.contains(where: {
                  $0.id == playerID && $0.isConnected && $0.kind == .human
              }) else { return }
        if readyPlayerIDs.remove(playerID) == nil { readyPlayerIDs.insert(playerID) }
        requestLayoutBroadcast()
        if readyCount >= requiredReadyCount { startSelectedGame() }
    }

    private func clearReadiness() {
        guard !readyPlayerIDs.isEmpty else { return }
        readyPlayerIDs.removeAll()
    }

    func requestHistoryClear() { confirmsHistoryClear = true }
    func cancelHistoryClear() { confirmsHistoryClear = false }

    func confirmHistoryClear(source: HostInputSource = .local) async {
        guard source == .local, confirmsHistoryClear else { return }
        do {
            try await historyStore.clear()
            historyRecords = []
            historySelection = 0
            historyPersistenceError = nil
        } catch {
            historyPersistenceError = "History could not be cleared: \(error.localizedDescription)"
        }
        confirmsHistoryClear = false
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
                if !humanConnectionOrder.contains(controllerID) { humanConnectionOrder.append(controllerID) }
                if captainID == nil { captainID = player.id }
            }
            statusMessage = player.kind == .bot
                ? "\(player.displayName) is ready"
                : "\(player.displayName) joined"
            requestLayoutBroadcast()
        case .playerReconnected(let player):
            statusMessage = "\(player.displayName) reconnected"
            requestLayoutBroadcast()
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
            lastDirectionAt.removeValue(forKey: player.id)
            lastDecisionAt.removeValue(forKey: player.id)
            humanConnectionOrder.removeAll { $0 == controllerID }
            if player.kind == .bot, let bot = bots.removeValue(forKey: controllerID) {
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
            guard phase == .lobby,
                  let player = host.players.first(where: {
                      $0.id == playerID && $0.isConnected && $0.kind == .human
                  }) else { return }
            switch action {
            case .selectMark(let mark):
                if host.assignMark(mark, to: player.id) {
                    clearReadiness()
                    requestLayoutBroadcast()
                }
            case .setBotFillTarget(let target):
                guard player.id == captainID, configuration.botCount == 0 else { return }
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
            guard phase == .playing,
                  games.indices.contains(menuSelection),
                  envelope.gameID == games[menuSelection].descriptor.id,
                  envelope.schemaVersion == ControllerScreen.schemaVersion,
                  let participant = currentParticipant(for: playerID),
                  !eliminatedControllers.contains(participant.controllerID) else { return }
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
        guard connected != connectedHumanControllers else { return }
        connectedHumanControllers = connected
        clearReadiness()
    }

    private func promoteCaptain() {
        let connectedByController = Dictionary(uniqueKeysWithValues: host.players.compactMap {
            player -> (ControllerID, PlayerID)? in
            guard player.isConnected, player.kind == .human,
                  let controllerID = host.controllerID(for: player.id) else { return nil }
            return (controllerID, player.id)
        })
        let promoted = humanConnectionOrder.lazy.compactMap { connectedByController[$0] }.first
        guard promoted != captainID else { return }
        captainID = promoted
        clearReadiness()
        if let promoted,
           let player = host.players.first(where: { $0.id == promoted }) {
            statusMessage = "\(player.displayName) is now party captain"
        }
        requestLayoutBroadcast()
    }

    private func startSelectedGame() {
        guard phase != .playing, games.indices.contains(menuSelection) else { return }
        let game = games[menuSelection]
        let connected = Set(host.players.filter(\.isConnected).map(\.id))
        let ids = turnOrder.participants(connected: connected, maximum: game.descriptor.maximumPlayers)
        guard ids.count >= game.descriptor.minimumPlayers else { return }
        let participants = ids.compactMap { id -> GameParticipant? in
            guard let player = host.players.first(where: { $0.id == id }),
                  let controllerID = host.controllerID(for: id) else { return nil }
            return GameParticipant(player: player, controllerID: controllerID)
        }
        guard participants.count == ids.count else { return }
        let modifier = pendingModifier
        pendingModifier = nil
        appliedModifier = modifier
        botDifficultyChange = nil
        clearReadiness()
        currentParticipants = participants
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
            participants: participants, inputs: host.inputs, seed: currentMatchSeed, modifierID: modifier?.id
        )
        currentSession = game.makeSession(context: context) { [weak self] events in
            self?.handleGame(events, matchID: matchID)
        }
        currentScene = currentSession?.scene
        phase = .playing
        statusMessage = "Match in progress"
        requestLayoutBroadcast()
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
        for event in events {
            switch event {
            case .audio(let cue):
                sounds?.play(cue)
            case let .haptic(playerID, pattern):
                haptics.append((playerID, pattern))
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
        pendingModifier = resolveVote(in: game.descriptor)
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
        let historyResult = await historyStore.append(record)
#if DEBUG
        if let checkpoint = finishMatchCheckpointForTesting { await checkpoint() }
#endif
        guard isCurrentMatch(matchID, lifecycleGeneration: lifecycleGeneration) else { return }
        applyHistoryAppend(record, result: historyResult)
        for participant in participants {
            guard isCurrentMatch(matchID, lifecycleGeneration: lifecycleGeneration) else { return }
            guard livePlayer(for: participant)?.isConnected == true else { continue }
            await send(.matchCompleted(PersonalMatchRecord(record: record, controllerID: participant.controllerID)), to: participant.player.id)
        }
        guard isCurrentMatch(matchID, lifecycleGeneration: lifecycleGeneration) else { return }
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
        phase = .gameOver(outcome)
        clearReadiness()
        requestLayoutBroadcast()
        requestBotReconciliation()
    }

    private func updateBotDifficulty(
        after outcome: GameOutcome,
        participants: [GameParticipant],
        gameID: String
    ) {
        let hasHuman = participants.contains { $0.player.kind == .human }
        let hasBot = participants.contains { $0.player.kind == .bot }
        guard hasHuman, hasBot, let winner = outcome.winner,
              let winnerKind = participants.first(where: { $0.player.id == winner })?.player.kind else {
            botDifficultyChange = nil
            return
        }
        let previous = difficultyByGameID[gameID] ?? .normal
        let updated = winnerKind == .human ? previous.harder : previous.easier
        guard updated != previous else {
            botDifficultyChange = nil
            return
        }
        difficultyByGameID[gameID] = updated
        let direction = updated.rawValue > previous.rawValue ? "increased" : "reduced"
        botDifficultyChange = "BOT DIFFICULTY \(direction.uppercased()) TO \(updated.title.uppercased())"
        statusMessage = botDifficultyChange ?? statusMessage
    }

    private func isCurrentMatch(_ matchID: UUID, lifecycleGeneration: UUID) -> Bool {
        isStarted && self.lifecycleGeneration == lifecycleGeneration
            && currentMatchID == matchID && phase == .playing
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

    private func resolveVote(in descriptor: GameDescriptor) -> GameModifierDescriptor? {
        guard !votes.isEmpty else { return nil }
        let counts = Dictionary(grouping: votes.values, by: { $0 }).mapValues(\.count)
        guard let maximum = counts.values.max() else { return nil }
        let tied = descriptor.modifiers.filter { counts[$0.id] == maximum }
        guard !tied.isEmpty else { return nil }
        return tied[Int(currentMatchSeed % UInt64(tied.count))]
    }

    private func isEligibleSpectator(_ playerID: PlayerID) -> Bool {
        guard phase == .playing, host.players.contains(where: { $0.id == playerID && $0.isConnected }) else { return false }
        guard let participant = currentParticipant(for: playerID) else { return true }
        return eliminatedControllers.contains(participant.controllerID)
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
              games[menuSelection].descriptor.modifiers.contains(where: { $0.id == modifierID }),
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
        let result = await historyStore.append(record)
        applyHistoryAppend(record, result: result)
    }

    private func applyHistoryAppend(_ record: MatchRecord, result: JSONRecordAppendResult) {
        guard result.wasInserted else { return }
        if !historyRecords.contains(where: { $0.id == record.id }) {
            historyRecords.insert(record, at: 0)
        }
        if let error = result.persistenceErrorDescription {
            historyPersistenceError = "This match is available for this session but could not be saved: \(error)"
        } else {
            historyPersistenceError = nil
        }
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
        case .history: return .historyNavigation
        case .gameOver(let outcome):
            return .gameOver(.init(
                title: outcome.title,
                subtitle: outcome.subtitle,
                nextModifier: pendingModifier?.title,
                control: controlStatus(for: playerID),
                botDifficultyChange: botDifficultyChange
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
                    state: .init(role: role, choices: game.descriptor.modifiers, tallies: voteTallies, selection: votes[playerID])
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
            requiredReadyCount: requiredReadyCount
        )
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
        for bot in botsToStop { await bot.stop() }
        guard !isStarted, lifecycleGeneration == recoveryGeneration else { return }
        await start(preservingHostInstanceID: preservedHostInstanceID)
    }

    private func prepareRuntimeForShutdown() -> [PartyClient] {
        botInputTask?.cancel()
        botInputTask = nil
        botReconciliationTask?.cancel()
        botReconciliationTask = nil
        soundPreparationTask?.cancel()
        soundPreparationTask = nil
        sounds?.shutdown()
        sounds = nil
        let botsToStop = Array(bots.values)
        bots.removeAll()
        resetRuntime()
        return botsToStop
    }

    private func resetRuntime() {
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
        phase = .lobby
        turnOrder = TurnOrder()
        currentSession = nil
        currentScene = nil
        currentMatchID = nil
        statusMessage = "Starting local party…"
        menuSelection = 0
        currentParticipants = []
        captainID = nil
        readyPlayerIDs = []
        humanConnectionOrder = []
        connectedHumanControllers = []
        lastDirectionAt = [:]
        lastDecisionAt = [:]
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

    func setStartCheckpointForTesting(_ checkpoint: (@MainActor () async -> Void)?) {
        startCheckpointForTesting = checkpoint
    }

    var hasHostEventConsumerForTesting: Bool {
        hostEventsTask != nil
    }

    func setFinishMatchCheckpointForTesting(_ checkpoint: (@MainActor () async -> Void)?) {
        finishMatchCheckpointForTesting = checkpoint
    }

    func finishCurrentMatchForTesting(_ outcome: GameOutcome) async {
        guard let currentMatchID else { return }
        await finishMatch(outcome, matchID: currentMatchID, lifecycleGeneration: lifecycleGeneration)
    }

    func isLiveParticipantForTesting(_ participant: GameParticipant) -> Bool {
        livePlayer(for: participant) != nil
    }

    var botInputFramesSentForTesting: UInt64 {
        bots.values.reduce(0) { $0 + $1.inputFramesSent }
    }

    func updateBotDifficultyForTesting(
        outcome: GameOutcome,
        participants: [GameParticipant],
        gameID: String = "pong"
    ) {
        updateBotDifficulty(after: outcome, participants: participants, gameID: gameID)
    }

    func setBotDifficultyForTesting(_ difficulty: GameBotDifficulty, gameID: String = "pong") {
        difficultyByGameID[gameID] = difficulty
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
        switch scenario {
        case "menu": phase = .gameMenu
        case "four-way-match":
            currentParticipants = fixturePlayers.map { player in
                GameParticipant(player: player, controllerID: ControllerID())
            }
            currentMatchID = UUID()
            let context = GameSessionContext(
                participants: currentParticipants, inputs: host.inputs,
                seed: configuration.seed ?? 42, modifierID: nil
            )
            currentSession = games[0].makeSession(context: context, onEvents: { _ in })
            currentScene = currentSession?.scene
            phase = .playing
        case "game-over":
            botDifficultyChange = "BOT DIFFICULTY INCREASED TO HARD"
            phase = .gameOver(.init(
                title: "P1 ADA WINS", subtitle: "Winner stays  •  Select for the next match", winner: PlayerID(0),
                playerOutcomes: fixturePlayers.map { .init(playerID: $0.id, outcome: $0.id == PlayerID(0) ? .won : .lost) },
                metrics: [.init(id: "paddle-hits", label: "Paddle hits", value: "27")]
            ))
        case "history": phase = .history
        default: phase = .lobby
        }
    }
#endif
}
