import Foundation
import Observation
import OSLog
import Dependencies

public enum HostEvent: Sendable {
    case playerJoined(PlayerInfo)
    case playerReconnected(PlayerInfo)
    case playerDisconnected(PlayerInfo)
    case playerExpired(PlayerInfo, controllerID: ControllerID)
    case rosterChanged([PlayerInfo])
    case application(playerID: PlayerID, payload: Data)
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
    /// A bounded stream that ends if its subscriber cannot keep up. Read the property again
    /// to subscribe afresh, or use `eventStream(onOverflow:)` to observe an overflow directly.
    public nonisolated var events: AsyncStream<HostEvent> {
        eventHub.stream(onOverflow: {})
    }

    public nonisolated func eventStream(
        onOverflow: @escaping @Sendable () -> Void
    ) -> AsyncStream<HostEvent> {
        eventHub.stream(onOverflow: onOverflow)
    }

    private struct PlayerSession {
        let controllerID: ControllerID
        let playerID: PlayerID
        var displayName: String
        var mark: PlayerMark
        let kind: PlayerKind
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

    private struct ConnectionWorker: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    private struct PendingMarkDisplacement: Sendable {
        let botControllerID: ControllerID
        let previousMark: PlayerMark
        let replacementMark: PlayerMark
    }

    private struct InitialMarkAssignment: Sendable {
        let mark: PlayerMark
        let displacement: PendingMarkDisplacement?
    }

    private enum BroadcastResult: Sendable {
        case sent
        case cancelled
        case failed(connectionID: UUID, errorDescription: String)
    }

    private nonisolated let eventHub = EventHub<HostEvent>()
    private let logger = Logger(subsystem: "PartyNet", category: "PartyHost")
    private let reconnectGrace: Duration
    private let renameProcessingInterval: Duration
    private let transportFactory: @Sendable (InputStore) -> HostTransport
    private var transport: HostTransport?
    private var transportTask: Task<Void, Never>?
    private var broadcastTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingRenames: [ControllerID: PendingRename] = [:]
    private var renameWorkers: [ControllerID: RenameWorker] = [:]
    private var helloWorkers: [UUID: ConnectionWorker] = [:]
    private var pendingPingResponses: [UUID: [UInt64]] = [:]
    private var pingWorkers: [UUID: ConnectionWorker] = [:]
    private var sessions: [ControllerID: PlayerSession] = [:]
    private var connectionOwners: [UUID: ControllerID] = [:]
    private var registeredLocalBotIDs: Set<ControllerID> = []
    private var pendingMarkDisplacements: [ControllerID: PendingMarkDisplacement] = [:]
    private var reservedInitialMarks: Set<PlayerMark> = []
    private var lifecycleGeneration: UInt64 = 0

    private static let maximumPendingPingResponsesPerConnection = 16

    public convenience init(
        reconnectGrace: Duration = PartyNetConstants.reconnectGrace,
        renameProcessingInterval: Duration = PartyNetConstants.renameProcessingInterval
    ) {
        self.init(
            reconnectGrace: reconnectGrace,
            renameProcessingInterval: renameProcessingInterval,
            transportFactory: { HostTransport(inputs: $0) }
        )
    }

    init(
        reconnectGrace: Duration = PartyNetConstants.reconnectGrace,
        renameProcessingInterval: Duration = PartyNetConstants.renameProcessingInterval,
        transportFactory: @escaping @Sendable (InputStore) -> HostTransport
    ) {
        self.reconnectGrace = reconnectGrace
        self.renameProcessingInterval = renameProcessingInterval
        self.transportFactory = transportFactory
    }

    isolated deinit {
        transportTask?.cancel()
        broadcastTasks.values.forEach { $0.cancel() }
        renameWorkers.values.forEach { $0.task.cancel() }
        helloWorkers.values.forEach { $0.task.cancel() }
        pingWorkers.values.forEach { $0.task.cancel() }
        sessions.values.forEach { $0.graceTask?.cancel() }
    }

    @discardableResult
    public func start(
        hostName: String,
        advertise: Bool = true,
        hostInstanceID suppliedHostInstanceID: UUID? = nil
    ) async throws -> UInt16 {
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        let previousTransport = prepareToStop()
        await previousTransport?.stop()
        guard lifecycleGeneration == generation else { throw PartyNetTransportError.stopped }
        self.hostName = hostName
        let hostInstanceID = suppliedHostInstanceID ?? UUID()
        self.hostInstanceID = hostInstanceID
        errorMessage = nil
        let transport = transportFactory(inputs)
        self.transport = transport
        let stream = transport.eventStream { [weak self, weak transport] in
            Task { @MainActor [weak self, weak transport] in
                guard let self, let transport else { return }
                await self.transportEventStreamOverwhelmed(
                    transport,
                    generation: generation
                )
            }
        }
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
        if case .application(let payload) = message,
           payload.count > PartyNetConstants.maximumApplicationPayloadBytes { return }
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

    public func controllerID(for playerID: PlayerID) -> ControllerID? {
        sessions.values.first { $0.playerID == playerID && $0.isAdmitted }?.controllerID
    }

    /// Marks a controller identity as a trusted in-process bot before it connects.
    /// Remote clients cannot opt into bot privileges through the wire protocol.
    public func registerLocalBot(controllerID: ControllerID) {
        registeredLocalBotIDs.insert(controllerID)
    }

    public func unregisterLocalBot(controllerID: ControllerID) {
        registeredLocalBotIDs.remove(controllerID)
    }

    /// Assigns a unique waiting-room mark. Humans can displace a bot, but never
    /// another human; the displaced bot inherits the human's previous mark.
    @discardableResult
    public func assignMark(_ mark: PlayerMark, to playerID: PlayerID) -> Bool {
        guard let requesterID = sessions.first(where: { $0.value.playerID == playerID })?.key,
              var requester = sessions[requesterID],
              requester.isAdmitted else { return false }
        guard requester.mark != mark else { return true }
        guard !reservedInitialMarks.contains(mark),
              !pendingMarkDisplacements.values.contains(where: {
                  $0.botControllerID == requesterID
              }) else { return false }

        let holders = sessions.lazy
            .filter { $0.key != requesterID && $0.value.mark == mark }
            .prefix(2)
        if let holderEntry = holders.first {
            guard requester.kind == .human,
                  holders.count == 1,
                  holderEntry.value.isAdmitted,
                  holderEntry.value.kind == .bot else { return false }
            var holder = holderEntry.value
            holder.mark = requester.mark
            sessions[holderEntry.key] = holder
        }

        requester.mark = mark
        sessions[requesterID] = requester
        refreshPlayers()
        return true
    }

    @discardableResult
    public func sendApplication(_ payload: Data, to playerID: PlayerID) async -> Bool {
        guard payload.count <= PartyNetConstants.maximumApplicationPayloadBytes else { return false }
        let generation = lifecycleGeneration
        guard let transport else { return false }
        guard let session = sessions.values.first(where: {
                  $0.playerID == playerID && $0.isAdmitted && $0.isWelcomedConnection
              }),
              let connectionID = session.connectionID,
              canBroadcast(generation: generation, over: transport) else { return false }
        do {
            try await transport.send(.application(payload), to: connectionID)
            return canBroadcast(generation: generation, over: transport)
        } catch {
            logger.debug("Application send to player \(playerID.rawValue) failed: \(error.localizedDescription)")
            return false
        }
    }

    public func broadcast(_ message: HostMessage) async {
        if case .application(let payload) = message,
           payload.count > PartyNetConstants.maximumApplicationPayloadBytes { return }
        let generation = lifecycleGeneration
        let connectionIDs = sessions.values.compactMap { session in
            session.isAdmitted && session.isWelcomedConnection ? session.connectionID : nil
        }
        guard let transport else { return }
        let broadcastID = UUID()
        let task = Task { [weak self, transport] in
            guard let self else { return }
            await withTaskGroup(of: BroadcastResult.self) { group in
                for connectionID in connectionIDs {
                    group.addTask { [weak self, transport] in
                        guard !Task.isCancelled,
                              let self,
                              await self.canBroadcast(generation: generation, over: transport)
                        else { return .cancelled }
                        do {
                            try await transport.send(message, to: connectionID)
                            return .sent
                        } catch is CancellationError {
                            return .cancelled
                        } catch {
                            return .failed(
                                connectionID: connectionID,
                                errorDescription: error.localizedDescription
                            )
                        }
                    }
                }
                for await result in group {
                    guard !Task.isCancelled,
                          self.canBroadcast(generation: generation, over: transport)
                    else {
                        group.cancelAll()
                        return
                    }
                    guard case let .failed(connectionID, errorDescription) = result else {
                        continue
                    }
                    logger.debug(
                        "Broadcast to connection \(connectionID, privacy: .public) failed: \(errorDescription)"
                    )
                }
            }
        }
        broadcastTasks[broadcastID] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        broadcastTasks.removeValue(forKey: broadcastID)
    }

    private func transportEventStreamOverwhelmed(
        _ transport: HostTransport,
        generation: UInt64
    ) async {
        guard lifecycleGeneration == generation, self.transport === transport else { return }
        let message = "The host transport event stream could not keep up."
        errorMessage = message
        eventHub.yield(.failure(message))
        await tearDown()
    }

    public func stop() async {
        await tearDown()
    }

    private func tearDown() async {
        lifecycleGeneration &+= 1
        let transport = prepareToStop()
        eventHub.finish()
        await transport?.stop()
    }

    private func prepareToStop() -> HostTransport? {
        let transport = transport
        self.transport = nil
        transportTask?.cancel()
        transportTask = nil
        broadcastTasks.values.forEach { $0.cancel() }
        broadcastTasks.removeAll()
        renameWorkers.values.forEach { $0.task.cancel() }
        renameWorkers.removeAll()
        pendingRenames.removeAll()
        helloWorkers.values.forEach { $0.task.cancel() }
        helloWorkers.removeAll()
        pingWorkers.values.forEach { $0.task.cancel() }
        pingWorkers.removeAll()
        pendingPingResponses.removeAll()
        for session in sessions.values {
            session.graceTask?.cancel()
        }
        sessions.removeAll()
        connectionOwners.removeAll()
        registeredLocalBotIDs.removeAll()
        pendingMarkDisplacements.removeAll()
        reservedInitialMarks.removeAll()
        players.removeAll()
        inputs.removeAll()
        port = nil
        return transport
    }

    private func canBroadcast(generation: UInt64, over transport: HostTransport) -> Bool {
        !Task.isCancelled
            && lifecycleGeneration == generation
            && self.transport === transport
    }

#if DEBUG
    public func configureFixture(hostName: String, players: [PlayerInfo]) {
        self.hostName = hostName
        self.players = players
    }

    public func simulateTransportEventStreamOverflowForTesting() async {
        guard let transport else { return }
        await transport.simulateEventOverflowForTesting()
    }
#endif

    private func handle(_ event: HostTransportEvent, generation: UInt64) async {
        guard lifecycleGeneration == generation else { return }
        switch event {
        case let .hello(connectionID, hello):
            enqueueHello(connectionID: connectionID, hello: hello, generation: generation)
        case let .message(connectionID, message):
            await handleMessage(connectionID: connectionID, message: message, generation: generation)
        case let .disconnected(connectionID):
            await handleDisconnect(connectionID: connectionID, generation: generation)
        case let .failure(message):
            errorMessage = message
            eventHub.yield(.failure(message))
        }
    }

    private func enqueueHello(connectionID: UUID, hello: Hello, generation: UInt64) {
        helloWorkers.removeValue(forKey: connectionID)?.task.cancel()
        let workerID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.handleHello(connectionID: connectionID, hello: hello, generation: generation)
            self.finishHelloWorker(connectionID: connectionID, workerID: workerID)
        }
        helloWorkers[connectionID] = ConnectionWorker(id: workerID, task: task)
    }

    private func finishHelloWorker(connectionID: UUID, workerID: UUID) {
        guard helloWorkers[connectionID]?.id == workerID else { return }
        helloWorkers.removeValue(forKey: connectionID)
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
            inputs.remove(existing.playerID)
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
            let kind: PlayerKind = registeredLocalBotIDs.contains(hello.controllerID) ? .bot : .human
            let markAssignment = assignInitialMark(
                preferred: hello.preferredMark,
                kind: kind,
                playerID: playerID
            )
            if let displacement = markAssignment.displacement {
                pendingMarkDisplacements[hello.controllerID] = displacement
                reservedInitialMarks.insert(displacement.previousMark)
                reservedInitialMarks.insert(displacement.replacementMark)
            }
            let created = PlayerSession(
                controllerID: hello.controllerID,
                playerID: playerID,
                displayName: DisplayName.sanitized(hello.displayName, fallback: fallbackName),
                mark: markAssignment.mark,
                kind: kind,
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
            discardPendingInitialMarkAssignment(for: hello.controllerID)
            await transport.disconnect(connectionID: connectionID)
            return
        }
        commitPendingInitialMarkAssignment(for: hello.controllerID)
        admitted.isAdmitted = true
        admitted.isWelcomedConnection = true
        sessions[hello.controllerID] = admitted
        refreshPlayers()
        eventHub.yield(event)
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
        guard let session = sessions[controllerID] else { return }
        if isNewSession {
            guard session.connectionID == connectionID
                    || (!session.isAdmitted && session.connectionID == nil) else { return }
            sessions.removeValue(forKey: controllerID)
            discardPendingInitialMarkAssignment(for: controllerID)
            connectionOwners.removeValue(forKey: connectionID)
            session.graceTask?.cancel()
            inputs.remove(session.playerID)
            refreshPlayers()
            if let token = session.sessionToken { await transport?.invalidate(token: token) }
            await transport?.disconnect(connectionID: connectionID)
        } else {
            guard session.connectionID == connectionID else { return }
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
        case let .application(payload):
            guard payload.count <= PartyNetConstants.maximumApplicationPayloadBytes else { return }
            eventHub.yield(.application(playerID: session.playerID, payload: payload))
        case let .input(frame):
            guard frame.token == session.sessionToken else { return }
            _ = inputs.update(frame, for: session.playerID)
        case let .ping(value):
            enqueuePingResponse(value, connectionID: connectionID, generation: generation)
        case .leave:
            await expire(controllerID: controllerID, generation: generation)
        }
    }

    private func enqueuePingResponse(_ nonce: UInt64, connectionID: UUID, generation: UInt64) {
        var pending = pendingPingResponses[connectionID, default: []]
        guard !pending.contains(nonce) else { return }
        guard pending.count < Self.maximumPendingPingResponsesPerConnection else {
            logger.warning(
                "Dropping excess ping response for connection \(connectionID, privacy: .public)"
            )
            return
        }
        pending.append(nonce)
        pendingPingResponses[connectionID] = pending
        guard pingWorkers[connectionID] == nil else { return }
        let workerID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainPingResponses(
                connectionID: connectionID,
                workerID: workerID,
                generation: generation
            )
        }
        pingWorkers[connectionID] = ConnectionWorker(id: workerID, task: task)
    }

    private func drainPingResponses(connectionID: UUID, workerID: UUID, generation: UInt64) async {
        defer { finishPingWorker(connectionID: connectionID, workerID: workerID) }
        while !Task.isCancelled,
              lifecycleGeneration == generation,
              pingWorkers[connectionID]?.id == workerID,
              let nonce = dequeuePingResponse(for: connectionID),
              let transport {
            do {
                try await transport.send(.pingResponse(nonce), to: connectionID)
            } catch is CancellationError {
                return
            } catch {
                logger.debug(
                    "Ping response to connection \(connectionID, privacy: .public) failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private func finishPingWorker(connectionID: UUID, workerID: UUID) {
        guard pingWorkers[connectionID]?.id == workerID else { return }
        pingWorkers.removeValue(forKey: connectionID)
    }

    private func dequeuePingResponse(for connectionID: UUID) -> UInt64? {
        guard var pending = pendingPingResponses[connectionID], !pending.isEmpty else {
            pendingPingResponses.removeValue(forKey: connectionID)
            return nil
        }
        let nonce = pending.removeFirst()
        if pending.isEmpty {
            pendingPingResponses.removeValue(forKey: connectionID)
        } else {
            pendingPingResponses[connectionID] = pending
        }
        return nonce
    }

    private func handleDisconnect(connectionID: UUID, generation: UInt64) async {
        guard lifecycleGeneration == generation else { return }
        helloWorkers.removeValue(forKey: connectionID)?.task.cancel()
        pingWorkers.removeValue(forKey: connectionID)?.task.cancel()
        pendingPingResponses.removeValue(forKey: connectionID)
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
        discardPendingInitialMarkAssignment(for: controllerID)
        let session = current
        if let connectionID = session.connectionID {
            connectionOwners.removeValue(forKey: connectionID)
        }
        session.graceTask?.cancel()
        inputs.remove(session.playerID)
        refreshPlayers()
        if session.isAdmitted {
            eventHub.yield(.playerExpired(
                info(for: session, connected: false),
                controllerID: session.controllerID
            ))
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

    private func lowestAvailablePlayerID() -> PlayerID? {
        let used = Set(sessions.values.map(\.playerID))
        return (0..<PartyNetConstants.maximumControllers)
            .map { PlayerID(UInt8($0)) }
            .first { !used.contains($0) }
    }

    private func assignInitialMark(
        preferred: PlayerMark?,
        kind: PlayerKind,
        playerID: PlayerID
    ) -> InitialMarkAssignment {
        if let preferred, !reservedInitialMarks.contains(preferred) {
            let holders = sessions.filter { $0.value.mark == preferred }
            if holders.isEmpty {
                return InitialMarkAssignment(mark: preferred, displacement: nil)
            }
            if kind == .human,
               holders.count == 1,
               let holder = holders.first,
               holder.value.kind == .bot,
               let replacement = firstAvailableMark(startingAt: holder.value.playerID) {
                return InitialMarkAssignment(
                    mark: preferred,
                    displacement: PendingMarkDisplacement(
                        botControllerID: holder.key,
                        previousMark: preferred,
                        replacementMark: replacement
                    )
                )
            }
        }

        return InitialMarkAssignment(
            mark: firstAvailableMark(startingAt: playerID)
                ?? PlayerMark.defaultMark(for: playerID),
            displacement: nil
        )
    }

    private func firstAvailableMark(startingAt playerID: PlayerID) -> PlayerMark? {
        let used = Set(sessions.values.map(\.mark)).union(reservedInitialMarks)
        let marks = PlayerMark.allCases
        let start = Int(playerID.rawValue) % marks.count
        return (0..<marks.count)
            .map { marks[(start + $0) % marks.count] }
            .first { !used.contains($0) }
    }

    private func commitPendingInitialMarkAssignment(for controllerID: ControllerID) {
        guard let displacement = pendingMarkDisplacements.removeValue(forKey: controllerID) else {
            return
        }
        reservedInitialMarks.remove(displacement.previousMark)
        reservedInitialMarks.remove(displacement.replacementMark)
        guard var bot = sessions[displacement.botControllerID],
              bot.mark == displacement.previousMark else { return }
        bot.mark = displacement.replacementMark
        sessions[displacement.botControllerID] = bot
    }

    private func discardPendingInitialMarkAssignment(for controllerID: ControllerID) {
        guard let displacement = pendingMarkDisplacements.removeValue(forKey: controllerID) else {
            return
        }
        reservedInitialMarks.remove(displacement.previousMark)
        reservedInitialMarks.remove(displacement.replacementMark)
    }

    private func info(for session: PlayerSession, connected: Bool) -> PlayerInfo {
        PlayerInfo(
            id: session.playerID,
            displayName: session.displayName,
            colorHex: PlayerPalette.color(for: session.playerID),
            isConnected: connected,
            mark: session.mark,
            kind: session.kind
        )
    }

    private func refreshPlayers() {
        let refreshedPlayers = sessions.values
            .filter(\.isAdmitted)
            .map {
                info(
                    for: $0,
                    connected: $0.connectionID != nil && $0.isWelcomedConnection
                )
            }
            .sorted { $0.id < $1.id }
        guard refreshedPlayers != players else { return }
        players = refreshedPlayers
        eventHub.yield(.rosterChanged(players))
    }
}
