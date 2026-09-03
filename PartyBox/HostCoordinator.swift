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
    private(set) var phase: HostPhase = .lobby
    private(set) var seatQueue = SeatQueue()
    private(set) var pongScene: PongScene?
    private(set) var statusMessage = "Starting local party…"
    private(set) var menuSelection = 0

    let menuItems = ["FOUR-WAY PONG"]
    private let sounds = ArcadeSoundPlayer()
    private var hostEventsTask: Task<Void, Never>?
    private var isStarted = false
    private var currentMatchPlayerCount = 0

    var connectedCount: Int { host.players.filter(\.isConnected).count }
    var canStart: Bool {
        seatQueue.active.contains { id in host.players.contains { $0.id == id && $0.isConnected } }
    }

    func start() async {
        guard !isStarted else { return }
        isStarted = true
        let stream = host.events
        hostEventsTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
        do {
            let name = ProcessInfo.processInfo.hostName
                .replacingOccurrences(of: ".local", with: "")
            _ = try await host.start(hostName: "\(name)'s PartyBox")
            statusMessage = "Ready for controllers"
        } catch {
            statusMessage = "Could not start: \(error.localizedDescription)"
        }
    }

    func stop() async {
        hostEventsTask?.cancel()
        hostEventsTask = nil
        await host.stop()
        isStarted = false
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

    private func handle(_ event: HostEvent) async {
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
        case let .playerExpired(playerID):
            if phase == .playing {
                seatQueue.left(playerID, fillVacancy: false)
                pongScene?.forfeit(playerID)
            } else {
                seatQueue.left(playerID)
            }
            statusMessage = host.players.isEmpty
                ? "Ready for controllers"
                : "Player \(Int(playerID.rawValue) + 1) left the party"
            await sendLayouts()
        case let .menu(_, action):
            perform(action)
        case let .failure(message):
            statusMessage = message
        }
    }

    private func startPong() {
        guard phase != .playing, canStart else { return }
        currentMatchPlayerCount = seatQueue.assignments.count
        let scene = PongScene(
            assignments: seatQueue.assignments,
            players: host.players,
            inputs: host.inputs
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
            sounds.play(event)
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
        for player in host.players where player.isConnected {
            await sendLayout(to: player.id)
        }
    }

    private func sendLayout(to playerID: PlayerID) async {
        let layout: ControllerLayout
        switch phase {
        case .lobby:
            layout = .lobby
        case .gameMenu:
            layout = .menu(items: menuItems, selected: menuSelection)
        case .playing:
            if let assignment = seatQueue.assignments.first(where: { $0.playerID == playerID }),
               let info = host.players.first(where: { $0.id == playerID }) {
                layout = .paddle(PaddleLayout(
                    edge: assignment.edge,
                    colorHex: info.colorHex,
                    label: "P\(info.number) \(info.displayName)"
                ))
            } else {
                layout = .spectator(SpectatorLayout(queuePosition: seatQueue.waitingPosition(of: playerID) ?? 1))
            }
        case let .gameOver(result):
            layout = .gameOver(title: result.title, subtitle: result.subtitle)
        }
        await host.send(.layout(layout), to: playerID)
    }
}
