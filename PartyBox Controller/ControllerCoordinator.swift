import CoreMotion
import Foundation
import Observation
import PartyBoxCore
import PartyNet
import UIKit

@MainActor
@Observable
final class ControllerCoordinator {
    struct MotionRetryBackoff {
        static let recoverySampleThreshold = 60
        static let maximumRetryExponent = 4
        static let maximumFailureCount = maximumRetryExponent + 1

        private(set) var failureCount = 0
        private(set) var successfulSampleCount = 0

        mutating func recordFailure() -> Duration {
            successfulSampleCount = 0
            failureCount = min(failureCount + 1, Self.maximumFailureCount)
            return ControllerCoordinator.motionRetryDelay(failureCount: failureCount)
        }

        mutating func recordSuccessfulSample() {
            guard failureCount > 0 else { return }
            successfulSampleCount += 1
            guard successfulSampleCount >= Self.recoverySampleThreshold else { return }
            reset()
        }

        mutating func reset() {
            failureCount = 0
            successfulSampleCount = 0
        }
    }

    struct MotionSampleTolerance {
        static let consecutiveMissingSampleLimit = 3

        private(set) var consecutiveMissingSamples = 0

        mutating func recordMissingSample() -> Bool {
            consecutiveMissingSamples += 1
            return consecutiveMissingSamples >= Self.consecutiveMissingSampleLimit
        }

        mutating func recordSuccessfulSample() {
            consecutiveMissingSamples = 0
        }

        mutating func reset() {
            consecutiveMissingSamples = 0
        }
    }

    struct DeviceCueDeliveryPolicy: Equatable {
        let playsHaptic: Bool
        let presentsColor: Bool
    }

    let client: PartyClient
    let configuration: ControllerLaunchConfiguration
    var displayName: String
    private(set) var savedDisplayName: String
    private(set) var discoveryHelpVisible = false
    private(set) var roster: [PlayerInfo] = []
    private(set) var layout: PartyBoxCore.ControllerLayout = .lobby(.waiting) {
        didSet {
            if case .game(let envelope) = layout {
                controllerScreen = envelope.validatedControllerScreen
            } else {
                controllerScreen = nil
            }
        }
    }
    private(set) var controllerScreen: ControllerScreen?
    private(set) var personalHistory: [PersonalMatchRecord] = []
    private(set) var personalCupHistory: [PersonalCupRecord] = []
    private(set) var historyPersistenceError: String?
    private(set) var currentDeviceCue: DeviceCue?
    var motionControlEnabled: Bool {
        didSet {
            defaults.set(motionControlEnabled, forKey: "partybox.motionControlEnabled")
            if !motionControlEnabled {
                client.setOrientation(.identity, available: false)
                client.setInput(axisX: 0, axisY: 0)
            }
            updateMotionCapture()
        }
    }
    var deviceEffectsEnabled: Bool {
        didSet {
            defaults.set(deviceEffectsEnabled, forKey: "partybox.deviceEffectsEnabled")
            if !deviceEffectsEnabled {
                currentDeviceCue = nil
                deviceCueTask?.cancel()
                deviceCueTask = nil
            }
        }
    }
    var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: "partybox.hapticsEnabled") }
    }

    var personalStatistics: HistoryStatistics { HistoryAggregation.personal(personalHistory) }
    var soloStatistics: HistoryStatistics { HistoryAggregation.solo(personalHistory) }
    var cupStatistics: CupStatistics { HistoryAggregation.cups(personalCupHistory) }
    var currentPlayer: PlayerInfo? {
        guard let welcomedPlayer = client.player else { return nil }
        return roster.first(where: { $0.id == welcomedPlayer.id }) ?? welcomedPlayer
    }
    var displayedInputAxisX: Float {
        client.inputAxisX
    }
    private(set) var motionNeutralAxisX: Float
    private(set) var motionNeutralAxisY: Float

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let historyStore: JSONRecordStore<PersonalMatchRecord>
    @ObservationIgnored private let cupHistoryStore: JSONRecordStore<PersonalCupRecord>
    @ObservationIgnored private let motionManager = CMMotionManager()
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var eventGeneration: UUID?
    @ObservationIgnored private var discoveryHelpTask: Task<Void, Never>?
    @ObservationIgnored private var discoveryHelpGeneration: UUID?
    @ObservationIgnored private var stopOperation: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var motionCaptureGeneration: UUID?
    @ObservationIgnored private var motionRetryTask: Task<Void, Never>?
    @ObservationIgnored private var motionRetryBackoff = MotionRetryBackoff()
    @ObservationIgnored private var motionSampleTolerance = MotionSampleTolerance()
    @ObservationIgnored private var deviceCueTask: Task<Void, Never>?
    @ObservationIgnored private var lifecycleGeneration: UUID?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var isSceneActive = true
#if DEBUG
    @ObservationIgnored private var startLoadCheckpointForTesting: (@MainActor () async -> Void)?
#endif

    init(
        defaults: UserDefaults? = nil,
        configuration suppliedConfiguration: ControllerLaunchConfiguration? = nil,
        historyFileURL: URL? = nil
    ) {
        let configuration = suppliedConfiguration ?? .current
        self.configuration = configuration
        let defaults = defaults
            ?? configuration.defaultsSuite.flatMap(UserDefaults.init(suiteName:))
            ?? .standard
        self.defaults = defaults
        motionControlEnabled = defaults.bool(forKey: "partybox.motionControlEnabled")
        deviceEffectsEnabled = defaults.object(forKey: "partybox.deviceEffectsEnabled") as? Bool ?? true
        hapticsEnabled = defaults.object(forKey: "partybox.hapticsEnabled") as? Bool ?? true
        motionNeutralAxisX = Float(defaults.double(forKey: "partybox.motionNeutralAxisX"))
        motionNeutralAxisY = Float(defaults.double(forKey: "partybox.motionNeutralAxisY"))
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
        savedDisplayName = name
        let preferredMark: PlayerMark
        if let rawMark = defaults.string(forKey: "partybox.preferredMark"),
           let storedMark = PlayerMark(rawValue: rawMark) {
            preferredMark = storedMark
        } else {
            preferredMark = PlayerMark.defaultMark(for: controllerID)
            defaults.set(preferredMark.rawValue, forKey: "partybox.preferredMark")
        }
        client = PartyClient(
            controllerID: controllerID,
            displayName: name,
            preferredMark: preferredMark
        )
        let defaultURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PartyBox Controller", isDirectory: true)
            .appendingPathComponent("history-\(controllerID.rawValue.uuidString)-v1.json")
        let resolvedHistoryURL = historyFileURL ?? defaultURL
        historyStore = JSONRecordStore(fileURL: configuration.isUITesting ? nil : resolvedHistoryURL)
        let cupURL = resolvedHistoryURL?.deletingLastPathComponent()
            .appendingPathComponent("cups-\(controllerID.rawValue.uuidString)-v1.json")
        cupHistoryStore = JSONRecordStore(fileURL: configuration.isUITesting ? nil : cupURL)
#if DEBUG
        if let scenario = configuration.scenario { applyFixture(scenario: scenario) }
#endif
    }

    func start() async {
        if let operation = stopOperation {
            await operation.task.value
            if stopOperation?.id == operation.id { stopOperation = nil }
        }
        guard !isStarted else { return }
        let generation = UUID()
        lifecycleGeneration = generation
        isStarted = true
        async let storedMatches = historyStore.all()
        async let storedCups = cupHistoryStore.all()
        let (matches, cups) = await (storedMatches, storedCups)
#if DEBUG
        if let checkpoint = startLoadCheckpointForTesting { await checkpoint() }
#endif
        guard isStarted, lifecycleGeneration == generation else { return }
        personalHistory = matches.sorted { $0.endedAt > $1.endedAt }
        personalCupHistory = cups.sorted { $0.endedAt > $1.endedAt }
#if DEBUG
        if let scenario = configuration.scenario {
            applyFixture(scenario: scenario)
            setIdleTimer(connected: isConnected)
            updateMotionCapture()
            return
        }
#endif
        startEventTask()
#if DEBUG
        if let hostAddressError = configuration.hostAddressError {
            client.configureFixture(state: .disconnected(hostAddressError.localizedDescription))
            return
        }
#endif
        await client.startBrowsing()
        guard isStarted, lifecycleGeneration == generation else { return }
#if DEBUG
        if let address = configuration.hostAddress,
           let host = try? DiscoveredHost(host: address.host, port: address.port, name: "UI Test Host") {
            client.insertTestingHost(host)
        }
#endif
        armDiscoveryHelp(resetVisibility: true)
    }

    func stop() async {
        if let operation = stopOperation {
            await operation.task.value
            return
        }
        isStarted = false
        lifecycleGeneration = nil
        eventGeneration = nil
        discoveryHelpTask?.cancel()
        discoveryHelpTask = nil
        discoveryHelpGeneration = nil
        eventTask?.cancel()
        eventTask = nil
        discoveryHelpVisible = false
        resetSessionPresentation()
        deviceCueTask?.cancel()
        deviceCueTask = nil
        setIdleTimer(connected: false)
        let id = UUID()
        let task = Task { [client] in await client.stop() }
        stopOperation = (id, task)
        await task.value
        if stopOperation?.id == id { stopOperation = nil }
    }

    func connect(to host: DiscoveredHost) async {
        discoveryHelpTask?.cancel()
        discoveryHelpTask = nil
        discoveryHelpGeneration = nil
        discoveryHelpVisible = false
        resetSessionPresentation()
        await client.connect(to: host)
        setIdleTimer(connected: isConnected)
        updateMotionCapture()
    }

    func rename() async {
        displayName = DisplayName.sanitized(displayName, fallback: "Player")
        defaults.set(displayName, forKey: "partybox.displayName")
        savedDisplayName = displayName
        await client.rename(to: displayName)
    }

    func returnToPicker() async {
        resetSessionPresentation()
        await client.disconnect()
        guard isStarted else { return }
        await client.startBrowsing()
        guard isStarted else { return }
        armDiscoveryHelp(resetVisibility: true)
        setIdleTimer(connected: false)
    }

    func retryDiscovery() async {
        guard isStarted else { return }
        await client.restartBrowsing()
        guard isStarted else { return }
        armDiscoveryHelp(resetVisibility: true)
    }

    func sendMenu(_ action: PartyBoxCore.MenuAction) async { await send(.menu(action)) }

    func selectMark(_ mark: PlayerMark) async {
        defaults.set(mark.rawValue, forKey: "partybox.preferredMark")
        client.setPreferredMark(mark)
        await send(.lobby(.selectMark(mark)))
    }

    func setBotFillTarget(_ target: Int) async {
        await send(.lobby(.setBotFillTarget(target)))
    }

    func sendGameAction(id: String, value: ControllerActionValue, gameID: String) async {
        await send(.game(.init(gameID: gameID, action: .init(id: id, value: value))))
    }

    func sendSpectator(_ action: SpectatorAction) async { await send(.spectator(action)) }

    func calibrateMotion() {
        motionNeutralAxisX = client.inputOrientation.horizontalTiltAxis()
        motionNeutralAxisY = client.inputOrientation.verticalTiltAxis()
        defaults.set(Double(motionNeutralAxisX), forKey: "partybox.motionNeutralAxisX")
        defaults.set(Double(motionNeutralAxisY), forKey: "partybox.motionNeutralAxisY")
        client.setInput(axisX: 0, axisY: 0)
        play(.success)
    }

    func makeRedactedDiagnosticsFile() -> URL? {
        struct Report: Codable {
            let generatedAt: Date
            let role: String
            let protocolVersion: UInt16
            let connectionState: String
            let layout: String
            let rttMilliseconds: Double?
            let inputFramesSent: UInt64
            let motionEnabled: Bool
            let effectsEnabled: Bool
            let savedMatches: Int
            let savedCups: Int
            let historyPersistenceHealthy: Bool
        }
        let stateName: String = switch client.state {
        case .browsing: "browsing"
        case .connecting: "connecting"
        case .connected: "connected"
        case .reconnecting: "reconnecting"
        case .rejected: "rejected"
        case .disconnected: "disconnected"
        }
        let layoutName: String = switch layout {
        case .lobby: "lobby"
        case .menu: "menu"
        case .game: "game"
        case .gameOver: "gameOver"
        case .historyNavigation: "history"
        }
        let generatedAt = Date()
        let report = Report(
            generatedAt: generatedAt,
            role: "controller",
            protocolVersion: PartyNetConstants.protocolVersion,
            connectionState: stateName,
            layout: layoutName,
            rttMilliseconds: client.rttMilliseconds,
            inputFramesSent: client.inputFramesSent,
            motionEnabled: motionControlEnabled,
            effectsEnabled: deviceEffectsEnabled,
            savedMatches: personalHistory.count,
            savedCups: personalCupHistory.count,
            historyPersistenceHealthy: historyPersistenceError == nil
        )
        do {
            return try RedactedDiagnosticsExporter.write(report, role: .controller)
        } catch {
            return nil
        }
    }

    func clearPersonalHistory() async {
        var failures: [String] = []
        do {
            try await historyStore.clear()
            personalHistory = []
        } catch {
            failures.append(error.localizedDescription)
        }
        do {
            try await cupHistoryStore.clear()
            personalCupHistory = []
        } catch {
            failures.append(error.localizedDescription)
        }
        historyPersistenceError = failures.isEmpty
            ? nil
            : "History could not be cleared: \(failures.joined(separator: "; "))"
    }

    func scenePhaseChanged(isActive: Bool) {
        isSceneActive = isActive
        if isActive { client.reconnectAfterForeground() }
        updateMotionCapture()
    }

    func updateIdleTimer() {
        setIdleTimer(connected: isConnected)
        updateMotionCapture()
    }

    var isConnected: Bool {
        if case .connected = client.state { return true }
        if case .reconnecting = client.state { return true }
        return false
    }

    private func send(_ command: ControllerCommand) async {
        guard let payload = try? PartyBoxWireCodec.encode(command) else { return }
        _ = await client.sendApplication(payload)
    }

    private func setIdleTimer(connected: Bool) { UIApplication.shared.isIdleTimerDisabled = connected }

    private func handle(_ event: ClientEvent) async {
        guard isStarted else { return }
        switch event {
        case let .application(payload):
            guard let presentation = try? PartyBoxWireCodec.decode(HostPresentation.self, from: payload) else { return }
            switch presentation {
            case .roster(let players): roster = players
            case .layout(let value):
                if layout != value, layout.isGame || value.isGame {
                    client.setInput(axisX: 0, axisY: 0, buttons: [])
                }
                layout = value
                updateMotionCapture()
            case .haptic(let pattern): play(pattern)
            case .deviceCue(let cue): show(cue)
            case .matchCompleted(let record):
                await appendPersonalHistory(record)
            case .cupCompleted(let record):
                await appendPersonalCupHistory(record)
            }
        case let .hostsChanged(hosts):
            if hosts.isEmpty {
                if case .browsing = client.state { armDiscoveryHelp() }
            } else {
                discoveryHelpTask?.cancel()
                discoveryHelpTask = nil
                discoveryHelpGeneration = nil
                discoveryHelpVisible = false
            }
        case .sessionReset:
            resetSessionPresentation()
        }
    }

    private func resetSessionPresentation() {
        stopMotionCapture()
        layout = .lobby(.waiting)
        roster = []
        currentDeviceCue = nil
        deviceCueTask?.cancel()
        deviceCueTask = nil
    }

    private func play(_ pattern: HapticPattern) {
        guard !configuration.disableEffects, hapticsEnabled else { return }
        switch pattern {
        case .lightImpact: UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.65)
        case .heavyImpact: UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: 1)
        case .error: UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func show(_ cue: DeviceCue) {
        let policy = Self.deviceCueDeliveryPolicy(
            effectsGloballyDisabled: configuration.disableEffects,
            deviceEffectsEnabled: deviceEffectsEnabled,
            hapticsEnabled: hapticsEnabled,
            containsHaptic: cue.haptic != nil
        )
        if policy.playsHaptic, let haptic = cue.haptic { play(haptic) }
        guard policy.presentsColor else { return }
        currentDeviceCue = cue
        deviceCueTask?.cancel()
        deviceCueTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(cue.durationMilliseconds))
            guard !Task.isCancelled, self?.currentDeviceCue?.id == cue.id else { return }
            self?.currentDeviceCue = nil
            self?.deviceCueTask = nil
        }
    }

    static func deviceCueDeliveryPolicy(
        effectsGloballyDisabled: Bool,
        deviceEffectsEnabled: Bool,
        hapticsEnabled: Bool,
        containsHaptic: Bool
    ) -> DeviceCueDeliveryPolicy {
        DeviceCueDeliveryPolicy(
            playsHaptic: !effectsGloballyDisabled && hapticsEnabled && containsHaptic,
            presentsColor: !effectsGloballyDisabled && deviceEffectsEnabled
        )
    }

    private var requestedInputs: RequestedInputs {
        controllerScreen?.requestedInputs ?? []
    }

    private func appendPersonalHistory(_ record: PersonalMatchRecord) async {
        let result = await historyStore.append(record)
        guard result.wasInserted else { return }
        if !personalHistory.contains(where: { $0.id == record.id }) {
            personalHistory.insert(record, at: 0)
        }
        if let error = result.persistenceErrorDescription {
            historyPersistenceError = "This match is available for this session but could not be saved: \(error)"
        } else {
            historyPersistenceError = nil
        }
    }

    private func appendPersonalCupHistory(_ record: PersonalCupRecord) async {
        let result = await cupHistoryStore.append(record)
        guard result.wasInserted else { return }
        if !personalCupHistory.contains(where: { $0.id == record.id }) {
            personalCupHistory.insert(record, at: 0)
        }
        if let error = result.persistenceErrorDescription {
            historyPersistenceError = "This Party Cup is available now but could not be saved: \(error)"
        }
    }

    private func updateMotionCapture() {
        let shouldRun = isStarted && isSceneActive && isConnected
            && motionControlEnabled && requestedInputs.contains(.orientation)
            && motionManager.isDeviceMotionAvailable
        guard shouldRun else {
            stopMotionCapture()
            return
        }
        guard !motionManager.isDeviceMotionActive else { return }
        guard motionRetryTask == nil else { return }
        let generation = UUID()
        motionCaptureGeneration = generation
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, error in
            MainActor.assumeIsolated {
                guard let self, self.motionCaptureGeneration == generation else { return }
                if error != nil {
                    self.handleMotionCaptureFailure(generation: generation)
                    return
                }
                guard let quaternion = motion?.attitude.quaternion else {
                    if self.motionSampleTolerance.recordMissingSample() {
                        self.handleMotionCaptureFailure(generation: generation)
                    }
                    return
                }
                self.motionSampleTolerance.recordSuccessfulSample()
                self.motionRetryBackoff.recordSuccessfulSample()
                let orientation = OrientationQuaternion(
                    x: Float(quaternion.x), y:Float(quaternion.y),
                    z: Float(quaternion.z), w: Float(quaternion.w)
                )
                self.client.setInput(
                    axisX: orientation.horizontalTiltAxis() - self.motionNeutralAxisX,
                    axisY: orientation.verticalTiltAxis() - self.motionNeutralAxisY
                )
                self.client.setOrientation(orientation)
            }
        }
    }

    private func stopMotionCapture() {
        let wasCapturingMotion = motionCaptureGeneration != nil
            || motionRetryTask != nil
            || motionManager.isDeviceMotionActive
        motionCaptureGeneration = nil
        motionRetryTask?.cancel()
        motionRetryTask = nil
        motionRetryBackoff.reset()
        motionSampleTolerance.reset()
        if motionManager.isDeviceMotionActive { motionManager.stopDeviceMotionUpdates() }
        client.setOrientation(.identity, available: false)
        if wasCapturingMotion { client.setInput(axisX: 0, axisY: 0) }
    }

    private func handleMotionCaptureFailure(generation: UUID) {
        guard motionCaptureGeneration == generation else { return }
        motionCaptureGeneration = nil
        motionSampleTolerance.reset()
        if motionManager.isDeviceMotionActive { motionManager.stopDeviceMotionUpdates() }
        client.setOrientation(.identity, available: false)
        client.setInput(axisX: 0, axisY: 0)
        guard motionRetryTask == nil else { return }
        let delay = motionRetryBackoff.recordFailure()
        motionRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.motionRetryTask = nil
            self.updateMotionCapture()
        }
    }

    static func motionRetryDelay(failureCount: Int) -> Duration {
        let exponent = min(max(failureCount - 1, 0), MotionRetryBackoff.maximumRetryExponent)
        return .seconds(1 << exponent)
    }

    private func startEventTask() {
        let generation = UUID()
        eventGeneration = generation
        let stream = client.eventStream { [weak self] in
            Task { @MainActor [weak self] in self?.restartEventTaskIfNeeded(generation: generation, cancelConsumer: true) }
        }
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
            self?.restartEventTaskIfNeeded(generation: generation, cancelConsumer: false)
        }
    }

    private func restartEventTaskIfNeeded(generation: UUID, cancelConsumer: Bool) {
        guard isStarted, eventGeneration == generation else { return }
        eventGeneration = nil
        let consumer = eventTask
        eventTask = nil
        if cancelConsumer { consumer?.cancel() }
        startEventTask()
    }

    private func armDiscoveryHelp(resetVisibility: Bool = false) {
        if resetVisibility {
            discoveryHelpTask?.cancel()
            discoveryHelpTask = nil
            discoveryHelpGeneration = nil
            discoveryHelpVisible = false
        }
        guard isStarted, client.hosts.isEmpty, discoveryHelpTask == nil, !discoveryHelpVisible else { return }
        let generation = UUID()
        discoveryHelpGeneration = generation
        discoveryHelpTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard let self, !Task.isCancelled, self.isStarted, self.discoveryHelpGeneration == generation else { return }
            self.discoveryHelpTask = nil
            self.discoveryHelpGeneration = nil
            guard self.client.hosts.isEmpty else { return }
            if case .browsing = self.client.state { self.discoveryHelpVisible = true }
        }
    }

#if DEBUG
    func appendPersonalHistoryForTesting(_ record: PersonalMatchRecord) async {
        await appendPersonalHistory(record)
    }

    func setStartLoadCheckpointForTesting(_ checkpoint: (@MainActor () async -> Void)?) {
        startLoadCheckpointForTesting = checkpoint
    }

    func refreshMotionCaptureForTesting() {
        updateMotionCapture()
    }

    func handleForTesting(_ event: ClientEvent) async {
        await handle(event)
    }

    private func applyFixture(scenario: String) {
        let players = (0..<4).map { index in
            let id = PlayerID(UInt8(index))
            return PlayerInfo(
                id: id,
                displayName: ["Ada", "Grace", "Katherine", "Bot 1"][index],
                colorHex: PlayerPalette.color(for: id),
                isConnected: index != 2,
                kind: index == 3 ? .bot : .human
            )
        }
        let currentPlayer = players[0]
        let member = players[1]
        let captainControl = PartyControlStatus(
            captainID: currentPlayer.id,
            isCaptain: true,
            isReady: false,
            readyCount: 2,
            requiredReadyCount: 2
        )
        let memberControl = PartyControlStatus(
            captainID: currentPlayer.id,
            isCaptain: false,
            isReady: true,
            readyCount: 2,
            requiredReadyCount: 2
        )
        let captainLobby = LobbyLayout(
            captainID: currentPlayer.id,
            isCaptain: true,
            botFillTarget: 2,
            activeBotCount: 1,
            maximumBotCount: PartyBoxRuntimeLimits.maximumLobbyBots,
            botDifficulty: "HARD"
        )
        let memberLobby = LobbyLayout(
            captainID: currentPlayer.id,
            isCaptain: false,
            botFillTarget: 2,
            activeBotCount: 1,
            maximumBotCount: PartyBoxRuntimeLimits.maximumLobbyBots,
            botDifficulty: "HARD"
        )
        let host = try? DiscoveredHost(host: "127.0.0.1", port: 49_999, name: "Living Room PartyBox", protocolVersion: PartyNetConstants.protocolVersion, instanceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let incompatible = try? DiscoveredHost(host: "127.0.0.1", port: 49_998, name: "Old PartyBox", protocolVersion: 999, instanceID: UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        roster = players
        switch scenario {
        case "empty-picker": client.configureFixture(state: .browsing)
        case "populated-picker": client.configureFixture(state: .browsing, hosts: [host, incompatible].compactMap { $0 })
        case "connecting": client.configureFixture(state: .connecting("Living Room PartyBox"))
        case "lobby":
            client.configureFixture(state: .connected("Living Room PartyBox"), player: currentPlayer)
            layout = .lobby(captainLobby)
        case "lobby-member":
            client.configureFixture(state: .connected("Living Room PartyBox"), player: member)
            layout = .lobby(memberLobby)
        case "menu":
            client.configureFixture(state: .connected("Living Room PartyBox"), player: currentPlayer)
            layout = .menu(.init(
                items: ["FOUR-WAY PONG", "SIGNAL SNAP", "GRAVITY GRAB", "SNAKE PIT", "LAST LIGHT", "PARTY CUP", "HISTORY & LEADERBOARD"],
                details: ["Pong, expanded", "Match the TV", "Swing around the ring", "Three quick lives", "Dodge the red", "Three-event championship", "Your night"],
                selected: 0,
                control: captainControl
            ))
        case "menu-member":
            client.configureFixture(state: .connected("Living Room PartyBox"), player: member)
            layout = .menu(.init(
                items: ["FOUR-WAY PONG", "SIGNAL SNAP", "GRAVITY GRAB", "SNAKE PIT", "LAST LIGHT", "PARTY CUP", "HISTORY & LEADERBOARD"],
                details: ["Pong, expanded", "Match the TV", "Swing around the ring", "Three quick lives", "Dodge the red", "Three-event championship", "Your night"],
                selected: 0,
                control: memberControl
            ))
        case "paddle-bottom", "paddle-top", "paddle-left", "paddle-right":
            client.configureFixture(state: .connected("Living Room PartyBox"), player: currentPlayer)
            let edge = String(scenario.dropFirst("paddle-".count))
            let screen = ControllerScreen(accessibilityID: "controller.layout.paddle.\(edge)", accentColorHex: currentPlayer.colorHex, components: [
                .text(.init(id: "player", text: "P1 Ada", style: .headline)),
                .axisSurface(.init(id: "controller.paddle.track", binding: .horizontal, instruction: "DRAG TO MOVE")),
            ])
            layout = .game(.init(gameID: "pong", payload: (try? PartyBoxWireCodec.encode(screen)) ?? Data()))
        case "signal-snap":
            client.configureFixture(state: .connected("Living Room PartyBox"), player: currentPlayer)
            let screen = ControllerScreen(
                accessibilityID: "controller.layout.signal-snap",
                accentColorHex: currentPlayer.colorHex,
                requestedInputs: .orientation,
                components: [
                    .text(.init(id: "signal.rule", text: "MATCH THE SYMBOL ON THE TV", style: .caption)),
                    .directionPad(.init(id: "signal.direction", instruction: "TAP THE MATCHING ARROW")),
                ]
            )
            layout = .game(.init(gameID: "signal-snap", payload: (try? PartyBoxWireCodec.encode(screen)) ?? Data()))
        case "gravity-grab":
            client.configureFixture(state: .connected("Living Room PartyBox"), player: currentPlayer)
            let screen = ControllerScreen(
                accessibilityID: "controller.layout.gravity-grab",
                accentColorHex: currentPlayer.colorHex,
                requestedInputs: .orientation,
                components: [
                    .text(.init(id: "gravity.rule", text: "STEER AROUND THE RING", style: .caption)),
                    .axisSurface(.init(id: "gravity.steer", binding: .twoDimensional, instruction: "DRAG TO AIM")),
                ]
            )
            layout = .game(.init(gameID: "gravity-grab", payload: (try? PartyBoxWireCodec.encode(screen)) ?? Data()))
        case "snake-pit":
            client.configureFixture(state: .connected("Living Room PartyBox"), player: currentPlayer)
            let screen = ControllerScreen(
                accessibilityID: "controller.layout.snake-pit",
                accentColorHex: currentPlayer.colorHex,
                requestedInputs: .orientation,
                components: [
                    .text(.init(id: "snake.rule", text: "TURN • SURVIVE • THREE LIVES", style: .caption)),
                    .directionPad(.init(id: "snake.direction", instruction: "CHOOSE YOUR NEXT TURN")),
                ]
            )
            layout = .game(.init(gameID: "snake-pit", payload: (try? PartyBoxWireCodec.encode(screen)) ?? Data()))
        case "last-light":
            client.configureFixture(state: .connected("Living Room PartyBox"), player: currentPlayer)
            let screen = ControllerScreen(
                accessibilityID: "controller.layout.last-light",
                accentColorHex: currentPlayer.colorHex,
                requestedInputs: .orientation,
                components: [
                    .text(.init(id: "light.rule", text: "DODGE THE RED", style: .caption)),
                    .axisSurface(.init(id: "light.steer", binding: .twoDimensional, instruction: "DRAG TO MOVE")),
                ]
            )
            layout = .game(.init(gameID: "last-light", payload: (try? PartyBoxWireCodec.encode(screen)) ?? Data()))
        case "spectator":
            client.configureFixture(state: .connected("Living Room PartyBox"), player: currentPlayer)
            let game = GameDescriptor(id: "pong", title: "Pong", summary: "Winner stays", minimumPlayers: 1, maximumPlayers: 4, modifiers: [
                .init(id: "fast-ball", title: "Fast Ball", detail: "+25% initial speed")
            ])
            let screen = SpectatorScreenFactory.make(game: game, state: .init(role: .waiting(position: 2), choices: game.modifiers, tallies: [:], selection: nil))
            layout = .game(.init(gameID: "pong", payload: (try? PartyBoxWireCodec.encode(screen)) ?? Data()))
        case "game-over":
            client.configureFixture(state: .connected("Living Room PartyBox"), player: currentPlayer)
            layout = .gameOver(.init(
                title: "P1 ADA WINS",
                subtitle: "Select to play again",
                control: captainControl,
                botDifficultyChange: "BOT DIFFICULTY INCREASED TO HARD"
            ))
        case "game-over-member":
            client.configureFixture(state: .connected("Living Room PartyBox"), player: member)
            layout = .gameOver(.init(
                title: "P1 ADA WINS",
                subtitle: "Select to play again",
                control: memberControl,
                botDifficultyChange: "BOT DIFFICULTY INCREASED TO HARD"
            ))
        case "history":
            client.configureFixture(state: .connected("Living Room PartyBox"), player: currentPlayer)
            layout = .historyNavigation
        case "reconnecting": client.configureFixture(state: .reconnecting("Connection interrupted"), player: currentPlayer)
        case "full-rejection": client.configureFixture(state: .rejected(RejectReason.full.message))
        case "version-rejection": client.configureFixture(state: .rejected(RejectReason.versionMismatch(hostVersion: 999).message))
        case "local-network-denial":
            client.configureFixture(state: .browsing, discoveryErrorMessage: "Local Network policy denied")
            discoveryHelpVisible = true
        case "connection-loss": client.configureFixture(state: .disconnected("The host is no longer reachable."), player: currentPlayer)
        default:
            client.configureFixture(state: .connected("Living Room PartyBox"), player: currentPlayer)
            layout = .lobby(.waiting)
        }
    }
#endif
}
