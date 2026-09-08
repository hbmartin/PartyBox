import Dependencies
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

typealias HostControlSender = @Sendable (
  _ connection: HostControlConnection,
  _ message: HostMessage
) async throws -> Void

private final class HandshakeDecisionSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var decision: HandshakeDecision?
  private var continuation: CheckedContinuation<HandshakeDecision, Never>?

  func wait() async -> HandshakeDecision {
    await withCheckedContinuation { continuation in
      lock.lock()
      if let decision {
        lock.unlock()
        continuation.resume(returning: decision)
      } else {
        precondition(self.continuation == nil)
        self.continuation = continuation
        lock.unlock()
      }
    }
  }

  func resolve(_ decision: HandshakeDecision) {
    lock.lock()
    guard self.decision == nil else {
      lock.unlock()
      return
    }
    self.decision = decision
    let continuation = continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(returning: decision)
  }
}

actor HostTransport {
  nonisolated func eventStream(
    onOverflow: @escaping @Sendable () -> Void
  ) -> AsyncStream<HostTransportEvent> {
    eventHub.stream(onOverflow: onOverflow)
  }

  private nonisolated let eventHub = EventHub<HostTransportEvent>()
  private let inputs: InputStore
  private let logger = Logger(subsystem: "PartyNet", category: "HostTransport")
  private let clock: AnyClock<Duration>
  private let controlSender: HostControlSender

  private var tcpListener: NetworkListener<HostControlProtocol>?
  private var udpListener: NetworkListener<UDP>?
  private var listenerTasks: [Task<Void, Never>] = []
  private var controlTasks: [UUID: Task<Void, Never>] = [:]
  private var acknowledgmentTasks: [UUID: Task<Void, Never>] = [:]
  private var udpTasks: [UUID: Task<Void, Never>] = [:]
  private var udpHandlerTokens: [UUID: UInt64] = [:]
  private var tokenUDPHandlers: [UInt64: Set<UUID>] = [:]
  private var connections: [UUID: HostControlConnection] = [:]
  private var decisions: [UUID: HandshakeDecisionSignal] = [:]
  private var tokenToPlayer: [UInt64: PlayerID] = [:]
  private var tokenToConnection: [UInt64: UUID] = [:]
  private var lastAcknowledgmentAt: [UInt64: AnyClock<Duration>.Instant] = [:]
  private var connectionTokens: [UUID: UInt64] = [:]
  private var boundUDPPort: UInt16?
  private var lifecycleGeneration: UInt64 = 0

  private let maximumControlHandlers = PartyNetConstants.maximumControllers + 8
  private let maximumUDPHandlers = PartyNetConstants.maximumControllers * 4

  var udpPort: UInt16? { boundUDPPort }

  init(
    inputs: InputStore,
    controlSender: @escaping HostControlSender = { connection, message in
      try await connection.send(message)
    }
  ) {
    @Dependency(\.continuousClock) var continuousClock
    clock = AnyClock(continuousClock)
    self.inputs = inputs
    self.controlSender = controlSender
  }

  deinit {
    decisions.values.forEach { $0.resolve(.reject(.malformedHello)) }
    listenerTasks.forEach { $0.cancel() }
    controlTasks.values.forEach { $0.cancel() }
    acknowledgmentTasks.values.forEach { $0.cancel() }
    udpTasks.values.forEach { $0.cancel() }
  }

  func start(hostName: String, hostInstanceID: UUID, advertise: Bool = true) async throws -> UInt16
  {
    reset(finishEvents: false)
    let generation = lifecycleGeneration
    do {
      let udp = try NetworkListener<UDP>(
        for: nil,
        using: .parameters { UDP() }.peerToPeerIncluded(false)
      )
      udpListener = udp
      let udpTask = Task { [udp, weak self] in
        do {
          try await udp.run { [weak self] connection in
            await self?.acceptDatagramConnection(connection, generation: generation)
          }
        } catch is CancellationError {
          // Expected during stop.
        } catch {
          await self?.listenerFailed(
            "UDP listener failed: \(error.localizedDescription)",
            generation: generation
          )
        }
      }
      listenerTasks.append(udpTask)
      let udpPort = try await waitForBoundPort(
        of: udp,
        clock: clock,
        operation: "starting the UDP listener",
        validate: { try await self.requireCurrentLifecycle(generation) }
      )
      guard lifecycleGeneration == generation else { throw PartyNetTransportError.stopped }
      boundUDPPort = udpPort

      let provider: (any ListenerProvider)? =
        advertise
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
      tcpListener = tcp
      let tcpTask = Task { [tcp, weak self] in
        do {
          try await tcp.run { [weak self] connection in
            await self?.acceptControlConnection(connection, generation: generation)
          }
        } catch is CancellationError {
          // Expected during stop.
        } catch {
          await self?.listenerFailed(
            "TCP listener failed: \(error.localizedDescription)",
            generation: generation
          )
        }
      }
      listenerTasks.append(tcpTask)
      let tcpPort = try await waitForBoundPort(
        of: tcp,
        clock: clock,
        operation: "starting the control listener",
        validate: { try await self.requireCurrentLifecycle(generation) }
      )
      guard lifecycleGeneration == generation else { throw PartyNetTransportError.stopped }
      logger.info("PartyBox host ready on TCP \(tcpPort), UDP \(udpPort)")
      return tcpPort
    } catch {
      if lifecycleGeneration == generation { stop() }
      throw error
    }
  }

  @discardableResult
  func respond(to connectionID: UUID, with decision: HandshakeDecision) async -> Bool {
    guard let connection = connections[connectionID],
      let decisionSignal = decisions.removeValue(forKey: connectionID)
    else { return false }
    let generation = lifecycleGeneration
    do {
      switch decision {
      case .reject(let reason):
        try await sendControl(
          .rejected(reason),
          over: connection,
          connectionID: connectionID,
          operation: "sending a handshake rejection"
        )
      case .accept(let welcome):
        tokenToPlayer[welcome.sessionToken] = welcome.player.id
        tokenToConnection[welcome.sessionToken] = connectionID
        connectionTokens[connectionID] = welcome.sessionToken
        try await sendControl(
          .welcome(welcome),
          over: connection,
          connectionID: connectionID,
          operation: "sending a host welcome"
        )
      }
      guard lifecycleGeneration == generation, connections[connectionID] != nil else {
        if case .accept(let welcome) = decision { removeToken(welcome.sessionToken) }
        decisionSignal.resolve(.reject(.malformedHello))
        return false
      }
      decisionSignal.resolve(decision)
      return true
    } catch {
      if case .accept(let welcome) = decision {
        removeToken(welcome.sessionToken)
      }
      decisionSignal.resolve(.reject(.malformedHello))
      return false
    }
  }

  func send(_ message: HostMessage, to connectionID: UUID) async throws {
    guard let connection = connections[connectionID] else {
      throw PartyNetTransportError.stopped
    }
    try await sendControl(
      message,
      over: connection,
      connectionID: connectionID,
      operation: "sending a host message"
    )
  }

  func invalidate(token: UInt64) {
    removeToken(token)
    if let handlerIDs = tokenUDPHandlers.removeValue(forKey: token) {
      for handlerID in handlerIDs {
        udpHandlerTokens.removeValue(forKey: handlerID)
        udpTasks.removeValue(forKey: handlerID)?.cancel()
      }
    }
  }

  func disconnect(connectionID: UUID) {
    controlTasks.removeValue(forKey: connectionID)?.cancel()
    finishControlConnection(
      connectionID: connectionID,
      generation: lifecycleGeneration
    )
  }

  func replace(connectionID: UUID) async {
    if decisions[connectionID] != nil {
      _ = await respond(to: connectionID, with: .reject(.replaced))
    } else if let connection = connections[connectionID] {
      try? await sendControl(
        .rejected(.replaced),
        over: connection,
        connectionID: connectionID,
        operation: "notifying a replaced controller"
      )
    }
    disconnect(connectionID: connectionID)
  }

  func stop() {
    reset(finishEvents: true)
  }

  private func reset(finishEvents: Bool) {
    lifecycleGeneration &+= 1
    for decisionSignal in decisions.values {
      decisionSignal.resolve(.reject(.malformedHello))
    }
    decisions.removeAll()
    listenerTasks.forEach { $0.cancel() }
    listenerTasks.removeAll()
    controlTasks.values.forEach { $0.cancel() }
    controlTasks.removeAll()
    acknowledgmentTasks.values.forEach { $0.cancel() }
    acknowledgmentTasks.removeAll()
    udpTasks.values.forEach { $0.cancel() }
    udpTasks.removeAll()
    udpHandlerTokens.removeAll()
    tokenUDPHandlers.removeAll()
    tcpListener = nil
    udpListener = nil
    connections.removeAll()
    connectionTokens.removeAll()
    tokenToPlayer.removeAll()
    tokenToConnection.removeAll()
    lastAcknowledgmentAt.removeAll()
    boundUDPPort = nil
    if finishEvents { eventHub.finish() }
  }

  private func requireCurrentLifecycle(_ generation: UInt64) throws {
    guard lifecycleGeneration == generation else { throw PartyNetTransportError.stopped }
  }

  private func acceptControlConnection(
    _ connection: HostControlConnection,
    generation: UInt64
  ) {
    guard lifecycleGeneration == generation,
      controlTasks.count < maximumControlHandlers
    else { return }
    let connectionID = UUID()
    let clock = clock
    controlTasks[connectionID] = Task { [connection, weak self] in
      guard await self?.registerControlConnection(
        connection,
        connectionID: connectionID,
        generation: generation
      ) == true else { return }
      do {
        let first = try await withTimeout(
          PartyNetConstants.helloTimeout,
          clock: clock,
          operationName: "waiting for controller hello"
        ) {
          try await connection.receive().content
        }
        if case .hello(let hello) = first {
          let decisionSignal = HandshakeDecisionSignal()
          guard await self?.registerDecision(
            connectionID: connectionID,
            hello: hello,
            generation: generation,
            decisionSignal: decisionSignal
          ) == true else { return }
          let decision = await withTaskCancellationHandler {
            await decisionSignal.wait()
          } onCancel: {
            decisionSignal.resolve(.reject(.malformedHello))
          }
          if case .accept = decision,
            await self?.lifecycleIsCurrent(generation) == true
          {
            for try await message in connection.messages {
              guard await self?.publishControlMessage(
                message.content,
                connectionID: connectionID,
                generation: generation
              ) == true else { break }
              if case .leave = message.content { break }
            }
          }
        } else {
          try? await self?.sendControl(
            .rejected(.malformedHello),
            over: connection,
            connectionID: connectionID,
            operation: "rejecting a malformed controller hello"
          )
        }
      } catch is CancellationError {
        // Expected during shutdown.
      } catch {
        await self?.controlConnectionFailed(error.localizedDescription)
      }
      await self?.finishControlConnection(
        connectionID: connectionID,
        generation: generation
      )
    }
  }

  private func acceptDatagramConnection(
    _ connection: NetworkConnection<UDP>,
    generation: UInt64
  ) {
    guard lifecycleGeneration == generation,
      udpTasks.count < maximumUDPHandlers
    else { return }
    let handlerID = UUID()
    let clock = clock
    udpTasks[handlerID] = Task { [connection, weak self] in
      do {
        while !Task.isCancelled {
          let packet = try await withTimeout(
            PartyNetConstants.udpIdleTimeout,
            clock: clock,
            operationName: "waiting for controller input"
          ) {
            try await connection.receive().content
          }
          guard await self?.processDatagram(
            packet,
            handlerID: handlerID,
            generation: generation
          ) == true else {
            break
          }
        }
      } catch is CancellationError {
        // Expected during shutdown.
      } catch {
        await self?.datagramFlowFailed(error.localizedDescription)
      }
      await self?.removeUDPHandler(handlerID)
    }
  }

  private func registerControlConnection(
    _ connection: HostControlConnection,
    connectionID: UUID,
    generation: UInt64
  ) -> Bool {
    guard lifecycleGeneration == generation else { return false }
    connections[connectionID] = connection
    return true
  }

  private func registerDecision(
    connectionID: UUID,
    hello: Hello,
    generation: UInt64,
    decisionSignal: HandshakeDecisionSignal
  ) -> Bool {
    guard lifecycleGeneration == generation, connections[connectionID] != nil else { return false }
    decisions[connectionID] = decisionSignal
    eventHub.yield(.hello(connectionID: connectionID, hello: hello))
    return true
  }

  private func publishControlMessage(
    _ message: ClientMessage,
    connectionID: UUID,
    generation: UInt64
  ) -> Bool {
    guard lifecycleGeneration == generation, connections[connectionID] != nil else { return false }
    eventHub.yield(.message(connectionID: connectionID, message: message))
    return true
  }

  private func finishControlConnection(connectionID: UUID, generation: UInt64) {
    controlTasks.removeValue(forKey: connectionID)
    acknowledgmentTasks.removeValue(forKey: connectionID)?.cancel()
    let wasConnected = connections.removeValue(forKey: connectionID) != nil
    decisions.removeValue(forKey: connectionID)?.resolve(.reject(.malformedHello))
    if let token = connectionTokens.removeValue(forKey: connectionID) {
      invalidate(token: token)
    }
    if lifecycleGeneration == generation, wasConnected {
      eventHub.yield(.disconnected(connectionID: connectionID))
    }
  }

  private func processDatagram(
    _ packet: Data,
    handlerID: UUID,
    generation: UInt64
  ) -> Bool {
    guard lifecycleGeneration == generation else { return false }
    guard let frame = InputFrame(data: packet),
      let playerID = tokenToPlayer[frame.token],
      let connectionID = tokenToConnection[frame.token]
    else {
      return true
    }
    guard associateUDPHandler(handlerID, with: frame.token) else { return false }
    // UDP and TCP fallback share a sequence stream. A TCP frame can win the race and
    // make this datagram stale for gameplay, but receipt still proves the UDP path is
    // healthy. InputStore continues to reject the stale state update.
    _ = inputs.update(frame, for: playerID)
    acknowledge(frame, connectionID: connectionID)
    return true
  }

  private func lifecycleIsCurrent(_ generation: UInt64) -> Bool {
    lifecycleGeneration == generation
  }

  private func controlConnectionFailed(_ message: String) {
    logger.debug("Control connection ended: \(message)")
  }

  private func datagramFlowFailed(_ message: String) {
    logger.debug("UDP flow ended: \(message)")
  }

  private func associateUDPHandler(_ handlerID: UUID, with token: UInt64) -> Bool {
    if let existing = udpHandlerTokens[handlerID] { return existing == token }
    guard tokenToPlayer[token] != nil else { return false }
    udpHandlerTokens[handlerID] = token
    tokenUDPHandlers[token, default: []].insert(handlerID)
    return true
  }

  private func removeUDPHandler(_ handlerID: UUID) {
    udpTasks.removeValue(forKey: handlerID)
    guard let token = udpHandlerTokens.removeValue(forKey: handlerID) else { return }
    tokenUDPHandlers[token]?.remove(handlerID)
    if tokenUDPHandlers[token]?.isEmpty == true { tokenUDPHandlers.removeValue(forKey: token) }
  }

  private func removeToken(_ token: UInt64) {
    tokenToPlayer.removeValue(forKey: token)
    tokenToConnection.removeValue(forKey: token)
    lastAcknowledgmentAt.removeValue(forKey: token)
    if let connectionID = connectionTokens.first(where: { $0.value == token })?.key {
      connectionTokens.removeValue(forKey: connectionID)
    }
  }

  private func listenerFailed(_ message: String, generation: UInt64) {
    guard lifecycleGeneration == generation else { return }
    eventHub.yield(.failure(message))
  }

  private func acknowledge(_ frame: InputFrame, connectionID: UUID) {
    guard acknowledgmentTasks[connectionID] == nil,
      let connection = connections[connectionID]
    else { return }
    let now = clock.now
    if let last = lastAcknowledgmentAt[frame.token],
      last.duration(to: now) < PartyNetConstants.inputRefreshInterval
    {
      return
    }
    lastAcknowledgmentAt[frame.token] = now
    let sequence = frame.sequence
    acknowledgmentTasks[connectionID] = Task { [weak self, connection] in
      await self?.sendInputAcknowledgment(
        sequence: sequence,
        over: connection,
        connectionID: connectionID
      )
    }
  }

  private func sendInputAcknowledgment(
    sequence: UInt32,
    over connection: HostControlConnection,
    connectionID: UUID
  ) async {
    defer { acknowledgmentTasks.removeValue(forKey: connectionID) }
    do {
      try await sendControl(
        .inputAck(sequence: sequence),
        over: connection,
        connectionID: connectionID,
        operation: "acknowledging controller input"
      )
    } catch is CancellationError {
      // Expected when the connection or transport stops.
    } catch {
      logger.debug("Input acknowledgment failed: \(error.localizedDescription)")
    }
  }

  private func sendControl(
    _ message: HostMessage,
    over connection: HostControlConnection,
    connectionID: UUID,
    operation: String
  ) async throws {
    let controlSender = controlSender
    do {
      try await withTimeout(
        PartyNetConstants.helloTimeout,
        clock: clock,
        operationName: operation
      ) {
        try await controlSender(connection, message)
      }
    } catch {
      if isTerminalControlWriteError(error) {
        disconnect(connectionID: connectionID)
      }
      throw error
    }
  }

#if DEBUG
  func simulateEventOverflowForTesting() {
    eventHub.simulateOverflowForTesting()
  }
#endif
}
