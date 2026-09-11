import PartyBoxCore
import PartyGameRuntime
import PartyNet
import SpriteKit

@MainActor
struct SignalSnapGame: PartyGame {
    let descriptor = GameDescriptor(
        id: "signal-snap",
        title: "SIGNAL SNAP",
        summary: "1–8 players  •  Match the TV symbol first",
        minimumPlayers: 1,
        maximumPlayers: 8,
        estimatedDurationSeconds: 75
    )

    func makeSession(context: GameSessionContext, onEvents: @escaping @MainActor ([GameEvent]) -> Void) -> any PartyGameSession {
        ArcadeChallengeSession(mode: .signalSnap, context: context, onEvents: onEvents)
    }
}

@MainActor
struct GravityGrabGame: PartyGame {
    let descriptor = GameDescriptor(
        id: "gravity-grab",
        title: "GRAVITY GRAB",
        summary: "1–8 players  •  Swing your magnet around the ring",
        minimumPlayers: 1,
        maximumPlayers: 8,
        estimatedDurationSeconds: 90
    )

    func makeSession(context: GameSessionContext, onEvents: @escaping @MainActor ([GameEvent]) -> Void) -> any PartyGameSession {
        ArcadeChallengeSession(mode: .gravityGrab, context: context, onEvents: onEvents)
    }
}

@MainActor
struct SnakePitGame: PartyGame {
    let descriptor = GameDescriptor(
        id: "snake-pit",
        title: "SNAKE PIT",
        summary: "1–8 players  •  Three quick lives",
        minimumPlayers: 1,
        maximumPlayers: 8,
        estimatedDurationSeconds: 90
    )

    func makeSession(context: GameSessionContext, onEvents: @escaping @MainActor ([GameEvent]) -> Void) -> any PartyGameSession {
        ArcadeChallengeSession(mode: .snakePit, context: context, onEvents: onEvents)
    }
}

@MainActor
struct LastLightGame: PartyGame {
    let descriptor = GameDescriptor(
        id: "last-light",
        title: "LAST LIGHT",
        summary: "1–8 players  •  Dodge the TV obstacles",
        minimumPlayers: 1,
        maximumPlayers: 8,
        estimatedDurationSeconds: 85
    )

    func makeSession(context: GameSessionContext, onEvents: @escaping @MainActor ([GameEvent]) -> Void) -> any PartyGameSession {
        ArcadeChallengeSession(mode: .lastLight, context: context, onEvents: onEvents)
    }
}

enum ArcadeChallengeMode: String {
    case pongQualifiers = "PONG QUALIFIERS"
    case signalSnap = "SIGNAL SNAP"
    case gravityGrab = "GRAVITY GRAB"
    case snakePit = "SNAKE PIT"
    case lastLight = "LAST LIGHT"

    var gameID: String {
        switch self {
        case .pongQualifiers: "pong"
        case .signalSnap: "signal-snap"
        case .gravityGrab: "gravity-grab"
        case .snakePit: "snake-pit"
        case .lastLight: "last-light"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .pongQualifiers: 36
        case .signalSnap: 72
        case .gravityGrab: 78
        case .snakePit: 84
        case .lastLight: 76
        }
    }
}

struct ArcadeRandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 1 : seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var output = state
        output = (output ^ (output >> 30)) &* 0xBF58_476D_1CE4_E5B9
        output = (output ^ (output >> 27)) &* 0x94D0_49BB_1331_11EB
        return output ^ (output >> 31)
    }
}

@MainActor
final class ArcadeChallengeSession: PartyGameSession {
    private let mode: ArcadeChallengeMode
    private let context: GameSessionContext
    private let onEvents: @MainActor ([GameEvent]) -> Void
    private let challengeScene: ArcadeChallengeScene

    var scene: SKScene { challengeScene }

    init(
        mode: ArcadeChallengeMode,
        context: GameSessionContext,
        onEvents: @escaping @MainActor ([GameEvent]) -> Void
    ) {
        self.mode = mode
        self.context = context
        self.onEvents = onEvents
        challengeScene = ArcadeChallengeScene(mode: mode, context: context, onEvents: onEvents)
    }

    func controllerScreen(for playerID: PlayerID) -> ControllerScreen {
        let player = context.participants.first(where: { $0.player.id == playerID })?.player
        let color = player?.colorHex ?? ArcadePalette.cyan
        let identity = player.map { "\($0.mark.glyph)  P\($0.number) \($0.displayName)" } ?? "PLAYER"
        let controls: [ScreenComponent]
        switch mode {
        case .pongQualifiers:
            controls = [
                .text(.init(id: "pong.qualifier.rule", text: "FOLLOW THE TV GATE • TOP SCORE ADVANCES", style: .caption, tint: .secondary)),
                .axisSurface(.init(id: "pong.qualifier", binding: .horizontal, instruction: "DRAG LEFT OR RIGHT  •  MOTION OPTIONAL")),
            ]
        case .signalSnap:
            controls = [
                .text(.init(id: "signal.rule", text: "MATCH THE SYMBOL ON THE TV", style: .caption, tint: .secondary)),
                .directionPad(.init(id: "signal.direction", instruction: "TAP THE MATCHING ARROW")),
            ]
        case .gravityGrab:
            controls = [
                .text(.init(id: "gravity.rule", text: "STEER AROUND THE RING • REACH OUT TO GRAB", style: .caption, tint: .secondary)),
                .axisSurface(.init(id: "gravity.steer", binding: .twoDimensional, instruction: "DRAG TO AIM  •  MOTION OPTIONAL")),
            ]
        case .snakePit:
            controls = [
                .text(.init(id: "snake.rule", text: "TURN • SURVIVE • THREE LIVES", style: .caption, tint: .secondary)),
                .directionPad(.init(id: "snake.direction", instruction: "CHOOSE YOUR NEXT TURN")),
            ]
        case .lastLight:
            controls = [
                .text(.init(id: "light.rule", text: "STAY IN THE LIGHT • DODGE THE RED", style: .caption, tint: .secondary)),
                .axisSurface(.init(id: "light.steer", binding: .twoDimensional, instruction: "DRAG TO MOVE  •  MOTION OPTIONAL")),
            ]
        }
        return ControllerScreen(
            accessibilityID: "controller.layout.\(mode.gameID)",
            accentColorHex: color,
            requestedInputs: .orientation,
            components: [.text(.init(id: "arcade.player", text: identity, style: .headline, tint: .accent))] + controls
        )
    }

    func handle(action: ControllerAction, from playerID: PlayerID) {
        guard case .choice(let choice) = action.value else { return }
        challengeScene.choose(choice, for: playerID)
    }

    func forfeit(_ playerID: PlayerID) { challengeScene.forfeit(playerID) }

    func botInput(for playerID: PlayerID, difficulty: GameBotDifficulty, deltaTime: Duration) -> GameBotInput? {
        challengeScene.botInput(for: playerID, difficulty: difficulty)
    }

#if DEBUG
    func updateForTesting(_ currentTime: TimeInterval) {
        challengeScene.update(currentTime)
    }

    func signalDirectionForTesting() -> String {
        challengeScene.signalDirectionForTesting
    }

    func scoreForTesting(_ playerID: PlayerID) -> Int? {
        challengeScene.scoreForTesting(playerID)
    }

    func snapshotForTesting() -> [PlayerID: ArcadeChallengePlayerSnapshot] {
        challengeScene.snapshotForTesting()
    }

    func reverseStorageForTesting() {
        challengeScene.reverseStorageForTesting()
    }

    func snakeTrailNodeIdentitiesForTesting() -> [PlayerID: [ObjectIdentifier]] {
        challengeScene.snakeTrailNodeIdentitiesForTesting()
    }
#endif
}

#if DEBUG
struct ArcadeChallengePlayerSnapshot: Equatable {
    let x: Double
    let y: Double
    let direction: String
    let score: Int
    let lives: Int
    let alive: Bool
}
#endif

@MainActor
private final class ArcadeChallengeScene: SKScene {
    private struct PlayerState {
        var x: Double
        var y: Double
        var direction: String
        var score: Int
        var lives: Int
        var alive: Bool
        var lastInput: String?
        var submittedSignalRound: Int?
        var lastHitAt: TimeInterval
    }

    private struct Hazard {
        var x: Double
        var y: Double
        let node: SKShapeNode
    }

    private let mode: ArcadeChallengeMode
    private let context: GameSessionContext
    private let onEvents: @MainActor ([GameEvent]) -> Void
    private var states: [PlayerID: PlayerState] = [:]
    private var playerNodes: [PlayerID: SKShapeNode] = [:]
    private var scoreLabels: [PlayerID: SKLabelNode] = [:]
    private var snakeTrails: [PlayerID: [CGPoint]] = [:]
    private let snakeTrailLayer = SKNode()
    private var snakeTrailContainers: [PlayerID: SKNode] = [:]
    private var snakeTrailNodes: [PlayerID: [SKShapeNode]] = [:]
    private var hazards: [Hazard] = []
    private var previousUpdateTime: TimeInterval?
    private var elapsed: TimeInterval = 0
    private var tickAccumulator: TimeInterval = 0
    private var spawnAccumulator: TimeInterval = 0
    private var signalAccumulator: TimeInterval = 0
    private var signalRound = 0
    private var signalDirection = "up"
    private var finished = false
    private var randomGenerator: ArcadeRandomNumberGenerator
    private let timerLabel = SKLabelNode(fontNamed: "AvenirNext-Heavy")
    private let promptLabel = SKLabelNode(fontNamed: "AvenirNext-Heavy")

    init(mode: ArcadeChallengeMode, context: GameSessionContext, onEvents: @escaping @MainActor ([GameEvent]) -> Void) {
        self.mode = mode
        self.context = context
        self.onEvents = onEvents
        randomGenerator = ArcadeRandomNumberGenerator(seed: context.seed)
        super.init(size: CGSize(width: 1_920, height: 1_080))
        scaleMode = .aspectFit
        backgroundColor = SKColor(red: 0.018, green: 0.025, blue: 0.075, alpha: 1)
        buildScene()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func update(_ currentTime: TimeInterval) {
        guard !finished else { return }
        let rawDelta = previousUpdateTime.map { currentTime - $0 } ?? (1.0 / 60.0)
        previousUpdateTime = currentTime
        let delta = min(max(rawDelta, 0), 0.05)
        elapsed += delta
        timerLabel.text = "\(max(0, Int(ceil(mode.duration - elapsed))))"
        readInputs()
        switch mode {
        case .pongQualifiers: updatePongQualifier(delta: delta)
        case .signalSnap: updateSignal(delta: delta)
        case .gravityGrab: updateGravity(delta: delta)
        case .snakePit: updateSnake(delta: delta)
        case .lastLight: updateLastLight(delta: delta)
        }
        syncPlayerNodes()
        if elapsed >= mode.duration { complete() }
    }

    func choose(_ choice: String, for playerID: PlayerID) {
        guard states[playerID]?.alive == true else { return }
        if mode == .signalSnap {
            submitSignal(choice, playerID: playerID)
        } else if mode == .snakePit, ["up", "down", "left", "right"].contains(choice) {
            let current = states[playerID]?.direction ?? "right"
            states[playerID]?.direction = nonReversingDirection(choice, current: current)
        }
    }

    func forfeit(_ playerID: PlayerID) {
        guard states[playerID]?.alive == true else { return }
        states[playerID]?.alive = false
        states[playerID]?.lives = 0
        onEvents([.eliminated(playerID)])
        if states.values.filter(\.alive).count <= 1 { complete() }
    }

    func botInput(for playerID: PlayerID, difficulty: GameBotDifficulty) -> GameBotInput? {
        guard let state = states[playerID], state.alive else { return nil }
        let precision: Float = switch difficulty { case .easy: 0.64; case .normal: 0.78; case .hard: 0.94 }
        switch mode {
        case .pongQualifiers:
            let target: Float = signalDirection == "left" ? -1 : 1
            return GameBotInput(axisX: target * precision)
        case .signalSnap:
            let axes = axes(for: signalDirection)
            return GameBotInput(axisX: axes.x * precision, axisY: axes.y * precision)
        case .gravityGrab:
            let angle = elapsed * (difficulty == .easy ? 0.7 : 1.1) + Double(playerID.rawValue)
            return GameBotInput(axisX: Float(cos(angle)) * precision, axisY: Float(sin(angle)) * precision)
        case .snakePit:
            let phase = Int(elapsed * (difficulty == .hard ? 3.0 : 1.7)) + Int(playerID.rawValue)
            let sequence: [(Float, Float)] = [(1, 0), (0, 1), (-1, 0), (0, -1)]
            let value = sequence[phase % sequence.count]
            return GameBotInput(axisX: value.0, axisY: value.1)
        case .lastLight:
            let angle = elapsed * (difficulty == .hard ? 1.7 : 1.1) + Double(playerID.rawValue) * 0.8
            return GameBotInput(axisX: Float(sin(angle)) * precision, axisY: Float(cos(angle * 0.73)) * precision)
        }
    }

    private func buildScene() {
        let title = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        title.text = "PARTYBOX  /  \(mode.rawValue)"
        title.fontSize = 34
        title.fontColor = SKColor(red: 0.4, green: 0.94, blue: 1, alpha: 1)
        title.horizontalAlignmentMode = .left
        title.position = CGPoint(x: 50, y: 1_015)
        addChild(title)

        timerLabel.fontSize = 42
        timerLabel.fontColor = .white
        timerLabel.horizontalAlignmentMode = .right
        timerLabel.position = CGPoint(x: 1_860, y: 1_010)
        addChild(timerLabel)

        let border = SKShapeNode(rect: CGRect(x: 250, y: 130, width: 1_420, height: 790), cornerRadius: 28)
        border.strokeColor = SKColor(red: 0.25, green: 0.9, blue: 1, alpha: 0.42)
        border.lineWidth = 4
        border.glowWidth = 10
        border.fillColor = .clear
        addChild(border)

        if mode == .gravityGrab {
            let ring = SKShapeNode(circleOfRadius: 320)
            ring.position = CGPoint(x: 960, y: 525)
            ring.strokeColor = SKColor(red: 0.25, green: 0.9, blue: 1, alpha: 0.55)
            ring.lineWidth = 8
            ring.glowWidth = 15
            ring.fillColor = SKColor(red: 0.03, green: 0.08, blue: 0.16, alpha: 0.35)
            addChild(ring)
        }

        snakeTrailLayer.zPosition = 1
        addChild(snakeTrailLayer)

        promptLabel.fontSize = 120
        promptLabel.fontColor = .white
        promptLabel.position = CGPoint(x: 960, y: 790)
        promptLabel.zPosition = 5
        addChild(promptLabel)

        for (index, participant) in context.participants.enumerated() {
            let angle = (Double(index) / Double(max(1, context.participants.count))) * .pi * 2
            let initialRadius = mode == .gravityGrab ? 1.0 : 0.38
            states[participant.player.id] = PlayerState(
                x: cos(angle) * initialRadius,
                y: sin(angle) * initialRadius,
                direction: ["right", "up", "left", "down"][index % 4],
                score: 0,
                lives: 3,
                alive: true,
                lastInput: nil,
                submittedSignalRound: nil,
                lastHitAt: -10
            )
            snakeTrails[participant.player.id] = []
            if mode == .snakePit {
                let trailContainer = SKNode()
                snakeTrailLayer.addChild(trailContainer)
                snakeTrailContainers[participant.player.id] = trailContainer
                snakeTrailNodes[participant.player.id] = []
            }
            let node = SKShapeNode(circleOfRadius: mode == .snakePit ? 23 : 31)
            node.fillColor = Self.color(participant.player.colorHex)
            node.strokeColor = .white
            node.lineWidth = 3
            node.glowWidth = 13
            let mark = SKLabelNode(fontNamed: "AvenirNext-Heavy")
            mark.text = participant.player.mark.glyph
            mark.fontSize = 22
            mark.fontColor = .black
            mark.verticalAlignmentMode = .center
            node.addChild(mark)
            addChild(node)
            playerNodes[participant.player.id] = node

            let score = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
            score.fontSize = 25
            score.fontColor = node.fillColor
            score.horizontalAlignmentMode = index < 4 ? .left : .right
            score.position = CGPoint(
                x: index < 4 ? 40 : 1_880,
                y: 900 - CGFloat(index % 4) * 62
            )
            addChild(score)
            scoreLabels[participant.player.id] = score
        }
        configurePrompt()
    }

    private func readInputs() {
        let snapshot = context.inputs.snapshot()
        for (playerID, frame) in snapshot where states[playerID]?.alive == true {
            let x = Double(frame.axisX)
            let y = Double(frame.axisY)
            switch mode {
            case .pongQualifiers:
                let direction: String? = abs(x) > 0.58 ? (x > 0 ? "right" : "left") : nil
                if direction != states[playerID]?.lastInput, let direction {
                    submitSignal(direction, playerID: playerID)
                }
                states[playerID]?.lastInput = direction
            case .signalSnap:
                let direction = dominantDirection(x: x, y: y)
                if direction != states[playerID]?.lastInput, let direction {
                    submitSignal(direction, playerID: playerID)
                }
                states[playerID]?.lastInput = direction
            case .gravityGrab:
                if abs(x) + abs(y) > 0.12 {
                    states[playerID]?.x = cos(atan2(y, x))
                    states[playerID]?.y = sin(atan2(y, x))
                }
            case .snakePit:
                if let direction = dominantDirection(x: x, y: y) {
                    let current = states[playerID]?.direction ?? "right"
                    states[playerID]?.direction = nonReversingDirection(direction, current: current)
                }
            case .lastLight:
                states[playerID]?.x = min(max(x, -1), 1)
                states[playerID]?.y = min(max(y, -1), 1)
            }
        }
    }

    private func updateSignal(delta: TimeInterval) {
        signalAccumulator += delta
        if signalAccumulator >= 3.0 {
            signalAccumulator = 0
            signalRound += 1
            if signalRound >= 24 { complete(); return }
            beginSignalRound()
        }
    }

    private func updatePongQualifier(delta: TimeInterval) {
        signalAccumulator += delta
        if signalAccumulator >= 1.5 {
            signalAccumulator = 0
            signalRound += 1
            if signalRound >= 24 { complete(); return }
            beginSignalRound()
        }
    }

    private func beginSignalRound() {
        if mode == .pongQualifiers {
            signalDirection = nextRandom().isMultiple(of: 2) ? "left" : "right"
            promptLabel.text = signalDirection == "left" ? "← GATE" : "GATE →"
            promptLabel.fontSize = 86
        } else {
            signalDirection = ["up", "right", "down", "left"][Int(nextRandom() % 4)]
            promptLabel.text = ["up": "↑", "right": "→", "down": "↓", "left": "←"][signalDirection]
        }
        promptLabel.fontColor = SKColor(red: 0.8, green: 0.95, blue: 1, alpha: 1)
        for playerID in states.keys {
            states[playerID]?.lastInput = nil
        }
    }

    private func configurePrompt() {
        switch mode {
        case .pongQualifiers, .signalSnap:
            beginSignalRound()
        case .gravityGrab:
            promptLabel.text = "✦"
            promptLabel.fontSize = 92
            promptLabel.position = CGPoint(x: 1_280, y: 525)
            promptLabel.fontColor = SKColor(red: 0.8, green: 0.95, blue: 1, alpha: 1)
        case .snakePit:
            promptLabel.text = "THREE LIVES"
            promptLabel.fontSize = 54
            promptLabel.fontColor = SKColor(red: 0.55, green: 1, blue: 0.65, alpha: 0.75)
        case .lastLight:
            promptLabel.text = "DODGE THE RED"
            promptLabel.fontSize = 54
            promptLabel.fontColor = SKColor(red: 1, green: 0.6, blue: 0.7, alpha: 0.75)
        }
    }

    private func submitSignal(_ direction: String, playerID: PlayerID) {
        guard signalAccumulator > 0.18,
              states[playerID]?.submittedSignalRound != signalRound else { return }
        states[playerID]?.submittedSignalRound = signalRound
        states[playerID]?.lastInput = direction
        if direction == signalDirection {
            let speedBonus = max(0, 30 - Int(signalAccumulator * 10))
            states[playerID]?.score += 40 + speedBonus
            onEvents([
                .audio(.lightImpact),
                .deviceCue(playerID, .init(colorHex: "#39FF88", haptic: .lightImpact)),
            ])
        } else {
            let current = states[playerID]?.score ?? 0
            states[playerID]?.score = max(0, current - 10)
            onEvents([.deviceCue(playerID, .init(colorHex: "#FF375F", haptic: .error))])
        }
    }

    private func updateGravity(delta: TimeInterval) {
        tickAccumulator += delta
        if tickAccumulator >= 0.65 {
            tickAccumulator = 0
            let targetAngle = Double(nextRandom() % 628) / 100
            promptLabel.text = "✦"
            promptLabel.position = CGPoint(x: 960 + cos(targetAngle) * 320, y: 525 + sin(targetAngle) * 320)
            for (playerID, state) in states where state.alive {
                let playerAngle = atan2(state.y, state.x)
                let distance = abs(atan2(sin(playerAngle - targetAngle), cos(playerAngle - targetAngle)))
                if distance < 0.34 {
                    states[playerID]?.score += 12
                    onEvents([.deviceCue(playerID, .init(colorHex: "#00E5FF", durationMilliseconds: 150, haptic: .lightImpact))])
                }
            }
        }
    }

    private func updateSnake(delta: TimeInterval) {
        tickAccumulator += delta
        guard tickAccumulator >= 0.14 else { return }
        tickAccumulator = 0
        let stateSnapshot = states
        let activePlayerIDs = stateSnapshot.compactMap { playerID, state in
            state.alive ? playerID : nil
        }.sorted { $0.rawValue < $1.rawValue }
        var nextStates = stateSnapshot
        var nextTrails = snakeTrails
        var occupied: [String: [PlayerID]] = [:]
        var collisions: Set<PlayerID> = []
        for playerID in activePlayerIDs {
            guard let state = stateSnapshot[playerID] else { continue }
            nextTrails[playerID, default: []].append(CGPoint(x: state.x, y: state.y))
            if (nextTrails[playerID]?.count ?? 0) > 36 {
                nextTrails[playerID]?.removeFirst()
            }
        }
        for playerID in activePlayerIDs {
            guard var state = stateSnapshot[playerID] else { continue }
            let vector = axes(for: state.direction)
            state.x += Double(vector.x) * 0.08
            state.y += Double(vector.y) * 0.08
            state.score += 1
            nextStates[playerID] = state
            if abs(state.x) > 1 || abs(state.y) > 1 {
                collisions.insert(playerID)
                continue
            }
            let head = CGPoint(x: state.x, y: state.y)
            for trailOwner in nextTrails.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                let trail = nextTrails[trailOwner, default: []]
                let collisionTrail = trailOwner == playerID ? trail.dropLast(min(3, trail.count)) : trail[...]
                if collisionTrail.contains(where: { hypot($0.x - head.x, $0.y - head.y) < 0.055 }) {
                    collisions.insert(playerID)
                    break
                }
            }
            let cell = "\(Int(state.x * 10)),\(Int(state.y * 6))"
            occupied[cell, default: []].append(playerID)
        }
        states = nextStates
        snakeTrails = nextTrails
        for collision in occupied.values where collision.count > 1 {
            collisions.formUnion(collision)
        }
        for playerID in collisions.sorted(by: { $0.rawValue < $1.rawValue }) {
            loseLife(playerID, checkForCompletion: false)
        }
        if context.participants.count > 1 && states.values.filter(\.alive).count <= 1 {
            complete()
        }
        rebuildSnakeTrails()
    }

    private func updateLastLight(delta: TimeInterval) {
        spawnAccumulator += delta
        if spawnAccumulator >= 0.72 {
            spawnAccumulator = 0
            let node = SKShapeNode(rectOf: CGSize(width: 82, height: 42), cornerRadius: 10)
            node.fillColor = SKColor(red: 1, green: 0.14, blue: 0.3, alpha: 0.85)
            node.strokeColor = .white.withAlphaComponent(0.5)
            node.glowWidth = 9
            addChild(node)
            hazards.append(Hazard(x: (Double(nextRandom() % 190) / 100) - 0.95, y: 1.1, node: node))
        }
        for index in hazards.indices.reversed() {
            hazards[index].y -= delta * 0.72
            hazards[index].node.position = arenaPoint(x: hazards[index].x, y: hazards[index].y)
            for (playerID, state) in states where state.alive && elapsed - state.lastHitAt > 0.8 {
                if abs(state.x - hazards[index].x) < 0.13 && abs(state.y - hazards[index].y) < 0.13 {
                    loseLife(playerID)
                    states[playerID]?.lastHitAt = elapsed
                }
            }
            if hazards[index].y < -1.15 {
                hazards[index].node.removeFromParent()
                hazards.remove(at: index)
            }
        }
        tickAccumulator += delta
        if tickAccumulator >= 0.25 {
            tickAccumulator = 0
            for playerID in states.keys where states[playerID]?.alive == true { states[playerID]?.score += 1 }
        }
    }

    private func loseLife(_ playerID: PlayerID, checkForCompletion: Bool = true) {
        guard var state = states[playerID], state.alive else { return }
        state.lives -= 1
        state.x = (Double(nextRandom() % 120) / 100) - 0.6
        state.y = (Double(nextRandom() % 100) / 100) - 0.5
        snakeTrails[playerID] = []
        if state.lives <= 0 {
            state.alive = false
            states[playerID] = state
            onEvents([
                .audio(.error),
                .deviceCue(playerID, .init(colorHex: "#FF375F", haptic: .error)),
                .eliminated(playerID),
            ])
            if checkForCompletion,
               context.participants.count > 1,
               states.values.filter(\.alive).count <= 1 { complete() }
        } else {
            states[playerID] = state
            onEvents([
                .audio(.heavyImpact),
                .deviceCue(playerID, .init(colorHex: "#FF9F0A", haptic: .heavyImpact)),
            ])
        }
    }

    private func complete() {
        guard !finished else { return }
        finished = true
        let sorted = context.participants.sorted { lhs, rhs in
            let left = states[lhs.player.id] ?? PlayerState(
                x: 0, y: 0, direction: "", score: 0, lives: 0, alive: false,
                lastInput: nil, submittedSignalRound: nil, lastHitAt: 0
            )
            let right = states[rhs.player.id] ?? PlayerState(
                x: 0, y: 0, direction: "", score: 0, lives: 0, alive: false,
                lastInput: nil, submittedSignalRound: nil, lastHitAt: 0
            )
            if left.score != right.score { return left.score > right.score }
            if left.lives != right.lives { return left.lives > right.lives }
            return lhs.player.id.rawValue < rhs.player.id.rawValue
        }
        let standings = sorted.enumerated().map { index, participant in
            GameStanding(
                playerID: participant.player.id,
                rank: index + 1,
                score: states[participant.player.id]?.score ?? 0,
                detail: "\(max(0, states[participant.player.id]?.lives ?? 0)) lives"
            )
        }
        let winner = sorted.first?.player
        let solo = context.participants.count == 1
        let playerOutcomes = context.participants.map { participant in
            PlayerMatchOutcome(
                playerID: participant.player.id,
                outcome: solo ? .practice : (participant.player.id == winner?.id ? .won : .lost)
            )
        }
        let winnerTitle = solo ? "PRACTICE COMPLETE" : winner.map { "P\($0.number) \($0.displayName) WINS" } ?? "EVENT COMPLETE"
        var events: [GameEvent] = [.audio(.success)]
        if let winner { events.append(.deviceCue(winner.id, .init(colorHex: "#39FF88", haptic: .success))) }
        events.append(.completed(.init(
            title: winnerTitle,
            subtitle: "\(mode.rawValue.capitalized) complete",
            winner: solo ? nil : winner?.id,
            playerOutcomes: playerOutcomes,
            metrics: [.init(id: "top-score", label: "Top score", value: "\(standings.first?.score ?? 0)")],
            standings: standings
        )))
        onEvents(events)
    }

    private func syncPlayerNodes() {
        for participant in context.participants {
            let id = participant.player.id
            guard let state = states[id] else { continue }
            if mode == .gravityGrab {
                playerNodes[id]?.position = CGPoint(x: 960 + state.x * 320, y: 525 + state.y * 320)
            } else {
                playerNodes[id]?.position = arenaPoint(x: state.x, y: state.y)
            }
            playerNodes[id]?.alpha = state.alive ? 1 : 0.16
            scoreLabels[id]?.text = "P\(participant.player.number)  \(state.score)  \(String(repeating: "◆", count: max(0, state.lives)))"
        }
    }

    private func arenaPoint(x: Double, y: Double) -> CGPoint {
        CGPoint(x: 960 + x * 650, y: 525 + y * 350)
    }

    private func rebuildSnakeTrails() {
        guard mode == .snakePit else { return }
        for participant in context.participants {
            let playerID = participant.player.id
            guard let container = snakeTrailContainers[playerID] else { continue }
            let color = Self.color(participant.player.colorHex)
            let points = snakeTrails[playerID, default: []]
            var nodes = snakeTrailNodes[playerID, default: []]
            while nodes.count < points.count {
                let segment = SKShapeNode(circleOfRadius: 7)
                segment.strokeColor = .clear
                segment.glowWidth = 4
                container.addChild(segment)
                nodes.append(segment)
            }
            for (index, point) in points.enumerated() {
                let segment = nodes[index]
                segment.position = arenaPoint(x: point.x, y: point.y)
                segment.fillColor = color.withAlphaComponent(0.35 + CGFloat(index) / 55)
                segment.isHidden = false
            }
            if nodes.count > points.count {
                for index in points.count..<nodes.count {
                    nodes[index].isHidden = true
                }
            }
            snakeTrailNodes[playerID] = nodes
        }
    }

    private func dominantDirection(x: Double, y: Double) -> String? {
        guard max(abs(x), abs(y)) > 0.58 else { return nil }
        if abs(x) > abs(y) { return x > 0 ? "right" : "left" }
        return y > 0 ? "up" : "down"
    }

    private func nonReversingDirection(_ candidate: String, current: String) -> String {
        let opposite = ["up": "down", "down": "up", "left": "right", "right": "left"]
        return opposite[current] == candidate ? current : candidate
    }

    private func axes(for direction: String) -> (x: Float, y: Float) {
        switch direction {
        case "up": (0, 1)
        case "down": (0, -1)
        case "left": (-1, 0)
        default: (1, 0)
        }
    }

    private func nextRandom() -> UInt64 {
        randomGenerator.next()
    }

#if DEBUG
    var signalDirectionForTesting: String { signalDirection }

    func scoreForTesting(_ playerID: PlayerID) -> Int? {
        states[playerID]?.score
    }

    func snapshotForTesting() -> [PlayerID: ArcadeChallengePlayerSnapshot] {
        states.mapValues {
            ArcadeChallengePlayerSnapshot(
                x: $0.x,
                y: $0.y,
                direction: $0.direction,
                score: $0.score,
                lives: $0.lives,
                alive: $0.alive
            )
        }
    }

    func reverseStorageForTesting() {
        states = Dictionary(uniqueKeysWithValues: states.sorted {
            $0.key.rawValue > $1.key.rawValue
        })
        snakeTrails = Dictionary(uniqueKeysWithValues: snakeTrails.sorted {
            $0.key.rawValue > $1.key.rawValue
        })
    }

    func snakeTrailNodeIdentitiesForTesting() -> [PlayerID: [ObjectIdentifier]] {
        snakeTrailNodes.mapValues { $0.map(ObjectIdentifier.init) }
    }
#endif

    private static func color(_ hex: String) -> SKColor {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let raw = UInt64(value, radix: 16) else { return .white }
        return SKColor(
            red: CGFloat((raw >> 16) & 0xFF) / 255,
            green: CGFloat((raw >> 8) & 0xFF) / 255,
            blue: CGFloat(raw & 0xFF) / 255,
            alpha: 1
        )
    }
}
