import Foundation
import Observation
import PartyNet

enum HostPhase: Equatable {
    case lobby
    case gameMenu
    case playing
    case gameOver(GameResult)
}

struct GameResult: Equatable {
    let title: String
    let subtitle: String
    let winner: PlayerID?
}

@MainActor
@Observable
final class HostCoordinator {
    let host = PartyHost()
    let configuration: HostLaunchConfiguration
    private(set) var phase: HostPhase = .lobby
    private(set) var seatQueue = SeatQueue()
    private(set) var pongScene: PongScene?
    private(set) var statusMessage = "Starting local party…"
    private(set) var menuSelection = 0

    let menuItems = ["FOUR-WAY PONG"]
    private let sounds: ArcadeSoundPlayer?
    private var bots: [PartyClient] = []
    private var hostEventsTask: Task<Void, Never>?
    private var isStarted = false
    private var lifecycleGeneration = UUID()
    private var currentMatchPlayerCount = 0
    private var currentMatchAssignments: [SeatAssignment] = []

    var connectedCount: Int { host.players.filter(\.isConnected).count }
    var canStart: Bool {
        !seatQueue.active.isEmpty && seatQueue.active.allSatisfy { id in
            host.players.contains { $0.id == id && $0.isConnected }
        }
    }

    init(configuration suppliedConfiguration: HostLaunchConfiguration? = nil) {
        let configuration = suppliedConfiguration ?? .current
        self.configuration = configuration
        sounds = configuration.disableEffects ? nil : ArcadeSoundPlayer()
#if DEBUG
        if let scenario = configuration.scenario {
            applyFixture(scenario: scenario)
        }
#endif
    }

    func start() async {
        guard !isStarted else { return }
        isStarted = true
        let generation = UUID()
        lifecycleGeneration = generation
        if configuration.scenario != nil {
#if DEBUG
            if let scenario = configuration.scenario { applyFixture(scenario: scenario) }
#endif
            statusMessage = "UI test fixture"
            return
        }
        let stream = host.events
        hostEventsTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event, generation: generation)
            }
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
            guard isStarted, lifecycleGeneration == generation else { return }
            statusMessage = "Ready for controllers"
            for index in 0..<configuration.botCount {
                guard isStarted, lifecycleGeneration == generation else { return }
                let bot = PartyClient(displayName: "Bot \(index + 1)")
                bots.append(bot)
                if let port = host.port { await bot.connect(host: "127.0.0.1", port: port) }
            }
        } catch {
            guard lifecycleGeneration == generation else { return }
            hostEventsTask?.cancel()
            hostEventsTask = nil
            await host.stop()
            isStarted = false
            if !Task.isCancelled {
                statusMessage = "Could not start: \(error.localizedDescription)"
            }
        }
    }

    func stop() async {
        isStarted = false
        lifecycleGeneration = UUID()
        hostEventsTask?.cancel()
        hostEventsTask = nil
        let botsToStop = bots
        bots.removeAll()
        phase = .lobby
        seatQueue = SeatQueue()
        pongScene = nil
        statusMessage = "Starting local party…"
        menuSelection = 0
        currentMatchPlayerCount = 0
        currentMatchAssignments = []
        await host.stop()
        for bot in botsToStop { await bot.stop() }
    }

    func perform(_ action: MenuAction) {
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
                startPong()
            case .back:
                phase = .lobby
                Task { await sendLayouts() }
            }
        case .playing:
            // A running match cannot be exited early in v1.
            break
        case .gameOver:
            switch action {
            case .select:
                startPong()
            case .back:
                phase = .gameMenu
                Task { await sendLayouts() }
            default:
                break
            }
        }
    }

    private func handle(_ event: HostEvent, generation: UUID) async {
        guard isStarted, lifecycleGeneration == generation else { return }
        switch event {
        case let .playerJoined(player):
            seatQueue.joined(player.id, allowActive: phase != .playing)
            statusMessage = "\(player.displayName) joined"
            await sendLayouts()
        case let .playerReconnected(player):
            statusMessage = "\(player.displayName) reconnected"
            await sendLayout(to: player.id)
        case let .playerDisconnected(player):
            statusMessage = "Waiting 15 seconds for \(player.displayName)…"
        case let .playerExpired(player):
            if phase == .playing {
                seatQueue.left(player.id, fillVacancy: false)
                currentMatchAssignments.removeAll { $0.playerID == player.id }
                pongScene?.forfeit(player.id)
            } else {
                seatQueue.left(player.id)
            }
            statusMessage = host.players.isEmpty
                ? "Ready for controllers"
                : "\(player.displayName) left the party"
            await sendLayouts()
        case let .menu(_, action):
            perform(action)
        case let .failure(message):
            statusMessage = message
        }
    }

    private func startPong() {
        guard phase != .playing, canStart else { return }
        let assignments = seatQueue.assignments
        currentMatchAssignments = assignments
        currentMatchPlayerCount = assignments.count
        host.inputs.neutralize()
        let scene = PongScene(
            assignments: assignments,
            players: host.players,
            inputs: host.inputs,
            seed: configuration.seed ?? UInt64.random(in: UInt64.min...UInt64.max)
        ) { [weak self] events in
            Task { @MainActor [weak self] in self?.handlePong(events) }
        }
        pongScene = scene
        phase = .playing
        statusMessage = "Match in progress"
        Task { await sendLayouts() }
    }

    private func handlePong(_ events: [PongEvent]) {
        guard phase == .playing else { return }
        for event in events {
            sounds?.play(event)
            switch event {
            case let .paddleHit(playerID):
                Task { await host.send(.feedback(.paddleHit), to: playerID) }
            case let .lostLife(playerID, remaining):
                if remaining > 0 {
                    Task { await host.send(.feedback(.lostLife), to: playerID) }
                }
            case let .eliminated(playerID), let .forfeited(playerID):
                Task { await host.send(.feedback(.eliminated), to: playerID) }
            case let .gameOver(winner, rally):
                finishMatch(winner: winner, rally: rally)
            }
        }
    }

    private func finishMatch(winner: PlayerID?, rally: Int) {
        guard phase == .playing else { return }
        let wasSolo = currentMatchPlayerCount == 1
        let result: GameResult
        if wasSolo {
            result = GameResult(
                title: "PRACTICE COMPLETE",
                subtitle: "Rally: \(rally)  •  Select to rotate and play again",
                winner: nil
            )
        } else if let winner, let player = host.players.first(where: { $0.id == winner }) {
            result = GameResult(
                title: "P\(player.number) \(player.displayName) WINS",
                subtitle: "Winner stays  •  Select for the next match",
                winner: winner
            )
            Task { await host.send(.feedback(.won), to: winner) }
        } else {
            result = GameResult(title: "MATCH OVER", subtitle: "Select for the next match", winner: nil)
        }
        seatQueue.rotateAfterMatch(winner: winner)
        phase = .gameOver(result)
        Task { await sendLayouts() }
    }

    private func sendLayouts() async {
        let pending = host.players.compactMap { player -> (PlayerID, ControllerLayout)? in
            guard player.isConnected else { return nil }
            return (player.id, layout(for: player.id))
        }
        let host = host
        await withTaskGroup(of: Void.self) { group in
            for (playerID, layout) in pending {
                group.addTask {
                    await host.send(.layout(layout), to: playerID)
                }
            }
        }
    }

    private func sendLayout(to playerID: PlayerID) async {
        await host.send(.layout(layout(for: playerID)), to: playerID)
    }

    private func layout(for playerID: PlayerID) -> ControllerLayout {
        switch phase {
        case .lobby:
            return .lobby
        case .gameMenu:
            return .menu(items: menuItems, selected: menuSelection)
        case .playing:
            if let assignment = currentMatchAssignments.first(where: { $0.playerID == playerID }),
               let info = host.players.first(where: { $0.id == playerID }) {
                return .paddle(PaddleLayout(
                    edge: assignment.edge,
                    colorHex: info.colorHex,
                    label: "P\(info.number) \(info.displayName)"
                ))
            } else {
                return .spectator(SpectatorLayout(
                    queuePosition: seatQueue.waitingPosition(of: playerID) ?? 1
                ))
            }
        case let .gameOver(result):
            return .gameOver(title: result.title, subtitle: result.subtitle)
        }
    }

#if DEBUG
    private func applyFixture(scenario: String) {
        phase = .lobby
        seatQueue = SeatQueue()
        pongScene = nil
        menuSelection = 0
        currentMatchPlayerCount = 0
        currentMatchAssignments = []
        let names = ["Ada", "Grace", "Katherine", "Margaret"]
        let players = names.indices.map { index in
            let id = PlayerID(UInt8(index))
            return PlayerInfo(
                id: id,
                displayName: names[index],
                colorHex: PlayerPalette.color(for: id)
            )
        }
        let fixturePlayers = scenario == "empty-lobby" ? [] : players
        host.configureFixture(hostName: configuration.hostName ?? "UI Test PartyBox", players: fixturePlayers)
        for player in fixturePlayers { seatQueue.joined(player.id) }
        switch scenario {
        case "menu":
            phase = .gameMenu
        case "four-way-match":
            currentMatchAssignments = seatQueue.assignments
            currentMatchPlayerCount = currentMatchAssignments.count
            pongScene = PongScene(
                assignments: currentMatchAssignments,
                players: fixturePlayers,
                inputs: host.inputs,
                seed: configuration.seed ?? UInt64.random(in: UInt64.min...UInt64.max),
                onEvents: { _ in }
            )
            phase = .playing
        case "game-over":
            phase = .gameOver(GameResult(
                title: "P1 ADA WINS",
                subtitle: "Winner stays  •  Select for the next match",
                winner: PlayerID(0)
            ))
        default:
            phase = .lobby
        }
    }
#endif
}
