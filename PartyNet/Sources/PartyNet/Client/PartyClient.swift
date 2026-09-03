import Foundation
import Observation
import Dependencies

public enum PartyClientState: Equatable, Sendable {
    case browsing
    case connecting(String)
    case connected(String)
    case reconnecting(String)
    case rejected(String)
    case disconnected(String)
}

public enum ClientEvent: Sendable {
    case feedback(Feedback)
    case hostsChanged([DiscoveredHost])
}

@MainActor
@Observable
public final class PartyClient {
    public private(set) var state: PartyClientState = .browsing
    public private(set) var hosts: [DiscoveredHost] = []
    public private(set) var discoveryErrorMessage: String?
    public private(set) var player: PlayerInfo?
    public private(set) var roster: [PlayerInfo] = []
    public private(set) var layout: ControllerLayout = .lobby
    public private(set) var rttMilliseconds: Double?
    public private(set) var rttSampleCount: UInt64 = 0
    public private(set) var inputFramesSent: UInt64 = 0
    public private(set) var usesTCPFallback = false
    public nonisolated let events: AsyncStream<ClientEvent>

    public let controllerID: ControllerID
    public private(set) var displayName: String

    private let eventContinuation: AsyncStream<ClientEvent>.Continuation
    private let transport: ClientTransport
    private var transportTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttemptID: UUID?
    private var connectionAttemptID: UUID?
    private var foregroundProbeTask: Task<Void, Never>?
    private var foregroundProbeNonce: UInt64?
    private var pendingInput: PendingInput?
    private var inputFlushTask: Task<Void, Never>?
    private var inputFlushID: UUID?
    private var connectionID: UUID?
    private var selectedHost: DiscoveredHost?
    private var expectedInstanceID: UUID?
    private var isExplicitlyDisconnected = false
#if DEBUG
    private var skipsReconnectNetworkingForTesting = false
    private var injectedHosts: [DiscoveredHost] = []
#endif

    private struct PendingInput: Sendable {
        let connectionID: UUID
        let axisX: Float
        let axisY: Float
        let buttons: Buttons
    }

    public init(
        controllerID: ControllerID = ControllerID(),
        displayName: String,
        inputSendInterval: Duration = .milliseconds(16)
    ) {
        self.controllerID = controllerID
        self.displayName = DisplayName.sanitized(displayName, fallback: "Player")
        transport = ClientTransport(inputSendInterval: inputSendInterval)
        var continuation: AsyncStream<ClientEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    public func startBrowsing() async {
        ensureEventTask()
        discoveryErrorMessage = nil
        await transport.startBrowsing()
        if connectionID == nil { state = .browsing }
    }

    public func connect(to host: DiscoveredHost) async {
        ensureEventTask()
        cancelReconnect()
        cancelForegroundProbe()
        cancelInputFlush()
        let attemptID = UUID()
        connectionAttemptID = attemptID
        if let connectionID {
            await transport.disconnect(connectionID: connectionID)
            guard connectionAttemptID == attemptID else { return }
            self.connectionID = nil
        }
        selectedHost = host
        expectedInstanceID = host.instanceID
        isExplicitlyDisconnected = false
        await connectSelectedHost(reconnecting: false, attemptID: attemptID)
    }

    public func connect(host: String, port: UInt16) async {
        do {
            let direct = try DiscoveredHost(host: host, port: port)
            await connect(to: direct)
        } catch {
            state = .disconnected(error.localizedDescription)
        }
    }

    public func rename(to value: String) async {
        displayName = DisplayName.sanitized(value, fallback: player.map { "Player \($0.number)" } ?? "Player")
        guard let connectionID else { return }
        try? await transport.send(.rename(displayName), connectionID: connectionID)
    }

    public func sendMenu(_ action: MenuAction) async {
        guard let connectionID else { return }
        try? await transport.send(.menu(action), connectionID: connectionID)
    }

    public func setInput(axisX: Float, axisY: Float = 0, buttons: Buttons = []) {
        guard let connectionID else { return }
        pendingInput = PendingInput(
            connectionID: connectionID,
            axisX: axisX,
            axisY: axisY,
            buttons: buttons
        )
        startInputFlushIfNeeded()
    }

    public func disconnect() async {
        isExplicitlyDisconnected = true
        connectionAttemptID = nil
        cancelReconnect()
        cancelForegroundProbe()
        cancelInputFlush()
        if let connectionID { await transport.disconnect(connectionID: connectionID) }
        self.connectionID = nil
        player = nil
        roster = []
        layout = .lobby
        usesTCPFallback = false
        discoveryErrorMessage = nil
        state = .browsing
    }

    public func stop() async {
        await disconnect()
        transportTask?.cancel()
        transportTask = nil
        await transport.stop()
    }

    public func reconnectAfterForeground() {
        guard !isExplicitlyDisconnected, selectedHost != nil else { return }
        if let connectionID {
            startForegroundProbe(connectionID: connectionID)
        } else {
            beginReconnect(reason: "Connection interrupted")
        }
    }

#if DEBUG
    public func configureFixture(
        state: PartyClientState,
        hosts: [DiscoveredHost] = [],
        discoveryErrorMessage: String? = nil,
        player: PlayerInfo? = nil,
        roster: [PlayerInfo] = [],
        layout: ControllerLayout = .lobby
    ) {
        self.state = state
        self.hosts = hosts
        self.discoveryErrorMessage = discoveryErrorMessage
        self.player = player
        self.roster = roster
        self.layout = layout
    }

    public func insertTestingHost(_ host: DiscoveredHost) {
        injectedHosts.removeAll { $0.id == host.id }
        injectedHosts.append(host)
        hosts = mergedHosts(hosts)
        eventContinuation.yield(.hostsChanged(hosts))
    }

    func interruptForTesting() async {
        guard let connectionID else { return }
        await transport.disconnect(connectionID: connectionID, sendLeave: false)
        self.connectionID = nil
        state = .disconnected("Simulated connection interruption")
    }

    func beginReconnectForTesting(host: String, port: UInt16) throws {
        selectedHost = try DiscoveredHost(host: host, port: port)
        expectedInstanceID = UUID()
        isExplicitlyDisconnected = false
        skipsReconnectNetworkingForTesting = true
        beginReconnect(reason: "Simulated connection interruption")
    }
#endif

    private func connectSelectedHost(reconnecting: Bool, attemptID: UUID) async {
        guard connectionAttemptID == attemptID, let host = selectedHost else { return }
        state = reconnecting ? .reconnecting(host.name) : .connecting(host.name)
        do {
            let hello = Hello(controllerID: controllerID, displayName: displayName)
            let (id, welcome) = try await transport.connect(to: host, hello: hello)
            guard connectionAttemptID == attemptID, !isExplicitlyDisconnected else {
                await transport.disconnect(connectionID: id)
                return
            }
            if reconnecting, let expectedInstanceID,
               welcome.hostInstanceID != expectedInstanceID {
                await transport.disconnect(connectionID: id)
                selectedHost = nil
                self.expectedInstanceID = nil
                connectionAttemptID = nil
                cancelReconnect()
                player = nil
                roster = []
                layout = .lobby
                usesTCPFallback = false
                state = .browsing
                return
            }
            connectionAttemptID = nil
            connectionID = id
            expectedInstanceID = welcome.hostInstanceID
            player = welcome.player
            rttMilliseconds = nil
            rttSampleCount = 0
            inputFramesSent = 0
            usesTCPFallback = false
            state = .connected(welcome.hostName)
        } catch let error as PartyClientError {
            guard connectionAttemptID == attemptID, !Task.isCancelled else { return }
            connectionAttemptID = nil
            switch error {
            case let .rejected(reason):
                isExplicitlyDisconnected = true
                state = .rejected(reason.message)
            default:
                state = reconnecting ? .reconnecting(host.name) : .disconnected(error.localizedDescription)
            }
        } catch {
            guard connectionAttemptID == attemptID, !Task.isCancelled else { return }
            connectionAttemptID = nil
            state = reconnecting ? .reconnecting(host.name) : .disconnected(error.localizedDescription)
        }
    }

    private func ensureEventTask() {
        guard transportTask == nil else { return }
        let stream = transport.events
        transportTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: ClientTransportEvent) async {
        switch event {
        case let .hosts(found):
            hosts = mergedHosts(found)
            if !found.isEmpty { discoveryErrorMessage = nil }
            eventContinuation.yield(.hostsChanged(hosts))
        case let .message(id, message):
            guard id == connectionID else { return }
            handle(message)
        case let .inputSent(id):
            guard id == connectionID else { return }
            inputFramesSent &+= 1
        case let .transportMode(id, usesTCPFallback):
            guard id == connectionID else { return }
            self.usesTCPFallback = usesTCPFallback
        case let .disconnected(id, reason):
            guard id == connectionID else { return }
            cancelForegroundProbe()
            cancelInputFlush()
            connectionID = nil
            usesTCPFallback = false
            guard !isExplicitlyDisconnected else { return }
            beginReconnect(reason: reason)
        case let .discoveryFailed(message):
            discoveryErrorMessage = message
        }
    }

    private func mergedHosts(_ found: [DiscoveredHost]) -> [DiscoveredHost] {
#if DEBUG
        let discoveredIDs = Set(found.map(\.id))
        return (found + injectedHosts.filter { !discoveredIDs.contains($0.id) }).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
#else
        return found
#endif
    }

    private func handle(_ message: HostMessage) {
        switch message {
        case let .welcome(value):
            player = value.player
        case let .rejected(reason):
            isExplicitlyDisconnected = true
            state = .rejected(reason.message)
        case let .roster(value):
            roster = value
            if let id = player?.id { player = value.first { $0.id == id } ?? player }
        case let .layout(value):
            let wasPaddleLayout = if case .paddle = layout { true } else { false }
            layout = value
            if case .paddle = value, !wasPaddleLayout {
                setInput(axisX: 0)
            }
        case let .feedback(value):
            eventContinuation.yield(.feedback(value))
        case .inputAck:
            break
        case let .pong(sentNanos):
            let elapsed = DispatchTime.now().uptimeNanoseconds &- sentNanos
            rttMilliseconds = Double(elapsed) / 1_000_000
            rttSampleCount &+= 1
            if foregroundProbeNonce == sentNanos { cancelForegroundProbe() }
        }
    }

    private func beginReconnect(reason: String) {
        guard reconnectTask == nil, selectedHost != nil, !isExplicitlyDisconnected else { return }
        let reconnectID = UUID()
        reconnectAttemptID = reconnectID
        state = .reconnecting(reason)
        @Dependency(\.continuousClock) var continuousClock
        let clock = AnyClock(continuousClock)
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            let deadline = clock.now.advanced(by: PartyNetConstants.clientReconnectWindow)
            while !Task.isCancelled, clock.now < deadline {
                guard self.reconnectAttemptID == reconnectID, !self.isExplicitlyDisconnected else { return }
#if DEBUG
                if self.skipsReconnectNetworkingForTesting {
                    do { try await clock.sleep(for: .seconds(1)) } catch { return }
                    continue
                }
#endif
                if let candidate = self.reconnectCandidate() {
                    self.selectedHost = candidate
                    let attemptID = UUID()
                    self.connectionAttemptID = attemptID
                    await self.connectSelectedHost(reconnecting: true, attemptID: attemptID)
                    guard self.reconnectAttemptID == reconnectID, !Task.isCancelled else { return }
                    if self.connectionID != nil {
                        self.finishReconnect(reconnectID)
                        return
                    }
                }
                do { try await clock.sleep(for: .seconds(1)) } catch { return }
            }
            guard !Task.isCancelled, self.reconnectAttemptID == reconnectID else { return }
            self.state = .disconnected("Could not reconnect within 30 seconds.")
            self.finishReconnect(reconnectID)
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttemptID = nil
    }

    private func finishReconnect(_ reconnectID: UUID) {
        guard reconnectAttemptID == reconnectID else { return }
        reconnectTask = nil
        reconnectAttemptID = nil
    }

    private func startInputFlushIfNeeded() {
        guard inputFlushTask == nil, pendingInput != nil else { return }
        let flushID = UUID()
        inputFlushID = flushID
        inputFlushTask = Task { [weak self] in
            await self?.flushPendingInputs(flushID: flushID)
        }
    }

    private func flushPendingInputs(flushID: UUID) async {
        while !Task.isCancelled, inputFlushID == flushID, let input = pendingInput {
            pendingInput = nil
            await transport.setInput(
                axisX: input.axisX,
                axisY: input.axisY,
                buttons: input.buttons,
                connectionID: input.connectionID
            )
        }
        guard inputFlushID == flushID else { return }
        inputFlushTask = nil
        inputFlushID = nil
        startInputFlushIfNeeded()
    }

    private func cancelInputFlush() {
        inputFlushTask?.cancel()
        inputFlushTask = nil
        inputFlushID = nil
        pendingInput = nil
    }

    private func startForegroundProbe(connectionID: UUID) {
        cancelForegroundProbe()
        let nonce = DispatchTime.now().uptimeNanoseconds
        foregroundProbeNonce = nonce
        @Dependency(\.continuousClock) var continuousClock
        let clock = AnyClock(continuousClock)
        foregroundProbeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.transport.send(.ping(nonce), connectionID: connectionID)
                try await clock.sleep(for: PartyNetConstants.pingInterval)
            } catch is CancellationError {
                return
            } catch {
                // A failed write is equivalent to a liveness timeout.
            }
            guard !Task.isCancelled,
                  self.foregroundProbeNonce == nonce,
                  self.connectionID == connectionID,
                  !self.isExplicitlyDisconnected else { return }
            self.foregroundProbeTask = nil
            self.foregroundProbeNonce = nil
            await self.transport.disconnect(connectionID: connectionID, sendLeave: false)
            guard self.connectionID == connectionID else { return }
            self.connectionID = nil
            self.beginReconnect(reason: "Connection interrupted")
        }
    }

    private func cancelForegroundProbe() {
        foregroundProbeTask?.cancel()
        foregroundProbeTask = nil
        foregroundProbeNonce = nil
    }

    private func reconnectCandidate() -> DiscoveredHost? {
        guard let selectedHost else { return nil }
        if selectedHost.instanceID == nil { return selectedHost }
        return hosts.first { $0.instanceID == expectedInstanceID }
    }
}
