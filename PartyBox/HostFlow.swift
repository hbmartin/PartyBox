import Foundation
import Observation
import PartyBoxCore
import PartyGameRuntime
import PartyNet

enum HostPhase: Equatable {
    case lobby
    case gameMenu
    case cupSetup
    case playing
    case gameOver(GameOutcome)
    case cupStandings(GameOutcome)
    case cupComplete(CupRecord)
    case history
}

enum HostInputSource: Equatable {
    case local
    case controller(PlayerID)
}

@MainActor
@Observable
final class HostFlow {
    enum Intent {
        case requestLayout
        case reconcileBots
        case clearBotDifficulty
        case clearCupSelection
        case setCupSelection(Int)
        case toggleCupGame(Int)
        case startSelectedGame
        case startCup
        case startNextCupEvent
        case resetCup
        case clearPendingModifier
        case setHistorySelection(Int)
        case cancelHistoryClear
    }

    struct Context {
        let players: [PlayerInfo]
        let gameCount: Int
        let menuItemCount: Int
        let cupEligibleCount: Int
        let cupSetupItemCount: Int
        let cupSetupSelection: Int
        let selectedCupGameCount: Int
        let canStart: Bool
        let historySelection: Int
        let historyRecordCount: Int
    }

    var phase: HostPhase = .lobby
    var menuSelection = 0
    var captainID: PlayerID?
    var readyPlayerIDs: Set<PlayerID> = []
    @ObservationIgnored var humanConnectionOrder: [ControllerID] = []
    @ObservationIgnored var connectedHumanControllers: Set<ControllerID> = []
    @ObservationIgnored private var lastDirectionAt: [PlayerID: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var lastDecisionAt: [PlayerID: ContinuousClock.Instant] = [:]

    func readyCount(players: [PlayerInfo]) -> Int {
        let connected = Set(players.filter { $0.isConnected && $0.kind == .human }.map(\.id))
        let captainVote = captainID.map { connected.contains($0) } == true ? 1 : 0
        return captainVote + readyPlayerIDs.intersection(connected).count
    }

    func requiredReadyCount(players: [PlayerInfo]) -> Int {
        let connectedHumans = players.count { $0.isConnected && $0.kind == .human }
        return connectedHumans == 0 ? 0 : (connectedHumans / 2) + 1
    }

    func clearReadiness() {
        readyPlayerIDs.removeAll()
    }

    func forgetInput(from playerID: PlayerID) {
        lastDirectionAt.removeValue(forKey: playerID)
        lastDecisionAt.removeValue(forKey: playerID)
    }

    func authorizesLobbyCommand(from playerID: PlayerID, players: [PlayerInfo]) -> Bool {
        phase == .lobby && players.contains {
            $0.id == playerID && $0.isConnected && $0.kind == .human
        }
    }

    func authorizesBotFillChange(from playerID: PlayerID, configuredBotCount: Int) -> Bool {
        playerID == captainID && configuredBotCount == 0
    }

    func authorizesGameAction(
        gameID: String,
        currentGameID: String?,
        schemaVersion: UInt16,
        participant: GameParticipant?,
        eliminatedControllers: Set<ControllerID>
    ) -> Bool {
        phase == .playing && gameID == currentGameID
            && schemaVersion == ControllerScreen.schemaVersion
            && participant.map { !eliminatedControllers.contains($0.controllerID) } == true
    }

    func authorizesSpectatorAction(
        isConnected: Bool,
        participant: GameParticipant?,
        eliminatedControllers: Set<ControllerID>
    ) -> Bool {
        guard phase == .playing, isConnected else { return false }
        guard let participant else { return true }
        return eliminatedControllers.contains(participant.controllerID)
    }

    func updateConnectedHumans(_ controllers: Set<ControllerID>) {
        guard controllers != connectedHumanControllers else { return }
        connectedHumanControllers = controllers
        clearReadiness()
    }

    @discardableResult
    func promoteCaptain(connectedByController: [ControllerID: PlayerID]) -> Bool {
        let promoted = humanConnectionOrder.lazy.compactMap { connectedByController[$0] }.first
        guard promoted != captainID else { return false }
        captainID = promoted
        clearReadiness()
        return true
    }

    func setMenuSelection(_ selection: Int) -> [Intent] {
        guard selection != menuSelection else { return [] }
        menuSelection = selection
        clearReadiness()
        return [.clearBotDifficulty, .requestLayout]
    }

    func transition(to newPhase: HostPhase) -> [Intent] {
        guard phase != newPhase else { return [] }
        phase = newPhase
        clearReadiness()
        var intents: [Intent] = []
        if newPhase == .gameMenu { intents.append(.clearBotDifficulty) }
        intents += [.requestLayout, .reconcileBots]
        return intents
    }

    func apply(
        _ action: MenuAction,
        source: HostInputSource,
        now suppliedNow: ContinuousClock.Instant?,
        context: Context
    ) -> [Intent] {
        guard accepts(action, from: source, now: suppliedNow, context: context) else { return [] }
        switch phase {
        case .lobby:
            if action == .select, context.canStart { return transition(to: .gameMenu) }
        case .gameMenu:
            switch action {
            case .up, .left:
                return setMenuSelection(max(0, menuSelection - 1))
            case .down, .right:
                return setMenuSelection(min(context.menuItemCount - 1, menuSelection + 1))
            case .select:
                if menuSelection < context.gameCount {
                    if isCaptainControl(source) { return [.startSelectedGame] }
                    if case let .controller(playerID) = source { return toggleReadiness(for: playerID, context: context) }
                } else if menuSelection == context.gameCount, isCaptainControl(source) {
                    return [.clearCupSelection] + transition(to: .cupSetup)
                } else if menuSelection == context.gameCount + 1 {
                    return transition(to: .history)
                }
            case .back:
                return transition(to: .lobby)
            }
        case .cupSetup:
            switch action {
            case .up, .left:
                return [.setCupSelection(max(0, context.cupSetupSelection - 1)), .requestLayout]
            case .down, .right:
                return [.setCupSelection(min(context.cupSetupItemCount - 1, context.cupSetupSelection + 1)), .requestLayout]
            case .select:
                if isCaptainControl(source) {
                    if context.cupSetupSelection == context.cupEligibleCount {
                        if context.canStart,
                           readyCount(players: context.players) >= requiredReadyCount(players: context.players) {
                            return [.startCup]
                        }
                    } else {
                        return [.toggleCupGame(context.cupSetupSelection)]
                    }
                } else if case let .controller(playerID) = source {
                    return toggleReadiness(for: playerID, context: context)
                }
            case .back:
                return [.clearCupSelection] + transition(to: .gameMenu)
            }
        case .playing:
            break
        case .gameOver:
            switch action {
            case .select:
                if isCaptainControl(source) { return [.startSelectedGame] }
                if case let .controller(playerID) = source { return toggleReadiness(for: playerID, context: context) }
            case .back:
                return [.clearPendingModifier] + transition(to: .gameMenu)
            default: break
            }
        case .history:
            switch action {
            case .up: return [.setHistorySelection(max(0, context.historySelection - 1))]
            case .down: return [.setHistorySelection(min(max(0, context.historyRecordCount - 1), context.historySelection + 1))]
            case .back: return [.cancelHistoryClear] + transition(to: .gameMenu)
            default: break
            }
        case .cupStandings:
            if action == .select {
                if isCaptainControl(source) {
                    if readyCount(players: context.players) >= requiredReadyCount(players: context.players) {
                        return [.startNextCupEvent]
                    }
                } else if case let .controller(playerID) = source {
                    return toggleReadiness(for: playerID, context: context)
                }
            }
        case .cupComplete:
            if action == .select || action == .back {
                return [.resetCup] + setMenuSelection(context.gameCount) + transition(to: .gameMenu)
            }
        }
        return []
    }

    private func toggleReadiness(for playerID: PlayerID, context: Context) -> [Intent] {
        guard context.canStart, playerID != captainID,
              context.players.contains(where: { $0.id == playerID && $0.isConnected && $0.kind == .human })
        else { return [] }
        if readyPlayerIDs.remove(playerID) == nil { readyPlayerIDs.insert(playerID) }
        var intents: [Intent] = [.requestLayout]
        if readyCount(players: context.players) >= requiredReadyCount(players: context.players) {
            switch phase {
            case .gameMenu, .gameOver: intents.append(.startSelectedGame)
            case .cupSetup where context.selectedCupGameCount == 3: intents.append(.startCup)
            case .cupStandings: intents.append(.startNextCupEvent)
            default: break
            }
        }
        return intents
    }

    private func accepts(
        _ action: MenuAction,
        from source: HostInputSource,
        now suppliedNow: ContinuousClock.Instant?,
        context: Context
    ) -> Bool {
        guard case let .controller(playerID) = source else { return true }
        guard let player = context.players.first(where: {
            $0.id == playerID && $0.isConnected && $0.kind == .human
        }) else { return false }

        let isAuthorized: Bool
        if action == .select {
            switch phase {
            case .gameMenu:
                isAuthorized = menuSelection < context.gameCount || player.id == captainID
            case .cupSetup, .cupStandings, .gameOver:
                isAuthorized = true
            case .lobby, .history, .cupComplete:
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

    func reset() {
        phase = .lobby
        menuSelection = 0
        captainID = nil
        readyPlayerIDs = []
        humanConnectionOrder = []
        connectedHumanControllers = []
        lastDirectionAt = [:]
        lastDecisionAt = [:]
    }
}
