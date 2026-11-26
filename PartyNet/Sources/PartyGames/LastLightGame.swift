import PartyBoxCore
import PartyGameRuntime
import PartyNet
import SpriteKit

@MainActor
struct LastLightGame: PartyGame {
    let descriptor = GameDescriptor(
        id: "last-light",
        title: "LAST LIGHT",
        summary: "1–8 players  •  Dodge the red, hog the spotlight",
        minimumPlayers: 1,
        maximumPlayers: 8,
        estimatedDurationSeconds: 65,
        supportsMotion: true
    )

    static let controls: [ScreenComponent] = [
        .text(.init(id: "light.rule", text: "STAY IN THE LIGHT • DODGE THE RED", style: .caption, tint: .secondary)),
        .axisSurface(.init(
            id: "light.steer",
            binding: .twoDimensional,
            instruction: "DRAG WHERE TO GO  •  MOTION OPTIONAL",
            swipe: .relative
        )),
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
            simulation: LastLightSimulation(players: context.participants.map(\.player.id), seed: context.seed),
            renderer: LastLightRenderer(),
            onEvents: onEvents
        )
    }
}

@MainActor
final class LastLightRenderer: ArcadeRenderer {
    private let light = SKShapeNode(circleOfRadius: 1)
    private var lightRadius: CGFloat = 0
    private let hazardLayer = SKNode()
    private var orbs: [PlayerID: SKShapeNode] = [:]
    private var hazardNodes: [Int: SKNode] = [:]
    private let hazardRed = SKColor(red: 1, green: 0.14, blue: 0.3, alpha: 1)

    func build(in scene: ArcadeScene, simulation: LastLightSimulation) {
        light.fillColor = SKColor(red: 1, green: 0.95, blue: 0.7, alpha: 0.13)
        light.strokeColor = SKColor(red: 1, green: 0.95, blue: 0.75, alpha: 0.55)
        light.lineWidth = 3
        light.glowWidth = 18
        light.zPosition = 0
        scene.gameLayer.addChild(light)

        hazardLayer.zPosition = 2
        scene.gameLayer.addChild(hazardLayer)

        for player in simulation.players {
            let orb = scene.makeToken(for: player.playerID, radius: CGFloat(LastLightSimulation.playerRadius))
            orb.zPosition = 4
            scene.gameLayer.addChild(orb)
            orbs[player.playerID] = orb
        }
    }

    func render(_ simulation: LastLightSimulation, events: [ArcadeEvent], in scene: ArcadeScene) {
        light.position = scene.point(simulation.lightCenter)
        let radius = CGFloat(simulation.lightRadius)
        if abs(radius - lightRadius) > 0.5 {
            lightRadius = radius
            light.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        }

        var live: Set<Int> = []
        for hazard in simulation.hazards {
            live.insert(hazard.id)
            let node = hazardNodes[hazard.id] ?? makeNode(for: hazard, in: scene)
            hazardNodes[hazard.id] = node
            node.position = position(for: hazard, in: scene)
            node.alpha = hazard.isArmed ? 1 : (Int(simulation.elapsed * 14).isMultiple(of: 2) ? 0.25 : 0.55)
        }
        for (id, node) in hazardNodes where !live.contains(id) {
            node.removeFromParent()
            hazardNodes.removeValue(forKey: id)
        }

        for player in simulation.players {
            guard let orb = orbs[player.playerID] else { continue }
            orb.position = scene.point(player.position)
            if !player.alive {
                orb.alpha = 0.12
            } else if player.isInvulnerable {
                orb.alpha = Int(simulation.elapsed * 16).isMultiple(of: 2) ? 0.3 : 0.9
            } else {
                orb.alpha = 1
            }
        }
        for case .lostLife(let playerID, _) in events {
            orbs[playerID]?.run(.sequence([.scale(to: 1.5, duration: 0.06), .scale(to: 1, duration: 0.18)]))
        }
    }

    private func makeNode(for hazard: LastLightSimulation.Hazard, in scene: ArcadeScene) -> SKNode {
        let node: SKNode
        switch hazard.kind {
        case .block:
            let half = LastLightSimulation.blockHalfSize
            let block = SKShapeNode(rectOf: CGSize(width: half.x * 2, height: half.y * 2), cornerRadius: 9)
            block.fillColor = hazardRed.withAlphaComponent(0.88)
            block.strokeColor = .white.withAlphaComponent(0.5)
            block.glowWidth = 8
            node = block
        case .seeker:
            let seeker = SKShapeNode(circleOfRadius: CGFloat(LastLightSimulation.seekerRadius))
            seeker.fillColor = SKColor(red: 1, green: 0.35, blue: 0.1, alpha: 0.95)
            seeker.strokeColor = .white
            seeker.glowWidth = 12
            seeker.run(.repeatForever(.sequence([.scale(to: 1.25, duration: 0.18), .scale(to: 1, duration: 0.18)])))
            node = seeker
        case .rowSweeper, .columnSweeper:
            node = makeSweeper(for: hazard)
        }
        hazardLayer.addChild(node)
        return node
    }

    /// Sweepers are two bars around a gap, built in local coordinates where the
    /// node sits on the bar's track and the gap is offset along the bar.
    private func makeSweeper(for hazard: LastLightSimulation.Hazard) -> SKNode {
        let container = SKNode()
        let horizontalBar = hazard.kind == .rowSweeper
        let thickness = LastLightSimulation.sweeperHalfThickness * 2
        let gapHalf = LastLightSimulation.sweeperGapHalfWidth
        let (low, high, center) = horizontalBar
            ? (ArcadeArena.minX, ArcadeArena.maxX, ArcadeArena.center.x)
            : (ArcadeArena.minY, ArcadeArena.maxY, ArcadeArena.center.y)
        let segments = [(low, hazard.gapCenter - gapHalf), (hazard.gapCenter + gapHalf, high)]
        for (start, end) in segments where end > start {
            let length = end - start
            let mid = ((start + end) / 2) - center
            let size = horizontalBar ? CGSize(width: length, height: thickness) : CGSize(width: thickness, height: length)
            let bar = SKShapeNode(rectOf: size, cornerRadius: 6)
            bar.fillColor = hazardRed.withAlphaComponent(0.85)
            bar.strokeColor = .white.withAlphaComponent(0.6)
            bar.glowWidth = 10
            bar.position = horizontalBar ? CGPoint(x: mid, y: 0) : CGPoint(x: 0, y: mid)
            container.addChild(bar)
        }
        return container
    }

    private func position(for hazard: LastLightSimulation.Hazard, in scene: ArcadeScene) -> CGPoint {
        switch hazard.kind {
        case .block, .seeker:
            scene.point(hazard.position)
        case .rowSweeper:
            CGPoint(x: ArcadeArena.center.x, y: hazard.position.y)
        case .columnSweeper:
            CGPoint(x: hazard.position.x, y: ArcadeArena.center.y)
        }
    }
}
