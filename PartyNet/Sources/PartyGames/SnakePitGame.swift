import PartyBoxCore
import PartyGameRuntime
import PartyNet
import SpriteKit

@MainActor
struct SnakePitGame: PartyGame {
    let descriptor = GameDescriptor(
        id: "snake-pit",
        title: "SNAKE PIT",
        summary: "1–8 players  •  Light cycles that keep getting faster",
        minimumPlayers: 1,
        maximumPlayers: 8,
        estimatedDurationSeconds: 65,
        supportsMotion: false
    )

    static let controls: [ScreenComponent] = [
        .text(.init(id: "snake.rule", text: "TURN • CUT THEM OFF • THREE LIVES", style: .caption, tint: .secondary)),
        .directionPad(.init(id: "snake.direction", instruction: "TAP OR SWIPE TO TURN")),
    ]

    func makeSession(context: GameSessionContext, onEvents: @escaping @MainActor ([GameEvent]) -> Void) -> any PartyGameSession {
        ArcadeSession(
            configuration: .init(
                gameID: descriptor.id,
                title: descriptor.title,
                supportsMotion: descriptor.supportsMotion,
                controls: Self.controls
            ),
            context: context,
            simulation: SnakePitSimulation(players: context.participants.map(\.player.id), seed: context.seed),
            renderer: SnakePitRenderer(),
            onEvents: onEvents
        )
    }
}

@MainActor
final class SnakePitRenderer: ArcadeRenderer {
    private var heads: [PlayerID: SKShapeNode] = [:]
    private var trailLayers: [PlayerID: SKNode] = [:]
    private var trailSprites: [PlayerID: [SKSpriteNode]] = [:]
    private var trailGenerations: [PlayerID: Int] = [:]
    private let pelletNode = SKShapeNode(circleOfRadius: 9)

    func build(in scene: ArcadeScene, simulation: SnakePitSimulation) {
        let size = CGSize(
            width: Double(SnakePitSimulation.columns) * SnakePitSimulation.cellSize,
            height: Double(SnakePitSimulation.rows) * SnakePitSimulation.cellSize
        )
        let board = SKShapeNode(rect: CGRect(origin: scene.point(SnakePitSimulation.origin), size: size), cornerRadius: 6)
        board.fillColor = SKColor(red: 0.03, green: 0.06, blue: 0.13, alpha: 0.85)
        board.strokeColor = SKColor(red: 0.3, green: 1, blue: 0.55, alpha: 0.45)
        board.lineWidth = 3
        board.glowWidth = 6
        scene.gameLayer.addChild(board)

        pelletNode.fillColor = .partyHex(SnakePitSimulation.pelletColor)
        pelletNode.strokeColor = .white
        pelletNode.glowWidth = 10
        pelletNode.zPosition = 3
        pelletNode.run(.repeatForever(.sequence([.scale(to: 1.3, duration: 0.3), .scale(to: 1, duration: 0.3)])))
        scene.gameLayer.addChild(pelletNode)

        for snake in simulation.snakes {
            let layer = SKNode()
            layer.zPosition = 1
            scene.gameLayer.addChild(layer)
            trailLayers[snake.playerID] = layer
            trailSprites[snake.playerID] = []
            trailGenerations[snake.playerID] = snake.trailGeneration

            let head = scene.makeToken(for: snake.playerID, radius: 15)
            head.zPosition = 4
            scene.gameLayer.addChild(head)
            heads[snake.playerID] = head
        }
    }

    func render(_ simulation: SnakePitSimulation, events: [ArcadeEvent], in scene: ArcadeScene) {
        if let pellet = simulation.pellet {
            pelletNode.isHidden = false
            pelletNode.position = scene.point(pellet.center)
        } else {
            pelletNode.isHidden = true
        }
        for snake in simulation.snakes {
            syncTrail(snake, in: scene)
            guard let head = heads[snake.playerID] else { continue }
            head.position = scene.point(snake.head.center)
            head.isHidden = !snake.onBoard
            head.alpha = snake.isGhost ? (Int(simulation.elapsed * 12).isMultiple(of: 2) ? 0.25 : 0.7) : 1
        }
        for event in events {
            if case .lostLife(let playerID, _) = event { burst(at: heads[playerID]?.position, playerID: playerID, in: scene) }
            if case .eliminated(let playerID) = event { burst(at: heads[playerID]?.position, playerID: playerID, in: scene) }
        }
    }

    private func syncTrail(_ snake: SnakePitSimulation.Snake, in scene: ArcadeScene) {
        guard let layer = trailLayers[snake.playerID] else { return }
        var sprites = trailSprites[snake.playerID, default: []]
        if trailGenerations[snake.playerID] != snake.trailGeneration {
            trailGenerations[snake.playerID] = snake.trailGeneration
            for sprite in sprites {
                sprite.run(.sequence([.group([.fadeOut(withDuration: 0.35), .scale(to: 0.2, duration: 0.35)]), .removeFromParent()]))
            }
            sprites = []
        }
        let color = scene.color(for: snake.playerID)
        let side = CGFloat(SnakePitSimulation.cellSize - 3)
        while sprites.count < snake.trail.count {
            let cell = snake.trail[sprites.count]
            let sprite = SKSpriteNode(color: color.withAlphaComponent(0.78), size: CGSize(width: side, height: side))
            sprite.position = scene.point(cell.center)
            layer.addChild(sprite)
            sprites.append(sprite)
        }
        trailSprites[snake.playerID] = sprites
    }

    private func burst(at position: CGPoint?, playerID: PlayerID, in scene: ArcadeScene) {
        guard let position else { return }
        let ring = SKShapeNode(circleOfRadius: 20)
        ring.position = position
        ring.strokeColor = scene.color(for: playerID)
        ring.lineWidth = 5
        ring.glowWidth = 10
        ring.zPosition = 6
        scene.gameLayer.addChild(ring)
        ring.run(.sequence([.group([.scale(to: 4, duration: 0.4), .fadeOut(withDuration: 0.4)]), .removeFromParent()]))
    }
}
