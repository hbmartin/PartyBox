import Foundation
import Observation
import PartyBoxCore
import PartyGameRuntime
import PartyNet

@MainActor
@Observable
final class HostCupDirector {
    var cupSetupSelection = 0
    var selectedCupGameIDs: [String] = []
    var cupEventIndex = 0
    var cupPoints: [ControllerID: Int] = [:]
    var cupEventWins: [ControllerID: Int] = [:]
    @ObservationIgnored var cupParticipants: [GameParticipant] = []
    @ObservationIgnored var cupMatchRecordIDs: [UUID] = []
    @ObservationIgnored var currentMatchIsCup = false

    func clearSelection() {
        selectedCupGameIDs = []
        cupSetupSelection = 0
    }

    func recordMatch(_ id: UUID) {
        cupMatchRecordIDs.append(id)
    }

    @discardableResult
    func toggleGame(at index: Int, eligibleGames: [GameDescriptor]) -> Bool {
        guard eligibleGames.indices.contains(index) else { return false }
        let gameID = eligibleGames[index].id
        if let selectedIndex = selectedCupGameIDs.firstIndex(of: gameID) {
            selectedCupGameIDs.remove(at: selectedIndex)
        } else if selectedCupGameIDs.count < 3 {
            selectedCupGameIDs.append(gameID)
        } else {
            return false
        }
        return true
    }

    func begin(participants: [GameParticipant]) {
        cupParticipants = participants
        cupEventIndex = 0
        cupPoints = Dictionary(uniqueKeysWithValues: participants.map { ($0.controllerID, 0) })
        cupEventWins = Dictionary(uniqueKeysWithValues: participants.map { ($0.controllerID, 0) })
        cupMatchRecordIDs = []
    }

    func abortFirstEvent() {
        cupParticipants = []
        cupPoints = [:]
        cupEventWins = [:]
    }

    func reconcileParticipants(_ current: [GameParticipant]) {
        let floor = cupPoints.values.min() ?? 0
        for participant in current {
            if let index = cupParticipants.firstIndex(where: { $0.controllerID == participant.controllerID }) {
                cupParticipants[index] = participant
            } else {
                cupParticipants.append(participant)
                cupPoints[participant.controllerID] = floor
                cupEventWins[participant.controllerID] = 0
            }
        }
    }

    func score(_ outcome: GameOutcome, participants: [GameParticipant]) {
        let fallback = participants.sorted { lhs, rhs in
            if lhs.player.id == outcome.winner { return true }
            if rhs.player.id == outcome.winner { return false }
            return lhs.player.id.rawValue < rhs.player.id.rawValue
        }.enumerated().map { index, participant in
            GameStanding(playerID: participant.player.id, rank: index + 1, score: 0)
        }
        let standings = outcome.standings.isEmpty ? fallback : outcome.standings
        let pointsByRank = [8, 6, 5, 4, 3, 2, 1, 0]
        for standing in standings {
            guard let participant = participants.first(where: { $0.player.id == standing.playerID }) else { continue }
            let points = pointsByRank[min(max(standing.rank - 1, 0), pointsByRank.count - 1)]
            cupPoints[participant.controllerID, default: 0] += points
            if standing.rank == 1 { cupEventWins[participant.controllerID, default: 0] += 1 }
        }
    }

    func standings(livePlayers: [ControllerID: PlayerInfo]) -> [CupStandingRecord] {
        let sorted = cupParticipants.sorted { lhs, rhs in
            let leftPoints = cupPoints[lhs.controllerID, default: 0]
            let rightPoints = cupPoints[rhs.controllerID, default: 0]
            if leftPoints != rightPoints { return leftPoints > rightPoints }
            let leftWins = cupEventWins[lhs.controllerID, default: 0]
            let rightWins = cupEventWins[rhs.controllerID, default: 0]
            if leftWins != rightWins { return leftWins > rightWins }
            return lhs.player.id.rawValue < rhs.player.id.rawValue
        }
        return sorted.enumerated().map { index, participant in
            CupStandingRecord(
                controllerID: participant.controllerID,
                displayName: livePlayers[participant.controllerID]?.displayName ?? participant.player.displayName,
                colorHex: participant.player.colorHex,
                kind: participant.player.kind,
                rank: index + 1,
                points: cupPoints[participant.controllerID, default: 0],
                eventWins: cupEventWins[participant.controllerID, default: 0]
            )
        }
    }

    func makeRecord(livePlayers: [ControllerID: PlayerInfo]) -> CupRecord {
        CupRecord(
            endedAt: Date(), gameIDs: selectedCupGameIDs,
            matchRecordIDs: cupMatchRecordIDs, standings: standings(livePlayers: livePlayers)
        )
    }

    func reset() {
        clearSelection()
        cupEventIndex = 0
        cupPoints = [:]
        cupEventWins = [:]
        cupParticipants = []
        cupMatchRecordIDs = []
        currentMatchIsCup = false
    }

}
