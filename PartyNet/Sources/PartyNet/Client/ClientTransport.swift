import Dependencies
import Foundation
import Network
import OSLog

enum ClientTransportEvent: Sendable {
  case hosts([DiscoveredHost])
  case message(connectionID: UUID, HostMessage)
  case inputSent(connectionID: UUID)
  case transportMode(connectionID: UUID, usesTCPFallback: Bool)
  case disconnected(connectionID: UUID, reason: String)
  case discoveryFailed(String)
}

public enum PartyClientError: Error, LocalizedError, Sendable {
  case invalidAddress
  case incompatibleHost
  case rejected(RejectReason)
  case unexpectedHandshake

  public var errorDescription: String? {
    switch self {
    case .invalidAddress: "The host address is invalid."
    case .incompatibleHost: "This host uses an incompatible PartyBox protocol."
    case .rejected(let reason): reason.message
    case .unexpectedHandshake: "The host returned an unexpected handshake response."
    }
  }
}

actor ClientTransport {
  nonisolated let events: AsyncStream<ClientTransportEvent>

  private struct DesiredInput: Equatable, Sendable {
    var axisX: Float = 0
    var axisY: Float = 0
    var buttons: Buttons = []
  }

  private struct Session: Sendable {
    let id: UUID
    let tcp: ClientControlConnection
    let udp: NetworkConnection<UDP>
    let welcome: Welcome
    let startedAt: AnyClock<Duration>.Instant
    var desired = DesiredInput()
    var lastUDPSent: DesiredInput?
    var lastUDPSentAt: AnyClock<Duration>.Instant?
    var lastTCPSentAt: AnyClock<Duration>.Instant?
    var lastAcknowledgedAt: AnyClock<Duration>.Instant?
    var usesTCPFallback = false
    var pingSentAt: AnyClock<Duration>.Instant?
    var pingNonce: UInt64?
    var sequence: UInt32 = 0
    var inputTask: Task<Void, Never>?
    var pingTask: Task<Void, Never>?
  }

  private let eventContinuation: AsyncStream<ClientTransportEvent>.Continuation
  private let logger = Logger(subsystem: "PartyNet", category: "ClientTransport")
  private let clock: AnyClock<Duration>
  private let inputSendInterval: Duration
  private var browser: NetworkBrowser<Bonjour>?
  private var browserTask: Task<Void, Never>?
  private var browserGeneration: UUID?
  private var receiveTasks: [UUID: Task<Void, Never>] = [:]
  private var sessions: [UUID: Session] = [:]

  init(inputSendInterval: Duration = .milliseconds(16)) {
    @Dependency(\.continuousClock) var continuousClock
    clock = AnyClock(continuousClock)
    self.inputSendInterval = max(inputSendInterval, .milliseconds(1))
    var continuation: AsyncStream<ClientTransportEvent>.Continuation!
    events = AsyncStream { continuation = $0 }
    eventContinuation = continuation
  }

  func startBrowsing() {
    guard browserTask == nil else { return }
    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = false
    let browser = NetworkBrowser(
      for: .bonjour(PartyNetConstants.serviceType, includeTxtRecord: true), using: parameters)
    self.browser = browser
    let generation = UUID()
    browserGeneration = generation
    let transport = self
    browserTask = Task { [browser, transport] in
      do {
        try await browser.run { endpoints in
          await transport.publish(endpoints)
        }
      } catch is CancellationError {
        // Expected on shutdown.
      } catch {
        transport.eventContinuation.yield(
          .discoveryFailed("Discovery failed: \(error.localizedDescription)"))
      }
      await transport.browserDidFinish(generation: generation)
    }
  }

  func connect(to host: DiscoveredHost, hello: Hello) async throws -> (UUID, Welcome) {
    guard host.isCompatible else { throw PartyClientError.incompatibleHost }
    await disconnectAllSessions()
    let connection: ClientControlConnection
    switch host.target {
    case .bonjour(let endpoint):
      connection = NetworkConnection(
        to: endpoint,
        using: .parameters { clientControlStack() }.peerToPeerIncluded(false)
      )
    case .endpoint(let endpoint):
      connection = NetworkConnection(
        to: endpoint,
        using: .parameters { clientControlStack() }.peerToPeerIncluded(false)
      )
    }

    let connectionID = UUID()
    do {
      try await withTimeout(PartyNetConstants.helloTimeout, operationName: "connecting to the host")
      {
        try await connection.send(.hello(hello))
      }
      let response = try await withTimeout(
        PartyNetConstants.helloTimeout, operationName: "waiting for host welcome"
      ) {
        try await connection.receive().content
      }
      let welcome: Welcome
      switch response {
      case .welcome(let value): welcome = value
      case .rejected(let reason): throw PartyClientError.rejected(reason)
      default: throw PartyClientError.unexpectedHandshake
      }
      guard welcome.protocolVersion == PartyNetConstants.protocolVersion else {
        throw PartyClientError.incompatibleHost
      }

      guard let remote = connection.currentPath?.remoteEndpoint ?? connection.remoteEndpoint,
        case .hostPort(let hostAddress, _) = remote,
        let udpPort = NWEndpoint.Port(rawValue: welcome.udpPort)
      else {
        throw PartyNetTransportError.invalidRemoteEndpoint
      }
      let udp = NetworkConnection<UDP>(
        to: .hostPort(host: hostAddress, port: udpPort),
        using: .parameters { UDP() }.peerToPeerIncluded(false)
      )
      var session = Session(
        id: connectionID,
        tcp: connection,
        udp: udp,
        welcome: welcome,
        startedAt: clock.now
      )
      let transport = self
      session.inputTask = Task { [transport] in
        await transport.runInputLoop(connectionID: connectionID)
      }
      session.pingTask = Task { [transport] in
        await transport.runPingLoop(connectionID: connectionID)
      }
      sessions[connectionID] = session
      receiveTasks[connectionID] = Task { [connection, transport] in
        await transport.receiveMessages(connectionID: connectionID, connection: connection)
      }
      return (connectionID, welcome)
    } catch {
      throw error
    }
  }

  func send(_ message: ClientMessage, connectionID: UUID) async throws {
    guard let session = sessions[connectionID] else { throw PartyNetTransportError.stopped }
    try await session.tcp.send(message)
  }

  func setInput(axisX: Float, axisY: Float, buttons: Buttons, connectionID: UUID) {
    guard var session = sessions[connectionID] else { return }
    session.desired = DesiredInput(
      axisX: axisX.isFinite ? min(max(axisX, -1), 1) : 0,
      axisY: axisY.isFinite ? min(max(axisY, -1), 1) : 0,
      buttons: buttons
    )
    sessions[connectionID] = session
  }

  func disconnect(connectionID: UUID, sendLeave: Bool = true) async {
    guard let session = sessions[connectionID] else { return }
    if sendLeave { try? await session.tcp.send(.leave) }
    removeSession(connectionID)
  }

  func stop() {
    browserTask?.cancel()
    browserTask = nil
    browserGeneration = nil
    browser = nil
    receiveTasks.values.forEach { $0.cancel() }
    receiveTasks.removeAll()
    for session in sessions.values {
      session.inputTask?.cancel()
      session.pingTask?.cancel()
    }
    sessions.removeAll()
  }

  private func publish(_ endpoints: [Bonjour.Endpoint]) {
    let hosts = endpoints.map(DiscoveredHost.init(endpoint:)).sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
    eventContinuation.yield(.hosts(hosts))
  }

  private func browserDidFinish(generation: UUID) {
    guard browserGeneration == generation else { return }
    browserTask = nil
    browserGeneration = nil
    browser = nil
  }

  private func disconnectAllSessions() async {
    for (connectionID, session) in sessions {
      try? await session.tcp.send(.leave)
      removeSession(connectionID)
    }
  }

  private func receiveMessages(connectionID: UUID, connection: ClientControlConnection) async {
    do {
      for try await message in connection.messages {
        if case .inputAck(let sequence) = message.content {
          acknowledgeUDP(sequence: sequence, connectionID: connectionID)
          continue
        }
        if case .pong(let nonce) = message.content,
          var session = sessions[connectionID], session.pingNonce == nonce
        {
          session.pingSentAt = nil
          session.pingNonce = nil
          sessions[connectionID] = session
        }
        eventContinuation.yield(.message(connectionID: connectionID, message.content))
      }
      endSession(connectionID, reason: "The host closed the connection.")
    } catch is CancellationError {
      // Explicit disconnect or replacement.
    } catch {
      endSession(connectionID, reason: error.localizedDescription)
    }
  }

  private func runInputLoop(connectionID: UUID) async {
    while !Task.isCancelled {
      do { try await clock.sleep(for: inputSendInterval) } catch { return }
      guard let session = sessions[connectionID] else { return }
      let now = clock.now
      let acknowledgmentIsFresh =
        session.lastAcknowledgedAt.map {
          $0.duration(to: now) < PartyNetConstants.udpReadyTimeout
        } ?? false
      let awaitingInitialAcknowledgment =
        session.lastAcknowledgedAt == nil
        && session.startedAt.duration(to: now) < PartyNetConstants.udpReadyTimeout
      let shouldFallback = !acknowledgmentIsFresh && !awaitingInitialAcknowledgment

      if shouldFallback != session.usesTCPFallback {
        if var latest = sessions[connectionID] {
          latest.usesTCPFallback = shouldFallback
          sessions[connectionID] = latest
        }
        eventContinuation.yield(
          .transportMode(
            connectionID: connectionID,
            usesTCPFallback: shouldFallback
          ))
      }

      let udpRefreshDue =
        session.lastUDPSentAt.map {
          $0.duration(to: now) >= PartyNetConstants.inputRefreshInterval
        } ?? true
      let udpChanged = session.desired != session.lastUDPSent
      if (!shouldFallback && (udpChanged || udpRefreshDue)) || (shouldFallback && udpRefreshDue) {
        await sendUDPInput(connectionID: connectionID, now: now)
      }

      guard shouldFallback else { continue }
      let tcpRateReady =
        session.lastTCPSentAt.map {
          $0.duration(to: now) >= PartyNetConstants.tcpFallbackInterval
        } ?? true
      if tcpRateReady, !(await sendTCPInput(connectionID: connectionID, now: now)) {
        return
      }
    }
  }

  private func sendUDPInput(connectionID: UUID, now: AnyClock<Duration>.Instant) async {
    guard var session = sessions[connectionID] else { return }
    let frame = makeInputFrame(from: session)
    // Record the sequence before suspending in `send`. On loopback, the acknowledgment can
    // otherwise reenter this actor before the sequence has advanced and be rejected as unsent.
    session.sequence &+= 1
    sessions[connectionID] = session
    do {
      try await session.udp.send(frame.encode())
      guard var latest = sessions[connectionID] else { return }
      latest.lastUDPSent = session.desired
      latest.lastUDPSentAt = now
      sessions[connectionID] = latest
      eventContinuation.yield(.inputSent(connectionID: connectionID))
    } catch {
      // A datagram path can fail independently. The acknowledgment deadline drives fallback.
    }
  }

  private func sendTCPInput(connectionID: UUID, now: AnyClock<Duration>.Instant) async -> Bool {
    guard var session = sessions[connectionID] else { return false }
    let frame = makeInputFrame(from: session)
    session.sequence &+= 1
    sessions[connectionID] = session
    do {
      try await session.tcp.send(.input(frame))
      guard var latest = sessions[connectionID] else { return true }
      latest.lastTCPSentAt = now
      sessions[connectionID] = latest
      eventContinuation.yield(.inputSent(connectionID: connectionID))
      return true
    } catch {
      endSession(connectionID, reason: error.localizedDescription)
      return false
    }
  }

  private func makeInputFrame(from session: Session) -> InputFrame {
    InputFrame(
      token: session.welcome.sessionToken,
      sequence: session.sequence,
      clientTimeMs: UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1_000_000),
      axisX: session.desired.axisX,
      axisY: session.desired.axisY,
      buttons: session.desired.buttons
    )
  }

  private func acknowledgeUDP(sequence: UInt32, connectionID: UUID) {
    guard var session = sessions[connectionID] else { return }
    let nextSequence = session.sequence
    let distanceFromAcknowledged = nextSequence &- sequence
    guard distanceFromAcknowledged > 0,
      distanceFromAcknowledged < (UInt32.max / 2) + 1
    else { return }
    session.lastAcknowledgedAt = clock.now
    let wasUsingFallback = session.usesTCPFallback
    session.usesTCPFallback = false
    sessions[connectionID] = session
    if wasUsingFallback {
      eventContinuation.yield(.transportMode(connectionID: connectionID, usesTCPFallback: false))
    }
  }

  private func runPingLoop(connectionID: UUID) async {
    while !Task.isCancelled {
      do { try await clock.sleep(for: PartyNetConstants.pingInterval) } catch { return }
      guard let session = sessions[connectionID] else { return }
      if let sentAt = session.pingSentAt,
        sentAt.duration(to: clock.now) >= PartyNetConstants.pingTimeout
      {
        endSession(connectionID, reason: "The host stopped responding.")
        return
      }
      let value = DispatchTime.now().uptimeNanoseconds
      if var latest = sessions[connectionID] {
        latest.pingSentAt = clock.now
        latest.pingNonce = value
        sessions[connectionID] = latest
      }
      do {
        try await session.tcp.send(.ping(value))
      } catch {
        endSession(connectionID, reason: error.localizedDescription)
        return
      }
    }
  }

  private func endSession(_ connectionID: UUID, reason: String) {
    guard sessions[connectionID] != nil else { return }
    removeSession(connectionID)
    logger.debug("Client session ended: \(reason)")
    eventContinuation.yield(.disconnected(connectionID: connectionID, reason: reason))
  }

  private func removeSession(_ connectionID: UUID) {
    guard let session = sessions.removeValue(forKey: connectionID) else { return }
    session.inputTask?.cancel()
    session.pingTask?.cancel()
    receiveTasks.removeValue(forKey: connectionID)?.cancel()
  }
}
