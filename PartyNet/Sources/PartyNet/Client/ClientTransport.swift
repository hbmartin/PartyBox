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

typealias ClientControlSender = @Sendable (
  _ connection: ClientControlConnection,
  _ message: ClientMessage
) async throws -> Void

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

struct PingWatchdog: Sendable {
  private(set) var oldestUnansweredAt: AnyClock<Duration>.Instant?
  private(set) var outstandingNonces: Set<UInt64> = []
  private var nonceOrder: [UInt64] = []
  private var sentAtByNonce: [UInt64: AnyClock<Duration>.Instant] = [:]

  mutating func record(nonce: UInt64, sentAt: AnyClock<Duration>.Instant) {
    guard outstandingNonces.insert(nonce).inserted else { return }
    nonceOrder.append(nonce)
    sentAtByNonce[nonce] = sentAt
    if nonceOrder.count == 1 { oldestUnansweredAt = sentAt }
  }

  @discardableResult
  mutating func acknowledge(nonce: UInt64) -> Bool {
    guard let acknowledgedIndex = nonceOrder.firstIndex(of: nonce) else { return false }
    for acknowledged in nonceOrder[...acknowledgedIndex] {
      outstandingNonces.remove(acknowledged)
      sentAtByNonce.removeValue(forKey: acknowledged)
    }
    nonceOrder.removeFirst(acknowledgedIndex + 1)
    oldestUnansweredAt = nonceOrder.first.flatMap { sentAtByNonce[$0] }
    return true
  }

  func hasTimedOut(at now: AnyClock<Duration>.Instant, after timeout: Duration) -> Bool {
    oldestUnansweredAt.map { $0.duration(to: now) >= timeout } ?? false
  }
}

actor ClientTransport {
  nonisolated func eventStream(
    onOverflow: @escaping @Sendable () -> Void
  ) -> AsyncStream<ClientTransportEvent> {
    eventHub.stream(onOverflow: onOverflow)
  }

  private struct DesiredInput: Equatable, Sendable {
    var axisX: Float = 0
    var axisY: Float = 0
    var buttons: Buttons = []
    var orientation: OrientationQuaternion = .identity
    var flags: InputFlags = []
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
    var lastUDPAttemptAt: AnyClock<Duration>.Instant?
    var lastTCPSentAt: AnyClock<Duration>.Instant?
    var lastAcknowledgedAt: AnyClock<Duration>.Instant?
    var usesTCPFallback = false
    var fallbackProbeSequenceFloor: UInt32?
    var pingWatchdog = PingWatchdog()
    var sequence: UInt32 = 0
    var inputTask: Task<Void, Never>?
    var pingTask: Task<Void, Never>?
  }

  private struct PendingHandshake: Sendable {
    let connection: ClientControlConnection
    let task: Task<HostMessage, Error>
  }

  private nonisolated let eventHub = EventHub<ClientTransportEvent>()
  private let logger = Logger(subsystem: "PartyNet", category: "ClientTransport")
  private let clock: AnyClock<Duration>
  private let controlSender: ClientControlSender
  private let inputSendInterval: Duration
  private let handshakeResponseHook: (@Sendable (HostMessage) async -> Void)?
  private var browser: NetworkBrowser<Bonjour>?
  private var browserTask: Task<Void, Never>?
  private var browserGeneration: UUID?
  private var receiveTasks: [UUID: Task<Void, Never>] = [:]
  private var sessions: [UUID: Session] = [:]
  private var pendingHandshakes: [UUID: PendingHandshake] = [:]
  private var leaveTasks: [UUID: Task<Void, Never>] = [:]

  init(
    inputSendInterval: Duration = .milliseconds(16),
    handshakeResponseHook: (@Sendable (HostMessage) async -> Void)? = nil,
    controlSender: @escaping ClientControlSender = { connection, message in
      try await connection.send(message)
    }
  ) {
    @Dependency(\.continuousClock) var continuousClock
    clock = AnyClock(continuousClock)
    self.inputSendInterval = max(inputSendInterval, .milliseconds(1))
    self.handshakeResponseHook = handshakeResponseHook
    self.controlSender = controlSender
  }

  deinit {
    browserTask?.cancel()
    pendingHandshakes.values.forEach { $0.task.cancel() }
    receiveTasks.values.forEach { $0.cancel() }
    leaveTasks.values.forEach { $0.cancel() }
    for session in sessions.values {
      session.inputTask?.cancel()
      session.pingTask?.cancel()
    }
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
    browserTask = Task { [browser, weak self] in
      do {
        try await browser.run { [weak self] endpoints in
          await self?.publish(endpoints)
        }
      } catch is CancellationError {
        // Expected on shutdown.
      } catch {
        self?.eventHub.yield(
          .discoveryFailed("Discovery failed: \(error.localizedDescription)"))
      }
      await self?.browserDidFinish(generation: generation)
    }
  }

  func restartBrowsing() {
    stopBrowsing()
    startBrowsing()
  }

  func connect(to host: DiscoveredHost, hello: Hello, attemptID: UUID) async throws -> (UUID, Welcome) {
    guard host.isCompatible else { throw PartyClientError.incompatibleHost }
    await cancelAllPendingHandshakes()
    disconnectAllSessions()
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
    let clock = clock
    let controlSender = controlSender
    let handshakeTask = Task { [connection] in
      try await withTimeout(
        PartyNetConstants.helloTimeout,
        clock: clock,
        operationName: "connecting to the host"
      ) {
        try await controlSender(connection, .hello(hello))
      }
      return try await withTimeout(
        PartyNetConstants.helloTimeout,
        clock: clock,
        operationName: "waiting for host welcome"
      ) {
        try await connection.receive().content
      }
    }
    pendingHandshakes[attemptID] = PendingHandshake(connection: connection, task: handshakeTask)
    var receivedWelcome = false
    do {
      let response = try await handshakeTask.value
      if case .welcome = response { receivedWelcome = true }
      if let handshakeResponseHook { await handshakeResponseHook(response) }
      guard pendingHandshakes[attemptID] != nil else { throw CancellationError() }
      let welcome: Welcome
      switch response {
      case .welcome(let value):
        welcome = value
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
      let inputSendInterval = inputSendInterval
      session.inputTask = Task { [clock, weak self] in
        while !Task.isCancelled {
          do { try await clock.sleep(for: inputSendInterval) } catch { return }
          guard await self?.runInputIteration(connectionID: connectionID) == true else { return }
        }
      }
      session.pingTask = Task { [clock, weak self] in
        while !Task.isCancelled {
          do { try await clock.sleep(for: PartyNetConstants.pingInterval) } catch { return }
          guard await self?.runPingIteration(connectionID: connectionID) == true else { return }
        }
      }
      sessions[connectionID] = session
      receiveTasks[connectionID] = Task { [connection, weak self] in
        do {
          for try await message in connection.messages {
            await self?.receiveMessage(message.content, connectionID: connectionID)
          }
          await self?.endSession(
            connectionID,
            reason: "The host closed the connection."
          )
        } catch is CancellationError {
          // Explicit disconnect or replacement.
        } catch {
          await self?.endSession(connectionID, reason: error.localizedDescription)
        }
      }
      pendingHandshakes.removeValue(forKey: attemptID)
      return (connectionID, welcome)
    } catch {
      if receivedWelcome {
        try? await sendControl(
          .leave,
          over: connection,
          operation: "leaving after an unsuccessful connection"
        )
      }
      pendingHandshakes.removeValue(forKey: attemptID)
      handshakeTask.cancel()
      throw error
    }
  }

  func cancelConnectionAttempt(_ attemptID: UUID) async {
    guard let pending = pendingHandshakes.removeValue(forKey: attemptID) else { return }
    pending.task.cancel()
    _ = try? await pending.task.value
  }

  func send(_ message: ClientMessage, connectionID: UUID) async throws {
    guard let session = sessions[connectionID] else { throw PartyNetTransportError.stopped }
    do {
      try await sendControl(
        message,
        over: session.tcp,
        operation: "sending a client message"
      )
    } catch {
      handleControlWriteFailure(error, connectionID: connectionID)
      throw error
    }
  }

  func setInput(
    axisX: Float,
    axisY: Float,
    buttons: Buttons,
    orientation: OrientationQuaternion,
    flags: InputFlags,
    connectionID: UUID
  ) {
    guard var session = sessions[connectionID] else { return }
    session.desired = DesiredInput(
      axisX: axisX.isFinite ? min(max(axisX, -1), 1) : 0,
      axisY: axisY.isFinite ? min(max(axisY, -1), 1) : 0,
      buttons: buttons,
      orientation: orientation,
      flags: flags
    )
    sessions[connectionID] = session
  }

  func disconnect(connectionID: UUID, sendLeave: Bool = true) async {
    guard let departure = detachSessionForLeave(connectionID) else { return }
    if sendLeave {
      scheduleLeave(
        over: departure.connection,
        receiveTask: departure.receiveTask,
        operation: "leaving the host"
      )
    } else {
      departure.receiveTask?.cancel()
    }
  }

  func stop() {
    stopBrowsing()
    pendingHandshakes.values.forEach { $0.task.cancel() }
    pendingHandshakes.removeAll()
    leaveTasks.values.forEach { $0.cancel() }
    leaveTasks.removeAll()
    receiveTasks.values.forEach { $0.cancel() }
    receiveTasks.removeAll()
    for session in sessions.values {
      session.inputTask?.cancel()
      session.pingTask?.cancel()
    }
    sessions.removeAll()
    eventHub.finish()
  }

  private func publish(_ endpoints: [Bonjour.Endpoint]) {
    let hosts = endpoints.map(DiscoveredHost.init(endpoint:)).sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
    eventHub.yield(.hosts(hosts))
  }

  private func browserDidFinish(generation: UUID) {
    guard browserGeneration == generation else { return }
    browserTask = nil
    browserGeneration = nil
    browser = nil
  }

  private func disconnectAllSessions() {
    let departures = Array(sessions.keys).compactMap(detachSessionForLeave)
    for departure in departures {
      scheduleLeave(
        over: departure.connection,
        receiveTask: departure.receiveTask,
        operation: "leaving a previous host"
      )
    }
  }

  private func cancelAllPendingHandshakes() async {
    let pending = Array(pendingHandshakes.values)
    pendingHandshakes.removeAll()
    for handshake in pending { handshake.task.cancel() }
    for handshake in pending { _ = try? await handshake.task.value }
  }

  private func stopBrowsing() {
    browserTask?.cancel()
    browserTask = nil
    browserGeneration = nil
    browser = nil
  }

  private func receiveMessage(_ message: HostMessage, connectionID: UUID) {
    if case .inputAck(let sequence) = message {
      acknowledgeUDP(sequence: sequence, connectionID: connectionID)
      return
    }
    if case .pingResponse(let nonce) = message,
      var session = sessions[connectionID], session.pingWatchdog.acknowledge(nonce: nonce)
    {
      sessions[connectionID] = session
    }
    eventHub.yield(.message(connectionID: connectionID, message))
  }

  private func runInputIteration(connectionID: UUID) async -> Bool {
    guard let session = sessions[connectionID] else { return false }
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
        latest.fallbackProbeSequenceFloor = shouldFallback ? latest.sequence : nil
        sessions[connectionID] = latest
      }
      eventHub.yield(
        .transportMode(
          connectionID: connectionID,
          usesTCPFallback: shouldFallback
        ))
    }

    let udpRefreshDue =
      (shouldFallback ? session.lastUDPAttemptAt : session.lastUDPSentAt).map {
        $0.duration(to: now) >= PartyNetConstants.inputRefreshInterval
      } ?? true
    let udpChanged = session.desired != session.lastUDPSent
    if (!shouldFallback && (udpChanged || udpRefreshDue)) || (shouldFallback && udpRefreshDue) {
      await sendUDPInput(connectionID: connectionID, now: now)
    }

    guard shouldFallback else { return true }
    let tcpRateReady =
      session.lastTCPSentAt.map {
        $0.duration(to: now) >= PartyNetConstants.tcpFallbackInterval
      } ?? true
    if tcpRateReady {
      return await sendTCPInput(connectionID: connectionID, now: now)
    }
    return true
  }

  private func sendUDPInput(connectionID: UUID, now: AnyClock<Duration>.Instant) async {
    guard var session = sessions[connectionID] else { return }
    let frame = makeInputFrame(from: session)
    // Record the sequence before suspending in `send`. On loopback, the acknowledgment can
    // otherwise reenter this actor before the sequence has advanced and be rejected as unsent.
    session.sequence &+= 1
    session.lastUDPAttemptAt = now
    sessions[connectionID] = session
    do {
      try await session.udp.send(frame.encode())
      guard var latest = sessions[connectionID] else { return }
      latest.lastUDPSent = session.desired
      latest.lastUDPSentAt = now
      sessions[connectionID] = latest
      eventHub.yield(.inputSent(connectionID: connectionID))
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
      try await sendControl(
        .input(frame),
        over: session.tcp,
        operation: "sending controller input over TCP"
      )
      guard var latest = sessions[connectionID] else { return true }
      latest.lastTCPSentAt = now
      sessions[connectionID] = latest
      eventHub.yield(.inputSent(connectionID: connectionID))
      return true
    } catch {
      handleControlWriteFailure(error, connectionID: connectionID)
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
      buttons: session.desired.buttons,
      orientation: session.desired.orientation,
      flags: session.desired.flags
    )
  }

  private func acknowledgeUDP(sequence: UInt32, connectionID: UUID) {
    guard var session = sessions[connectionID] else { return }
    let nextSequence = session.sequence
    let distanceFromAcknowledged = nextSequence &- sequence
    guard distanceFromAcknowledged > 0,
      distanceFromAcknowledged < (UInt32.max / 2) + 1
    else { return }
    if let floor = session.fallbackProbeSequenceFloor {
      let distanceFromFloor = sequence &- floor
      guard distanceFromFloor < (UInt32.max / 2) + 1 else { return }
    }
    session.lastAcknowledgedAt = clock.now
    let wasUsingFallback = session.usesTCPFallback
    session.usesTCPFallback = false
    session.fallbackProbeSequenceFloor = nil
    sessions[connectionID] = session
    if wasUsingFallback {
      eventHub.yield(.transportMode(connectionID: connectionID, usesTCPFallback: false))
    }
  }

  private func runPingIteration(connectionID: UUID) async -> Bool {
    guard let session = sessions[connectionID] else { return false }
    let now = clock.now
    if session.pingWatchdog.hasTimedOut(at: now, after: PartyNetConstants.pingTimeout) {
      endSession(connectionID, reason: "The host stopped responding.")
      return false
    }
    let value = DispatchTime.now().uptimeNanoseconds
    if var latest = sessions[connectionID] {
      latest.pingWatchdog.record(nonce: value, sentAt: now)
      sessions[connectionID] = latest
    }
    do {
      try await sendControl(
        .ping(value),
        over: session.tcp,
        operation: "pinging the host"
      )
      return true
    } catch {
      handleControlWriteFailure(error, connectionID: connectionID)
      return false
    }
  }

  private func endSession(_ connectionID: UUID, reason: String) {
    guard sessions[connectionID] != nil else { return }
    removeSession(connectionID)
    logger.debug("Client session ended: \(reason)")
    eventHub.yield(.disconnected(connectionID: connectionID, reason: reason))
  }

  private func removeSession(_ connectionID: UUID) {
    guard let session = sessions.removeValue(forKey: connectionID) else { return }
    session.inputTask?.cancel()
    session.pingTask?.cancel()
    receiveTasks.removeValue(forKey: connectionID)?.cancel()
  }

  private func detachSessionForLeave(
    _ connectionID: UUID
  ) -> (connection: ClientControlConnection, receiveTask: Task<Void, Never>?)? {
    guard let session = sessions.removeValue(forKey: connectionID) else { return nil }
    session.inputTask?.cancel()
    session.pingTask?.cancel()
    return (session.tcp, receiveTasks.removeValue(forKey: connectionID))
  }

  private func handleControlWriteFailure(_ error: any Error, connectionID: UUID) {
    guard isTerminalControlWriteError(error) else { return }
    endSession(connectionID, reason: error.localizedDescription)
  }

  private func scheduleLeave(
    over connection: ClientControlConnection,
    receiveTask: Task<Void, Never>?,
    operation: String
  ) {
    let taskID = UUID()
    leaveTasks[taskID] = Task { [weak self, receiveTask] in
      guard let self else {
        receiveTask?.cancel()
        return
      }
      _ = try? await self.sendControl(.leave, over: connection, operation: operation)
      receiveTask?.cancel()
      await self.finishLeaveTask(taskID)
    }
  }

  private func finishLeaveTask(_ taskID: UUID) {
    leaveTasks.removeValue(forKey: taskID)
  }

  private nonisolated func sendControl(
    _ message: ClientMessage,
    over connection: ClientControlConnection,
    operation: String
  ) async throws {
    let controlSender = controlSender
    try await withTimeout(
      PartyNetConstants.helloTimeout,
      clock: clock,
      operationName: operation
    ) {
      try await controlSender(connection, message)
    }
  }

#if DEBUG
  func simulateEventOverflowForTesting() {
    eventHub.simulateOverflowForTesting()
  }
#endif
}
