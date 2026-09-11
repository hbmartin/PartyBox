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
        directory: URL
    ) throws -> URL {
        let url = directory.appendingPathComponent("PartyBox-\(role.rawValue)-diagnostics.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
        return url
    }
}
