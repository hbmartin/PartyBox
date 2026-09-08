import Foundation
import Observation
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
    let id = UUID()
    let emoji: String
}

@MainActor
@Observable
final class HostCoordinator {
    let host = PartyHost()
    let configuration: HostLaunchConfiguration
    private(set) var phase: HostPhase = .lobby
    private(set) var turnOrder = TurnOrder()
    private(set) var statusMessage = "Starting local party…"
    private(set) var menuSelection = 0
    private(set) var currentScene: SKScene?
    private(set) var reactionBursts: [ReactionBurst] = []
    private(set) var voteTallies: [String: Int] = [:]
    private(set) var historyRecords: [MatchRecord] = []
    private(set) var historySelection = 0
    private(set) var confirmsHistoryClear = false

    @ObservationIgnored private let games: [any PartyGame]
    @ObservationIgnored private let sounds: ArcadeSoundPlayer?
    @ObservationIgnored private let historyStore: JSONRecordStore<MatchRecord>
    @ObservationIgnored private var currentSession: (any PartyGameSession)?
    @ObservationIgnored private var bots: [PartyClient] = []
    @ObservationIgnored private var hostEventsTask: Task<Void, Never>?
    @ObservationIgnored private var reactionTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var lifecycleGeneration = UUID()
    @ObservationIgnored private var currentParticipants: [GameParticipant] = []
    @ObservationIgnored private var eliminatedPlayers: Set<PlayerID> = []
    @ObservationIgnored private var votes: [PlayerID: String] = [:]
    @ObservationIgnored private var lastReactionAt: [PlayerID: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var currentMatchSeed: UInt64 = 1
    @ObservationIgnored private var matchStartedAt = Date()
    @ObservationIgnored private var appliedModifier: GameModifierDescriptor?
    @ObservationIgnored private var pendingModifier: GameModifierDescriptor?

    var menuItems: [String] { games.map { $0.descriptor.title } + ["HISTORY & LEADERBOARD"] }
    var menuDetails: [String] { games.map { $0.descriptor.summary } + ["All-time results and match details"] }
    var leaderboard: [LeaderboardEntry] { HistoryAggregation.leaderboard(historyRecords) }
    var connectedCount: Int { host.players.filter(\.isConnected).count }
    var canStart: Bool {
        if phase == .lobby { return connectedCount > 0 }
        guard games.indices.contains(menuSelection) else { return false }
        return connectedCount >= games[menuSelection].descriptor.minimumPlayers
    }

    init(configuration suppliedConfiguration: HostLaunchConfiguration? = nil, historyFileURL: URL? = nil) {
        let configuration = suppliedConfiguration ?? .current
        self.configuration = configuration
        games = [PongGame()]
        sounds = configuration.disableEffects ? nil : ArcadeSoundPlayer()
        let defaultURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PartyBox", isDirectory: true)
            .appendingPathComponent("history-v1.json")
        historyStore = JSONRecordStore(fileURL: configuration.isUITesting ? nil : (historyFileURL ?? defaultURL))
    }

    func start() async {
        guard !isStarted else { return }
        isStarted = true
        historyRecords = await historyStore.all().sorted { $0.endedAt > $1.endedAt }
        let generation = UUID()
        lifecycleGeneration = generation
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
            _ = try await host.start(hostName: name)
            statusMessage = "Ready for controllers"
            for index in 0..<configuration.botCount {
                let bot = PartyClient(displayName: "Bot \(index + 1)")
                bots.append(bot)
                if let port = host.port { await bot.connect(host: "127.0.0.1", port: port) }
            }
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

    func stop() async {
        isStarted = false
        lifecycleGeneration = UUID()
        hostEventsTask?.cancel()
        hostEventsTask = nil
        reactionTasks.values.forEach { $0.cancel() }
        reactionTasks.removeAll()
        let botsToStop = bots
        bots.removeAll()
        resetRuntime()
        await host.stop()
        for bot in botsToStop { await bot.stop() }
    }

    func perform(_ action: PartyBoxCore.MenuAction, source: HostInputSource = .local) {
        switch phase {
        case .lobby:
            if action == .select, canStart {
                phase = .gameMenu
                Task { await sendLayouts() }
            }
        case .gameMenu:
            switch action {
            case .up, .left:
                menuSelection = max(0, menuSelection - 1)
                Task { await sendLayouts() }
            case .down, .right:
                menuSelection = min(menuItems.count - 1, menuSelection + 1)
                Task { await sendLayouts() }
            case .select:
                if games.indices.contains(menuSelection) { startSelectedGame() }
                else {
                    phase = .history
                    Task { await sendLayouts() }
                }
            case .back:
                phase = .lobby
                Task { await sendLayouts() }
            }
        case .playing:
            break
        case .gameOver:
            switch action {
            case .select: startSelectedGame()
            case .back:
                pendingModifier = nil
                phase = .gameMenu
                Task { await sendLayouts() }
            default: break
            }
        case .history:
            switch action {
            case .up: historySelection = max(0, historySelection - 1)
            case .down: historySelection = min(max(0, historyRecords.count - 1), historySelection + 1)
            case .back:
                confirmsHistoryClear = false
                phase = .gameMenu
                Task { await sendLayouts() }
            default: break
            }
        }
    }

    func requestHistoryClear() { confirmsHistoryClear = true }
    func cancelHistoryClear() { confirmsHistoryClear = false }

    func confirmHistoryClear(source: HostInputSource = .local) async {
        guard source == .local, confirmsHistoryClear else { return }
        try? await historyStore.clear()
        historyRecords = []
        historySelection = 0
        confirmsHistoryClear = false
    }

    private func handle(_ event: HostEvent, generation: UUID) async {
        guard isStarted, lifecycleGeneration == generation else { return }
        switch event {
        case .rosterChanged(let roster):
            await broadcast(.roster(roster))
        case .playerJoined(let player):
            turnOrder.joined(player.id)
            statusMessage = "\(player.displayName) joined"
            await sendLayouts()
        case .playerReconnected(let player):
            statusMessage = "\(player.displayName) reconnected"
            await sendLayout(to: player.id)
        case .playerDisconnected(let player):
            statusMessage = "Waiting 15 seconds for \(player.displayName)…"
        case .playerExpired(let player):
            turnOrder.left(player.id)
            votes.removeValue(forKey: player.id)
            lastReactionAt.removeValue(forKey: player.id)
            if phase == .playing { currentSession?.forfeit(player.id) }
            statusMessage = host.players.isEmpty ? "Ready for controllers" : "\(player.displayName) left the party"
            await sendLayouts()
        case let .application(playerID, payload):
            guard let command = try? PartyBoxWireCodec.decode(ControllerCommand.self, from: payload) else { return }
            await handle(command, from: playerID)
        case .failure(let message):
            statusMessage = message
        }
    }

    private func handle(_ command: ControllerCommand, from playerID: PlayerID) async {
        switch command {
        case .menu(let action): perform(action, source: .controller(playerID))
        case .game(let envelope):
            guard phase == .playing,
                  games.indices.contains(menuSelection),
                  envelope.gameID == games[menuSelection].descriptor.id,
                  envelope.schemaVersion == ControllerScreen.schemaVersion,
                  currentParticipants.contains(where: { $0.player.id == playerID }),
                  !eliminatedPlayers.contains(playerID) else { return }
            currentSession?.handle(action: envelope.action, from: playerID)
        case .spectator(let action):
            guard isEligibleSpectator(playerID) else { return }
            switch action {
            case .reaction(let emoji): addReaction(emoji, from: playerID)
            case .vote(let modifierID):
                guard games.indices.contains(menuSelection),
                      games[menuSelection].descriptor.modifiers.contains(where: { $0.id == modifierID }) else { return }
                votes[playerID] = modifierID
                updateVoteTallies()
                await sendLayouts()
            }
        }
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
        currentParticipants = participants
        eliminatedPlayers = []
        votes = [:]
        voteTallies = [:]
        currentMatchSeed = configuration.seed ?? UInt64.random(in: 1...UInt64.max)
        matchStartedAt = Date()
        host.inputs.neutralize()
        let context = GameSessionContext(
            participants: participants, inputs: host.inputs, seed: currentMatchSeed, modifierID: modifier?.id
        )
        currentSession = game.makeSession(context: context) { [weak self] events in self?.handleGame(events) }
        currentScene = currentSession?.scene
        phase = .playing
        statusMessage = "Match in progress"
        Task { await sendLayouts() }
    }

    private func handleGame(_ events: [GameEvent]) {
        guard phase == .playing else { return }
        for event in events {
            switch event {
            case let .haptic(playerID, pattern):
                sounds?.play(pattern)
                Task { await send(.haptic(pattern), to: playerID) }
            case .eliminated(let playerID):
                eliminatedPlayers.insert(playerID)
                Task { await sendLayouts() }
            case .completed(let outcome):
                Task { await finishMatch(outcome) }
            }
        }
    }

    private func finishMatch(_ outcome: GameOutcome) async {
        guard phase == .playing, games.indices.contains(menuSelection) else { return }
        let game = games[menuSelection]
        pendingModifier = resolveVote(in: game.descriptor)
        let endedAt = Date()
        let participantRecords = currentParticipants.map { participant in
            let value = outcome.playerOutcomes.first { $0.playerID == participant.player.id }?.outcome ?? .lost
            return MatchParticipant(
                controllerID: participant.controllerID,
                displayName: host.players.first(where: { $0.id == participant.player.id })?.displayName ?? participant.player.displayName,
                colorHex: participant.player.colorHex,
                outcome: value
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
        if (try? await historyStore.append(record)) == true { historyRecords.insert(record, at: 0) }
        for participant in currentParticipants where host.players.contains(where: { $0.id == participant.player.id && $0.isConnected }) {
            await send(.matchCompleted(PersonalMatchRecord(record: record, controllerID: participant.controllerID)), to: participant.player.id)
        }
        turnOrder.rotateAfterMatch(active: currentParticipants.map { $0.player.id }, winner: outcome.winner)
        currentSession = nil
        currentScene = nil
        appliedModifier = nil
        phase = .gameOver(outcome)
        await sendLayouts()
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
        return !currentParticipants.contains(where: { $0.player.id == playerID }) || eliminatedPlayers.contains(playerID)
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

    private func layout(for playerID: PlayerID) -> PartyBoxCore.ControllerLayout {
        switch phase {
        case .lobby: return .lobby
        case .gameMenu: return .menu(.init(items: menuItems, details: menuDetails, selected: menuSelection))
        case .history: return .historyNavigation
        case .gameOver(let outcome):
            return .gameOver(.init(title: outcome.title, subtitle: outcome.subtitle, nextModifier: pendingModifier?.title))
        case .playing:
            guard games.indices.contains(menuSelection) else { return .lobby }
            let game = games[menuSelection]
            let active = currentParticipants.map { $0.player.id }
            let screen: ControllerScreen
            if active.contains(playerID), !eliminatedPlayers.contains(playerID) {
                screen = currentSession?.controllerScreen(for: playerID) ?? SpectatorScreenFactory.make(
                    game: game.descriptor,
                    state: .init(role: .active, choices: [], tallies: [:], selection: nil)
                )
            } else {
                let role: PlayerRole = eliminatedPlayers.contains(playerID)
                    ? .eliminated
                    : .waiting(position: turnOrder.waitingPosition(of: playerID, active: active) ?? 1)
                screen = SpectatorScreenFactory.make(
                    game: game.descriptor,
                    state: .init(role: role, choices: game.descriptor.modifiers, tallies: voteTallies, selection: votes[playerID])
                )
            }
            guard let payload = try? PartyBoxWireCodec.encode(screen) else { return .lobby }
            return .game(.init(gameID: game.descriptor.id, payload: payload))
        }
    }

    private func sendLayouts() async {
        let pending = host.players.filter(\.isConnected).map { ($0.id, layout(for: $0.id)) }
        await withTaskGroup(of: Void.self) { group in
            for (playerID, layout) in pending {
                group.addTask { [host] in
                    guard let payload = try? PartyBoxWireCodec.encode(HostPresentation.layout(layout)) else { return }
                    _ = await host.sendApplication(payload, to: playerID)
                }
            }
        }
    }

    private func sendLayout(to playerID: PlayerID) async { await send(.layout(layout(for: playerID)), to: playerID) }

    private func send(_ presentation: HostPresentation, to playerID: PlayerID) async {
        guard let payload = try? PartyBoxWireCodec.encode(presentation) else { return }
        _ = await host.sendApplication(payload, to: playerID)
    }

    private func broadcast(_ presentation: HostPresentation) async {
        guard let payload = try? PartyBoxWireCodec.encode(presentation) else { return }
        await withTaskGroup(of: Void.self) { group in
            for player in host.players where player.isConnected {
                group.addTask { [host] in _ = await host.sendApplication(payload, to: player.id) }
            }
        }
    }

    private func recoverFromHostEventStreamEnding(generation: UUID, cancelConsumer: Bool) async {
        guard isStarted, lifecycleGeneration == generation else { return }
        isStarted = false
        let recoveryGeneration = UUID()
        lifecycleGeneration = recoveryGeneration
        let consumer = hostEventsTask
        hostEventsTask = nil
        if cancelConsumer { consumer?.cancel() }
        let botsToStop = bots
        bots.removeAll()
        resetRuntime()
        statusMessage = "Restarting after a host event overload…"
        await host.stop()
        for bot in botsToStop { await bot.stop() }
        guard !isStarted, lifecycleGeneration == recoveryGeneration else { return }
        await start()
    }

    private func resetRuntime() {
        phase = .lobby
        turnOrder = TurnOrder()
        currentSession = nil
        currentScene = nil
        statusMessage = "Starting local party…"
        menuSelection = 0
        currentParticipants = []
        eliminatedPlayers = []
        votes = [:]
        voteTallies = [:]
        pendingModifier = nil
        appliedModifier = nil
        reactionBursts = []
        confirmsHistoryClear = false
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

    private func applyFixture(scenario: String) {
        resetRuntime()
        let names = ["Ada", "Grace", "Katherine", "Margaret"]
        let players = names.indices.map { index in
            let id = PlayerID(UInt8(index))
            return PlayerInfo(id: id, displayName: names[index], colorHex: PlayerPalette.color(for: id))
        }
        let fixturePlayers = scenario == "empty-lobby" ? [] : players
        host.configureFixture(hostName: configuration.hostName ?? "UI Test PartyBox", players: fixturePlayers)
        fixturePlayers.forEach { turnOrder.joined($0.id) }
        switch scenario {
        case "menu": phase = .gameMenu
        case "four-way-match":
            currentParticipants = fixturePlayers.map { player in
                GameParticipant(player: player, controllerID: ControllerID())
            }
            let context = GameSessionContext(
                participants: currentParticipants, inputs: host.inputs,
                seed: configuration.seed ?? 42, modifierID: nil
            )
            currentSession = games[0].makeSession(context: context, onEvents: { _ in })
            currentScene = currentSession?.scene
            phase = .playing
        case "game-over":
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
