import Foundation
import Observation
import OSLog

public enum HostEvent: Sendable {
    case playerJoined(PlayerInfo)
    case playerReconnected(PlayerInfo)
    case playerDisconnected(PlayerInfo)
    case playerExpired(PlayerID)
    case menu(playerID: PlayerID, action: MenuAction)
    case failure(String)
}

@MainActor
@Observable
public final class PartyHost {
    public private(set) var players: [PlayerInfo] = []
    public private(set) var hostName = "PartyBox"
    public private(set) var hostInstanceID = UUID()
    public private(set) var port: UInt16?
    public private(set) var errorMessage: String?
    public let inputs = InputStore()
    public nonisolated let events: AsyncStream<HostEvent>

    private struct PlayerSession {
        let controllerID: ControllerID
        let playerID: PlayerID
        var displayName: String
        var connectionID: UUID?
        var sessionToken: UInt64?
        var graceTask: Task<Void, Never>?
    }

    private let eventContinuation: AsyncStream<HostEvent>.Continuation
    private let logger = Logger(subsystem: "PartyNet", category: "PartyHost")
    private let reconnectGrace: Duration
    private var transport: HostTransport?
    private var transportTask: Task<Void, Never>?
    private var sessions: [ControllerID: PlayerSession] = [:]
    private var connectionOwners: [UUID: ControllerID] = [:]

    public init(reconnectGrace: Duration = PartyNetConstants.reconnectGrace) {
        self.reconnectGrace = reconnectGrace
        var continuation: AsyncStream<HostEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    @discardableResult
    public func start(hostName: String, advertise: Bool = true) async throws -> UInt16 {
        await stop()
        self.hostName = hostName
        hostInstanceID = UUID()
        errorMessage = nil
        let transport = HostTransport(inputs: inputs)
        self.transport = transport
        let stream = transport.events
        transportTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
        do {
            let port = try await transport.start(
                hostName: hostName,
                hostInstanceID: hostInstanceID,
                advertise: advertise
            )
            self.port = port
            return port
        } catch {
            errorMessage = error.localizedDescription
            eventContinuation.yield(.failure(error.localizedDescription))
            throw error
        }
    }

    public func send(_ message: HostMessage, to playerID: PlayerID) async {
        guard let session = sessions.values.first(where: { $0.playerID == playerID }),
              let connectionID = session.connectionID else { return }
        do {
            try await transport?.send(message, to: connectionID)
        } catch {
            logger.debug("Send to player \(playerID.rawValue) failed: \(error.localizedDescription)")
        }
    }

    public func broadcast(_ message: HostMessage) async {
        for session in sessions.values where session.connectionID != nil {
            await send(message, to: session.playerID)
        }
    }

    public func stop() async {
        transportTask?.cancel()
        transportTask = nil
        for session in sessions.values {
            session.graceTask?.cancel()
        }
        sessions.removeAll()
        connectionOwners.removeAll()
        players.removeAll()
        inputs.removeAll()
        port = nil
        await transport?.stop()
        transport = nil
    }

    private func handle(_ event: HostTransportEvent) async {
        switch event {
        case let .hello(connectionID, hello):
            await handleHello(connectionID: connectionID, hello: hello)
        case let .message(connectionID, message):
            await handleMessage(connectionID: connectionID, message: message)
        case let .disconnected(connectionID):
            handleDisconnect(connectionID: connectionID)
        case let .failure(message):
            errorMessage = message
            eventContinuation.yield(.failure(message))
        }
    }

    private func handleHello(connectionID: UUID, hello: Hello) async {
        guard hello.protocolVersion == PartyNetConstants.protocolVersion else {
            await transport?.respond(
                to: connectionID,
                with: .reject(.versionMismatch(hostVersion: PartyNetConstants.protocolVersion))
            )
            return
        }

        let fallbackName: String
        let session: PlayerSession
        let event: HostEvent
        if var existing = sessions[hello.controllerID] {
            fallbackName = "Player \(existing.playerID.rawValue + 1)"
            if let oldToken = existing.sessionToken { await transport?.invalidate(token: oldToken) }
            if let oldConnection = existing.connectionID {
                connectionOwners.removeValue(forKey: oldConnection)
                await transport?.replace(connectionID: oldConnection)
            }
            existing.graceTask?.cancel()
            existing.graceTask = nil
            existing.displayName = DisplayName.sanitized(hello.displayName, fallback: fallbackName)
            existing.connectionID = connectionID
            let token = UInt64.random(in: UInt64.min...UInt64.max)
            existing.sessionToken = token
            sessions[hello.controllerID] = existing
            connectionOwners[connectionID] = hello.controllerID
            session = existing
            event = .playerReconnected(info(for: existing, connected: true))
        } else {
            guard sessions.count < PartyNetConstants.maximumControllers,
                  let playerID = lowestAvailablePlayerID() else {
                await transport?.respond(to: connectionID, with: .reject(.full))
                return
            }
            fallbackName = "Player \(playerID.rawValue + 1)"
            let created = PlayerSession(
                controllerID: hello.controllerID,
                playerID: playerID,
                displayName: DisplayName.sanitized(hello.displayName, fallback: fallbackName),
                connectionID: connectionID,
                sessionToken: UInt64.random(in: UInt64.min...UInt64.max)
            )
            sessions[hello.controllerID] = created
            connectionOwners[connectionID] = hello.controllerID
            session = created
            event = .playerJoined(info(for: created, connected: true))
        }

        let player = info(for: session, connected: true)
        guard let udpPort = await transportUDPPort(), let token = session.sessionToken else {
            await transport?.respond(to: connectionID, with: .reject(.malformedHello))
            return
        }
        let welcome = Welcome(
            player: player,
            udpPort: udpPort,
            sessionToken: token,
            hostName: hostName,
            hostInstanceID: hostInstanceID
        )
        await transport?.respond(to: connectionID, with: .accept(welcome))
        refreshPlayers()
        eventContinuation.yield(event)
        await broadcast(.roster(players))
    }

    private func transportUDPPort() async -> UInt16? {
        await transport?.udpPort
    }

    private func handleMessage(connectionID: UUID, message: ClientMessage) async {
        guard let controllerID = connectionOwners[connectionID], var session = sessions[controllerID],
              session.connectionID == connectionID else { return }

        switch message {
        case .hello:
            break
        case let .rename(name):
            session.displayName = DisplayName.sanitized(name, fallback: "Player \(session.playerID.rawValue + 1)")
            sessions[controllerID] = session
            refreshPlayers()
            await broadcast(.roster(players))
        case let .menu(action):
            eventContinuation.yield(.menu(playerID: session.playerID, action: action))
        case let .input(frame):
            guard frame.token == session.sessionToken else { return }
            _ = inputs.update(frame, for: session.playerID)
        case let .ping(value):
            await send(.pong(value), to: session.playerID)
        case .leave:
            expire(controllerID: controllerID)
        }
    }

    private func handleDisconnect(connectionID: UUID) {
        guard let controllerID = connectionOwners.removeValue(forKey: connectionID),
              var session = sessions[controllerID], session.connectionID == connectionID else { return }
        session.connectionID = nil
        if let token = session.sessionToken {
            Task { await transport?.invalidate(token: token) }
        }
        session.sessionToken = nil
        session.graceTask?.cancel()
        let grace = reconnectGrace
        session.graceTask = Task { [weak self, grace] in
            do {
                try await Task.sleep(for: grace)
                guard !Task.isCancelled else { return }
                self?.expire(controllerID: controllerID)
            } catch {}
        }
        sessions[controllerID] = session
        refreshPlayers()
        let player = info(for: session, connected: false)
        eventContinuation.yield(.playerDisconnected(player))
        Task { await broadcast(.roster(players)) }
    }

    private func expire(controllerID: ControllerID) {
        guard let session = sessions.removeValue(forKey: controllerID) else { return }
        if let connectionID = session.connectionID { connectionOwners.removeValue(forKey: connectionID) }
        if let token = session.sessionToken { Task { await transport?.invalidate(token: token) } }
        session.graceTask?.cancel()
        inputs.remove(session.playerID)
        refreshPlayers()
        eventContinuation.yield(.playerExpired(session.playerID))
        Task { await broadcast(.roster(players)) }
    }

    private func lowestAvailablePlayerID() -> PlayerID? {
        let used = Set(sessions.values.map(\.playerID))
        return (0..<PartyNetConstants.maximumControllers)
            .map { PlayerID(UInt8($0)) }
            .first { !used.contains($0) }
    }

    private func info(for session: PlayerSession, connected: Bool) -> PlayerInfo {
        PlayerInfo(
            id: session.playerID,
            displayName: session.displayName,
            colorHex: PlayerPalette.color(for: session.playerID),
            isConnected: connected
        )
    }

    private func refreshPlayers() {
        players = sessions.values
            .map { info(for: $0, connected: $0.connectionID != nil) }
            .sorted { $0.id < $1.id }
    }
}
