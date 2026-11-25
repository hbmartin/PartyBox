import PartyBoxCore
import PartyGameRuntime
import PartyNet
import SpriteKit

@MainActor
struct SkyHopGame: PartyGame {
    let descriptor = GameDescriptor(
        id: "sky-hop",
        title: "SKY HOP",
        summary: "1–8 players  •  Tap to flap through ever-tighter gaps",
        minimumPlayers: 1,
        maximumPlayers: 8,
        estimatedDurationSeconds: 60,
        supportsMotion: false
    )

    static let controls: [ScreenComponent] = [
        .text(.init(id: "sky.rule", text: "TAP TO FLAP • LAST ONE FLYING WINS", style: .caption, tint: .secondary)),
        .actionButton(.init(id: "sky.flap", label: "FLAP", route: .game("sky.flap"))),
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
            simulation: SkyHopSimulation(players: context.participants.map(\.player.id), seed: context.seed),
            renderer: SkyHopRenderer(),
            onEvents: onEvents
        )
    }
}

@MainActor
final class SkyHopRenderer: ArcadeRenderer {
    private struct GateSprites {
        let lower: SKSpriteNode
        let upper: SKSpriteNode
        let lowerLip: SKSpriteNode
        let upperLip: SKSpriteNode

        var all: [SKSpriteNode] { [lower, upper, lowerLip, upperLip] }
    }

    private struct Star {
        let node: SKSpriteNode
        let baseX: Double
        let parallax: Double
    }

    private static let lipHeight = 16.0
    private static let pillarColor = SKColor(red: 0.16, green: 0.86, blue: 0.52, alpha: 0.92)
    private static let lipColor = SKColor(red: 0.62, green: 1, blue: 0.8, alpha: 1)
    private static let hazardColor = SKColor(red: 1, green: 0.22, blue: 0.37, alpha: 0.7)

    private let pillarLayer = SKNode()
    private var birdNodes: [PlayerID: SKShapeNode] = [:]
    private var fallen: Set<PlayerID> = []
    private var gateSprites: [Int: GateSprites] = [:]
    private var spritePool: [SKSpriteNode] = []
    private var stars: [Star] = []

    func build(in scene: ArcadeScene, simulation: SkyHopSimulation) {
        buildStarfield(in: scene)

        for y in [ArcadeArena.minY, ArcadeArena.maxY] {
            let edge = SKSpriteNode(color: Self.hazardColor, size: CGSize(width: ArcadeArena.maxX - ArcadeArena.minX - 40, height: 4))
            edge.position = CGPoint(x: ArcadeArena.center.x, y: y)
            edge.zPosition = 1
            scene.gameLayer.addChild(edge)
        }

        pillarLayer.zPosition = 2
        scene.gameLayer.addChild(pillarLayer)

        for (index, bird) in simulation.birds.enumerated() {
            let token = scene.makeToken(for: bird.playerID, radius: CGFloat(SkyHopSimulation.birdRadius))
            let beak = SKShapeNode(path: Self.beakPath)
            beak.fillColor = SKColor(red: 1, green: 0.78, blue: 0.2, alpha: 1)
            beak.strokeColor = .white
            beak.lineWidth = 2
            beak.zPosition = -1
            token.addChild(beak)
            token.zPosition = 4 + CGFloat(simulation.birds.count - index) * 0.01
            scene.gameLayer.addChild(token)
            birdNodes[bird.playerID] = token
        }
    }

    func render(_ simulation: SkyHopSimulation, events: [ArcadeEvent], in scene: ArcadeScene) {
        scrollStars(distance: simulation.distance)
        syncGates(simulation.gates)

        for bird in simulation.birds where !fallen.contains(bird.playerID) {
            guard let node = birdNodes[bird.playerID] else { continue }
            node.position = scene.point(ArcadeVector(x: bird.x, y: bird.y))
            node.zRotation = CGFloat(min(max(bird.vy * 0.000_9, -1.1), 0.5))
        }

        for event in events {
            switch event {
            case .eliminated(let playerID):
                tumble(playerID, speed: simulation.scrollSpeed, in: scene)
            case .cue(let playerID, _, _):
                guard !fallen.contains(playerID), let node = birdNodes[playerID] else { continue }
                node.removeAction(forKey: "pass")
                node.setScale(1)
                node.run(.sequence([.scale(to: 1.3, duration: 0.06), .scale(to: 1, duration: 0.14)]), withKey: "pass")
            default:
                break
            }
        }
    }

    // MARK: Gates

    /// Positions each gate's pillars, clipped to the arena so they slide in and
    /// out at its edges, reusing sprites from a pool.
    private func syncGates(_ gates: [SkyHopSimulation.Gate]) {
        var live: Set<Int> = []
        for gate in gates {
            let left = max(gate.x, ArcadeArena.minX)
            let right = min(gate.trailingEdge, ArcadeArena.maxX)
            guard right > left else { continue }
            live.insert(gate.id)
            let sprites = gateSprites[gate.id] ?? makeGateSprites()
            gateSprites[gate.id] = sprites
            let lipHeight = Self.lipHeight
            place(sprites.lower, left: left, right: right, bottom: ArcadeArena.minY, top: gate.gapBottom)
            place(sprites.upper, left: left, right: right, bottom: gate.gapTop, top: ArcadeArena.maxY)
            place(sprites.lowerLip, left: left, right: right, bottom: gate.gapBottom - lipHeight, top: gate.gapBottom)
            place(sprites.upperLip, left: left, right: right, bottom: gate.gapTop, top: gate.gapTop + lipHeight)
        }
        for (id, sprites) in gateSprites where !live.contains(id) {
            for sprite in sprites.all {
                sprite.isHidden = true
                spritePool.append(sprite)
            }
            gateSprites.removeValue(forKey: id)
        }
    }

    private func makeGateSprites() -> GateSprites {
        GateSprites(
            lower: dequeueSprite(color: Self.pillarColor),
            upper: dequeueSprite(color: Self.pillarColor),
            lowerLip: dequeueSprite(color: Self.lipColor),
            upperLip: dequeueSprite(color: Self.lipColor)
        )
    }

    private func dequeueSprite(color: SKColor) -> SKSpriteNode {
        let sprite = spritePool.popLast() ?? {
            let sprite = SKSpriteNode(color: color, size: CGSize(width: 1, height: 1))
            pillarLayer.addChild(sprite)
            return sprite
        }()
        sprite.color = color
        sprite.isHidden = false
        return sprite
    }

    private func place(_ sprite: SKSpriteNode, left: Double, right: Double, bottom: Double, top: Double) {
        guard top > bottom else {
            sprite.isHidden = true
            return
        }
        sprite.isHidden = false
        sprite.size = CGSize(width: right - left, height: top - bottom)
        sprite.position = CGPoint(x: (left + right) / 2, y: (bottom + top) / 2)
    }

    // MARK: Birds

    private static let beakPath: CGPath = {
        let radius = SkyHopSimulation.birdRadius
        let path = CGMutablePath()
        path.move(to: CGPoint(x: radius - 4, y: 7))
        path.addLine(to: CGPoint(x: radius + 14, y: 0))
        path.addLine(to: CGPoint(x: radius - 4, y: -7))
        path.closeSubpath()
        return path
    }()

    /// Crashed birds drift back with the corridor, spin and drop off-screen.
    private func tumble(_ playerID: PlayerID, speed: Double, in scene: ArcadeScene) {
        guard fallen.insert(playerID).inserted, let node = birdNodes[playerID] else { return }
        let ring = SKShapeNode(circleOfRadius: CGFloat(SkyHopSimulation.birdRadius))
        ring.position = node.position
        ring.strokeColor = scene.color(for: playerID)
        ring.lineWidth = 5
        ring.glowWidth = 10
        ring.zPosition = 6
        scene.gameLayer.addChild(ring)
        ring.run(.sequence([.group([.scale(to: 3.5, duration: 0.4), .fadeOut(withDuration: 0.4)]), .removeFromParent()]))

        let duration = 0.9
        let drop = SKAction.moveTo(y: -80, duration: duration)
        drop.timingMode = .easeIn
        node.removeAllActions()
        node.setScale(1)
        node.run(.sequence([
            .group([
                drop,
                .moveBy(x: -speed * duration * 0.5, y: 0, duration: duration),
                .rotate(byAngle: -.pi * 3, duration: duration),
                .sequence([.wait(forDuration: duration * 0.4), .fadeOut(withDuration: duration * 0.6)]),
            ]),
            .hide(),
        ]))
    }

    // MARK: Background

    private func buildStarfield(in scene: ArcadeScene) {
        var random = ArcadeRandomNumberGenerator(seed: 0x5C40_57A2)
        let layer = SKNode()
        layer.zPosition = 0
        scene.gameLayer.addChild(layer)
        for index in 0..<36 {
            let near = index.isMultiple(of: 3)
            let side = near ? 4.0 : 2.5
            let star = SKSpriteNode(
                color: SKColor(red: 0.7, green: 0.85, blue: 1, alpha: near ? 0.55 : 0.3),
                size: CGSize(width: side, height: side)
            )
            star.position = CGPoint(
                x: 0,
                y: random.double(in: (ArcadeArena.minY + 12)...(ArcadeArena.maxY - 12))
            )
            layer.addChild(star)
            stars.append(Star(
                node: star,
                baseX: random.double(in: 0...(ArcadeArena.maxX - ArcadeArena.minX)),
                parallax: near ? 0.35 : 0.15
            ))
        }
        scrollStars(distance: 0)
    }

    private func scrollStars(distance: Double) {
        let width = ArcadeArena.maxX - ArcadeArena.minX
        for star in stars {
            var offset = (star.baseX - (distance * star.parallax)).truncatingRemainder(dividingBy: width)
            if offset < 0 { offset += width }
            star.node.position.x = ArcadeArena.minX + offset
        }
    }

#if DEBUG
    /// Pillar and lip sprites ever created, visible or pooled.
    var pillarSpriteCountForTesting: Int { pillarLayer.children.count }
    var visiblePillarSpriteCountForTesting: Int { pillarLayer.children.count { !$0.isHidden } }
#endif
}
