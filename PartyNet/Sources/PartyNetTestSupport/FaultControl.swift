import Foundation

public enum FaultControlRequest: Codable, Equatable, Sendable {
    case reset
    case udp(dropRate: Double, delayMilliseconds: Int, jitterMilliseconds: Int, reorderWindow: Int)
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

    public init(
        succeeded: Bool,
        message: String,
        metadata: FaultRigMetadata? = nil,
        profile: FaultProfile? = nil,
        metrics: FaultMetrics = FaultMetrics()
    ) {
        self.succeeded = succeeded
        self.message = message
        self.metadata = metadata
        self.profile = profile
        self.metrics = metrics
    }
}
