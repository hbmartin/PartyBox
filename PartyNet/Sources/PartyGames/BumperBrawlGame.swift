import PartyBoxCore
import PartyGameRuntime
import PartyNet
import SpriteKit

@MainActor
struct BumperBrawlGame: PartyGame {
    let descriptor = GameDescriptor(
        id: "bumper-brawl",
        title: "BUMPER BRAWL",
        summary: "1–8 players  •  Knock rivals off the shrinking ice",
        minimumPlayers: 1,
        maximumPlayers: 8,
        estimatedDurationSeconds: 75,
        supportsMotion: true
    )

    static let controls: [ScreenComponent] = [
        .text(.init(id: "bumper.rule", text: "PUSH RIVALS OFF THE ICE • TAP DASH", style: .caption, tint: .secondary)),
        .axisSurface(.init(
            id: "bumper.steer",
            binding: .twoDimensional,
            instruction: "DRAG TO PUSH  •  MOTION OPTIONAL",
            swipe: .heading
        )),
        .actionButton(.init(id: "bumper.dash", label: "DASH", route: .game("bumper.dash"))),
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
            simulation: BumperBrawlSimulation(players: context.participants.map(\.player.id), seed: context.seed),
            renderer: BumperBrawlRenderer(),
            onEvents: onEvents
        )
    }
}

@MainActor
final class BumperBrawlRenderer: ArcadeRenderer {
    private static let dashRingRadius: CGFloat = 52
    private static let dashRingSteps = 24
    private static let droneFill = SKColor(red: 0.42, green: 0.44, blue: 0.5, alpha: 1)
    private static let droneRed = SKColor(red: 1, green: 0.22, blue: 0.28, alpha: 1)
    private static let dangerColor = SKColor(red: 1, green: 0.3, blue: 0.22, alpha: 1)

    private let platform = SKShapeNode()
    private let rim = SKShapeNode()
    private var drawnRadius: CGFloat = 0
    private var tokens: [SKShapeNode] = []
    private var dashRings: [SKShapeNode] = []
    private var drawnDashSteps: [Int] = []
    private var seenFalls: [Int] = []
    private var seenKOs: [Int] = []
    private var colors: [SKColor] = []
    private let readyRingPath = CGPath(
        ellipseIn: CGRect(
            x: -dashRingRadius,
            y: -dashRingRadius,
            width: dashRingRadius * 2,
            height: dashRingRadius * 2
        ),
        transform: nil
    )

    func build(in scene: ArcadeScene, simulation: BumperBrawlSimulation) {
        let center = scene.point(ArcadeArena.center)
        platform.position = center
        // Opaque so the disk (taller than the shared arena rect) hides the
        // arena border behind it, and pucks sinking at z < 0 vanish under it.
        platform.fillColor = SKColor(red: 0.12, green: 0.17, blue: 0.235, alpha: 1)
        platform.strokeColor = SKColor(red: 0.85, green: 0.97, blue: 1, alpha: 0.55)
        platform.lineWidth = 3
        platform.zPosition = 0
        scene.gameLayer.addChild(platform)

        let finalRadius = CGFloat(BumperBrawlSimulation.finalPlatformRadius)
        let finalRing = SKShapeNode(circleOfRadius: finalRadius)
        finalRing.position = center
        finalRing.strokeColor = SKColor.white.withAlphaComponent(0.12)
        finalRing.lineWidth = 2
        finalRing.fillColor = .clear
        finalRing.zPosition = 0.5
        scene.gameLayer.addChild(finalRing)

        rim.position = center
        rim.fillColor = .clear
        rim.strokeColor = Self.dangerColor
        rim.lineWidth = 6
        rim.glowWidth = 16
        rim.zPosition = 1
        scene.gameLayer.addChild(rim)

        let radius = CGFloat(BumperBrawlSimulation.puckRadius)
        for puck in simulation.pucks {
            let color = puck.playerID.map { scene.color(for: $0) } ?? Self.droneRed
            let token = puck.playerID.map { scene.makeToken(for: $0, radius: radius) } ?? makeDrone(radius: radius)
            token.zPosition = 4
            let ring = SKShapeNode(path: readyRingPath)
            ring.fillColor = .clear
            ring.lineWidth = 5
            ring.lineCap = .round
            ring.zPosition = -0.5
            token.addChild(ring)
            scene.gameLayer.addChild(token)
            tokens.append(token)
            dashRings.append(ring)
            drawnDashSteps.append(-1)
            seenFalls.append(puck.falls)
            seenKOs.append(puck.kos)
            colors.append(color)
        }
    }

    func render(_ simulation: BumperBrawlSimulation, events: [ArcadeEvent], in scene: ArcadeScene) {
        renderPlatform(simulation)
        for (index, puck) in simulation.pucks.enumerated() where index < tokens.count {
            let token = tokens[index]
            token.position = scene.point(puck.position)
            if puck.isFalling {
                // Slide off the rim, sinking under the ice as it shrinks away.
                let remaining = CGFloat(puck.fallRemaining / BumperBrawlSimulation.respawnDelay)
                token.isHidden = false
                token.zPosition = -1
                token.setScale(0.25 + (0.75 * remaining))
                token.alpha = remaining
            } else if !puck.alive {
                token.isHidden = true
            } else {
                token.isHidden = false
                token.zPosition = 4
                token.setScale(puck.isDashing ? 1.12 : 1)
                token.alpha = puck.isGhost ? (Int(simulation.elapsed * 12).isMultiple(of: 2) ? 0.28 : 0.55) : 1
            }
            renderDashRing(index, puck: puck)
            if puck.falls != seenFalls[index] {
                seenFalls[index] = puck.falls
                splash(at: token.position, color: colors[index], in: scene)
            }
            if puck.kos != seenKOs[index] {
                seenKOs[index] = puck.kos
                knockout(above: token.position, color: colors[index], in: scene)
            }
        }
    }

    private func renderPlatform(_ simulation: BumperBrawlSimulation) {
        let radius = CGFloat(simulation.platformRadius)
        if abs(radius - drawnRadius) > 0.5 {
            drawnRadius = radius
            let path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
            platform.path = path
            rim.path = path
        }
        let pulse = simulation.isShrinking ? 0.5 + (0.5 * sin(simulation.elapsed * 5)) : 0
        rim.alpha = CGFloat(0.3 + (0.4 * simulation.shrinkProgress) + (0.25 * pulse))
    }

    private func renderDashRing(_ index: Int, puck: BumperBrawlSimulation.Puck) {
        let ring = dashRings[index]
        ring.isHidden = !puck.onBoard
        let steps = Self.dashRingSteps
        let step = puck.dashReady ? steps : min(steps - 1, Int(puck.dashCharge * Double(steps)))
        guard step != drawnDashSteps[index] else { return }
        drawnDashSteps[index] = step
        if step >= steps {
            ring.path = readyRingPath
            ring.strokeColor = SKColor.white.withAlphaComponent(0.95)
            ring.glowWidth = 6
        } else {
            let path = CGMutablePath()
            let sweep = (CGFloat(step) / CGFloat(steps)) * .pi * 2
            path.addArc(
                center: .zero,
                radius: Self.dashRingRadius,
                startAngle: .pi / 2,
                endAngle: (.pi / 2) - max(sweep, 0.05),
                clockwise: true
            )
            ring.path = path
            ring.strokeColor = colors[index].withAlphaComponent(0.5)
            ring.glowWidth = 0
        }
    }

    private func makeDrone(radius: CGFloat) -> SKShapeNode {
        let node = SKShapeNode(circleOfRadius: radius)
        node.fillColor = Self.droneFill
        node.strokeColor = Self.droneRed
        node.lineWidth = 4
        node.glowWidth = 8
        let eye = SKShapeNode(circleOfRadius: radius * 0.32)
        eye.fillColor = Self.droneRed
        eye.strokeColor = .clear
        eye.glowWidth = 6
        eye.zPosition = 1
        eye.run(.repeatForever(.sequence([.fadeAlpha(to: 0.45, duration: 0.4), .fadeAlpha(to: 1, duration: 0.4)])))
        node.addChild(eye)
        return node
    }

    private func splash(at position: CGPoint, color: SKColor, in scene: ArcadeScene) {
        for (delay, scale) in [(0.0, 3.2), (0.1, 2.2)] {
            let ring = SKShapeNode(circleOfRadius: CGFloat(BumperBrawlSimulation.puckRadius) * 0.6)
            ring.position = position
            ring.strokeColor = color
            ring.fillColor = .clear
            ring.lineWidth = 5
            ring.glowWidth = 10
            ring.zPosition = 6
            ring.alpha = 0
            scene.gameLayer.addChild(ring)
            ring.run(.sequence([
                .wait(forDuration: delay),
                .fadeIn(withDuration: 0),
                .group([.scale(to: scale, duration: 0.45), .fadeOut(withDuration: 0.45)]),
                .removeFromParent(),
            ]))
        }
    }

    private func knockout(above position: CGPoint, color: SKColor, in scene: ArcadeScene) {
        let label = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        label.text = "KO!"
        label.fontSize = 44
        label.fontColor = color
        label.verticalAlignmentMode = .center
        label.position = CGPoint(x: position.x, y: position.y + 64)
        label.zPosition = 8
        label.setScale(0.6)
        scene.gameLayer.addChild(label)
        label.run(.sequence([
            .group([.scale(to: 1.15, duration: 0.14), .moveBy(x: 0, y: 26, duration: 0.14)]),
            .group([.moveBy(x: 0, y: 40, duration: 0.6), .fadeOut(withDuration: 0.6)]),
            .removeFromParent(),
        ]))
    }
}
