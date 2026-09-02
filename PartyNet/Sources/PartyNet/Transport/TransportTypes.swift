import Foundation
import Network

typealias HostControlProtocol = Coder<HostMessage, ClientMessage, NetworkJSONCoder>
typealias ClientControlProtocol = Coder<ClientMessage, HostMessage, NetworkJSONCoder>
typealias HostControlConnection = NetworkConnection<HostControlProtocol>
typealias ClientControlConnection = NetworkConnection<ClientControlProtocol>

enum PartyNetTransportError: Error, LocalizedError, Sendable {
    case timedOut(String)
    case unexpectedFirstMessage
    case invalidRemoteEndpoint
    case stopped

    var errorDescription: String? {
        switch self {
        case let .timedOut(operation): "Timed out while \(operation)."
        case .unexpectedFirstMessage: "The first controller message was not a hello."
        case .invalidRemoteEndpoint: "The host did not provide a usable network address."
        case .stopped: "The network session stopped."
        }
    }
}

func hostControlStack() -> HostControlProtocol {
    Coder(sending: HostMessage.self, receiving: ClientMessage.self, using: .json) {
        TCP()
            .noDelay(true)
            .keepalive(idleTimeInSeconds: 2, count: 3, intervalInSeconds: 1)
            .connectionTimeout(5)
    }
}

func clientControlStack() -> ClientControlProtocol {
    Coder(sending: ClientMessage.self, receiving: HostMessage.self, using: .json) {
        TCP()
            .noDelay(true)
            .keepalive(idleTimeInSeconds: 2, count: 3, intervalInSeconds: 1)
            .connectionTimeout(5)
    }
}

func withTimeout<T: Sendable>(
    _ duration: Duration,
    operationName: String,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw PartyNetTransportError.timedOut(operationName)
        }
        guard let result = try await group.next() else {
            throw PartyNetTransportError.stopped
        }
        group.cancelAll()
        return result
    }
}
