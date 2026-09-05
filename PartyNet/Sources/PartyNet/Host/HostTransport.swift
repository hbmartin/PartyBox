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

actor HostTransport {
  nonisolated var events: AsyncStream<HostTransportEvent> { eventHub.stream() }

  private nonisolated let eventHub = EventHub<HostTransportEvent>()
  private let inputs: InputStore
  private let logger = Logger(subsystem: "PartyNet", category: "HostTransport")
  private let clock: AnyClock<Duration>

  private var tcpListener: NetworkListener<HostControlProtocol>?
  private var udpListener: NetworkListener<UDP>?
  private var listenerTasks: [Task<Void, Never>] = []
  private var controlTasks: [UUID: Task<Void, Never>] = [:]
  private var udpTasks: [UUID: Task<Void, Never>] = [:]
  private var udpHandlerTokens: [UUID: UInt64] = [:]
  private var tokenUDPHandlers: [UInt64: Set<UUID>] = [:]
  private var connections: [UUID: HostControlConnection] = [:]
  private var decisions: [UUID: CheckedContinuation<HandshakeDecision, Never>] = [:]
  private var tokenToPlayer: [UInt64: PlayerID] = [:]
  private var tokenToConnection: [UInt64: UUID] = [:]
  private var lastAcknowledgmentAt: [UInt64: AnyClock<Duration>.Instant] = [:]
  private var connectionTokens: [UUID: UInt64] = [:]
  private var boundUDPPort: UInt16?
  private var lifecycleGeneration: UInt64 = 0

  private let maximumControlHandlers = PartyNetConstants.maximumControllers + 8
  private let maximumUDPHandlers = PartyNetConstants.maximumControllers * 4

  var udpPort: UInt16? { boundUDPPort }

  init(inputs: InputStore) {
    @Dependency(\.continuousClock) var continuousClock
    clock = AnyClock(continuousClock)
    self.inputs = inputs
  }

  func start(hostName: String, hostInstanceID: UUID, advertise: Bool = true) async throws -> UInt16
  {
    stop()
    let generation = lifecycleGeneration
    do {
      let udp = try NetworkListener<UDP>(
        for: nil,
        using: .parameters { UDP() }.peerToPeerIncluded(false)
      )
      udpListener = udp
      let transport = self
      let udpTask = Task { [udp, transport] in
        do {
          try await udp.run { connection in
            await transport.acceptDatagramConnection(connection, generation: generation)
          }
        } catch is CancellationError {
          // Expected during stop.
        } catch {
          await transport.listenerFailed(
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
        validate: { try await transport.requireCurrentLifecycle(generation) }
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
      let tcpTask = Task { [tcp, transport] in
        do {
          try await tcp.run { connection in
            await transport.acceptControlConnection(connection, generation: generation)
          }
        } catch is CancellationError {
          // Expected during stop.
        } catch {
          await transport.listenerFailed(
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
        validate: { try await transport.requireCurrentLifecycle(generation) }
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
      let continuation = decisions.removeValue(forKey: connectionID)
    else { return false }
    let generation = lifecycleGeneration
    do {
      switch decision {
      case .reject(let reason):
        try await connection.send(.rejected(reason))
      case .accept(let welcome):
        tokenToPlayer[welcome.sessionToken] = welcome.player.id
        tokenToConnection[welcome.sessionToken] = connectionID
        connectionTokens[connectionID] = welcome.sessionToken
        try await connection.send(.welcome(welcome))
      }
      guard lifecycleGeneration == generation, connections[connectionID] != nil else {
        if case .accept(let welcome) = decision { removeToken(welcome.sessionToken) }
        continuation.resume(returning: .reject(.malformedHello))
        return false
      }
      continuation.resume(returning: decision)
      return true
    } catch {
      if case .accept(let welcome) = decision {
        removeToken(welcome.sessionToken)
      }
      continuation.resume(returning: .reject(.malformedHello))
      return false
    }
  }

  func send(_ message: HostMessage, to connectionID: UUID) async throws {
    guard let connection = connections[connectionID] else {
      throw PartyNetTransportError.stopped
    }
    try await connection.send(message)
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
  }

  func replace(connectionID: UUID) async {
    if decisions[connectionID] != nil {
      _ = await respond(to: connectionID, with: .reject(.replaced))
    } else if let connection = connections[connectionID] {
      try? await connection.send(.rejected(.replaced))
    }
    disconnect(connectionID: connectionID)
  }

  func stop() {
    lifecycleGeneration &+= 1
    for continuation in decisions.values {
      continuation.resume(returning: .reject(.malformedHello))
    }
    decisions.removeAll()
    listenerTasks.forEach { $0.cancel() }
    listenerTasks.removeAll()
    controlTasks.values.forEach { $0.cancel() }
    controlTasks.removeAll()
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
    let transport = self
    controlTasks[connectionID] = Task { [connection, transport] in
      await transport.receiveControl(
        on: connection,
        connectionID: connectionID,
        generation: generation
      )
    }
  }

  private func receiveControl(
    on connection: HostControlConnection,
    connectionID: UUID,
    generation: UInt64
  ) async {
    guard lifecycleGeneration == generation else { return }
    connections[connectionID] = connection
    defer {
      controlTasks.removeValue(forKey: connectionID)
      let wasConnected = connections.removeValue(forKey: connectionID) != nil
      decisions.removeValue(forKey: connectionID)?.resume(returning: .reject(.malformedHello))
      if let token = connectionTokens.removeValue(forKey: connectionID) {
        invalidate(token: token)
      }
      if lifecycleGeneration == generation, wasConnected {
        eventHub.yield(.disconnected(connectionID: connectionID))
      }
    }

    do {
      let first = try await withTimeout(
        PartyNetConstants.helloTimeout,
        clock: clock,
        operationName: "waiting for controller hello"
      ) {
        try await connection.receive().content
      }
      guard case .hello(let hello) = first else {
        try? await connection.send(.rejected(.malformedHello))
        return
      }

      let decision = await withCheckedContinuation { continuation in
        decisions[connectionID] = continuation
        eventHub.yield(.hello(connectionID: connectionID, hello: hello))
      }
      guard lifecycleGeneration == generation else { return }

      switch decision {
      case .reject:
        return
      case .accept:
        break
      }

      for try await message in connection.messages {
        guard lifecycleGeneration == generation else { return }
        eventHub.yield(.message(connectionID: connectionID, message: message.content))
        if case .leave = message.content { break }
      }
    } catch is CancellationError {
      // Expected during shutdown.
    } catch {
      logger.debug("Control connection ended: \(error.localizedDescription)")
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
    let transport = self
    udpTasks[handlerID] = Task { [connection, transport] in
      await transport.receiveDatagrams(
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
    defer { removeUDPHandler(handlerID) }
    do {
      while !Task.isCancelled {
        guard lifecycleGeneration == generation else { return }
        let packet = try await withTimeout(
          PartyNetConstants.udpIdleTimeout,
          clock: clock,
          operationName: "waiting for controller input"
        ) {
          try await connection.receive().content
        }
        guard let frame = InputFrame(data: packet),
          let playerID = tokenToPlayer[frame.token],
          let connectionID = tokenToConnection[frame.token]
        else {
          continue
        }
        guard associateUDPHandler(handlerID, with: frame.token) else { return }
        // UDP and TCP fallback share a sequence stream. A TCP frame can win the race and
        // make this datagram stale for gameplay, but receipt still proves the UDP path is
        // healthy. InputStore continues to reject the stale state update.
        _ = inputs.update(frame, for: playerID)
        await acknowledge(frame, connectionID: connectionID)
      }
    } catch {
      logger.debug("UDP flow ended: \(error.localizedDescription)")
    }
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

  private func acknowledge(_ frame: InputFrame, connectionID: UUID) async {
    let now = clock.now
    if let last = lastAcknowledgmentAt[frame.token],
      last.duration(to: now) < PartyNetConstants.inputRefreshInterval
    {
      return
    }
    lastAcknowledgmentAt[frame.token] = now
    do {
      try await connections[connectionID]?.send(.inputAck(sequence: frame.sequence))
    } catch {
      logger.debug("Input acknowledgment failed: \(error.localizedDescription)")
    }
  }
}
