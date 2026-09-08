import Foundation
import PartyNet

public enum MatchParticipantOutcome: String, Codable, Equatable, Sendable {
    case won, lost, forfeited, practice
}

public struct MatchMetric: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let value: String

    public init(id: String, label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

public struct MatchParticipant: Codable, Equatable, Sendable {
    public let controllerID: ControllerID
    public let displayName: String
    public let colorHex: String
    public let outcome: MatchParticipantOutcome
    public let kind: PlayerKind

    public init(
        controllerID: ControllerID,
        displayName: String,
        colorHex: String,
        outcome: MatchParticipantOutcome,
        kind: PlayerKind = .human
    ) {
        self.controllerID = controllerID
        self.displayName = displayName
        self.colorHex = colorHex
        self.outcome = outcome
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case controllerID, displayName, colorHex, outcome, kind
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        controllerID = try values.decode(ControllerID.self, forKey: .controllerID)
        displayName = try values.decode(String.self, forKey: .displayName)
        colorHex = try values.decode(String.self, forKey: .colorHex)
        outcome = try values.decode(MatchParticipantOutcome.self, forKey: .outcome)
        kind = try values.decodeIfPresent(PlayerKind.self, forKey: .kind) ?? .human
    }
}

public struct MatchRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let gameID: String
    public let gameTitle: String
    public let endedAt: Date
    public let durationSeconds: Double
    public let modifierTitle: String?
    public let participants: [MatchParticipant]
    public let metrics: [MatchMetric]

    public init(id: UUID = UUID(), gameID: String, gameTitle: String, endedAt: Date, durationSeconds: Double, modifierTitle: String?, participants: [MatchParticipant], metrics: [MatchMetric]) {
        self.id = id
        self.gameID = gameID
        self.gameTitle = gameTitle
        self.endedAt = endedAt
        self.durationSeconds = max(0, durationSeconds)
        self.modifierTitle = modifierTitle
        self.participants = participants
        self.metrics = metrics
    }

    public var humanCount: Int { participants.count { $0.kind == .human } }
    public var botCount: Int { participants.count { $0.kind == .bot } }
    public var isPractice: Bool { humanCount == 1 && botCount == 0 }
    public var isSoloBotMatch: Bool { humanCount == 1 && botCount > 0 }
    public var isPartyMatch: Bool { humanCount >= 2 }
    public var isCompetitive: Bool { isPartyMatch }
}

public struct PersonalMatchParticipant: Codable, Equatable, Sendable {
    public let displayName: String
    public let colorHex: String
    public let outcome: MatchParticipantOutcome
    public let kind: PlayerKind

    public init(
        displayName: String,
        colorHex: String,
        outcome: MatchParticipantOutcome,
        kind: PlayerKind = .human
    ) {
        self.displayName = displayName
        self.colorHex = colorHex
        self.outcome = outcome
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case displayName, colorHex, outcome, kind
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try values.decode(String.self, forKey: .displayName)
        colorHex = try values.decode(String.self, forKey: .colorHex)
        outcome = try values.decode(MatchParticipantOutcome.self, forKey: .outcome)
        kind = try values.decodeIfPresent(PlayerKind.self, forKey: .kind) ?? .human
    }
}

public struct PersonalMatchRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let gameID: String
    public let gameTitle: String
    public let endedAt: Date
    public let durationSeconds: Double
    public let modifierTitle: String?
    public let participants: [PersonalMatchParticipant]
    public let ownOutcome: MatchParticipantOutcome
    public let metrics: [MatchMetric]

    public init(record: MatchRecord, controllerID: ControllerID) {
        id = record.id
        gameID = record.gameID
        gameTitle = record.gameTitle
        endedAt = record.endedAt
        durationSeconds = record.durationSeconds
        modifierTitle = record.modifierTitle
        metrics = record.metrics
        participants = record.participants.map {
            .init(
                displayName: $0.displayName,
                colorHex: $0.colorHex,
                outcome: $0.outcome,
                kind: $0.kind
            )
        }
        ownOutcome = record.participants.first { $0.controllerID == controllerID }?.outcome ?? .lost
    }

    public var humanCount: Int { participants.count { $0.kind == .human } }
    public var botCount: Int { participants.count { $0.kind == .bot } }
    public var isPractice: Bool { humanCount == 1 && botCount == 0 }
    public var isSoloBotMatch: Bool { humanCount == 1 && botCount > 0 }
    public var isPartyMatch: Bool { humanCount >= 2 }
    public var isCompetitive: Bool { isPartyMatch }
}

public struct HistoryStatistics: Equatable, Sendable {
    public let played: Int
    public let won: Int
    public var winRate: Double { played == 0 ? 0 : Double(won) / Double(played) }
}

public struct LeaderboardEntry: Identifiable, Equatable, Sendable {
    public let id: ControllerID
    public let displayName: String
    public let colorHex: String
    public let statistics: HistoryStatistics
}

public enum HistoryAggregation {
    public static func leaderboard(_ records: [MatchRecord]) -> [LeaderboardEntry] {
        var values: [ControllerID: (name: String, color: String, played: Int, won: Int, date: Date)] = [:]
        for record in records.sorted(by: { $0.endedAt < $1.endedAt }) where record.isPartyMatch {
            for participant in record.participants where participant.kind == .human {
                var current = values[participant.controllerID] ?? (participant.displayName, participant.colorHex, 0, 0, .distantPast)
                current.played += 1
                if participant.outcome == .won { current.won += 1 }
                if record.endedAt >= current.date {
                    current.name = participant.displayName
                    current.color = participant.colorHex
                    current.date = record.endedAt
                }
                values[participant.controllerID] = current
            }
        }
        return values.map { id, value in
            LeaderboardEntry(id: id, displayName: value.name, colorHex: value.color, statistics: .init(played: value.played, won: value.won))
        }.sorted {
            if $0.statistics.won != $1.statistics.won { return $0.statistics.won > $1.statistics.won }
            if $0.statistics.winRate != $1.statistics.winRate { return $0.statistics.winRate > $1.statistics.winRate }
            if $0.statistics.played != $1.statistics.played { return $0.statistics.played > $1.statistics.played }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    public static func personal(_ records: [PersonalMatchRecord]) -> HistoryStatistics {
        let competitive = records.filter(\.isPartyMatch)
        return HistoryStatistics(played: competitive.count, won: competitive.count { $0.ownOutcome == .won })
    }

    public static func solo(_ records: [PersonalMatchRecord]) -> HistoryStatistics {
        let solo = records.filter(\.isSoloBotMatch)
        return HistoryStatistics(played: solo.count, won: solo.count { $0.ownOutcome == .won })
    }
}

public enum JSONRecordAppendResult: Equatable, Sendable {
    case duplicate
    case inserted
    case insertedWithPersistenceFailure(errorDescription: String)

    public var wasInserted: Bool {
        switch self {
        case .duplicate: false
        case .inserted, .insertedWithPersistenceFailure: true
        }
    }

    public var persistenceErrorDescription: String? {
        guard case .insertedWithPersistenceFailure(let errorDescription) = self else { return nil }
        return errorDescription
    }
}

public actor JSONRecordStore<Record: Codable & Identifiable & Sendable> where Record.ID == UUID {
    private struct Archive: Codable {
        let version: Int
        var records: [Record]
    }
    private let fileURL: URL?
    private var records: [Record]

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        guard let fileURL else {
            records = []
            return
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            records = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        if let archive = try? decoder.decode(Archive.self, from: data), archive.version == 1 {
            records = archive.records
        } else {
            records = []
            let suffix = Int(Date().timeIntervalSince1970)
            let backupURL = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(suffix).json")
            try? FileManager.default.moveItem(at: fileURL, to: backupURL)
        }
    }

    public func all() -> [Record] { records }

    public func append(_ record: Record) -> JSONRecordAppendResult {
        guard !records.contains(where: { $0.id == record.id }) else { return .duplicate }
        records.append(record)
        do {
            try persist()
            return .inserted
        } catch {
            return .insertedWithPersistenceFailure(errorDescription: error.localizedDescription)
        }
    }

    public func clear() throws {
        try persist([])
        records.removeAll()
    }

    private func persist(_ recordsToPersist: [Record]? = nil) throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(Archive(version: 1, records: recordsToPersist ?? records)).write(to: fileURL, options: .atomic)
    }
}
