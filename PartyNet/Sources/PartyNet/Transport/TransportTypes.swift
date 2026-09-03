import Foundation
import Network
import Dependencies

final class EventHub<Event: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]

    func stream() -> AsyncStream<Event> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.remove(id) }
        }
    }

    func yield(_ event: Event) {
        lock.lock()
        let current = Array(continuations.values)
        lock.unlock()
        for continuation in current { continuation.yield(event) }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}

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

package func waitForBoundPort<ApplicationProtocol: NetworkProtocolOptions>(
    of listener: NetworkListener<ApplicationProtocol>,
    clock: AnyClock<Duration>,
    operation: String,
    validate: @escaping @Sendable () async throws -> Void = {}
) async throws -> UInt16 {
    for _ in 0..<500 {
        try await validate()
        if let port = listener.port, port.rawValue != 0 { return port.rawValue }
        try Task.checkCancellation()
        try await clock.sleep(for: .milliseconds(10))
    }
    throw PartyNetTransportError.timedOut(operation)
}

package func waitForBoundPort<ApplicationProtocol: NetworkProtocolOptions>(
    of listener: NetworkListener<ApplicationProtocol>,
    operation: String
) async throws -> UInt16 {
    @Dependency(\.continuousClock) var continuousClock
    return try await waitForBoundPort(
        of: listener,
        clock: AnyClock(continuousClock),
        operation: operation
    )
}

package func withTimeout<T: Sendable, TimeoutError: Error & Sendable>(
    _ duration: Duration,
    clock: AnyClock<Duration>,
    timeoutError: @escaping @Sendable () -> TimeoutError,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await clock.sleep(for: duration)
            throw timeoutError()
        }
        guard let result = try await group.next() else { throw timeoutError() }
        group.cancelAll()
        return result
    }
}

package func withTimeout<T: Sendable, TimeoutError: Error & Sendable>(
    _ duration: Duration,
    timeoutError: @escaping @Sendable () -> TimeoutError,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    @Dependency(\.continuousClock) var dependencyClock
    return try await withTimeout(
        duration,
        clock: AnyClock(dependencyClock),
        timeoutError: timeoutError,
        operation: operation
    )
}

package func withTimeout<T: Sendable>(
    _ duration: Duration,
    clock: AnyClock<Duration>,
    operationName: String,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withTimeout(
        duration,
        clock: clock,
        timeoutError: { PartyNetTransportError.timedOut(operationName) },
        operation: operation
    )
}

package func withTimeout<T: Sendable>(
    _ duration: Duration,
    operationName: String,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    @Dependency(\.continuousClock) var dependencyClock
    return try await withTimeout(
        duration,
        clock: AnyClock(dependencyClock),
        operationName: operationName,
        operation: operation
    )
}
