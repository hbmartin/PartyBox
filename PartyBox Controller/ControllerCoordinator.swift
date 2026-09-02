import Foundation
import Observation
import PartyNet
import UIKit

@MainActor
@Observable
final class ControllerCoordinator {
    let client: PartyClient
    var displayName: String
    private(set) var discoveryHelpVisible = false

    private let defaults: UserDefaults
    private var eventTask: Task<Void, Never>?
    private var discoveryHelpTask: Task<Void, Never>?
    private var isStarted = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let controllerID: ControllerID
        if let stored = defaults.string(forKey: "partybox.controllerID"), let uuid = UUID(uuidString: stored) {
            controllerID = ControllerID(rawValue: uuid)
        } else {
            controllerID = ControllerID()
            defaults.set(controllerID.rawValue.uuidString, forKey: "partybox.controllerID")
        }
        let name = DisplayName.sanitized(
            defaults.string(forKey: "partybox.displayName") ?? "Player",
            fallback: "Player"
        )
        displayName = name
        client = PartyClient(controllerID: controllerID, displayName: name)
    }

    func start() async {
        guard !isStarted else { return }
        isStarted = true
        let stream = client.events
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
        await client.startBrowsing()
        discoveryHelpTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard let self, self.client.hosts.isEmpty else { return }
            self.discoveryHelpVisible = true
        }
    }

    func stop() async {
        discoveryHelpTask?.cancel()
        eventTask?.cancel()
        await client.stop()
        isStarted = false
        setIdleTimer(connected: false)
    }

    func connect(to host: DiscoveredHost) async {
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
        setIdleTimer(connected: false)
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
        }
    }
}
