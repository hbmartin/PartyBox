import Dependencies
import Foundation
import Network
import PartyNet

public actor NetworkFaultProxy {
    private struct BufferedDatagram: Sendable {
        let data: Data
        let token: UInt64
    }

    private let clock: AnyClock<Duration>
    private var profile: FaultProfile
    private var randomState: UInt64
    private var metrics = FaultMetrics()

    private var upstreamHost: NWEndpoint.Host?
    private var upstreamTCPPort: NWEndpoint.Port?
    private var downstreamTCPListener: NetworkListener<HostControlProtocol>?
    private var downstreamUDPListener: NetworkListener<UDP>?
    private var listenerTasks: [Task<Void, Never>] = []
    private var controlHandlerTasks: [UUID: Task<Void, Never>] = [:]
    private var udpHandlerTasks: [UUID: Task<Void, Never>] = [:]
    private var bridgeTasks: [UUID: [Task<Void, Never>]] = [:]
    private var bridgeWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var bridgeControllerIDs: [UUID: ControllerID] = [:]
    private var bridgeTokens: [UUID: UInt64] = [:]
    private var downstreamConnections: [UUID: HostControlConnection] = [:]
    private var upstreamConnections: [UUID: ClientControlConnection] = [:]
    private var upstreamUDPConnections: [UInt64: NetworkConnection<UDP>] = [:]
    private var upstreamUDPPorts: [UInt64: NWEndpoint.Port] = [:]
    private var reorderQueues: [UInt64: [BufferedDatagram]] = [:]
    private var packetOrdinal = 0
    private var lifecycleGeneration: UInt64 = 0

    public private(set) var tcpPort: UInt16?
    public private(set) var udpPort: UInt16?

    public init(profile: FaultProfile = .stable) {
        @Dependency(\.continuousClock) var continuousClock
        clock = AnyClock(continuousClock)
        self.profile = profile
        randomState = profile.seed == 0 ? 1 : profile.seed
    }

    @discardableResult
    public func start(upstreamHost: String = "127.0.0.1", upstreamTCPPort: UInt16) async throws -> (tcp: UInt16, udp: UInt16) {
        stop()
        let generation = lifecycleGeneration
        guard let tcpPort = NWEndpoint.Port(rawValue: upstreamTCPPort) else {
            throw PartyNetTransportError.invalidRemoteEndpoint
        }
        self.upstreamHost = NWEndpoint.Host(upstreamHost)
        self.upstreamTCPPort = tcpPort
        do {
            let udpParameters = NWParametersBuilder.parameters { UDP() }
                .localEndpoint(.hostPort(host: "127.0.0.1", port: .any))
                .localOnly(true)
                .peerToPeerIncluded(false)
            let udpListener = try NetworkListener<UDP>(for: nil, using: udpParameters)
            downstreamUDPListener = udpListener
            let proxy = self
            listenerTasks.append(Task { [udpListener, proxy] in
                do {
                    try await udpListener.run { connection in
                        await proxy.acceptDatagramConnection(connection, generation: generation)
                    }
                } catch is CancellationError {
                } catch {
                    await proxy.listenerFailed(generation: generation)
                }
            })
            let boundUDP = try await waitForPort(
                of: udpListener,
                operation: "starting fault-proxy UDP",
                generation: generation
            )
            guard lifecycleGeneration == generation else { throw PartyNetTransportError.stopped }
            udpPort = boundUDP

            let tcpParameters = NWParametersBuilder.parameters { hostControlStack() }
                .localEndpoint(.hostPort(host: "127.0.0.1", port: .any))
                .localOnly(true)
                .peerToPeerIncluded(false)
            let tcpListener = try NetworkListener<HostControlProtocol>(for: nil, using: tcpParameters)
            downstreamTCPListener = tcpListener
            listenerTasks.append(Task { [tcpListener, proxy] in
                do {
                    try await tcpListener.run { connection in
                        await proxy.acceptControlConnection(connection, generation: generation)
                    }
                } catch is CancellationError {
                } catch {
                    await proxy.listenerFailed(generation: generation)
                }
            })
            let boundTCP = try await waitForPort(
                of: tcpListener,
                operation: "starting fault-proxy TCP",
                generation: generation
            )
            guard lifecycleGeneration == generation else { throw PartyNetTransportError.stopped }
            self.tcpPort = boundTCP
            return (boundTCP, boundUDP)
        } catch {
            if lifecycleGeneration == generation { stop() }
            throw error
        }
    }

    public func setProfile(_ profile: FaultProfile) {
        self.profile = profile
        randomState = profile.seed == 0 ? 1 : profile.seed
        packetOrdinal = 0
        reorderQueues.removeAll()
    }

    public func reset() {
        setProfile(.stable)
        let activeTCPHandlers = metrics.activeTCPHandlers
        metrics = FaultMetrics()
        metrics.activeTCPBridges = downstreamConnections.count
        metrics.activeTCPHandlers = activeTCPHandlers
        metrics.activeUDPSessions = upstreamUDPPorts.count
    }

    public func currentProfile() -> FaultProfile { profile }

    public func currentMetrics() -> FaultMetrics { metrics }

    public func connectedControllerIDs() -> Set<ControllerID> {
        Set(bridgeControllerIDs.values)
    }

    public func updateUpstream(host: String = "127.0.0.1", tcpPort: UInt16) throws {
        guard let port = NWEndpoint.Port(rawValue: tcpPort) else {
            throw PartyNetTransportError.invalidRemoteEndpoint
        }
        upstreamHost = NWEndpoint.Host(host)
        upstreamTCPPort = port
        upstreamUDPConnections.removeAll()
        upstreamUDPPorts.removeAll()
        reorderQueues.removeAll()
        metrics.activeUDPSessions = 0
    }

    public func noteHostRestart() {
        metrics.hostRestarts += 1
    }

    public func cutTCP(controllerID: ControllerID? = nil) async {
        metrics.tcpCuts += 1
        let bridgeIDs = if let controllerID {
            bridgeControllerIDs.compactMap { bridgeID, bridgedControllerID in
                bridgedControllerID == controllerID ? bridgeID : nil
            }
        } else {
            Array(Set(downstreamConnections.keys).union(controlHandlerTasks.keys))
        }
        let handlers = bridgeIDs.compactMap { controlHandlerTasks[$0] }
        for bridgeID in bridgeIDs {
            // Cancel both bridge directions without synthesizing `.leave`: a network cut must
            // exercise the host's disconnect grace period, not the explicit-leave path.
            removeBridge(bridgeID)
        }
        for handler in handlers { await handler.value }
    }

    public func stop() {
        lifecycleGeneration &+= 1
        listenerTasks.forEach { $0.cancel() }
        listenerTasks.removeAll()
        controlHandlerTasks.values.forEach { $0.cancel() }
        controlHandlerTasks.removeAll()
        udpHandlerTasks.values.forEach { $0.cancel() }
        udpHandlerTasks.removeAll()
        for bridgeID in Array(downstreamConnections.keys) { removeBridge(bridgeID) }
        downstreamTCPListener = nil
        downstreamUDPListener = nil
        downstreamConnections.removeAll()
        upstreamConnections.removeAll()
        bridgeControllerIDs.removeAll()
        bridgeTokens.removeAll()
        upstreamUDPConnections.removeAll()
        upstreamUDPPorts.removeAll()
        reorderQueues.removeAll()
        metrics.activeTCPBridges = 0
        metrics.activeUDPSessions = 0
        tcpPort = nil
        udpPort = nil
    }

    private func listenerFailed(generation: UInt64) {
        guard lifecycleGeneration == generation else { return }
        // Listener state is observable through missing ports/failed client connections.
    }

    private func acceptControlConnection(
        _ downstream: HostControlConnection,
        generation: UInt64
    ) {
        guard lifecycleGeneration == generation else { return }
        let bridgeID = UUID()
        let proxy = self
        controlHandlerTasks[bridgeID] = Task { [downstream, proxy] in
            await proxy.receiveControl(
                on: downstream,
                bridgeID: bridgeID,
                generation: generation
            )
        }
    }

    private func receiveControl(
        on downstream: HostControlConnection,
        bridgeID: UUID,
        generation: UInt64
    ) async {
        guard !Task.isCancelled, lifecycleGeneration == generation else { return }
        guard let upstreamHost, let upstreamTCPPort, let proxyUDPPort = udpPort else { return }
        metrics.activeTCPHandlers += 1
        defer {
            metrics.activeTCPHandlers -= 1
            controlHandlerTasks.removeValue(forKey: bridgeID)
            removeBridge(bridgeID, cancelHandler: false)
        }
        let upstream = ClientControlConnection(
            to: .hostPort(host: upstreamHost, port: upstreamTCPPort),
            using: .parameters { clientControlStack() }.peerToPeerIncluded(false)
        )
        downstreamConnections[bridgeID] = downstream
        upstreamConnections[bridgeID] = upstream
        metrics.tcpConnections += 1
        metrics.activeTCPBridges = downstreamConnections.count

        do {
            let first = try await withProxyTimeout(
                operationName: "waiting for fault-proxy downstream hello"
            ) {
                try await downstream.receive().content
            }
            guard case let .hello(hello) = first else {
                try? await downstream.send(.rejected(.malformedHello))
                return
            }
            bridgeControllerIDs[bridgeID] = hello.controllerID
            try await upstream.send(.hello(hello))
            let response = try await withProxyTimeout(
                operationName: "waiting for fault-proxy upstream welcome"
            ) {
                try await upstream.receive().content
            }
            guard lifecycleGeneration == generation,
                  downstreamConnections[bridgeID] != nil else { return }
            switch response {
            case let .welcome(welcome):
                bridgeTokens[bridgeID] = welcome.sessionToken
                upstreamUDPPorts[welcome.sessionToken] = try requirePort(welcome.udpPort)
                metrics.activeUDPSessions = upstreamUDPPorts.count
                let proxiedWelcome = Welcome(
                    player: welcome.player,
                    udpPort: proxyUDPPort,
                    sessionToken: welcome.sessionToken,
                    hostName: welcome.hostName,
                    hostInstanceID: welcome.hostInstanceID,
                    protocolVersion: welcome.protocolVersion
                )
                try await downstream.send(.welcome(proxiedWelcome))
            default:
                try await downstream.send(response)
                return
            }

            await withCheckedContinuation { continuation in
                bridgeWaiters[bridgeID] = continuation
                let clientToHost = Task { [downstream] in
                    do {
                        for try await message in downstream.messages {
                            try await self.forwardToHost(message.content, bridgeID: bridgeID)
                            if case .leave = message.content { break }
                        }
                    } catch {}
                    self.bridgeDirectionEnded(bridgeID)
                }
                let hostToClient = Task { [upstream] in
                    do {
                        for try await message in upstream.messages {
                            try await self.forwardToClient(message.content, bridgeID: bridgeID)
                        }
                    } catch {}
                    self.bridgeDirectionEnded(bridgeID)
                }
                bridgeTasks[bridgeID] = [clientToHost, hostToClient]
            }
        } catch {
            // Either side closing is an expected fault-proxy lifecycle event.
        }
    }

    private func forwardToHost(_ message: ClientMessage, bridgeID: UUID) async throws {
        guard let upstream = upstreamConnections[bridgeID] else {
            throw PartyNetTransportError.stopped
        }
        try await upstream.send(message)
        metrics.tcpMessagesClientToHost += 1
    }

    private func forwardToClient(_ message: HostMessage, bridgeID: UUID) async throws {
        guard let downstream = downstreamConnections[bridgeID] else {
            throw PartyNetTransportError.stopped
        }
        try await downstream.send(message)
        metrics.tcpMessagesHostToClient += 1
    }

    private func bridgeDirectionEnded(_ bridgeID: UUID) {
        removeBridge(bridgeID)
    }

    private func removeBridge(_ bridgeID: UUID, cancelHandler: Bool = true) {
        if cancelHandler { controlHandlerTasks.removeValue(forKey: bridgeID)?.cancel() }
        bridgeTasks.removeValue(forKey: bridgeID)?.forEach { $0.cancel() }
        downstreamConnections.removeValue(forKey: bridgeID)
        upstreamConnections.removeValue(forKey: bridgeID)
        bridgeControllerIDs.removeValue(forKey: bridgeID)
        if let token = bridgeTokens.removeValue(forKey: bridgeID) {
            upstreamUDPConnections.removeValue(forKey: token)
            upstreamUDPPorts.removeValue(forKey: token)
            reorderQueues.removeValue(forKey: token)
            metrics.activeUDPSessions = upstreamUDPPorts.count
        }
        bridgeWaiters.removeValue(forKey: bridgeID)?.resume()
        metrics.activeTCPBridges = downstreamConnections.count
    }

    private func acceptDatagramConnection(
        _ connection: NetworkConnection<UDP>,
        generation: UInt64
    ) {
        guard lifecycleGeneration == generation else { return }
        let handlerID = UUID()
        let proxy = self
        udpHandlerTasks[handlerID] = Task { [connection, proxy] in
            await proxy.receiveDatagrams(
                on: connection,
                handlerID: handlerID,
                generation: generation
            )
        }
    }

    private func receiveDatagrams(
        on connection: NetworkConnection<UDP>,
        handlerID: UUID,
        generation: UInt64
    ) async {
        defer { udpHandlerTasks.removeValue(forKey: handlerID) }
        do {
            while !Task.isCancelled {
                guard lifecycleGeneration == generation else { return }
                let data = try await connection.receive().content
                await acceptDatagram(data)
            }
        } catch {
            // Datagram flows are intentionally short-lived and lossy.
        }
    }

    private func acceptDatagram(_ data: Data) async {
        metrics.udpReceived += 1
        guard let frame = InputFrame(data: data), upstreamUDPPorts[frame.token] != nil else {
            metrics.udpRejected += 1
            return
        }
        packetOrdinal += 1
        if shouldDrop(packetOrdinal: packetOrdinal) {
            metrics.udpDropped += 1
            return
        }

        let packet = BufferedDatagram(data: data, token: frame.token)
        guard profile.reorderWindow > 1 else {
            await forward(packet)
            return
        }
        reorderQueues[frame.token, default: []].append(packet)
        guard reorderQueues[frame.token, default: []].count >= profile.reorderWindow else { return }
        let batch = Array(reorderQueues[frame.token, default: []].prefix(profile.reorderWindow))
        reorderQueues[frame.token]?.removeFirst(profile.reorderWindow)
        metrics.udpReordered += batch.count
        for item in batch.reversed() { await forward(item) }
    }

    private func forward(_ packet: BufferedDatagram) async {
        let delay = nextDelayMilliseconds()
        if delay > 0 {
            metrics.udpDelayed += 1
            do { try await clock.sleep(for: .milliseconds(delay)) } catch { return }
        }
        guard let upstreamHost, let port = upstreamUDPPorts[packet.token] else {
            metrics.udpRejected += 1
            return
        }
        let connection: NetworkConnection<UDP>
        if let existing = upstreamUDPConnections[packet.token] {
            connection = existing
        } else {
            connection = NetworkConnection<UDP>(
                to: .hostPort(host: upstreamHost, port: port),
                using: .parameters { UDP() }.peerToPeerIncluded(false)
            )
            upstreamUDPConnections[packet.token] = connection
        }
        do {
            try await connection.send(packet.data)
            metrics.udpForwarded += 1
        } catch {
            upstreamUDPConnections.removeValue(forKey: packet.token)
            metrics.udpRejected += 1
        }
    }

    private func shouldDrop(packetOrdinal: Int) -> Bool {
        switch profile.udpDropPolicy.validated() {
        case .none:
            return false
        case let .every(interval):
            return packetOrdinal.isMultiple(of: interval)
        case let .rate(rate):
            return nextUnitRandom() < rate
        }
    }

    private func nextDelayMilliseconds() -> Int {
        guard profile.jitterMilliseconds > 0 else { return profile.delayMilliseconds }
        let width = profile.jitterMilliseconds * 2 + 1
        let offset = Int(nextRandom() % UInt64(width)) - profile.jitterMilliseconds
        return max(profile.delayMilliseconds + offset, 0)
    }

    private func nextUnitRandom() -> Double {
        Double(nextRandom() >> 11) / Double(UInt64(1) << 53)
    }

    private func nextRandom() -> UInt64 {
        randomState = randomState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return randomState
    }

    private func requirePort(_ rawValue: UInt16) throws -> NWEndpoint.Port {
        guard let port = NWEndpoint.Port(rawValue: rawValue) else {
            throw PartyNetTransportError.invalidRemoteEndpoint
        }
        return port
    }

    private func waitForPort<ApplicationProtocol: NetworkProtocolOptions>(
        of listener: NetworkListener<ApplicationProtocol>,
        operation: String,
        generation: UInt64
    ) async throws -> UInt16 {
        for _ in 0..<500 {
            guard lifecycleGeneration == generation else { throw PartyNetTransportError.stopped }
            if let port = listener.port, port.rawValue != 0 { return port.rawValue }
            try Task.checkCancellation()
            try await clock.sleep(for: .milliseconds(10))
        }
        throw PartyNetTransportError.timedOut(operation)
    }

    private func withProxyTimeout<T: Sendable>(
        _ duration: Duration = PartyNetConstants.helloTimeout,
        operationName: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let clock = clock
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
}
