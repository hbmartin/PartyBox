import Foundation

public enum DiagnosticsRole: String, Sendable {
    case host
    case controller
}

public enum RedactedDiagnosticsExporter {
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
        retentionLimit: Int = 5
    ) throws -> URL {
        let filenamePrefix = "PartyBox-\(role.rawValue)-diagnostics-"
        let url = directory.appendingPathComponent(
            "\(filenamePrefix)\(timestamp(for: now))-\(UUID().uuidString).json"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
        pruneOldExports(
            in: directory,
            filenamePrefix: filenamePrefix,
            retentionLimit: max(1, retentionLimit),
            preserving: url
        )
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
        preserving currentExport: URL
    ) {
        let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else { return }
        let escapedPrefix = NSRegularExpression.escapedPattern(for: filenamePrefix)
        let pattern = "^\(escapedPrefix)\\d{8}T\\d{6}\\.\\d{3}Z-"
            + "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
            + "[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\\.json$"
        guard let filenameExpression = try? NSRegularExpression(pattern: pattern) else { return }
        let currentExport = currentExport.standardizedFileURL
        let olderExports = files.filter { file in
            let filename = file.lastPathComponent
            let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
            return filenameExpression.firstMatch(in: filename, range: range) != nil
                && file.standardizedFileURL != currentExport
        }.sorted { lhs, rhs in
            let leftDate = try? lhs.resourceValues(forKeys: resourceKeys).contentModificationDate
            let rightDate = try? rhs.resourceValues(forKeys: resourceKeys).contentModificationDate
            if leftDate != rightDate {
                return (leftDate ?? .distantPast) > (rightDate ?? .distantPast)
            }
            return lhs.lastPathComponent > rhs.lastPathComponent
        }
        for expired in olderExports.dropFirst(max(0, retentionLimit - 1)) {
            try? FileManager.default.removeItem(at: expired)
        }
    }
}
