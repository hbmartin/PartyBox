import Foundation
import Network
import PartyNet
import PartyNetTestSupport
import Testing

/// Raw peers send one numbered frame at a time, so each observed decision belongs to that frame.
@MainActor
final class UDPReplayRig {
  struct Peer {
    let id: ControllerID
    let player: PlayerID
    let token: UInt64
    let control: ClientControlConnection
  }

  private let rig: FaultRig
  private let tcpPort: NWEndpoint.Port
  private let udp: NetworkConnection<UDP>
  private var sequence: UInt32 = 0
  var proxy: NetworkFaultProxy { rig.proxy }

  private init(rig: FaultRig, metadata: FaultRigMetadata) throws {
    self.rig = rig
    tcpPort = try #require(NWEndpoint.Port(rawValue: metadata.tcpPort))
    let udpPort = try #require(NWEndpoint.Port(rawValue: metadata.udpPort))
    udp = NetworkConnection<UDP>(
      to: .hostPort(host: "127.0.0.1", port: udpPort),
      using: .parameters { UDP() }.peerToPeerIncluded(false)
    )
  }

  static func withRig<Result>(profile: FaultProfile, _ body: @MainActor (UDPReplayRig) async throws -> Result) async throws -> Result {
    let rig = FaultRig(profile: profile)
    let metadata = try await rig.start()
    do {
      let result = try await body(UDPReplayRig(rig: rig, metadata: metadata))
      await rig.stop()
      return result
    } catch {
      await rig.stop()
      throw error
    }
  }

  func connect(_ id: ControllerID) async throws -> Peer {
    let control = ClientControlConnection(
      to: .hostPort(host: "127.0.0.1", port: tcpPort),
      using: .parameters { clientControlStack() }.peerToPeerIncluded(false)
    )
    let welcome = try await withTimeout(.seconds(5), operationName: "connecting a UDP replay peer") {
      try await control.send(.hello(Hello(controllerID: id, displayName: "Replay")))
      guard case let .welcome(welcome) = try await control.receive().content else {
        throw PartyClientError.unexpectedHandshake
      }
      return welcome
    }
    return Peer(id: id, player: welcome.player.id, token: welcome.sessionToken, control: control)
  }

  func disconnect(_ peer: Peer) async throws {
    try await peer.control.send(.leave)
    try await waitFor("disconnecting a replay peer") {
      await !self.proxy.connectedControllerIDs().contains(peer.id)
    }
  }

  func sendMalformed() async throws {
    let before = await proxy.currentMetrics()
    try await udp.send(Data([0xff]))
    try await waitFor("rejecting a malformed datagram") {
      await self.proxy.currentMetrics().udpRejected == before.udpRejected + 1
    }
  }

  /// Returns true for a drop. A forward is complete when the host sees the numbered frame.
  func send(_ peer: Peer) async throws -> Bool {
    sequence += 1
    let frame = InputFrame(token: peer.token, sequence: sequence, clientTimeMs: 0, axisX: 0, axisY: 0)
    let before = await proxy.currentMetrics()
    try await udp.send(frame.encode())
    try await waitFor("processing UDP frame \(frame.sequence)") {
      let metrics = await self.proxy.currentMetrics()
      return metrics.udpDropped == before.udpDropped + 1
        || (metrics.udpForwarded == before.udpForwarded + 1 && self.rig.host.inputs.snapshot()[peer.player] == frame)
    }
    return await proxy.currentMetrics().udpDropped > before.udpDropped
  }

  private func waitFor(_ description: String, _ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await condition()) {
      guard ContinuousClock.now < deadline else { throw PartyNetTransportError.timedOut(description) }
      try await Task.sleep(for: .milliseconds(2))
    }
  }
}
