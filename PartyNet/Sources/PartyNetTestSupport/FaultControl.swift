import Foundation
import PartyNet

public enum FaultControlRequest: Codable, Equatable, Sendable {
    case reset
    case udp(dropRate: Double, delayMilliseconds: Int, jitterMilliseconds: Int, reorderWindow: Int, lossScope: UDPLossScope? = nil)
    case cutTCP
    case restartHost
    case metrics
}

public struct FaultControlResponse: Codable, Equatable, Sendable {
    public let succeeded: Bool
    public let message: String
    public let metadata: FaultRigMetadata?
    public let profile: FaultProfile?
    public let metrics: FaultMetrics
    public let hostInputActivity: [InputActivity]

    package func failureMessage(for request: FaultControlRequest) -> String? {
        guard succeeded else { return message }
        guard case let .udp(_, _, _, _, requested?) = request,
              profile?.lossScope != requested else { return nil }
        let reported = profile?.lossScope.rawValue ?? "no profile"
        return "Requested UDP loss scope \(requested.rawValue), but the server reported \(reported)."
    }

    public init(
        succeeded: Bool,
        message: String,
        metadata: FaultRigMetadata? = nil,
        profile: FaultProfile? = nil,
        metrics: FaultMetrics = FaultMetrics(),
        hostInputActivity: [InputActivity] = []
    ) {
        self.succeeded = succeeded
        self.message = message
        self.metadata = metadata
        self.profile = profile
        self.metrics = metrics
        self.hostInputActivity = hostInputActivity
    }

    private enum CodingKeys: String, CodingKey {
        case succeeded
        case message
        case metadata
        case profile
        case metrics
        case hostInputActivity
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        succeeded = try container.decode(Bool.self, forKey: .succeeded)
        message = try container.decode(String.self, forKey: .message)
        metadata = try container.decodeIfPresent(FaultRigMetadata.self, forKey: .metadata)
        profile = try container.decodeIfPresent(FaultProfile.self, forKey: .profile)
        metrics = try container.decode(FaultMetrics.self, forKey: .metrics)
        hostInputActivity =
            try container.decodeIfPresent(
                [InputActivity].self,
                forKey: .hostInputActivity
            ) ?? []
    }
}
