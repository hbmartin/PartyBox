import Foundation
import Network
import Dependencies

final class EventHub<Event: Sendable>: @unchecked Sendable {
    private struct Subscription {
        let continuation: AsyncStream<Event>.Continuation
        let onOverflow: @Sendable () -> Void
    }

    private let lock = NSLock()
    private let bufferLimit: Int
    private var subscriptions: [UUID: Subscription] = [:]

    init(bufferLimit: Int = 4_096) {
        precondition(bufferLimit > 0)
        self.bufferLimit = bufferLimit
    }

    func stream(onOverflow: @escaping @Sendable () -> Void) -> AsyncStream<Event> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingOldest(bufferLimit)) { continuation in
            lock.lock()
            subscriptions[id] = Subscription(
                continuation: continuation,
                onOverflow: onOverflow
            )
            lock.unlock()
            continuation.onTermination = { [weak self] _ in _ = self?.remove(id) }
        }
    }

    func yield(_ event: Event) {
        lock.lock()
        let current = Array(subscriptions)
        lock.unlock()
        for (id, subscription) in current {
            switch subscription.continuation.yield(event) {
            case .enqueued:
                break
            case .dropped:
                finishOverflowedSubscription(id: id, subscription: subscription)
            case .terminated:
                remove(id)
            @unknown default:
                finishOverflowedSubscription(id: id, subscription: subscription)
            }
        }
    }

    /// Finishes the streams that are currently subscribed. New calls to `stream()` create
    /// fresh subscriptions so a transport can still be restarted after it has stopped.
    func finish() {
        lock.lock()
        let current = subscriptions.values.map(\.continuation)
        subscriptions.removeAll()
        lock.unlock()
        for continuation in current { continuation.finish() }
    }

    deinit {
        finish()
    }

    @discardableResult
    private func remove(_ id: UUID) -> Subscription? {
        lock.lock()
        let subscription = subscriptions.removeValue(forKey: id)
        lock.unlock()
        return subscription
    }

    private func finishOverflowedSubscription(id: UUID, subscription: Subscription) {
        guard remove(id) != nil else { return }
        subscription.continuation.finish()
        subscription.onOverflow()
    }

#if DEBUG
    func simulateOverflowForTesting() {
        lock.lock()
        let current = Array(subscriptions)
        lock.unlock()
        for (id, subscription) in current {
            finishOverflowedSubscription(id: id, subscription: subscription)
        }
    }
#endif
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

package func isTerminalControlWriteError(_ error: any Error) -> Bool {
    !(error is CancellationError) && !(error is EncodingError)
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
