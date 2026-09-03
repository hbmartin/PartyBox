import Foundation
import Observation
import PartyNet
import UIKit

@MainActor
@Observable
final class ControllerCoordinator {
    let client: PartyClient
    let configuration: ControllerLaunchConfiguration
    var displayName: String
    private(set) var discoveryHelpVisible = false

    private let defaults: UserDefaults
    private var eventTask: Task<Void, Never>?
    private var discoveryHelpTask: Task<Void, Never>?
    private var isStarted = false

    init(
        defaults: UserDefaults? = nil,
        configuration suppliedConfiguration: ControllerLaunchConfiguration? = nil
    ) {
        let configuration = suppliedConfiguration ?? .current
        self.configuration = configuration
        let defaults = defaults
            ?? configuration.defaultsSuite.flatMap(UserDefaults.init(suiteName:))
            ?? .standard
        self.defaults = defaults
        let controllerID: ControllerID
        if let configured = configuration.controllerID {
            controllerID = ControllerID(rawValue: configured)
            defaults.set(configured.uuidString, forKey: "partybox.controllerID")
        } else if let stored = defaults.string(forKey: "partybox.controllerID"), let uuid = UUID(uuidString: stored) {
            controllerID = ControllerID(rawValue: uuid)
        } else {
            controllerID = ControllerID()
            defaults.set(controllerID.rawValue.uuidString, forKey: "partybox.controllerID")
        }
        let name = DisplayName.sanitized(
            configuration.displayName ?? defaults.string(forKey: "partybox.displayName") ?? "Player",
            fallback: "Player"
        )
        displayName = name
        client = PartyClient(controllerID: controllerID, displayName: name)
#if DEBUG
        if let scenario = configuration.scenario { applyFixture(scenario: scenario) }
#endif
    }

    func start() async {
        guard !isStarted else { return }
        isStarted = true
#if DEBUG
        if configuration.scenario != nil {
            setIdleTimer(connected: isConnected)
            return
        }
#endif
        let stream = client.events
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
        await client.startBrowsing()
#if DEBUG
        if let address = configuration.hostAddress,
           let host = try? DiscoveredHost(host: address.host, port: address.port, name: "UI Test Host") {
            client.insertTestingHost(host)
        }
#endif
        armDiscoveryHelp(resetVisibility: true)
    }

    func stop() async {
        discoveryHelpTask?.cancel()
        discoveryHelpTask = nil
        eventTask?.cancel()
        eventTask = nil
        await client.stop()
        discoveryHelpVisible = false
        isStarted = false
        setIdleTimer(connected: false)
    }

    func connect(to host: DiscoveredHost) async {
        discoveryHelpTask?.cancel()
        discoveryHelpTask = nil
        discoveryHelpVisible = false
        await client.connect(to: host)
        setIdleTimer(connected: isConnected)
    }

    func rename() async {
        displayName = DisplayName.sanitized(displayName, fallback: "Player")
        defaults.set(displayName, forKey: "partybox.displayName")
        await client.rename(to: displayName)
    }

    func returnToPicker() async {
        await client.disconnect()
        await client.startBrowsing()
        armDiscoveryHelp(resetVisibility: true)
        setIdleTimer(connected: false)
    }

    func retryDiscovery() async {
        await client.startBrowsing()
        armDiscoveryHelp(resetVisibility: true)
    }

    func updateIdleTimer() {
        setIdleTimer(connected: isConnected)
    }

    var isConnected: Bool {
        if case .connected = client.state { return true }
        if case .reconnecting = client.state { return true }
        return false
    }

    private func setIdleTimer(connected: Bool) {
        UIApplication.shared.isIdleTimerDisabled = connected
    }

    private func handle(_ event: ClientEvent) {
        switch event {
        case let .feedback(feedback):
            guard !configuration.disableEffects else { return }
            switch feedback {
            case .paddleHit:
                UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.65)
            case .lostLife:
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: 1)
            case .eliminated:
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            case .won:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        case let .hostsChanged(hosts):
            if hosts.isEmpty {
                if case .browsing = client.state { armDiscoveryHelp() }
            } else {
                discoveryHelpTask?.cancel()
                discoveryHelpTask = nil
                discoveryHelpVisible = false
            }
        }
    }

    private func armDiscoveryHelp(resetVisibility: Bool = false) {
        if resetVisibility {
            discoveryHelpTask?.cancel()
            discoveryHelpTask = nil
            discoveryHelpVisible = false
        }
        guard discoveryHelpTask == nil, !discoveryHelpVisible else { return }
        discoveryHelpTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard let self else { return }
            self.discoveryHelpTask = nil
            guard self.client.hosts.isEmpty else { return }
            if case .browsing = self.client.state { self.discoveryHelpVisible = true }
        }
    }

#if DEBUG
    private func applyFixture(scenario: String) {
        let players = (0..<4).map { index in
            let id = PlayerID(UInt8(index))
            return PlayerInfo(
                id: id,
                displayName: ["Ada", "Grace", "Katherine", "Margaret"][index],
                colorHex: PlayerPalette.color(for: id),
                isConnected: index != 2
            )
        }
        let currentPlayer = players[0]
        let host = try? DiscoveredHost(
            host: "127.0.0.1",
            port: 49_999,
            name: "Living Room PartyBox",
            protocolVersion: PartyNetConstants.protocolVersion,
            instanceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        )
        let incompatible = try? DiscoveredHost(
            host: "127.0.0.1",
            port: 49_998,
            name: "Old PartyBox",
            protocolVersion: 999,
            instanceID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        )

        switch scenario {
        case "empty-picker":
            client.configureFixture(state: .browsing)
        case "populated-picker":
            client.configureFixture(state: .browsing, hosts: [host, incompatible].compactMap { $0 })
        case "connecting":
            client.configureFixture(state: .connecting("Living Room PartyBox"))
        case "menu":
            client.configureFixture(
                state: .connected("Living Room PartyBox"), player: currentPlayer, roster: players,
                layout: .menu(items: ["FOUR-WAY PONG"], selected: 0)
            )
        case "paddle-bottom", "paddle-top", "paddle-left", "paddle-right":
            let edge: PaddleEdge = switch scenario {
            case "paddle-top": .top
            case "paddle-left": .left
            case "paddle-right": .right
            default: .bottom
            }
            client.configureFixture(
                state: .connected("Living Room PartyBox"), player: currentPlayer, roster: players,
                layout: .paddle(PaddleLayout(edge: edge, colorHex: currentPlayer.colorHex, label: "P1 Ada"))
            )
        case "spectator":
            client.configureFixture(
                state: .connected("Living Room PartyBox"), player: currentPlayer, roster: players,
                layout: .spectator(SpectatorLayout(queuePosition: 2))
            )
        case "game-over":
            client.configureFixture(
                state: .connected("Living Room PartyBox"), player: currentPlayer, roster: players,
                layout: .gameOver(title: "P1 ADA WINS", subtitle: "Winner stays")
            )
        case "reconnecting":
            client.configureFixture(state: .reconnecting("Connection interrupted"), player: currentPlayer, roster: players)
        case "full-rejection":
            client.configureFixture(state: .rejected(RejectReason.full.message))
        case "version-rejection":
            client.configureFixture(state: .rejected(RejectReason.versionMismatch(hostVersion: 999).message))
        case "local-network-denial":
            client.configureFixture(state: .browsing, discoveryErrorMessage: "Local Network policy denied")
            discoveryHelpVisible = true
        case "connection-loss":
            client.configureFixture(state: .disconnected("The host is no longer reachable."), player: currentPlayer)
        default:
            client.configureFixture(
                state: .connected("Living Room PartyBox"), player: currentPlayer, roster: players, layout: .lobby
            )
        }
    }
#endif
}
