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
    case application(Data)
    case hostsChanged([DiscoveredHost])
}

@MainActor
@Observable
public final class PartyClient {
    public private(set) var state: PartyClientState = .browsing
    public private(set) var hosts: [DiscoveredHost] = []
    public private(set) var discoveryErrorMessage: String?
    public private(set) var player: PlayerInfo?
    public private(set) var rttMilliseconds: Double?
    public private(set) var rttSampleCount: UInt64 = 0
    public private(set) var inputFramesSent: UInt64 = 0
    public private(set) var usesTCPFallback = false
    public private(set) var inputAxisX: Float = 0
    public private(set) var inputAxisY: Float = 0
    public private(set) var inputButtons: Buttons = []
    public private(set) var inputOrientation: OrientationQuaternion = .identity
    public private(set) var inputFlags: InputFlags = []
    /// A bounded stream that ends if its subscriber cannot keep up. Read the property again
    /// to subscribe afresh, or use `eventStream(onOverflow:)` to observe an overflow directly.
    public nonisolated var events: AsyncStream<ClientEvent> {
        eventHub.stream(onOverflow: {})
    }

    public nonisolated func eventStream(
        onOverflow: @escaping @Sendable () -> Void
    ) -> AsyncStream<ClientEvent> {
        eventHub.stream(onOverflow: onOverflow)
    }

    public let controllerID: ControllerID
    public private(set) var displayName: String

    private nonisolated let eventHub = EventHub<ClientEvent>()
    private let transport: ClientTransport
    private var transportTask: Task<Void, Never>?
    private var transportEventGeneration: UUID?
    private var transportRecovery: (id: UUID, task: Task<Void, Never>)?
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
    private var isStopped = false
#if DEBUG
    private var skipsReconnectNetworkingForTesting = false
    private var injectedHosts: [DiscoveredHost] = []
#endif

    private struct PendingInput: Sendable {
        let connectionID: UUID
        let axisX: Float
        let axisY: Float
        let buttons: Buttons
        let orientation: OrientationQuaternion
        let flags: InputFlags
    }

    public init(
        controllerID: ControllerID = ControllerID(),
        displayName: String,
        inputSendInterval: Duration = .milliseconds(16)
    ) {
        self.controllerID = controllerID
        self.displayName = DisplayName.sanitized(displayName, fallback: "Player")
        transport = ClientTransport(inputSendInterval: inputSendInterval)
    }

    isolated deinit {
        transportTask?.cancel()
        transportRecovery?.task.cancel()
        reconnectTask?.cancel()
        foregroundProbeTask?.cancel()
        inputFlushTask?.cancel()
    }

    public func startBrowsing() async {
        isStopped = false
        await waitForTransportRecovery()
        guard !isStopped else { return }
        ensureEventTask()
        discoveryErrorMessage = nil
        await transport.startBrowsing()
        if connectionID == nil { state = .browsing }
    }

    public func restartBrowsing() async {
        isStopped = false
        await waitForTransportRecovery()
        guard !isStopped else { return }
        ensureEventTask()
        discoveryErrorMessage = nil
        await transport.restartBrowsing()
        if connectionID == nil, connectionAttemptID == nil { state = .browsing }
    }

    public func connect(to host: DiscoveredHost) async {
        isStopped = false
        await waitForTransportRecovery()
        guard !isStopped else { return }
        ensureEventTask()
        cancelReconnect()
        cancelForegroundProbe()
        cancelInputFlush()
        resetSessionPresentation()
        let attemptID = UUID()
        connectionAttemptID = attemptID
        selectedHost = host
        expectedInstanceID = host.instanceID
        isExplicitlyDisconnected = false
        if let previousConnectionID = connectionID {
            connectionID = nil
            await transport.disconnect(connectionID: previousConnectionID)
            guard connectionAttemptID == attemptID else { return }
        }
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

    @discardableResult
    public func sendApplication(_ payload: Data) async -> Bool {
        guard payload.count <= PartyNetConstants.maximumApplicationPayloadBytes,
              let connectionID else { return false }
        do {
            try await transport.send(.application(payload), connectionID: connectionID)
            return true
        } catch {
            return false
        }
    }

    public func setInput(axisX: Float, axisY: Float = 0, buttons: Buttons = []) {
        let axisX = axisX.isFinite ? min(max(axisX, -1), 1) : 0
        let axisY = axisY.isFinite ? min(max(axisY, -1), 1) : 0
        inputAxisX = axisX
        inputAxisY = axisY
        inputButtons = buttons
        enqueueCurrentInput()
    }

    public func setOrientation(
        _ orientation: OrientationQuaternion,
        available: Bool = true
    ) {
        if available, let normalized = orientation.normalized {
            inputOrientation = normalized
            inputFlags.insert(.motionAvailable)
        } else {
            inputOrientation = .identity
            inputFlags.remove(.motionAvailable)
        }
        enqueueCurrentInput()
    }

    private func enqueueCurrentInput() {
        guard let connectionID else { return }
        pendingInput = PendingInput(
            connectionID: connectionID,
            axisX: inputAxisX,
            axisY: inputAxisY,
            buttons: inputButtons,
            orientation: inputOrientation,
            flags: inputFlags
        )
        startInputFlushIfNeeded()
    }

    public func disconnect() async {
        isExplicitlyDisconnected = true
        cancelReconnect()
        cancelForegroundProbe()
        cancelInputFlush()
        let pendingAttemptID = connectionAttemptID
        if let pendingAttemptID {
            await transport.cancelConnectionAttempt(pendingAttemptID)
            guard isExplicitlyDisconnected else { return }
            if connectionAttemptID == pendingAttemptID {
                connectionAttemptID = nil
            } else if connectionAttemptID != nil {
                return
            }
        }
        let establishedConnectionID = connectionID
        connectionID = nil
        if let establishedConnectionID {
            await transport.disconnect(connectionID: establishedConnectionID)
            guard connectionAttemptID == nil, isExplicitlyDisconnected else { return }
        }
        resetSessionPresentation()
        discoveryErrorMessage = nil
        state = .browsing
    }

    public func stop() async {
        isStopped = true
        transportRecovery?.task.cancel()
        await waitForTransportRecovery()
        await disconnect()
        transportEventGeneration = nil
        transportTask?.cancel()
        transportTask = nil
        await transport.stop()
        eventHub.finish()
    }

    public func reconnectAfterForeground() {
        guard !isExplicitlyDisconnected, selectedHost != nil else { return }
        guard connectionAttemptID == nil else { return }
        if let connectionID {
            startForegroundProbe(connectionID: connectionID)
        } else {
            cancelReconnect()
            beginReconnect(reason: "Connection interrupted")
        }
    }

#if DEBUG
    public func configureFixture(
        state: PartyClientState,
        hosts: [DiscoveredHost] = [],
        discoveryErrorMessage: String? = nil,
        player: PlayerInfo? = nil
    ) {
        self.state = state
        self.hosts = hosts
        self.discoveryErrorMessage = discoveryErrorMessage
        self.player = player
    }

    public func insertTestingHost(_ host: DiscoveredHost) {
        injectedHosts.removeAll { $0.id == host.id }
        injectedHosts.append(host)
        hosts = mergedHosts(hosts)
        eventHub.yield(.hostsChanged(hosts))
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

    func simulateTransportEventStreamOverflowForTesting() async {
        isStopped = false
        ensureEventTask()
        await transport.simulateEventOverflowForTesting()
        while transportRecovery == nil { await Task.yield() }
        await waitForTransportRecovery()
    }
#endif

    private func connectSelectedHost(reconnecting: Bool, attemptID: UUID) async {
        guard connectionAttemptID == attemptID, let host = selectedHost else { return }
        state = reconnecting ? .reconnecting(host.name) : .connecting(host.name)
        do {
            let hello = Hello(controllerID: controllerID, displayName: displayName)
            let (id, welcome) = try await transport.connect(
                to: host,
                hello: hello,
                attemptID: attemptID
            )
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
                resetSessionPresentation()
                state = .browsing
                return
            }
            connectionAttemptID = nil
            connectionID = id
            expectedInstanceID = welcome.hostInstanceID
            player = welcome.player
            rttMilliseconds = nil
            rttSampleCount = 0
            usesTCPFallback = false
            state = .connected(welcome.hostName)
        } catch let error as PartyClientError {
            guard connectionAttemptID == attemptID,
                  !isExplicitlyDisconnected,
                  !Task.isCancelled else { return }
            connectionAttemptID = nil
            switch error {
            case let .rejected(reason):
                isExplicitlyDisconnected = true
                state = .rejected(reason.message)
            default:
                state = reconnecting ? .reconnecting(host.name) : .disconnected(error.localizedDescription)
            }
        } catch {
            guard connectionAttemptID == attemptID,
                  !isExplicitlyDisconnected,
                  !Task.isCancelled else { return }
            connectionAttemptID = nil
            state = reconnecting ? .reconnecting(host.name) : .disconnected(error.localizedDescription)
        }
    }

    private func ensureEventTask() {
        guard !isStopped, transportRecovery == nil, transportTask == nil else { return }
        let generation = UUID()
        transportEventGeneration = generation
        let stream = transport.eventStream { [weak self] in
            Task { @MainActor [weak self] in
                self?.transportEventStreamEnded(
                    generation: generation,
                    cancelConsumer: true
                )
            }
        }
        transportTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
            self?.transportEventStreamEnded(
                generation: generation,
                cancelConsumer: false
            )
        }
    }

    private func transportEventStreamEnded(
        generation: UUID,
        cancelConsumer: Bool
    ) {
        guard !isStopped,
              transportRecovery == nil,
              transportEventGeneration == generation else { return }
        transportEventGeneration = nil
        let consumer = transportTask
        transportTask = nil
        if cancelConsumer { consumer?.cancel() }

        let preservesTerminalState = isTerminalState
        let shouldReconnect = !preservesTerminalState
            && !isExplicitlyDisconnected
            && selectedHost != nil
        cancelReconnect()
        cancelForegroundProbe()
        cancelInputFlush()
        connectionAttemptID = nil
        connectionID = nil
        let reason = "The client transport event stream could not keep up."
        if !preservesTerminalState {
            resetSessionPresentation()
            state = shouldReconnect ? .reconnecting(reason) : .browsing
        }

        let recoveryID = UUID()
        let recoveryTask = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performTransportRecovery(
                id: recoveryID,
                shouldReconnect: shouldReconnect,
                reason: reason
            )
        }
        transportRecovery = (recoveryID, recoveryTask)
    }

    private func performTransportRecovery(
        id: UUID,
        shouldReconnect: Bool,
        reason: String
    ) async {
        await transport.stop()
        guard transportRecovery?.id == id else { return }
        transportRecovery = nil
        guard !isStopped else { return }
        ensureEventTask()
        if shouldReconnect,
           !isTerminalState,
           !isExplicitlyDisconnected,
           selectedHost != nil {
            beginReconnect(reason: reason)
        } else {
            await transport.startBrowsing()
        }
    }

    private func waitForTransportRecovery() async {
        while let recovery = transportRecovery {
            await recovery.task.value
        }
    }

    private var isTerminalState: Bool {
        switch state {
        case .rejected, .disconnected:
            true
        default:
            false
        }
    }

    private func handle(_ event: ClientTransportEvent) async {
        switch event {
        case let .hosts(found):
            hosts = mergedHosts(found)
            if !found.isEmpty { discoveryErrorMessage = nil }
            eventHub.yield(.hostsChanged(hosts))
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
            resetInputPresentation()
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
        case let .application(payload):
            guard payload.count <= PartyNetConstants.maximumApplicationPayloadBytes else { return }
            eventHub.yield(.application(payload))
        case .inputAck:
            break
        case let .pingResponse(sentNanos):
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
            await self.transport.restartBrowsing()
            let deadline = clock.now.advanced(by: PartyNetConstants.clientReconnectWindow)
            while !Task.isCancelled, clock.now < deadline {
                guard self.reconnectAttemptID == reconnectID, !self.isExplicitlyDisconnected else { return }
#if DEBUG
                if self.skipsReconnectNetworkingForTesting {
                    do { try await clock.sleep(for: .seconds(1)) } catch { return }
                    continue
                }
#endif
                await self.transport.startBrowsing()
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
                orientation: input.orientation,
                flags: input.flags,
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

    private func resetSessionPresentation() {
        player = nil
        resetInputPresentation()
        rttMilliseconds = nil
        rttSampleCount = 0
        usesTCPFallback = false
    }

    private func resetInputPresentation() {
        inputAxisX = 0
        inputAxisY = 0
        inputButtons = []
        inputOrientation = .identity
        inputFlags = []
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
                try await clock.sleep(for: PartyNetConstants.pingTimeout)
            } catch is CancellationError {
                return
            } catch {
                // A failed write is equivalent to a liveness timeout.
            }
            guard !Task.isCancelled,
                  self.foregroundProbeNonce == nonce,
                  self.connectionID == connectionID,
                  !self.isExplicitlyDisconnected else { return }
            await self.transport.disconnect(connectionID: connectionID, sendLeave: false)
            guard self.connectionID == connectionID,
                  !self.isExplicitlyDisconnected else { return }
            if self.foregroundProbeNonce == nonce {
                self.foregroundProbeTask = nil
                self.foregroundProbeNonce = nil
            }
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
