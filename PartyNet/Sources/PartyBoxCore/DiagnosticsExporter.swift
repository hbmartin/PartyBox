import Foundation
import OSLog

public enum DiagnosticsRole: String, Sendable {
    case host
    case controller
}

/// A diagnostics file that remains protected from retention cleanup while this handle is alive.
///
/// Call ``release()`` when the file is no longer being offered for sharing. After release, the
/// URL may be removed by retention cleanup. Dropping the last reference also releases the file.
public final class DiagnosticsExport: Sendable {
    public let url: URL

    private let releaseAction: @Sendable () async -> Void

    fileprivate init(
        url: URL,
        releaseAction: @escaping @Sendable () async -> Void
    ) {
        self.url = url
        self.releaseAction = releaseAction
    }

    /// Makes the export eligible for retention cleanup. Calling this more than once is harmless.
    public func release() async {
        await releaseAction()
    }

    deinit {
        let releaseAction = releaseAction
        Task {
            await releaseAction()
        }
    }
}

public enum RedactedDiagnosticsExporter {
    typealias FileRemover = @Sendable (URL) throws -> Void

    private static let store = DiagnosticsExportStore()

    @concurrent
    public static func write<Report: Encodable & Sendable>(
        _ report: Report,
        role: DiagnosticsRole
    ) async throws -> DiagnosticsExport {
        try await write(
            report,
            role: role,
            directory: FileManager.default.temporaryDirectory
        )
    }

    @concurrent
    static func write<Report: Encodable & Sendable>(
        _ report: Report,
        role: DiagnosticsRole,
        directory: URL,
        now: Date = Date(),
        retentionLimit: Int = 5,
        removeItem: @escaping FileRemover = { url in
            try FileManager.default.removeItem(at: url)
        }
    ) async throws -> DiagnosticsExport {
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try Task.checkCancellation()

        let lease = try await store.write(
            data,
            role: role,
            directory: directory,
            now: now,
            retentionLimit: max(1, retentionLimit),
            removeItem: removeItem
        )
        let store = store
        let export = DiagnosticsExport(url: lease.url) {
            await store.release(leaseID: lease.id)
        }
        if Task.isCancelled {
            await export.release()
            throw CancellationError()
        }
        return export
    }
}

private actor DiagnosticsExportStore {
    private struct Scope: Hashable, Sendable {
        let directory: URL
        let role: DiagnosticsRole
    }

    private struct Configuration: Sendable {
        let retentionLimit: Int
        let removeItem: RedactedDiagnosticsExporter.FileRemover
    }

    private struct ActiveExport: Sendable {
        let url: URL
        let scope: Scope
    }

    private struct RetainedExport {
        let url: URL
        let logicalMilliseconds: Int64?
    }

    struct Lease: Sendable {
        let id: UUID
        let url: URL
    }

    private static let timestampLength = 20
    private let logger = Logger(subsystem: "PartyBoxCore", category: "DiagnosticsExporter")
    private var activeExports: [UUID: ActiveExport] = [:]
    private var configurations: [Scope: Configuration] = [:]

    func write(
        _ data: Data,
        role: DiagnosticsRole,
        directory: URL,
        now: Date,
        retentionLimit: Int,
        removeItem: @escaping RedactedDiagnosticsExporter.FileRemover
    ) throws -> Lease {
        let scope = Scope(directory: directory.standardizedFileURL, role: role)
        let configuration = Configuration(
            retentionLimit: retentionLimit,
            removeItem: removeItem
        )
        configurations[scope] = configuration

        let existingExports = try exports(in: scope)
        let nowMilliseconds = milliseconds(for: now)
        let latestMilliseconds = existingExports.compactMap(\.logicalMilliseconds).max()
        let logicalMilliseconds = max(
            nowMilliseconds,
            latestMilliseconds.map { $0 + 1 } ?? nowMilliseconds
        )
        let filenamePrefix = filenamePrefix(for: role)
        let url = scope.directory.appendingPathComponent(
            "\(filenamePrefix)\(timestamp(for: logicalMilliseconds))-\(UUID().uuidString).json"
        ).standardizedFileURL
        let leaseID = UUID()

        do {
            try data.write(to: url, options: .atomic)
            activeExports[leaseID] = ActiveExport(url: url, scope: scope)
            try prune(scope: scope, configuration: configuration)
        } catch {
            activeExports.removeValue(forKey: leaseID)
            do {
                try removeItem(url)
            } catch {
                logger.error(
                    "Could not clean up failed diagnostics export \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
            throw error
        }

        return Lease(id: leaseID, url: url)
    }

    func release(leaseID: UUID) {
        guard let activeExport = activeExports.removeValue(forKey: leaseID),
              let configuration = configurations[activeExport.scope] else { return }
        do {
            try prune(scope: activeExport.scope, configuration: configuration)
        } catch {
            logger.error(
                "Could not prune released diagnostics export \(activeExport.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func prune(
        scope: Scope,
        configuration: Configuration
    ) throws {
        let exports = try exports(in: scope)
        let activeURLs = Set(activeExports.values.lazy
            .filter { $0.scope == scope }
            .map(\.url))
        let inactiveExports = exports.filter { !activeURLs.contains($0.url) }.sorted(by: isNewer)
        let inactiveSlots = max(0, configuration.retentionLimit - activeURLs.count)

        for expired in inactiveExports.dropFirst(inactiveSlots) {
            do {
                try configuration.removeItem(expired.url)
            } catch {
                logger.error(
                    "Could not remove expired diagnostics export \(expired.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func exports(in scope: Scope) throws -> [RetainedExport] {
        let files = try FileManager.default.contentsOfDirectory(
            at: scope.directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let prefix = filenamePrefix(for: scope.role)
        let expression = try filenameExpression(prefix: prefix)

        return files.compactMap { file in
            let filename = file.lastPathComponent
            let fullRange = NSRange(filename.startIndex..<filename.endIndex, in: filename)
            guard expression.firstMatch(in: filename, range: fullRange) != nil else { return nil }
            let timestampStart = filename.index(filename.startIndex, offsetBy: prefix.count)
            let timestampEnd = filename.index(
                timestampStart,
                offsetBy: Self.timestampLength,
                limitedBy: filename.endIndex
            ) ?? filename.endIndex
            let timestamp = String(filename[timestampStart..<timestampEnd])
            return RetainedExport(
                url: file.standardizedFileURL,
                logicalMilliseconds: milliseconds(for: timestamp)
            )
        }
    }

    private func isNewer(_ lhs: RetainedExport, _ rhs: RetainedExport) -> Bool {
        switch (lhs.logicalMilliseconds, rhs.logicalMilliseconds) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.url.lastPathComponent > rhs.url.lastPathComponent
        }
    }

    private func filenamePrefix(for role: DiagnosticsRole) -> String {
        "PartyBox-\(role.rawValue)-diagnostics-"
    }

    private func filenameExpression(prefix: String) throws -> NSRegularExpression {
        let escapedPrefix = NSRegularExpression.escapedPattern(for: prefix)
        let pattern = "^\(escapedPrefix)\\d{8}T\\d{6}\\.\\d{3}Z-"
            + "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
            + "[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\\.json$"
        return try NSRegularExpression(pattern: pattern)
    }

    private func milliseconds(for date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince1970 * 1_000))
    }

    private func milliseconds(for timestamp: String) -> Int64? {
        guard let date = timestampFormatter().date(from: timestamp) else { return nil }
        return milliseconds(for: date)
    }

    private func timestamp(for milliseconds: Int64) -> String {
        timestampFormatter().string(
            from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        )
    }

    private func timestampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        formatter.isLenient = false
        return formatter
    }
}
