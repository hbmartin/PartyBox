import Foundation
import Observation
import OSLog
import Dependencies

public enum HostEvent: Sendable {
    case playerJoined(PlayerInfo)
    case playerReconnected(PlayerInfo)
    case playerDisconnected(PlayerInfo)
    case playerExpired(PlayerInfo)
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
    public nonisolated var events: AsyncStream<HostEvent> { eventHub.stream() }

    private struct PlayerSession {
        let controllerID: ControllerID
        let playerID: PlayerID
        var displayName: String
        var connectionID: UUID?
        var sessionToken: UInt64?
        var isAdmitted: Bool
        var isWelcomedConnection: Bool
        var revision: UUID
        var graceTask: Task<Void, Never>?
    }

    private struct PendingRename: Sendable {
        let connectionID: UUID
        let boundedName: String
    }

    private struct RenameWorker: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    private nonisolated let eventHub = EventHub<HostEvent>()
    private let logger = Logger(subsystem: "PartyNet", category: "PartyHost")
    private let reconnectGrace: Duration
    private let renameProcessingInterval: Duration
    private var transport: HostTransport?
    private var transportTask: Task<Void, Never>?
    private var rosterBroadcastTask: Task<Void, Never>?
    private var rosterBroadcastGeneration = UUID()
    private var pendingRosterBroadcast: [PlayerInfo]?
    private var pendingRenames: [ControllerID: PendingRename] = [:]
    private var renameWorkers: [ControllerID: RenameWorker] = [:]
    private var sessions: [ControllerID: PlayerSession] = [:]
    private var connectionOwners: [UUID: ControllerID] = [:]
    private var lifecycleGeneration: UInt64 = 0

    public init(
        reconnectGrace: Duration = PartyNetConstants.reconnectGrace,
        renameProcessingInterval: Duration = PartyNetConstants.renameProcessingInterval
    ) {
        self.reconnectGrace = reconnectGrace
        self.renameProcessingInterval = renameProcessingInterval
    }

    @discardableResult
    public func start(hostName: String, advertise: Bool = true) async throws -> UInt16 {
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        let previousTransport = prepareToStop()
        await previousTransport?.stop()
        guard lifecycleGeneration == generation else { throw PartyNetTransportError.stopped }
        self.hostName = hostName
        let hostInstanceID = UUID()
        self.hostInstanceID = hostInstanceID
        errorMessage = nil
        let transport = HostTransport(inputs: inputs)
        self.transport = transport
        let stream = transport.events
        transportTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event, generation: generation)
            }
        }
        do {
            let port = try await transport.start(
                hostName: hostName,
                hostInstanceID: hostInstanceID,
                advertise: advertise
            )
            guard lifecycleGeneration == generation, self.transport === transport else {
                await transport.stop()
                throw PartyNetTransportError.stopped
            }
            self.port = port
            return port
        } catch {
            await transport.stop()
            if lifecycleGeneration == generation, self.transport === transport {
                transportTask?.cancel()
                transportTask = nil
                self.transport = nil
                port = nil
                errorMessage = error.localizedDescription
                eventHub.yield(.failure(error.localizedDescription))
            }
            throw error
        }
    }

    public func send(_ message: HostMessage, to playerID: PlayerID) async {
        guard let session = sessions.values.first(where: {
                  $0.playerID == playerID && $0.isAdmitted && $0.isWelcomedConnection
              }),
              let connectionID = session.connectionID else { return }
        do {
            try await transport?.send(message, to: connectionID)
        } catch {
            logger.debug("Send to player \(playerID.rawValue) failed: \(error.localizedDescription)")
        }
    }

    public func broadcast(_ message: HostMessage) async {
        let generation = lifecycleGeneration
        let connectionIDs = sessions.values.compactMap { session in
            session.isAdmitted && session.isWelcomedConnection ? session.connectionID : nil
        }
        for connectionID in connectionIDs {
            guard !Task.isCancelled, lifecycleGeneration == generation else { return }
            do {
                try await transport?.send(message, to: connectionID)
            } catch {
                logger.debug("Broadcast failed: \(error.localizedDescription)")
            }
        }
    }

    public func stop() async {
        lifecycleGeneration &+= 1
        let transport = prepareToStop()
        await transport?.stop()
        eventHub.finish()
    }

    private func prepareToStop() -> HostTransport? {
        let transport = transport
        self.transport = nil
        transportTask?.cancel()
        transportTask = nil
        rosterBroadcastTask?.cancel()
        rosterBroadcastTask = nil
        rosterBroadcastGeneration = UUID()
        pendingRosterBroadcast = nil
        renameWorkers.values.forEach { $0.task.cancel() }
        renameWorkers.removeAll()
        pendingRenames.removeAll()
        for session in sessions.values {
            session.graceTask?.cancel()
        }
        sessions.removeAll()
        connectionOwners.removeAll()
        players.removeAll()
        inputs.removeAll()
        port = nil
        return transport
    }

#if DEBUG
    public func configureFixture(hostName: String, players: [PlayerInfo]) {
        self.hostName = hostName
        self.players = players
    }
#endif

    private func handle(_ event: HostTransportEvent, generation: UInt64) async {
        guard lifecycleGeneration == generation else { return }
        switch event {
        case let .hello(connectionID, hello):
            await handleHello(connectionID: connectionID, hello: hello, generation: generation)
        case let .message(connectionID, message):
            await handleMessage(connectionID: connectionID, message: message, generation: generation)
        case let .disconnected(connectionID):
            await handleDisconnect(connectionID: connectionID, generation: generation)
        case let .failure(message):
            errorMessage = message
            eventHub.yield(.failure(message))
        }
    }

    private func handleHello(connectionID: UUID, hello: Hello, generation: UInt64) async {
        guard lifecycleGeneration == generation, let transport else { return }
        guard hello.protocolVersion == PartyNetConstants.protocolVersion else {
            await transport.respond(
                to: connectionID,
                with: .reject(.versionMismatch(hostVersion: PartyNetConstants.protocolVersion))
            )
            return
        }

        guard let udpPort = await transport.udpPort else {
            await transport.respond(to: connectionID, with: .reject(.malformedHello))
            return
        }
        guard lifecycleGeneration == generation else { return }

        let fallbackName: String
        let session: PlayerSession
        let event: HostEvent
        let isNewSession: Bool
        let token: UInt64
        if var existing = sessions[hello.controllerID] {
            cancelPendingRename(for: hello.controllerID)
            isNewSession = false
            fallbackName = "Player \(existing.playerID.rawValue + 1)"
            let oldToken = existing.sessionToken
            let oldConnection = existing.connectionID
            if let oldConnection { connectionOwners.removeValue(forKey: oldConnection) }
            existing.graceTask?.cancel()
            existing.graceTask = nil
            existing.revision = UUID()
            existing.displayName = DisplayName.sanitized(hello.displayName, fallback: fallbackName)
            existing.connectionID = connectionID
            existing.isWelcomedConnection = false
            token = UInt64.random(in: UInt64.min...UInt64.max)
            existing.sessionToken = token
            sessions[hello.controllerID] = existing
            connectionOwners[connectionID] = hello.controllerID
            if let oldToken { await transport.invalidate(token: oldToken) }
            guard lifecycleGeneration == generation,
                  sessions[hello.controllerID]?.connectionID == connectionID else {
                await abandonReconnectHandshake(
                    on: transport,
                    connectionID: connectionID,
                    replacedConnectionID: oldConnection
                )
                return
            }
            if let oldConnection {
                await transport.replace(connectionID: oldConnection)
            }
            guard lifecycleGeneration == generation,
                  sessions[hello.controllerID]?.connectionID == connectionID else {
                await abandonReconnectHandshake(on: transport, connectionID: connectionID)
                return
            }
            session = existing
            event = .playerReconnected(info(for: existing, connected: true))
        } else {
            isNewSession = true
            guard sessions.count < PartyNetConstants.maximumControllers,
                  let playerID = lowestAvailablePlayerID() else {
                await transport.respond(to: connectionID, with: .reject(.full))
                return
            }
            fallbackName = "Player \(playerID.rawValue + 1)"
            token = UInt64.random(in: UInt64.min...UInt64.max)
            let created = PlayerSession(
                controllerID: hello.controllerID,
                playerID: playerID,
                displayName: DisplayName.sanitized(hello.displayName, fallback: fallbackName),
                connectionID: connectionID,
                sessionToken: token,
                isAdmitted: false,
                isWelcomedConnection: false,
                revision: UUID()
            )
            sessions[hello.controllerID] = created
            connectionOwners[connectionID] = hello.controllerID
            session = created
            event = .playerJoined(info(for: created, connected: true))
        }

        let player = info(for: session, connected: true)
        let welcome = Welcome(
            player: player,
            udpPort: udpPort,
            sessionToken: token,
            hostName: hostName,
            hostInstanceID: hostInstanceID
        )
        let accepted = await transport.respond(to: connectionID, with: .accept(welcome))
        guard lifecycleGeneration == generation else { return }
        guard accepted else {
            await rollbackFailedHello(
                controllerID: hello.controllerID,
                connectionID: connectionID,
                isNewSession: isNewSession,
                generation: generation
            )
            return
        }
        guard var admitted = sessions[hello.controllerID], admitted.connectionID == connectionID else {
            await transport.disconnect(connectionID: connectionID)
            return
        }
        admitted.isAdmitted = true
        admitted.isWelcomedConnection = true
        sessions[hello.controllerID] = admitted
        refreshPlayers()
        eventHub.yield(event)
        enqueueRosterBroadcast()
    }

    private func abandonReconnectHandshake(
        on transport: HostTransport,
        connectionID: UUID,
        replacedConnectionID: UUID? = nil
    ) async {
        _ = await transport.respond(to: connectionID, with: .reject(.replaced))
        if let replacedConnectionID {
            await transport.replace(connectionID: replacedConnectionID)
        }
    }

    private func rollbackFailedHello(
        controllerID: ControllerID,
        connectionID: UUID,
        isNewSession: Bool,
        generation: UInt64
    ) async {
        guard lifecycleGeneration == generation else { return }
        guard let session = sessions[controllerID], session.connectionID == connectionID else { return }
        if isNewSession {
            sessions.removeValue(forKey: controllerID)
            connectionOwners.removeValue(forKey: connectionID)
            session.graceTask?.cancel()
            inputs.remove(session.playerID)
            refreshPlayers()
            enqueueRosterBroadcast()
            if let token = session.sessionToken { await transport?.invalidate(token: token) }
            await transport?.disconnect(connectionID: connectionID)
        } else {
            await handleDisconnect(connectionID: connectionID, generation: generation)
        }
    }

    private func handleMessage(
        connectionID: UUID,
        message: ClientMessage,
        generation: UInt64
    ) async {
        guard lifecycleGeneration == generation else { return }
        guard let controllerID = connectionOwners[connectionID], let session = sessions[controllerID],
              session.connectionID == connectionID,
              session.isAdmitted,
              session.isWelcomedConnection else { return }

        switch message {
        case .hello:
            break
        case let .rename(name):
            enqueueRename(
                name,
                controllerID: controllerID,
                connectionID: connectionID,
                generation: generation
            )
        case let .menu(action):
            eventHub.yield(.menu(playerID: session.playerID, action: action))
        case let .input(frame):
            guard frame.token == session.sessionToken else { return }
            _ = inputs.update(frame, for: session.playerID)
        case let .ping(value):
            await send(.pong(value), to: session.playerID)
        case .leave:
            await expire(controllerID: controllerID, generation: generation)
        }
    }

    private func handleDisconnect(connectionID: UUID, generation: UInt64) async {
        guard lifecycleGeneration == generation else { return }
        guard let controllerID = connectionOwners.removeValue(forKey: connectionID),
              var session = sessions[controllerID], session.connectionID == connectionID else { return }
        cancelPendingRename(for: controllerID)
        let wasAdmitted = session.isAdmitted
        let token = session.sessionToken
        session.connectionID = nil
        session.sessionToken = nil
        session.isWelcomedConnection = false
        session.revision = UUID()
        let revision = session.revision
        session.graceTask?.cancel()
        let grace = reconnectGrace
        @Dependency(\.continuousClock) var clock
        session.graceTask = Task { [weak self, grace] in
            do {
                try await clock.sleep(for: grace)
                guard !Task.isCancelled else { return }
                await self?.expire(
                    controllerID: controllerID,
                    generation: generation,
                    expectedRevision: revision
                )
            } catch {}
        }
        sessions[controllerID] = session
        refreshPlayers()
        if wasAdmitted {
            let player = info(for: session, connected: false)
            eventHub.yield(.playerDisconnected(player))
            enqueueRosterBroadcast()
        }
        if let token { await transport?.invalidate(token: token) }
    }

    private func expire(
        controllerID: ControllerID,
        generation: UInt64,
        expectedRevision: UUID? = nil
    ) async {
        guard lifecycleGeneration == generation,
              let current = sessions[controllerID],
              expectedRevision == nil || current.revision == expectedRevision else { return }
        cancelPendingRename(for: controllerID)
        _ = sessions.removeValue(forKey: controllerID)
        let session = current
        if let connectionID = session.connectionID {
            connectionOwners.removeValue(forKey: connectionID)
        }
        session.graceTask?.cancel()
        inputs.remove(session.playerID)
        refreshPlayers()
        if session.isAdmitted {
            eventHub.yield(.playerExpired(info(for: session, connected: false)))
            enqueueRosterBroadcast()
        }
        if let connectionID = session.connectionID {
            await transport?.disconnect(connectionID: connectionID)
        }
        if let token = session.sessionToken { await transport?.invalidate(token: token) }
    }

    private func enqueueRename(
        _ name: String,
        controllerID: ControllerID,
        connectionID: UUID,
        generation: UInt64
    ) {
        let pending = PendingRename(
            connectionID: connectionID,
            boundedName: DisplayName.boundedForAnalysis(name)
        )
        if renameWorkers[controllerID] != nil {
            pendingRenames[controllerID] = pending
            return
        }

        applyRename(pending, controllerID: controllerID)
        startRenameWorker(
            controllerID: controllerID,
            generation: generation
        )
    }

    private func applyRename(_ pending: PendingRename, controllerID: ControllerID) {
        guard var session = sessions[controllerID],
              session.connectionID == pending.connectionID,
              session.isAdmitted,
              session.isWelcomedConnection else { return }
        let sanitized = DisplayName.sanitized(
            pending.boundedName,
            fallback: "Player \(session.playerID.rawValue + 1)"
        )
        guard sanitized != session.displayName else { return }
        session.displayName = sanitized
        sessions[controllerID] = session
        refreshPlayers()
        enqueueRosterBroadcast()
    }

    private func startRenameWorker(
        controllerID: ControllerID,
        generation: UInt64
    ) {
        @Dependency(\.continuousClock) var continuousClock
        let clock = AnyClock(continuousClock)
        let workerID = UUID()
        let task = Task { [weak self, clock] in
            guard let self else { return }
            await self.runRenameWorker(
                controllerID: controllerID,
                workerID: workerID,
                generation: generation,
                clock: clock
            )
        }
        renameWorkers[controllerID] = RenameWorker(
            id: workerID,
            task: task
        )
    }

    private func runRenameWorker(
        controllerID: ControllerID,
        workerID: UUID,
        generation: UInt64,
        clock: AnyClock<Duration>
    ) async {
        defer { finishRenameWorker(controllerID: controllerID, workerID: workerID) }
        while !Task.isCancelled, lifecycleGeneration == generation {
            do {
                try await clock.sleep(for: renameProcessingInterval)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  lifecycleGeneration == generation,
                  renameWorkers[controllerID]?.id == workerID,
                  let pending = pendingRenames.removeValue(forKey: controllerID) else { return }
            applyRename(pending, controllerID: controllerID)
        }
    }

    private func finishRenameWorker(controllerID: ControllerID, workerID: UUID) {
        guard renameWorkers[controllerID]?.id == workerID else { return }
        renameWorkers.removeValue(forKey: controllerID)
    }

    private func cancelPendingRename(for controllerID: ControllerID) {
        renameWorkers.removeValue(forKey: controllerID)?.task.cancel()
        pendingRenames.removeValue(forKey: controllerID)
    }

    private func enqueueRosterBroadcast() {
        pendingRosterBroadcast = players
        guard rosterBroadcastTask == nil else { return }
        let generation = rosterBroadcastGeneration
        let lifecycleGeneration = lifecycleGeneration
        rosterBroadcastTask = Task { [weak self] in
            await self?.drainRosterBroadcasts(
                generation: generation,
                lifecycleGeneration: lifecycleGeneration
            )
        }
    }

    private func drainRosterBroadcasts(generation: UUID, lifecycleGeneration: UInt64) async {
        while !Task.isCancelled,
              self.lifecycleGeneration == lifecycleGeneration,
              rosterBroadcastGeneration == generation,
              let roster = pendingRosterBroadcast {
            pendingRosterBroadcast = nil
            await broadcast(.roster(roster))
        }
        if self.lifecycleGeneration == lifecycleGeneration,
           rosterBroadcastGeneration == generation {
            rosterBroadcastTask = nil
        }
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
            .filter(\.isAdmitted)
            .map {
                info(
                    for: $0,
                    connected: $0.connectionID != nil && $0.isWelcomedConnection
                )
            }
            .sorted { $0.id < $1.id }
    }
}
