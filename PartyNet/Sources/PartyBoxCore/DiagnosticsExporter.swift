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
        try? FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: url.path
        )
        pruneOldExports(
            in: directory,
            filenamePrefix: filenamePrefix,
            retentionLimit: max(1, retentionLimit)
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
        retentionLimit: Int
    ) {
        let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else { return }
        let exports = files.filter {
            isExportFilename($0.lastPathComponent, filenamePrefix: filenamePrefix)
        }.sorted { lhs, rhs in
            let leftDate = try? lhs.resourceValues(forKeys: resourceKeys).contentModificationDate
            let rightDate = try? rhs.resourceValues(forKeys: resourceKeys).contentModificationDate
            if leftDate != rightDate {
                return (leftDate ?? .distantPast) > (rightDate ?? .distantPast)
            }
            return lhs.lastPathComponent > rhs.lastPathComponent
        }
        for expired in exports.dropFirst(retentionLimit) {
            try? FileManager.default.removeItem(at: expired)
        }
    }

    private static func isExportFilename(_ filename: String, filenamePrefix: String) -> Bool {
        let escapedPrefix = NSRegularExpression.escapedPattern(for: filenamePrefix)
        let pattern = "^\(escapedPrefix)\\d{8}T\\d{6}\\.\\d{3}Z-"
            + "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
            + "[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\\.json$"
        return filename.range(of: pattern, options: .regularExpression) != nil
    }
}
