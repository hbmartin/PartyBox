import Foundation
import Observation
import OSLog
import PartyBoxCore

@MainActor
@Observable
final class HostRecords {
    nonisolated struct DiagnosticsActivity: Codable, Sendable {
        let acceptedFrames: UInt64
        let minimumAxis: Float
        let maximumAxis: Float
    }

    nonisolated struct DiagnosticsReport: Codable, Sendable {
        let generatedAt: Date
        let role: String
        let protocolVersion: UInt16
        let phase: String
        let connectedPlayers: Int
        let connectedHumans: Int
        let activeBots: Int
        let currentGame: String?
        let inputActivity: [DiagnosticsActivity]
        let historyPersistenceHealthy: Bool
    }

    typealias DiagnosticsExporter = @Sendable (DiagnosticsReport) async throws -> DiagnosticsExport

    private(set) var historyRecords: [MatchRecord] = []
    private(set) var cupRecords: [CupRecord] = []
    private(set) var matchHistoryPersistenceError: String?
    private(set) var cupHistoryPersistenceError: String?
    var historySelection = 0
    var confirmsHistoryClear = false

    var historyPersistenceError: String? {
        let failures = [matchHistoryPersistenceError, cupHistoryPersistenceError].compactMap { $0 }
        return failures.isEmpty ? nil : failures.joined(separator: "\n")
    }
    var leaderboard: [LeaderboardEntry] { HistoryAggregation.leaderboard(historyRecords) }

    @ObservationIgnored private let historyStore: JSONRecordStore<MatchRecord>
    @ObservationIgnored private let cupHistoryStore: JSONRecordStore<CupRecord>
    @ObservationIgnored private let diagnosticsExporter: DiagnosticsExporter
    @ObservationIgnored private let logger = Logger(subsystem: "PartyBox", category: "HostRecords")

    init(configuration: HostLaunchConfiguration, historyFileURL: URL?, diagnosticsExporter: DiagnosticsExporter?) {
        if let diagnosticsExporter {
            self.diagnosticsExporter = diagnosticsExporter
        } else if configuration.failDiagnosticsExport {
            self.diagnosticsExporter = { _ in throw CocoaError(.fileWriteNoPermission) }
        } else {
            self.diagnosticsExporter = { report in
                try await RedactedDiagnosticsExporter.write(report, role: .host)
            }
        }
        let defaultURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PartyBox", isDirectory: true)
            .appendingPathComponent("history-v1.json")
        let resolvedHistoryURL = historyFileURL ?? defaultURL
        historyStore = JSONRecordStore(fileURL: configuration.isUITesting ? nil : resolvedHistoryURL)
        let cupURL = resolvedHistoryURL?.deletingLastPathComponent().appendingPathComponent("cups-v1.json")
        cupHistoryStore = JSONRecordStore(fileURL: configuration.isUITesting ? nil : cupURL)
    }

    func load() async -> ([MatchRecord], [CupRecord]) {
        async let matchLoad = historyStore.all()
        async let cupLoad = cupHistoryStore.all()
        let (matches, cups) = await (matchLoad, cupLoad)
        return (matches.sorted { $0.endedAt > $1.endedAt }, cups.sorted { $0.endedAt > $1.endedAt })
    }

    func installLoaded(matches: [MatchRecord], cups: [CupRecord]) {
        historyRecords = matches
        cupRecords = cups
    }

    func appendMatch(_ record: MatchRecord) async -> JSONRecordAppendResult {
        await historyStore.append(record)
    }

    func appendCup(_ record: CupRecord) async -> JSONRecordAppendResult {
        await cupHistoryStore.append(record)
    }

    func applyMatchAppend(_ record: MatchRecord, result: JSONRecordAppendResult) {
        guard result.wasInserted else { return }
        if !historyRecords.contains(where: { $0.id == record.id }) {
            historyRecords.insert(record, at: 0)
        }
        if let error = result.persistenceErrorDescription {
            matchHistoryPersistenceError = "This match is available for this session but could not be saved: \(error)"
        } else {
            matchHistoryPersistenceError = nil
        }
    }

    func applyCupAppend(_ record: CupRecord, result: JSONRecordAppendResult) {
        guard result.wasInserted else { return }
        if !cupRecords.contains(where: { $0.id == record.id }) {
            cupRecords.insert(record, at: 0)
        }
        if let error = result.persistenceErrorDescription {
            cupHistoryPersistenceError = "This Party Cup is available now but could not be saved: \(error)"
        } else {
            cupHistoryPersistenceError = nil
        }
    }

    func clear() async {
        do {
            try await historyStore.clear()
            historyRecords = []
            historySelection = 0
            matchHistoryPersistenceError = nil
        } catch {
            matchHistoryPersistenceError = "Match history could not be cleared: \(error.localizedDescription)"
        }
        do {
            try await cupHistoryStore.clear()
            cupRecords = []
            cupHistoryPersistenceError = nil
        } catch {
            cupHistoryPersistenceError = "Party Cup history could not be cleared: \(error.localizedDescription)"
        }
        confirmsHistoryClear = false
    }

    func export(_ report: DiagnosticsReport) async throws -> DiagnosticsExport {
        do {
            return try await diagnosticsExporter(report)
        } catch {
            logger.error("Could not export diagnostics: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}
