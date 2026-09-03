import Foundation
import Network
import Dependencies

package typealias HostControlProtocol = Coder<HostMessage, ClientMessage, NetworkJSONCoder>
package typealias ClientControlProtocol = Coder<ClientMessage, HostMessage, NetworkJSONCoder>
package typealias HostControlConnection = NetworkConnection<HostControlProtocol>
package typealias ClientControlConnection = NetworkConnection<ClientControlProtocol>

package enum PartyNetTransportError: Error, LocalizedError, Sendable {
    case timedOut(String)
    case invalidRemoteEndpoint
    case stopped

    package var errorDescription: String? {
        switch self {
        case let .timedOut(operation): "Timed out while \(operation)."
        case .invalidRemoteEndpoint: "The host did not provide a usable network address."
        case .stopped: "The network session stopped."
        }
    }
}

package func hostControlStack() -> HostControlProtocol {
    Coder(sending: HostMessage.self, receiving: ClientMessage.self, using: .json) {
        TCP()
            .noDelay(true)
            .keepalive(idleTimeInSeconds: 2, count: 3, intervalInSeconds: 1)
            .connectionTimeout(5)
    }
}

package func clientControlStack() -> ClientControlProtocol {
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
    @Dependency(\.continuousClock) var dependencyClock
    let clock = AnyClock(dependencyClock)
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await clock.sleep(for: duration)
            throw PartyNetTransportError.timedOut(operationName)
        }
        guard let result = try await group.next() else {
            throw PartyNetTransportError.stopped
        }
        group.cancelAll()
        return result
    }
}
