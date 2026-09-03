import Foundation
import Network
import OSLog

enum HostTransportEvent: Sendable {
    case hello(connectionID: UUID, hello: Hello)
    case message(connectionID: UUID, message: ClientMessage)
    case disconnected(connectionID: UUID)
    case failure(String)
}

enum HandshakeDecision: Sendable {
    case accept(Welcome)
    case reject(RejectReason)
}

actor HostTransport {
    nonisolated let events: AsyncStream<HostTransportEvent>

    private let eventContinuation: AsyncStream<HostTransportEvent>.Continuation
    private let inputs: InputStore
    private let logger = Logger(subsystem: "PartyNet", category: "HostTransport")

    private var tcpListener: NetworkListener<HostControlProtocol>?
    private var udpListener: NetworkListener<UDP>?
    private var listenerTasks: [Task<Void, Never>] = []
    private var controlTasks: [UUID: Task<Void, Never>] = [:]
    private var connections: [UUID: HostControlConnection] = [:]
    private var decisions: [UUID: CheckedContinuation<HandshakeDecision, Never>] = [:]
    private var tokenToPlayer: [UInt64: PlayerID] = [:]
    private var connectionTokens: [UUID: UInt64] = [:]
    private var boundUDPPort: UInt16?

    var udpPort: UInt16? { boundUDPPort }

    init(inputs: InputStore) {
        self.inputs = inputs
        var continuation: AsyncStream<HostTransportEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    func start(hostName: String, hostInstanceID: UUID, advertise: Bool = true) async throws -> UInt16 {
        stop()

        let udp = try NetworkListener<UDP>(
            for: nil,
            using: .parameters { UDP() }.peerToPeerIncluded(false)
        )
        udpListener = udp
        let transport = self
        let udpTask = Task { [udp, transport] in
            do {
                try await udp.run { connection in
                    await transport.receiveDatagrams(on: connection)
                }
            } catch is CancellationError {
                // Expected during stop.
            } catch {
                transport.eventContinuation.yield(.failure("UDP listener failed: \(error.localizedDescription)"))
            }
        }
        listenerTasks.append(udpTask)
        let udpPort = try await waitForPort(of: udp, operation: "starting the UDP listener")
        boundUDPPort = udpPort

        let provider: (any ListenerProvider)? = advertise
            ? BonjourListenerProvider(
                name: hostName,
                type: PartyNetConstants.serviceType,
                txtRecord: NWTXTRecord([
                    "v": String(PartyNetConstants.protocolVersion),
                    "id": hostInstanceID.uuidString,
                ])
            )
            : nil
        let tcp = try NetworkListener<HostControlProtocol>(
            for: provider,
            using: .parameters { hostControlStack() }.peerToPeerIncluded(false)
        )
        _ = tcp.newConnectionLimit(PartyNetConstants.maximumControllers + 8)
        tcpListener = tcp
        let tcpTask = Task { [tcp, transport] in
            do {
                try await tcp.run { connection in
                    await transport.receiveControl(on: connection)
                }
            } catch is CancellationError {
                // Expected during stop.
            } catch {
                transport.eventContinuation.yield(.failure("TCP listener failed: \(error.localizedDescription)"))
            }
        }
        listenerTasks.append(tcpTask)
        let tcpPort = try await waitForPort(of: tcp, operation: "starting the control listener")
        logger.info("PartyBox host ready on TCP \(tcpPort), UDP \(udpPort)")
        return tcpPort
    }

    func respond(to connectionID: UUID, with decision: HandshakeDecision) async {
        guard let connection = connections[connectionID],
              let continuation = decisions.removeValue(forKey: connectionID) else { return }
        do {
            switch decision {
            case let .reject(reason):
                try await connection.send(.rejected(reason))
            case let .accept(welcome):
                tokenToPlayer[welcome.sessionToken] = welcome.player.id
                connectionTokens[connectionID] = welcome.sessionToken
                try await connection.send(.welcome(welcome))
            }
            continuation.resume(returning: decision)
        } catch {
            continuation.resume(returning: .reject(.malformedHello))
        }
    }

    func send(_ message: HostMessage, to connectionID: UUID) async throws {
        guard let connection = connections[connectionID] else {
            throw PartyNetTransportError.stopped
        }
        try await connection.send(message)
    }

    func invalidate(token: UInt64) {
        tokenToPlayer.removeValue(forKey: token)
        if let connectionID = connectionTokens.first(where: { $0.value == token })?.key {
            connectionTokens.removeValue(forKey: connectionID)
        }
    }

    func disconnect(connectionID: UUID) {
        controlTasks.removeValue(forKey: connectionID)?.cancel()
    }

    func replace(connectionID: UUID) async {
        if let connection = connections[connectionID] {
            try? await connection.send(.rejected(.replaced))
        }
        disconnect(connectionID: connectionID)
    }

    func stop() {
        for continuation in decisions.values {
            continuation.resume(returning: .reject(.malformedHello))
        }
        decisions.removeAll()
        listenerTasks.forEach { $0.cancel() }
        listenerTasks.removeAll()
        controlTasks.values.forEach { $0.cancel() }
        controlTasks.removeAll()
        tcpListener = nil
        udpListener = nil
        connections.removeAll()
        connectionTokens.removeAll()
        tokenToPlayer.removeAll()
        boundUDPPort = nil
    }

    private func waitForPort<ApplicationProtocol: NetworkProtocolOptions>(
        of listener: NetworkListener<ApplicationProtocol>,
        operation: String
    ) async throws -> UInt16 {
        for _ in 0..<500 {
            if let port = listener.port, port.rawValue != 0 { return port.rawValue }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PartyNetTransportError.timedOut(operation)
    }

    private func receiveControl(on connection: HostControlConnection) async {
        let connectionID = UUID()
        connections[connectionID] = connection
        defer {
            controlTasks.removeValue(forKey: connectionID)
            connections.removeValue(forKey: connectionID)
            decisions.removeValue(forKey: connectionID)?.resume(returning: .reject(.malformedHello))
            if let token = connectionTokens.removeValue(forKey: connectionID) {
                tokenToPlayer.removeValue(forKey: token)
            }
            eventContinuation.yield(.disconnected(connectionID: connectionID))
        }

        do {
            let first = try await withTimeout(PartyNetConstants.helloTimeout, operationName: "waiting for controller hello") {
                try await connection.receive().content
            }
            guard case let .hello(hello) = first else {
                try? await connection.send(.rejected(.malformedHello))
                return
            }

            let decision = await withCheckedContinuation { continuation in
                decisions[connectionID] = continuation
                eventContinuation.yield(.hello(connectionID: connectionID, hello: hello))
            }

            switch decision {
            case .reject:
                return
            case .accept:
                break
            }

            let continuation = eventContinuation
            let receiveTask = Task { [connection, continuation] in
                do {
                    for try await message in connection.messages {
                        continuation.yield(.message(connectionID: connectionID, message: message.content))
                    }
                } catch is CancellationError {
                    // Duplicate replacement or host shutdown.
                } catch {
                    // The enclosing handler reports the disconnect below.
                }
            }
            controlTasks[connectionID] = receiveTask
            await receiveTask.value
        } catch is CancellationError {
            // Expected during shutdown.
        } catch {
            logger.debug("Control connection ended: \(error.localizedDescription)")
        }
    }

    private func receiveDatagrams(on connection: NetworkConnection<UDP>) async {
        do {
            while !Task.isCancelled {
                let packet = try await withTimeout(PartyNetConstants.udpIdleTimeout, operationName: "waiting for controller input") {
                    try await connection.receive().content
                }
                guard let frame = InputFrame(data: packet), let playerID = tokenToPlayer[frame.token] else {
                    continue
                }
                _ = inputs.update(frame, for: playerID)
            }
        } catch {
            logger.debug("UDP flow ended: \(error.localizedDescription)")
        }
    }
}
