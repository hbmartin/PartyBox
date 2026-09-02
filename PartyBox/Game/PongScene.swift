import PartyNet
import SpriteKit

final class PongScene: SKScene {
    private let arenaCenter = CGPoint(x: 960, y: 540)
    private let arenaSize = CGSize(width: 1_000, height: 1_000)
    private let inputStore: InputStore
    private let playerInfo: [PlayerID: PlayerInfo]
    private let onEvents: ([PongEvent]) -> Void
    private var simulation: PongSimulation
    private var previousUpdateTime: TimeInterval?

    private let ballNode = SKShapeNode(circleOfRadius: PongSimulation.ballRadius)
    private let countdownLabel = SKLabelNode(fontNamed: "AvenirNext-Heavy")
    private var paddleNodes: [PaddleEdge: SKShapeNode] = [:]
    private var lifeLabels: [PaddleEdge: SKLabelNode] = [:]

    init(
        assignments: [SeatAssignment],
        players: [PlayerInfo],
        inputs: InputStore,
        seed: UInt64 = UInt64.random(in: 1...UInt64.max),
        onEvents: @escaping ([PongEvent]) -> Void
    ) {
        simulation = PongSimulation(assignments: assignments, seed: seed)
        inputStore = inputs
        playerInfo = Dictionary(uniqueKeysWithValues: players.map { ($0.id, $0) })
        self.onEvents = onEvents
        super.init(size: CGSize(width: 1_920, height: 1_080))
        scaleMode = .aspectFit
        backgroundColor = SKColor(red: 0.02, green: 0.025, blue: 0.08, alpha: 1)
        buildScene(assignments: assignments)
        syncNodes()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func update(_ currentTime: TimeInterval) {
        let snapshot = inputStore.snapshot()
        for (playerID, frame) in snapshot {
            simulation.setPaddle(for: playerID, normalizedPosition: Double(frame.axisX))
        }

        let delta = previousUpdateTime.map { currentTime - $0 } ?? (1.0 / 60.0)
        previousUpdateTime = currentTime
        let events = simulation.step(deltaTime: delta)
        syncNodes()
        if !events.isEmpty {
            animate(events)
            onEvents(events)
        }
    }

    func forfeit(_ playerID: PlayerID) {
        let events = simulation.forfeit(playerID)
        syncNodes()
        if !events.isEmpty {
            animate(events)
            onEvents(events)
        }
    }

    private func buildScene(assignments: [SeatAssignment]) {
        let grid = SKNode()
        for offset in stride(from: -400, through: 400, by: 100) {
            let vertical = SKShapeNode(rectOf: CGSize(width: 1, height: 1_000))
            vertical.position = CGPoint(x: arenaCenter.x + CGFloat(offset), y: arenaCenter.y)
            vertical.strokeColor = .clear
            vertical.fillColor = SKColor(red: 0.10, green: 0.22, blue: 0.40, alpha: 0.20)
            grid.addChild(vertical)
            let horizontal = SKShapeNode(rectOf: CGSize(width: 1_000, height: 1))
            horizontal.position = CGPoint(x: arenaCenter.x, y: arenaCenter.y + CGFloat(offset))
            horizontal.strokeColor = .clear
            horizontal.fillColor = SKColor(red: 0.10, green: 0.22, blue: 0.40, alpha: 0.20)
            grid.addChild(horizontal)
        }
        addChild(grid)

        let border = SKShapeNode(rectOf: arenaSize, cornerRadius: 16)
        border.position = arenaCenter
        border.strokeColor = SKColor(red: 0.18, green: 0.90, blue: 1, alpha: 0.55)
        border.lineWidth = 5
        border.glowWidth = 12
        border.fillColor = .clear
        addChild(border)

        for assignment in assignments {
            let info = playerInfo[assignment.playerID]
            let color = SKColor.partyHex(info?.colorHex ?? "#FFFFFF")
            let horizontal = assignment.edge == .bottom || assignment.edge == .top
            let size = horizontal
                ? CGSize(width: PongSimulation.paddleLength, height: PongSimulation.paddleThickness)
                : CGSize(width: PongSimulation.paddleThickness, height: PongSimulation.paddleLength)
            let paddle = SKShapeNode(rectOf: size, cornerRadius: 12)
            paddle.fillColor = color
            paddle.strokeColor = .white.withAlphaComponent(0.8)
            paddle.lineWidth = 2
            paddle.glowWidth = 18
            addChild(paddle)
            paddleNodes[assignment.edge] = paddle

            let label = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
            label.fontSize = 25
            label.fontColor = color
            label.horizontalAlignmentMode = .center
            label.verticalAlignmentMode = .center
            label.text = "P\(info?.number ?? Int(assignment.playerID.rawValue) + 1)  \(info?.displayName ?? "Player")"
            label.position = labelPosition(for: assignment.edge)
            if !horizontal { label.zRotation = assignment.edge == .left ? .pi / 2 : -.pi / 2 }
            addChild(label)

            let lives = SKLabelNode(fontNamed: "AvenirNext-Heavy")
            lives.fontSize = 23
            lives.fontColor = color
            lives.horizontalAlignmentMode = .center
            lives.verticalAlignmentMode = .center
            lives.position = lifePosition(for: assignment.edge)
            if !horizontal { lives.zRotation = assignment.edge == .left ? .pi / 2 : -.pi / 2 }
            addChild(lives)
            lifeLabels[assignment.edge] = lives
        }

        ballNode.fillColor = .white
        ballNode.strokeColor = SKColor(red: 0.35, green: 0.95, blue: 1, alpha: 1)
        ballNode.lineWidth = 3
        ballNode.glowWidth = 24
        addChild(ballNode)

        countdownLabel.fontSize = 86
        countdownLabel.fontColor = .white
        countdownLabel.horizontalAlignmentMode = .center
        countdownLabel.verticalAlignmentMode = .center
        countdownLabel.position = arenaCenter
        addChild(countdownLabel)

        let title = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        title.text = "PARTYBOX  /  PONG"
        title.fontSize = 28
        title.fontColor = SKColor(red: 0.72, green: 0.78, blue: 0.96, alpha: 0.8)
        title.horizontalAlignmentMode = .left
        title.position = CGPoint(x: 42, y: 1_025)
        addChild(title)
    }

    private func syncNodes() {
        ballNode.position = CGPoint(
            x: arenaCenter.x + simulation.ballPosition.x,
            y: arenaCenter.y + simulation.ballPosition.y
        )
        ballNode.isHidden = simulation.ballVelocity == .zero
        countdownLabel.text = simulation.countdown.map(String.init)

        for edge in PaddleEdge.allCases {
            guard let player = simulation.players[edge] else { continue }
            let travel = PongSimulation.arenaHalfExtent - (PongSimulation.paddleLength / 2)
            let offset = player.paddlePosition * travel
            paddleNodes[edge]?.position = paddlePosition(for: edge, tangent: offset)
            paddleNodes[edge]?.isHidden = !player.isActive
            lifeLabels[edge]?.text = String(repeating: "◆", count: player.lives)
            lifeLabels[edge]?.alpha = player.isActive ? 1 : 0.28
        }
    }

    private func animate(_ events: [PongEvent]) {
        for event in events {
            switch event {
            case let .paddleHit(playerID):
                guard let edge = simulation.players.first(where: { $0.value.playerID == playerID })?.key else { continue }
                paddleNodes[edge]?.run(.sequence([
                    .scale(to: 1.18, duration: 0.045),
                    .scale(to: 1, duration: 0.10),
                ]))
                ballNode.run(.sequence([
                    .fadeAlpha(to: 0.35, duration: 0.025),
                    .fadeAlpha(to: 1, duration: 0.07),
                ]))
            case let .lostLife(playerID, _):
                guard let edge = simulation.players.first(where: { $0.value.playerID == playerID })?.key else { continue }
                lifeLabels[edge]?.run(.sequence([
                    .scale(to: 1.45, duration: 0.08),
                    .scale(to: 1, duration: 0.18),
                ]))
            case let .eliminated(playerID), let .forfeited(playerID):
                guard let edge = simulation.players.first(where: { $0.value.playerID == playerID })?.key else { continue }
                lifeLabels[edge]?.run(.fadeAlpha(to: 0.2, duration: 0.25))
            case .gameOver:
                break
            }
        }
    }

    private func paddlePosition(for edge: PaddleEdge, tangent: Double) -> CGPoint {
        switch edge {
        case .bottom: CGPoint(x: arenaCenter.x + tangent, y: arenaCenter.y - 500)
        case .top: CGPoint(x: arenaCenter.x + tangent, y: arenaCenter.y + 500)
        case .left: CGPoint(x: arenaCenter.x - 500, y: arenaCenter.y + tangent)
        case .right: CGPoint(x: arenaCenter.x + 500, y: arenaCenter.y + tangent)
        }
    }

    private func labelPosition(for edge: PaddleEdge) -> CGPoint {
        switch edge {
        case .bottom: CGPoint(x: arenaCenter.x, y: 18)
        case .top: CGPoint(x: arenaCenter.x, y: 1_062)
        case .left: CGPoint(x: 430, y: arenaCenter.y)
        case .right: CGPoint(x: 1_490, y: arenaCenter.y)
        }
    }

    private func lifePosition(for edge: PaddleEdge) -> CGPoint {
        switch edge {
        case .bottom: CGPoint(x: arenaCenter.x + 410, y: 18)
        case .top: CGPoint(x: arenaCenter.x - 410, y: 1_062)
        case .left: CGPoint(x: 430, y: arenaCenter.y - 410)
        case .right: CGPoint(x: 1_490, y: arenaCenter.y + 410)
        }
    }
}

private extension SKColor {
    static func partyHex(_ value: String) -> SKColor {
        let hex = value.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard hex.count == 6, let number = UInt64(hex, radix: 16) else { return .white }
        return SKColor(
            red: CGFloat((number >> 16) & 0xFF) / 255,
            green: CGFloat((number >> 8) & 0xFF) / 255,
            blue: CGFloat(number & 0xFF) / 255,
            alpha: 1
        )
    }
}
