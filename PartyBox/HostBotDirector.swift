import Foundation
import Observation
import PartyBoxCore
import PartyGameRuntime
import PartyNet

@MainActor
@Observable
final class HostBotDirector {
    enum ReconciliationResult {
        case completed
        case joinFailed
        case cancelled
    }

    var botFillTarget = 0
    var botDifficultyChange: String?
    @ObservationIgnored var needsReconciliation = false
    @ObservationIgnored var bots: [ControllerID: PartyClient] = [:]
    @ObservationIgnored private var nextBotNumber = 1
    @ObservationIgnored private var difficultyByGameID: [String: GameBotDifficulty] = [:]

    func difficulty(for gameID: String?) -> GameBotDifficulty {
        guard let gameID else { return .normal }
        return difficultyByGameID[gameID] ?? .normal
    }

    func setDifficulty(_ difficulty: GameBotDifficulty, for gameID: String) {
        difficultyByGameID[gameID] = difficulty
    }

    func desiredCount(configuredCount: Int, connectedHumanCount: Int) -> Int {
        if configuredCount > 0 {
            return min(configuredCount, max(0, PartyNetConstants.maximumControllers - connectedHumanCount))
        }
        return min(botFillTarget, max(0, PartyBoxRuntimeLimits.releasePartySize - connectedHumanCount))
    }

    func reconcile(
        host: PartyHost,
        port: UInt16,
        desired: Int,
        isCurrentLifecycle: @MainActor () -> Bool,
        canChangeRoster: @MainActor () -> Bool,
        isMatchParticipant: @MainActor (ControllerID) -> Bool
    ) async -> ReconciliationResult {
        while bots.count > desired, isCurrentLifecycle(), canChangeRoster(),
              let entry = bots.sorted(by: {
                  $0.value.displayName.localizedStandardCompare($1.value.displayName) == .orderedDescending
              }).first {
            bots.removeValue(forKey: entry.key)
            await entry.value.stop()
            host.unregisterLocalBot(controllerID: entry.key)
        }

        // A client that failed after host admission can remain protected by the
        // current match. Replace it once the match has ended.
        while isCurrentLifecycle(), canChangeRoster(),
              let entry = bots.first(where: { $0.value.player == nil && !isMatchParticipant($0.key) }) {
            bots.removeValue(forKey: entry.key)
            await entry.value.stop()
            host.unregisterLocalBot(controllerID: entry.key)
        }

        while bots.count < desired, isCurrentLifecycle(), canChangeRoster() {
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
#if DEBUG
            if let afterConnectForTesting { await afterConnectForTesting() }
#endif
            guard isCurrentLifecycle() else {
                bots.removeValue(forKey: controllerID)
                await bot.stop()
                host.unregisterLocalBot(controllerID: controllerID)
                return .cancelled
            }
            guard bot.player != nil else {
                if isMatchParticipant(controllerID) { return .completed }
                bots.removeValue(forKey: controllerID)
                await bot.stop()
                host.unregisterLocalBot(controllerID: controllerID)
                return .joinFailed
            }
        }
        return isCurrentLifecycle() ? .completed : .cancelled
    }

#if DEBUG
    @ObservationIgnored var afterConnectForTesting: (@MainActor () async -> Void)?
#endif

    func drive(
        session: any PartyGameSession,
        participants: [GameParticipant],
        difficulty: GameBotDifficulty,
        deltaTime: TimeInterval
    ) {
        for bot in bots.values {
            guard let player = bot.player,
                  player.kind == .bot,
                  participants.contains(where: { $0.player.id == player.id }),
                  let input = session.botInput(
                      for: player.id,
                      difficulty: difficulty,
                      deltaTime: .seconds(deltaTime)
                  ) else { continue }
            bot.setInput(axisX: input.axisX, axisY: input.axisY, buttons: input.buttons)
        }
    }

    @discardableResult
    func updateDifficulty(after outcome: GameOutcome, participants: [GameParticipant], gameID: String) -> String? {
        let hasHuman = participants.contains { $0.player.kind == .human }
        let hasBot = participants.contains { $0.player.kind == .bot }
        guard hasHuman, hasBot, let winner = outcome.winner,
              let winnerKind = participants.first(where: { $0.player.id == winner })?.player.kind else {
            botDifficultyChange = nil
            return nil
        }
        let previous = difficultyByGameID[gameID] ?? .normal
        let updated = winnerKind == .human ? previous.harder : previous.easier
        guard updated != previous else {
            botDifficultyChange = nil
            return nil
        }
        difficultyByGameID[gameID] = updated
        let direction = updated.rawValue > previous.rawValue ? "increased" : "reduced"
        botDifficultyChange = "BOT DIFFICULTY \(direction.uppercased()) TO \(updated.title.uppercased())"
        return botDifficultyChange
    }

    func takeBotsForShutdown() -> [PartyClient] {
        let clients = Array(bots.values)
        bots.removeAll()
        needsReconciliation = false
        return clients
    }
}
