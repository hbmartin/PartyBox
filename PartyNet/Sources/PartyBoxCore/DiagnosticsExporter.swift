import Foundation
import Synchronization

public enum DiagnosticsRole: String, Sendable {
    case host
    case controller
}

public enum RedactedDiagnosticsExporter {
    private struct RetainedExport {
        let url: URL
        var modificationDate: Date
    }

    private static let retentionLock = Mutex(())

    public static func write<Report: Encodable>(
        _ report: Report,
        role: DiagnosticsRole
    ) throws -> URL {
        try write(
            report,
            role: role,
            directory: FileManager.default.temporaryDirectory
        )
    }

    static func write<Report: Encodable>(
        _ report: Report,
        role: DiagnosticsRole,
        directory: URL,
        now: Date = Date(),
        retentionLimit: Int = 5,
        modificationDateProvider: (URL) throws -> Date? = { file in
            try file.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
        }
    ) throws -> URL {
        let filenamePrefix = "PartyBox-\(role.rawValue)-diagnostics-"
        let url = directory.appendingPathComponent(
            "\(filenamePrefix)\(timestamp(for: now))-\(UUID().uuidString).json"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
        do {
            try retentionLock.withLock { _ in
                try pruneOldExports(
                    in: directory,
                    filenamePrefix: filenamePrefix,
                    retentionLimit: max(1, retentionLimit),
                    preserving: url,
                    modificationDateProvider: modificationDateProvider
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    private static func timestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return formatter.string(from: date)
    }

    private static func pruneOldExports(
        in directory: URL,
        filenamePrefix: String,
        retentionLimit: Int,
        preserving currentExport: URL,
        modificationDateProvider: (URL) throws -> Date?
    ) throws {
        let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey]
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )
        let escapedPrefix = NSRegularExpression.escapedPattern(for: filenamePrefix)
        let pattern = "^\(escapedPrefix)\\d{8}T\\d{6}\\.\\d{3}Z-"
            + "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
            + "[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\\.json$"
        let filenameExpression = try NSRegularExpression(pattern: pattern)
        let currentExport = currentExport.standardizedFileURL
        var retainedExports: [RetainedExport] = []
        for file in files {
            let filename = file.lastPathComponent
            let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
            guard filenameExpression.firstMatch(in: filename, range: range) != nil else { continue }
            let standardizedFile = file.standardizedFileURL
            let modificationDate: Date
            do {
                guard let date = try modificationDateProvider(file) else {
                    if standardizedFile == currentExport {
                        throw CocoaError(.fileReadUnknown)
                    }
                    continue
                }
                modificationDate = date
            } catch {
                if standardizedFile == currentExport { throw error }
                continue
            }
            retainedExports.append(RetainedExport(
                url: standardizedFile,
                modificationDate: modificationDate
            ))
        }

        guard let currentIndex = retainedExports.firstIndex(where: { $0.url == currentExport }) else {
            throw CocoaError(.fileReadUnknown)
        }
        let currentModificationDate = retainedExports[currentIndex].modificationDate
        if let newestPriorDate = retainedExports.indices
            .filter({ $0 != currentIndex })
            .map({ retainedExports[$0].modificationDate })
            .max(), currentModificationDate <= newestPriorDate {
            let logicalModificationDate = newestPriorDate.addingTimeInterval(1)
            try FileManager.default.setAttributes(
                [.modificationDate: logicalModificationDate],
                ofItemAtPath: currentExport.path
            )
            retainedExports[currentIndex].modificationDate = logicalModificationDate
        }

        let olderExports = retainedExports.filter {
            $0.url != currentExport
        }.sorted { lhs, rhs in
            if lhs.modificationDate != rhs.modificationDate {
                return lhs.modificationDate > rhs.modificationDate
            }
            return lhs.url.lastPathComponent > rhs.url.lastPathComponent
        }
        for expired in olderExports.dropFirst(max(0, retentionLimit - 1)) {
            try? FileManager.default.removeItem(at: expired.url)
        }
    }
}
