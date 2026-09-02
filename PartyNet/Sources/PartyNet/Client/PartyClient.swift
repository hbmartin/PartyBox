import Foundation
import Observation

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
}

@MainActor
@Observable
public final class PartyClient {
    public private(set) var state: PartyClientState = .browsing
    public private(set) var hosts: [DiscoveredHost] = []
    public private(set) var player: PlayerInfo?
    public private(set) var roster: [PlayerInfo] = []
    public private(set) var layout: ControllerLayout = .lobby
    public private(set) var rttMilliseconds: Double?
    public nonisolated let events: AsyncStream<ClientEvent>

    public let controllerID: ControllerID
    public private(set) var displayName: String

    private let eventContinuation: AsyncStream<ClientEvent>.Continuation
    private let transport = ClientTransport()
    private var transportTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var connectionID: UUID?
    private var selectedHost: DiscoveredHost?
    private var expectedInstanceID: UUID?
    private var isExplicitlyDisconnected = false

    public init(controllerID: ControllerID = ControllerID(), displayName: String) {
        self.controllerID = controllerID
        self.displayName = DisplayName.sanitized(displayName, fallback: "Player")
        var continuation: AsyncStream<ClientEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    public func startBrowsing() async {
        ensureEventTask()
        await transport.startBrowsing()
        if connectionID == nil { state = .browsing }
    }

    public func connect(to host: DiscoveredHost) async {
        ensureEventTask()
        reconnectTask?.cancel()
        selectedHost = host
        expectedInstanceID = host.instanceID
        isExplicitlyDisconnected = false
        await connectSelectedHost(reconnecting: false)
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
        Task { await transport.setInput(axisX: axisX, axisY: axisY, buttons: buttons, connectionID: connectionID) }
    }

    public func disconnect() async {
        isExplicitlyDisconnected = true
        reconnectTask?.cancel()
        reconnectTask = nil
        if let connectionID { await transport.disconnect(connectionID: connectionID) }
        self.connectionID = nil
        player = nil
        roster = []
        layout = .lobby
        state = .browsing
    }

    public func stop() async {
        await disconnect()
        transportTask?.cancel()
        transportTask = nil
        await transport.stop()
    }

    public func reconnectAfterForeground() {
        guard connectionID == nil, selectedHost != nil else { return }
        beginReconnect(reason: "Connection interrupted")
    }

#if DEBUG
    func interruptForTesting() async {
        guard let connectionID else { return }
        await transport.disconnect(connectionID: connectionID, sendLeave: false)
        self.connectionID = nil
        state = .disconnected("Simulated connection interruption")
    }
#endif

    private func connectSelectedHost(reconnecting: Bool) async {
        guard let host = selectedHost else { return }
        state = reconnecting ? .reconnecting(host.name) : .connecting(host.name)
        do {
            let hello = Hello(controllerID: controllerID, displayName: displayName)
            let (id, welcome) = try await transport.connect(to: host, hello: hello)
            connectionID = id
            expectedInstanceID = welcome.hostInstanceID
            player = welcome.player
            state = .connected(welcome.hostName)
        } catch let error as PartyClientError {
            switch error {
            case let .rejected(reason): state = .rejected(reason.message)
            default: state = .disconnected(error.localizedDescription)
            }
        } catch {
            state = .disconnected(error.localizedDescription)
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
            hosts = found
        case let .message(id, message):
            guard id == connectionID else { return }
            handle(message)
        case let .disconnected(id, reason):
            guard id == connectionID else { return }
            connectionID = nil
            guard !isExplicitlyDisconnected else { return }
            beginReconnect(reason: reason)
        case let .failure(message):
            if connectionID == nil { state = .disconnected(message) }
        }
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
            layout = value
        case let .feedback(value):
            eventContinuation.yield(.feedback(value))
        case let .pong(sentNanos):
            let elapsed = DispatchTime.now().uptimeNanoseconds &- sentNanos
            rttMilliseconds = Double(elapsed) / 1_000_000
        }
    }

    private func beginReconnect(reason: String) {
        guard reconnectTask == nil, selectedHost != nil else { return }
        state = .reconnecting(reason)
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: PartyNetConstants.clientReconnectWindow)
            while !Task.isCancelled, clock.now < deadline {
                if let candidate = self.reconnectCandidate() {
                    self.selectedHost = candidate
                    await self.connectSelectedHost(reconnecting: true)
                    if self.connectionID != nil {
                        self.reconnectTask = nil
                        return
                    }
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            self.state = .disconnected("Could not reconnect within 30 seconds.")
            self.reconnectTask = nil
        }
    }

    private func reconnectCandidate() -> DiscoveredHost? {
        guard let selectedHost else { return nil }
        if selectedHost.instanceID == nil { return selectedHost }
        return hosts.first { $0.instanceID == expectedInstanceID }
    }
}
