import PartyBoxCore
import PartyGameRuntime
import PartyNet
import SpriteKit

/// Draws one arcade game. `build` runs once before the first frame; `render`
/// runs after every simulation step (and during the intro with no events).
@MainActor
protocol ArcadeRenderer: AnyObject {
    associatedtype Simulation: ArcadeSimulation
    func build(in scene: ArcadeScene, simulation: Simulation)
    func render(_ simulation: Simulation, events: [ArcadeEvent], in scene: ArcadeScene)
}

/// Shared TV scene: HUD chrome, score rail, intro countdown and banners. Game
/// nodes go in `gameLayer`. The owning session drives it through `onFrame`.
@MainActor
final class ArcadeScene: SKScene {
    let players: [PlayerInfo]
    let gameLayer = SKNode()
    var onFrame: ((Double) -> Void)?

    private let playerByID: [PlayerID: PlayerInfo]
    private let timerLabel = SKLabelNode(fontNamed: "AvenirNext-Heavy")
    private let introLabel = SKLabelNode(fontNamed: "AvenirNext-Heavy")
    private let bannerLabel = SKLabelNode(fontNamed: "AvenirNext-Heavy")
    private var scoreLabels: [PlayerID: SKLabelNode] = [:]
    private var scoreTexts: [PlayerID: String] = [:]
    private var timerText: String?
    private var previousUpdateTime: TimeInterval?

    init(title: String, players: [PlayerInfo], showsBorder: Bool = true) {
        self.players = players
        playerByID = Dictionary(players.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        super.init(size: ArcadeArena.sceneSize)
        scaleMode = .aspectFit
        backgroundColor = SKColor(red: 0.018, green: 0.025, blue: 0.075, alpha: 1)
        buildChrome(title: title, showsBorder: showsBorder)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func update(_ currentTime: TimeInterval) {
        let rawDelta = previousUpdateTime.map { currentTime - $0 } ?? (1.0 / 60.0)
        previousUpdateTime = currentTime
        onFrame?(min(max(rawDelta, 0), 0.05))
    }

    func info(for playerID: PlayerID) -> PlayerInfo? { playerByID[playerID] }

    func color(for playerID: PlayerID) -> SKColor {
        .partyHex(playerByID[playerID]?.colorHex ?? "#FFFFFF")
    }

    /// Scene point for a world position. Arcade simulations already use scene
    /// points, so this is the identity; it exists to keep call sites explicit.
    func point(_ vector: ArcadeVector) -> CGPoint {
        CGPoint(x: vector.x, y: vector.y)
    }

    /// A glowing round player token carrying the player's mark glyph.
    func makeToken(for playerID: PlayerID, radius: CGFloat) -> SKShapeNode {
        let node = SKShapeNode(circleOfRadius: radius)
        node.fillColor = color(for: playerID)
        node.strokeColor = .white
        node.lineWidth = 3
        node.glowWidth = max(4, radius * 0.35)
        if let info = playerByID[playerID] {
            let mark = SKLabelNode(fontNamed: "AvenirNext-Heavy")
            mark.text = info.mark.glyph
            mark.fontSize = max(14, radius * 0.75)
            mark.fontColor = .black.withAlphaComponent(0.85)
            mark.verticalAlignmentMode = .center
            mark.horizontalAlignmentMode = .center
            mark.zPosition = 1
            node.addChild(mark)
        }
        return node
    }

    func setTimer(_ seconds: Double?) {
        let text = seconds.map { "\(max(0, Int(ceil($0))))" }
        guard text != timerText else { return }
        timerText = text
        timerLabel.text = text
    }

    func setScoreLine(_ text: String, for playerID: PlayerID, active: Bool) {
        guard let label = scoreLabels[playerID] else { return }
        let number = playerByID[playerID]?.number ?? Int(playerID.rawValue) + 1
        let full = "P\(number)  \(text)"
        if scoreTexts[playerID] != full {
            scoreTexts[playerID] = full
            label.text = full
        }
        label.alpha = active ? 1 : 0.35
    }

    func setIntro(_ text: String?) {
        guard introLabel.text != text else { return }
        introLabel.text = text
        guard text != nil else { return }
        introLabel.removeAllActions()
        introLabel.setScale(1.35)
        introLabel.run(.scale(to: 1, duration: 0.18))
    }

    func flashBanner(_ text: String, colorHex: String = "#FFFFFF") {
        bannerLabel.removeAllActions()
        bannerLabel.text = text
        bannerLabel.fontColor = .partyHex(colorHex)
        bannerLabel.alpha = 1
        bannerLabel.setScale(0.8)
        bannerLabel.run(.sequence([
            .scale(to: 1.08, duration: 0.12),
            .scale(to: 1, duration: 0.08),
            .wait(forDuration: 0.7),
            .fadeOut(withDuration: 0.35),
        ]))
    }

    private func buildChrome(title: String, showsBorder: Bool) {
        let titleLabel = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        titleLabel.text = "PARTYBOX  /  \(title)"
        titleLabel.fontSize = 34
        titleLabel.fontColor = SKColor(red: 0.4, green: 0.94, blue: 1, alpha: 1)
        titleLabel.horizontalAlignmentMode = .left
        titleLabel.position = CGPoint(x: 50, y: 1_015)
        titleLabel.zPosition = 20
        addChild(titleLabel)

        timerLabel.fontSize = 42
        timerLabel.fontColor = .white
        timerLabel.horizontalAlignmentMode = .right
        timerLabel.position = CGPoint(x: 1_860, y: 1_010)
        timerLabel.zPosition = 20
        addChild(timerLabel)

        if showsBorder {
            let border = SKShapeNode(rect: ArcadeArena.rect, cornerRadius: 28)
            border.strokeColor = SKColor(red: 0.25, green: 0.9, blue: 1, alpha: 0.42)
            border.lineWidth = 4
            border.glowWidth = 10
            border.fillColor = .clear
            border.zPosition = 2
            addChild(border)
        }

        gameLayer.zPosition = 5
        addChild(gameLayer)

        for (index, player) in players.enumerated() {
            let label = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
            label.fontSize = 25
            label.fontColor = color(for: player.id)
            label.horizontalAlignmentMode = index < 4 ? .left : .right
            label.position = CGPoint(x: index < 4 ? 30 : 1_890, y: 900 - CGFloat(index % 4) * 62)
            label.zPosition = 20
            addChild(label)
            scoreLabels[player.id] = label
        }

        introLabel.fontSize = 180
        introLabel.fontColor = .white
        introLabel.verticalAlignmentMode = .center
        introLabel.position = CGPoint(x: 960, y: 525)
        introLabel.zPosition = 40
        addChild(introLabel)

        bannerLabel.fontSize = 96
        bannerLabel.verticalAlignmentMode = .center
        bannerLabel.position = CGPoint(x: 960, y: 640)
        bannerLabel.zPosition = 41
        bannerLabel.alpha = 0
        addChild(bannerLabel)
    }
}

/// Generic host-facing session for every arcade game.
@MainActor
final class ArcadeSession<Renderer: ArcadeRenderer>: PartyGameSession {
    typealias Simulation = Renderer.Simulation

    struct Configuration {
        let gameID: String
        let title: String
        let supportsMotion: Bool
        let controls: [ScreenComponent]
        var introDuration: Double = 1.5
    }

    private struct BotMemory {
        var random: ArcadeRandomNumberGenerator
        var reactionRemaining = 0.0
        var decision = ArcadeBotDecision.idle
        var wantsPress = false
        var pressFrames = 0
        var releaseFrames = 0
    }

    private let configuration: Configuration
    private let context: GameSessionContext
    private let onEvents: @MainActor ([GameEvent]) -> Void
    private let renderer: Renderer
    private let sampler: ArcadeInputSampler
    private let arcadeScene: ArcadeScene
    private let playerIDs: [PlayerID]
    private(set) var simulation: Simulation
    private var introRemaining: Double
    private var completed = false
    private var forfeited: Set<PlayerID> = []
    private var bots: [PlayerID: BotMemory] = [:]

    var scene: SKScene { arcadeScene }

    init(
        configuration: Configuration,
        context: GameSessionContext,
        simulation: Simulation,
        renderer: Renderer,
        onEvents: @escaping @MainActor ([GameEvent]) -> Void
    ) {
        self.configuration = configuration
        self.context = context
        self.simulation = simulation
        self.renderer = renderer
        self.onEvents = onEvents
        playerIDs = context.participants.map(\.player.id)
        sampler = ArcadeInputSampler(store: context.inputs)
        introRemaining = max(0, configuration.introDuration)
        arcadeScene = ArcadeScene(title: configuration.title, players: context.participants.map(\.player))
        renderer.build(in: arcadeScene, simulation: simulation)
        arcadeScene.onFrame = { [weak self] delta in self?.advance(by: delta) }
        refreshHUD()
        renderer.render(simulation, events: [], in: arcadeScene)
    }

    func controllerScreen(for playerID: PlayerID) -> ControllerScreen {
        let player = context.participants.first(where: { $0.player.id == playerID })?.player
        let identity = player.map { "\($0.mark.glyph)  P\($0.number) \($0.displayName)" } ?? "PLAYER"
        return ControllerScreen(
            accessibilityID: "controller.layout.\(configuration.gameID)",
            accentColorHex: player?.colorHex ?? ArcadePalette.cyan,
            requestedInputs: configuration.supportsMotion ? .orientation : [],
            components: [.text(.init(id: "arcade.player", text: identity, style: .headline, tint: .accent))]
                + configuration.controls
        )
    }

    func handle(action: ControllerAction, from playerID: PlayerID) {
        guard playerIDs.contains(playerID), !completed else { return }
        switch action.value {
        case .trigger:
            let steering = configuration.gameID == "bumper-brawl" && action.id == "bumper.dash"
                ? action.steering : nil
            sampler.queuePress(for: playerID, steering: steering)
        case .choice(let value):
            if let direction = ArcadeDirection(rawValue: value) {
                sampler.queueTurn(direction, for: playerID)
            }
        }
    }

    func forfeit(_ playerID: PlayerID) {
        guard !completed, simulation.isActive(playerID) else { return }
        let events = simulation.forfeit(playerID)
        guard !events.isEmpty else { return }
        forfeited.insert(playerID)
        refreshHUD()
        renderer.render(simulation, events: events, in: arcadeScene)
        publish(events)
    }

    func botInput(for playerID: PlayerID, difficulty: GameBotDifficulty, deltaTime: Duration) -> GameBotInput? {
        guard playerIDs.contains(playerID), !completed, simulation.isActive(playerID) else { return nil }
        var memory = bots[playerID] ?? BotMemory(random: ArcadeRandomNumberGenerator(
            seed: ArcadeRandomNumberGenerator.mixed(context.seed, UInt64(playerID.rawValue) &+ 0xB07)
        ))
        memory.reactionRemaining -= deltaTime.arcadeSeconds
        if memory.reactionRemaining <= 0 {
            memory.reactionRemaining = Simulation.botReactionInterval(for: difficulty)
            if introRemaining <= 0 {
                memory.decision = simulation.botDecision(for: playerID, difficulty: difficulty, random: &memory.random)
                if memory.decision.press { memory.wantsPress = true }
            }
        }
        var buttons: Buttons = []
        if memory.pressFrames > 0 {
            buttons = .primary
            memory.pressFrames -= 1
            if memory.pressFrames == 0 { memory.releaseFrames = 2 }
        } else if memory.releaseFrames > 0 {
            memory.releaseFrames -= 1
        } else if memory.wantsPress {
            memory.wantsPress = false
            memory.pressFrames = 2
            buttons = .primary
        }
        bots[playerID] = memory
        return GameBotInput(
            axisX: Float(memory.decision.axisX),
            axisY: Float(memory.decision.axisY),
            buttons: buttons
        )
    }

    /// Advances one frame. `ArcadeScene.update` calls this with a clamped delta.
    func advance(by rawDelta: Double) {
        guard !completed else { return }
        let delta = min(max(rawDelta, 0), 0.05)
        if introRemaining > 0 {
            introRemaining -= delta
            _ = sampler.sample(players: playerIDs)
            if introRemaining > 0 {
                let step = max(configuration.introDuration / 3, 0.001)
                arcadeScene.setIntro("\(min(3, Int(ceil(introRemaining / step))))")
            } else {
                arcadeScene.setIntro(nil)
                arcadeScene.flashBanner("GO!", colorHex: ArcadeOutcomeBuilder.winnerColor)
            }
            refreshHUD()
            renderer.render(simulation, events: [], in: arcadeScene)
            return
        }
        let inputs = sampler.sample(players: playerIDs)
        let events = simulation.step(deltaTime: delta, inputs: inputs)
        refreshHUD()
        renderer.render(simulation, events: events, in: arcadeScene)
        publish(events)
    }

    private func refreshHUD() {
        arcadeScene.setTimer(simulation.timeRemaining)
        for playerID in playerIDs {
            arcadeScene.setScoreLine(
                simulation.scoreLine(for: playerID),
                for: playerID,
                active: simulation.isActive(playerID)
            )
        }
    }

    private func publish(_ events: [ArcadeEvent]) {
        var translated = events.flatMap(ArcadeOutcomeBuilder.translate)
        for case .banner(let text) in events {
            arcadeScene.flashBanner(text)
        }
        if simulation.isFinished, !completed {
            completed = true
            translated += ArcadeOutcomeBuilder.completionEvents(
                title: configuration.title,
                participants: context.participants,
                ranking: simulation.ranking(),
                metric: simulation.resultMetric,
                forfeited: forfeited
            )
        }
        if !translated.isEmpty { onEvents(translated) }
    }

#if DEBUG
    var simulationForTesting: Simulation {
        get { simulation }
        set { simulation = newValue }
    }

    var isCompletedForTesting: Bool { completed }

    func skipIntroForTesting() {
        introRemaining = 0
        arcadeScene.setIntro(nil)
    }

    func advanceForTesting(seconds: Double, step: Double = 1.0 / 60.0) {
        var remaining = seconds
        while remaining > 0.000_001, !completed {
            let delta = min(step, remaining)
            advance(by: delta)
            remaining -= delta
        }
    }
#endif
}
