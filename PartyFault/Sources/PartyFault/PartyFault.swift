import Foundation
import Network

public enum TrafficDirection: String, Codable, CaseIterable, Sendable {
    case clientToServer
    case serverToClient
}

public enum TCPFailureMode: String, Codable, Sendable {
    case none
    case blackhole
    case cut
    case reset
}

public struct UDPImpairment: Codable, Equatable, Sendable {
    public let lossRate: Double
    public let delayMilliseconds: Int
    public let jitterMilliseconds: Int
    public let duplicateRate: Double
    public let reorderWindow: Int

    public init(
        lossRate: Double = 0,
        delayMilliseconds: Int = 0,
        jitterMilliseconds: Int = 0,
        duplicateRate: Double = 0,
        reorderWindow: Int = 1
    ) {
        self.lossRate = Self.rate(lossRate)
        self.delayMilliseconds = Self.milliseconds(delayMilliseconds)
        self.jitterMilliseconds = Self.milliseconds(jitterMilliseconds)
        self.duplicateRate = Self.rate(duplicateRate)
        self.reorderWindow = min(max(reorderWindow, 1), 1_024)
    }

    private static func rate(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }

    private static func milliseconds(_ value: Int) -> Int { min(max(value, 0), 60_000) }

    private enum CodingKeys: String, CodingKey {
        case lossRate, delayMilliseconds, jitterMilliseconds, duplicateRate, reorderWindow
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            lossRate: try values.decodeIfPresent(Double.self, forKey: .lossRate) ?? 0,
            delayMilliseconds: try values.decodeIfPresent(Int.self, forKey: .delayMilliseconds) ?? 0,
            jitterMilliseconds: try values.decodeIfPresent(Int.self, forKey: .jitterMilliseconds) ?? 0,
            duplicateRate: try values.decodeIfPresent(Double.self, forKey: .duplicateRate) ?? 0,
            reorderWindow: try values.decodeIfPresent(Int.self, forKey: .reorderWindow) ?? 1
        )
    }
}

public struct TCPImpairment: Codable, Equatable, Sendable {
    public let delayMilliseconds: Int
    public let jitterMilliseconds: Int
    public let throttleBytesPerSecond: Int?
    public let failure: TCPFailureMode

    public init(
        delayMilliseconds: Int = 0,
        jitterMilliseconds: Int = 0,
        throttleBytesPerSecond: Int? = nil,
        failure: TCPFailureMode = .none
    ) {
        self.delayMilliseconds = min(max(delayMilliseconds, 0), 60_000)
        self.jitterMilliseconds = min(max(jitterMilliseconds, 0), 60_000)
        self.throttleBytesPerSecond = throttleBytesPerSecond.map { min(max($0, 1), 1_000_000_000) }
        self.failure = failure
    }

    private enum CodingKeys: String, CodingKey {
        case delayMilliseconds, jitterMilliseconds, throttleBytesPerSecond, failure
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            delayMilliseconds: try values.decodeIfPresent(Int.self, forKey: .delayMilliseconds) ?? 0,
            jitterMilliseconds: try values.decodeIfPresent(Int.self, forKey: .jitterMilliseconds) ?? 0,
            throttleBytesPerSecond: try values.decodeIfPresent(Int.self, forKey: .throttleBytesPerSecond),
            failure: try values.decodeIfPresent(TCPFailureMode.self, forKey: .failure) ?? .none
        )
    }
}

public struct LinkImpairment: Codable, Equatable, Sendable {
    public let udp: UDPImpairment
    public let tcp: TCPImpairment

    public init(udp: UDPImpairment = .init(), tcp: TCPImpairment = .init()) {
        self.udp = udp
        self.tcp = tcp
    }
}

public struct FaultProfile: Codable, Equatable, Sendable {
    public let seed: UInt64
    public let clientToServer: LinkImpairment
    public let serverToClient: LinkImpairment

    public init(
        seed: UInt64 = 1,
        clientToServer: LinkImpairment = .init(),
        serverToClient: LinkImpairment = .init()
    ) {
        self.seed = seed == 0 ? 1 : seed
        self.clientToServer = clientToServer
        self.serverToClient = serverToClient
    }

    public static let stable = FaultProfile()

    private enum CodingKeys: String, CodingKey { case seed, clientToServer, serverToClient }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            seed: try values.decodeIfPresent(UInt64.self, forKey: .seed) ?? 1,
            clientToServer: try values.decodeIfPresent(LinkImpairment.self, forKey: .clientToServer) ?? .init(),
            serverToClient: try values.decodeIfPresent(LinkImpairment.self, forKey: .serverToClient) ?? .init()
        )
    }

    public func link(for direction: TrafficDirection) -> LinkImpairment {
        direction == .clientToServer ? clientToServer : serverToClient
    }
}

public struct DirectionMetrics: Codable, Equatable, Sendable {
    public var tcpBytesReceived: UInt64 = 0
    public var tcpBytesForwarded: UInt64 = 0
    public var tcpChunksBlackholed: UInt64 = 0
    public var udpDatagramsReceived: UInt64 = 0
    public var udpDatagramsForwarded: UInt64 = 0
    public var udpDatagramsDropped: UInt64 = 0
    public var udpDatagramsDuplicated: UInt64 = 0
    public var udpDatagramsReordered: UInt64 = 0
    public var delayedUnits: UInt64 = 0

    public init() {}
}

public struct FaultMetrics: Codable, Equatable, Sendable {
    public var acceptedTCPConnections: UInt64 = 0
    public var acceptedUDPFlows: UInt64 = 0
    public var activeTCPConnections: Int = 0
    public var activeUDPFlows: Int = 0
    public var forcedCuts: UInt64 = 0
    public var clientToServer = DirectionMetrics()
    public var serverToClient = DirectionMetrics()

    public init() {}
}

public struct ProxyEndpoints: Codable, Equatable, Sendable {
    public let host: String
    public let tcpPort: UInt16
    public let udpPort: UInt16
    public let controlPort: UInt16

    public init(host: String, tcpPort: UInt16, udpPort: UInt16, controlPort: UInt16) {
        self.host = host
        self.tcpPort = tcpPort
        self.udpPort = udpPort
        self.controlPort = controlPort
    }
}

public enum ControlRequest: Codable, Equatable, Sendable {
    case profile(FaultProfile)
    case metrics
    case resetMetrics
    case cutConnections
}

public struct ControlResponse: Codable, Equatable, Sendable {
    public let succeeded: Bool
    public let message: String
    public let profile: FaultProfile
    public let metrics: FaultMetrics

    public init(succeeded: Bool, message: String, profile: FaultProfile, metrics: FaultMetrics) {
        self.succeeded = succeeded
        self.message = message
        self.profile = profile
        self.metrics = metrics
    }
}

public struct UDPDeliveryPlan: Equatable, Sendable {
    public let delays: [Duration]
    public var isDropped: Bool { delays.isEmpty }
}

public enum TCPForwardDecision: Equatable, Sendable {
    case forward(after: Duration)
    case blackhole
    case terminate(reset: Bool)
}

public actor ImpairmentEngine {
    private var profile: FaultProfile
    private var randomState: UInt64

    public init(profile: FaultProfile = .stable) {
        self.profile = profile
        randomState = profile.seed
    }

    public func setProfile(_ value: FaultProfile) {
        profile = value
        randomState = value.seed
    }

    public func currentProfile() -> FaultProfile { profile }

    public func udpPlan(direction: TrafficDirection) -> UDPDeliveryPlan {
        let value = profile.link(for: direction).udp
        guard nextUnit() >= value.lossRate else { return UDPDeliveryPlan(delays: []) }
        let first = Duration.milliseconds(delay(base: value.delayMilliseconds, jitter: value.jitterMilliseconds))
        if nextUnit() < value.duplicateRate {
            let duplicate = first + .milliseconds(max(1, delay(base: 2, jitter: value.jitterMilliseconds)))
            return UDPDeliveryPlan(delays: [first, duplicate])
        }
        return UDPDeliveryPlan(delays: [first])
    }

    public func tcpDecision(direction: TrafficDirection, byteCount: Int) -> TCPForwardDecision {
        let value = profile.link(for: direction).tcp
        switch value.failure {
        case .blackhole: return .blackhole
        case .cut: return .terminate(reset: false)
        case .reset: return .terminate(reset: true)
        case .none:
            var milliseconds = delay(base: value.delayMilliseconds, jitter: value.jitterMilliseconds)
            if let rate = value.throttleBytesPerSecond {
                milliseconds += Int(ceil((Double(max(0, byteCount)) / Double(rate)) * 1_000))
            }
            return .forward(after: .milliseconds(milliseconds))
        }
    }

    private func delay(base: Int, jitter: Int) -> Int {
        guard jitter > 0 else { return base }
        let width = UInt64((jitter * 2) + 1)
        return max(0, base + Int(nextRandom() % width) - jitter)
    }

    private func nextUnit() -> Double { Double(nextRandom() >> 11) / Double(UInt64(1) << 53) }

    private func nextRandom() -> UInt64 {
        randomState = randomState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return randomState
    }
}

public enum PartyFaultError: Error, LocalizedError, Sendable {
    case invalidPort
    case listenerDidNotStart
    case forcedTermination(reset: Bool)

    public var errorDescription: String? {
        switch self {
        case .invalidPort: "A TCP or UDP port was invalid."
        case .listenerDidNotStart: "A proxy listener did not become ready."
        case .forcedTermination(let reset): reset ? "Connection reset by fault profile." : "Connection cut by fault profile."
        }
    }
}

public actor GenericFaultProxy {
    private let engine: ImpairmentEngine
    private var metrics = FaultMetrics()
    private var tcpListener: NetworkListener<TCP>?
    private var udpListener: NetworkListener<UDP>?
    private var listenerTasks: [Task<Void, Never>] = []
    private var flowTasks: [UUID: Task<Void, Never>] = [:]
    private var generation: UInt64 = 0
    private var upstreamHost = NWEndpoint.Host("127.0.0.1")
    private var upstreamTCPPort = NWEndpoint.Port.any
    private var upstreamUDPPort = NWEndpoint.Port.any

    public init(profile: FaultProfile = .stable) { engine = ImpairmentEngine(profile: profile) }

    deinit {
        listenerTasks.forEach { $0.cancel() }
        flowTasks.values.forEach { $0.cancel() }
    }

    public func start(
        upstreamHost: String,
        upstreamTCPPort: UInt16,
        upstreamUDPPort: UInt16,
        bindHost: String = "127.0.0.1"
    ) async throws -> (tcp: UInt16, udp: UInt16) {
        stop()
        guard upstreamTCPPort > 0, upstreamUDPPort > 0,
              let tcpPort = NWEndpoint.Port(rawValue: upstreamTCPPort),
              let udpPort = NWEndpoint.Port(rawValue: upstreamUDPPort) else { throw PartyFaultError.invalidPort }
        self.upstreamHost = NWEndpoint.Host(upstreamHost)
        self.upstreamTCPPort = tcpPort
        self.upstreamUDPPort = udpPort
        let currentGeneration = generation

        let tcpParameters = NWParametersBuilder.parameters { TCP().noDelay(true) }
            .localEndpoint(.hostPort(host: NWEndpoint.Host(bindHost), port: .any))
            .localOnly(Self.isLoopback(bindHost))
            .peerToPeerIncluded(false)
        let tcpListener = try NetworkListener<TCP>(for: nil, using: tcpParameters)
        self.tcpListener = tcpListener
        listenerTasks.append(Task { [tcpListener] in
            do { try await tcpListener.run { self.acceptTCP($0, generation: currentGeneration) } } catch {}
        })

        let udpParameters = NWParametersBuilder.parameters { UDP() }
            .localEndpoint(.hostPort(host: NWEndpoint.Host(bindHost), port: .any))
            .localOnly(Self.isLoopback(bindHost))
            .peerToPeerIncluded(false)
        let udpListener = try NetworkListener<UDP>(for: nil, using: udpParameters)
        self.udpListener = udpListener
        listenerTasks.append(Task { [udpListener] in
            do { try await udpListener.run { self.acceptUDP($0, generation: currentGeneration) } } catch {}
        })

        let boundTCP = try await boundPort(tcpListener)
        let boundUDP = try await boundPort(udpListener)
        return (boundTCP, boundUDP)
    }

    public func stop() {
        generation &+= 1
        listenerTasks.forEach { $0.cancel() }
        listenerTasks.removeAll()
        flowTasks.values.forEach { $0.cancel() }
        flowTasks.removeAll()
        tcpListener = nil
        udpListener = nil
        metrics.activeTCPConnections = 0
        metrics.activeUDPFlows = 0
    }

    public func setProfile(_ profile: FaultProfile) async { await engine.setProfile(profile) }
    public func currentProfile() async -> FaultProfile { await engine.currentProfile() }
    public func currentMetrics() -> FaultMetrics { metrics }

    public func resetMetrics() {
        let tcp = metrics.activeTCPConnections
        let udp = metrics.activeUDPFlows
        metrics = FaultMetrics()
        metrics.activeTCPConnections = tcp
        metrics.activeUDPFlows = udp
    }

    public func cutConnections() {
        metrics.forcedCuts += 1
        flowTasks.values.forEach { $0.cancel() }
        flowTasks.removeAll()
        metrics.activeTCPConnections = 0
        metrics.activeUDPFlows = 0
    }

    private func acceptTCP(_ downstream: NetworkConnection<TCP>, generation: UInt64) {
        guard generation == self.generation else { return }
        let id = UUID()
        metrics.acceptedTCPConnections += 1
        metrics.activeTCPConnections += 1
        let upstream = NetworkConnection<TCP>(
            to: .hostPort(host: upstreamHost, port: upstreamTCPPort),
            using: .parameters { TCP().noDelay(true) }
                .peerToPeerIncluded(false)
        )
        flowTasks[id] = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.forwardTCP(from: downstream, to: upstream, direction: .clientToServer) }
                group.addTask { await self.forwardTCP(from: upstream, to: downstream, direction: .serverToClient) }
                await group.next()
                group.cancelAll()
            }
            self.finishTCP(id)
        }
    }

    private func forwardTCP(
        from source: NetworkConnection<TCP>,
        to destination: NetworkConnection<TCP>,
        direction: TrafficDirection
    ) async {
        do {
            while !Task.isCancelled {
                let message = try await source.receive(atMost: 65_536)
                let data = message.content
                if data.isEmpty && message.metadata.endOfStream {
                    try? await destination.send(Data(), endOfStream: true)
                    return
                }
                guard !data.isEmpty else { continue }
                noteTCPReceived(data.count, direction: direction)
                switch await engine.tcpDecision(direction: direction, byteCount: data.count) {
                case .blackhole:
                    noteTCPBlackhole(direction: direction)
                case .terminate(let reset):
                    if !reset { try? await destination.send(Data(), endOfStream: true) }
                    return
                case .forward(let delay):
                    if delay > .zero { try await Task.sleep(for: delay); noteDelay(direction: direction) }
                    try await destination.send(data, endOfStream: message.metadata.endOfStream)
                    noteTCPForwarded(data.count, direction: direction)
                    if message.metadata.endOfStream { return }
                }
            }
        } catch {}
    }

    private func acceptUDP(_ downstream: NetworkConnection<UDP>, generation: UInt64) {
        guard generation == self.generation else { return }
        let id = UUID()
        metrics.acceptedUDPFlows += 1
        metrics.activeUDPFlows += 1
        let upstream = NetworkConnection<UDP>(
            to: .hostPort(host: upstreamHost, port: upstreamUDPPort),
            using: .parameters { UDP() }
                .peerToPeerIncluded(false)
        )
        flowTasks[id] = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.forwardUDP(from: downstream, to: upstream, direction: .clientToServer) }
                group.addTask { await self.forwardUDP(from: upstream, to: downstream, direction: .serverToClient) }
                await group.next()
                group.cancelAll()
            }
            self.finishUDP(id)
        }
    }

    private func forwardUDP(
        from source: NetworkConnection<UDP>,
        to destination: NetworkConnection<UDP>,
        direction: TrafficDirection
    ) async {
        var reorderBuffer: [Data] = []
        do {
            while !Task.isCancelled {
                let data = try await source.receive().content
                noteUDPReceived(direction: direction)
                let profile = await engine.currentProfile().link(for: direction).udp
                reorderBuffer.append(data)
                guard reorderBuffer.count >= profile.reorderWindow else { continue }
                let payloads = profile.reorderWindow > 1 ? Array(reorderBuffer.reversed()) : reorderBuffer
                reorderBuffer.removeAll(keepingCapacity: true)
                if profile.reorderWindow > 1 { noteUDPReordered(payloads.count, direction: direction) }
                for payload in payloads {
                    let plan = await engine.udpPlan(direction: direction)
                    if plan.isDropped { noteUDPDropped(direction: direction); continue }
                    if plan.delays.count > 1 { noteUDPDuplicated(plan.delays.count - 1, direction: direction) }
                    for delay in plan.delays {
                        if delay > .zero { try await Task.sleep(for: delay); noteDelay(direction: direction) }
                        try await destination.send(payload)
                        noteUDPForwarded(direction: direction)
                    }
                }
            }
        } catch {}
    }

    private func finishTCP(_ id: UUID) {
        if flowTasks.removeValue(forKey: id) != nil { metrics.activeTCPConnections = max(0, metrics.activeTCPConnections - 1) }
    }

    private func finishUDP(_ id: UUID) {
        if flowTasks.removeValue(forKey: id) != nil { metrics.activeUDPFlows = max(0, metrics.activeUDPFlows - 1) }
    }

    private func boundPort<P>(_ listener: NetworkListener<P>) async throws -> UInt16 {
        for _ in 0..<500 {
            if let raw = listener.port?.rawValue, raw != 0 { return raw }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PartyFaultError.listenerDidNotStart
    }

    private nonisolated static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private func updateDirection(_ direction: TrafficDirection, _ body: (inout DirectionMetrics) -> Void) {
        if direction == .clientToServer { body(&metrics.clientToServer) }
        else { body(&metrics.serverToClient) }
    }

    private func noteTCPReceived(_ bytes: Int, direction: TrafficDirection) { updateDirection(direction) { $0.tcpBytesReceived += UInt64(bytes) } }
    private func noteTCPForwarded(_ bytes: Int, direction: TrafficDirection) { updateDirection(direction) { $0.tcpBytesForwarded += UInt64(bytes) } }
    private func noteTCPBlackhole(direction: TrafficDirection) { updateDirection(direction) { $0.tcpChunksBlackholed += 1 } }
    private func noteUDPReceived(direction: TrafficDirection) { updateDirection(direction) { $0.udpDatagramsReceived += 1 } }
    private func noteUDPForwarded(direction: TrafficDirection) { updateDirection(direction) { $0.udpDatagramsForwarded += 1 } }
    private func noteUDPDropped(direction: TrafficDirection) { updateDirection(direction) { $0.udpDatagramsDropped += 1 } }
    private func noteUDPDuplicated(_ count: Int, direction: TrafficDirection) { updateDirection(direction) { $0.udpDatagramsDuplicated += UInt64(count) } }
    private func noteUDPReordered(_ count: Int, direction: TrafficDirection) { updateDirection(direction) { $0.udpDatagramsReordered += UInt64(count) } }
    private func noteDelay(direction: TrafficDirection) { updateDirection(direction) { $0.delayedUnits += 1 } }
}
