import PartyBoxCore
import PartyGameRuntime
import PartyNet
import SpriteKit

@MainActor
struct HotFuseGame: PartyGame {
    let descriptor = GameDescriptor(
        id: "hot-fuse",
        title: "HOT FUSE",
        summary: "1–8 players  •  Pass the bomb before it blows",
        minimumPlayers: 1,
        maximumPlayers: 8,
        estimatedDurationSeconds: 75,
        supportsMotion: true
    )

    static let controls: [ScreenComponent] = [
        .text(.init(id: "fuse.rule", text: "PASS THE BOMB • DON'T HOLD IT AT THE BOOM", style: .caption, tint: .secondary)),
        .axisSurface(.init(
            id: "fuse.steer",
            binding: .twoDimensional,
            instruction: "DRAG TO RUN  •  MOTION OPTIONAL",
            swipe: .heading
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
            simulation: HotFuseSimulation(players: context.participants.map(\.player.id), seed: context.seed),
            renderer: HotFuseRenderer(),
            onEvents: onEvents
        )
    }
}

@MainActor
final class HotFuseRenderer: ArcadeRenderer {
    private var tokens: [PlayerID: SKShapeNode] = [:]
    private var shields: [PlayerID: SKShapeNode] = [:]
    private var droneNodes: [Int: SKShapeNode] = [:]
    private var droneGenerations: [Int: Int] = [:]
    private let bomb = SKNode()
    private let bombGlow = SKShapeNode(circleOfRadius: 34)
    private let bombBody = SKShapeNode(circleOfRadius: 18)
    private let bombSpark = SKShapeNode(circleOfRadius: 6)
    private var bombPoint: CGPoint?
    private var blastGeneration = 0
    private var passGeneration = 0
    private let bombRed = SKColor.partyHex(HotFuseSimulation.bombColor)
    private let blastOrange = SKColor(red: 1, green: 0.62, blue: 0.1, alpha: 1)

    func build(in scene: ArcadeScene, simulation: HotFuseSimulation) {
        let field = SKShapeNode(
            rect: ArcadeArena.rect.insetBy(dx: HotFuseSimulation.fieldInset, dy: HotFuseSimulation.fieldInset),
            cornerRadius: 20
        )
        field.fillColor = SKColor(red: 0.08, green: 0.03, blue: 0.07, alpha: 0.55)
        field.strokeColor = bombRed.withAlphaComponent(0.25)
        field.lineWidth = 2
        field.zPosition = 0
        scene.gameLayer.addChild(field)

        for bumper in HotFuseSimulation.bumpers {
            let radius = CGFloat(HotFuseSimulation.bumperRadius)
            let node = SKShapeNode(circleOfRadius: radius)
            node.position = scene.point(bumper)
            node.fillColor = SKColor(red: 0.14, green: 0.09, blue: 0.2, alpha: 1)
            node.strokeColor = blastOrange
            node.lineWidth = 5
            node.glowWidth = 10
            node.zPosition = 1
            let core = SKShapeNode(circleOfRadius: radius * 0.55)
            core.fillColor = .clear
            core.strokeColor = blastOrange.withAlphaComponent(0.4)
            core.lineWidth = 3
            node.addChild(core)
            scene.gameLayer.addChild(node)
        }

        for drone in simulation.drones {
            let node = SKShapeNode(circleOfRadius: CGFloat(HotFuseSimulation.droneRadius))
            node.fillColor = SKColor(white: 0.55, alpha: 1)
            node.strokeColor = SKColor(white: 0.85, alpha: 1)
            node.lineWidth = 3
            node.glowWidth = 4
            node.zPosition = 3
            let eye = SKShapeNode(circleOfRadius: 8)
            eye.fillColor = SKColor(white: 0.2, alpha: 1)
            eye.strokeColor = .clear
            node.addChild(eye)
            node.position = scene.point(drone.position)
            scene.gameLayer.addChild(node)
            droneNodes[drone.id] = node
            droneGenerations[drone.id] = drone.generation
        }

        for player in simulation.players {
            let token = scene.makeToken(for: player.playerID, radius: CGFloat(HotFuseSimulation.playerRadius))
            token.zPosition = 4
            let shield = SKShapeNode(circleOfRadius: CGFloat(HotFuseSimulation.playerRadius + 12))
            shield.fillColor = SKColor(red: 0.6, green: 0.95, blue: 1, alpha: 0.08)
            shield.strokeColor = SKColor(red: 0.6, green: 0.95, blue: 1, alpha: 0.55)
            shield.lineWidth = 3
            shield.glowWidth = 6
            shield.zPosition = -1
            shield.isHidden = true
            token.addChild(shield)
            scene.gameLayer.addChild(token)
            tokens[player.playerID] = token
            shields[player.playerID] = shield
        }

        bombGlow.fillColor = bombRed.withAlphaComponent(0.3)
        bombGlow.strokeColor = bombRed
        bombGlow.lineWidth = 3
        bombGlow.glowWidth = 16
        bomb.addChild(bombGlow)
        bombBody.fillColor = SKColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)
        bombBody.strokeColor = .white.withAlphaComponent(0.85)
        bombBody.lineWidth = 2
        bomb.addChild(bombBody)
        let fuse = SKShapeNode(rectOf: CGSize(width: 5, height: 12), cornerRadius: 2)
        fuse.fillColor = SKColor(white: 0.75, alpha: 1)
        fuse.strokeColor = .clear
        fuse.position = CGPoint(x: 9, y: 18)
        fuse.zRotation = -.pi / 5
        bomb.addChild(fuse)
        bombSpark.fillColor = SKColor(red: 1, green: 0.85, blue: 0.3, alpha: 1)
        bombSpark.strokeColor = .white
        bombSpark.glowWidth = 6
        bombSpark.position = CGPoint(x: 14, y: 25)
        bomb.addChild(bombSpark)
        bomb.zPosition = 8
        bomb.isHidden = true
        scene.gameLayer.addChild(bomb)

        if simulation.isDrill {
            let caption = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
            caption.text = "\(HotFuseSimulation.drillBanner)  •  TAG A DRONE TO RESET THE FUSE"
            caption.fontSize = 26
            caption.fontColor = SKColor(white: 0.85, alpha: 0.8)
            caption.position = CGPoint(x: ArcadeArena.center.x, y: Double(ArcadeArena.rect.maxY) + 22)
            caption.zPosition = 6
            scene.gameLayer.addChild(caption)
        }
    }

    func render(_ simulation: HotFuseSimulation, events: [ArcadeEvent], in scene: ArcadeScene) {
        let flicker = Int(simulation.elapsed * 14).isMultiple(of: 2)
        for player in simulation.players {
            guard let token = tokens[player.playerID] else { continue }
            token.position = scene.point(player.position)
            token.isHidden = !player.alive
            shields[player.playerID]?.isHidden = !(player.alive && player.isImmune)
            shields[player.playerID]?.alpha = flicker ? 0.7 : 1
        }

        for drone in simulation.drones {
            guard let node = droneNodes[drone.id] else { continue }
            if droneGenerations[drone.id] != drone.generation {
                droneGenerations[drone.id] = drone.generation
                node.removeAllActions()
                node.setScale(0.2)
                node.run(.scale(to: 1, duration: 0.25))
            }
            node.position = scene.point(drone.position)
        }

        renderBomb(simulation, in: scene)

        if let pass = simulation.lastPass, pass.generation != passGeneration {
            passGeneration = pass.generation
            ring(at: scene.point(pass.position), radius: 26, color: bombRed, scale: 3, duration: 0.25, in: scene)
        }
        if let blast = simulation.lastBlast, blast.generation != blastGeneration {
            blastGeneration = blast.generation
            explode(at: scene.point(blast.position), in: scene)
        }
    }

    private func renderBomb(_ simulation: HotFuseSimulation, in scene: ArcadeScene) {
        guard !simulation.isFinished,
              let carrier = simulation.carrier,
              let holder = simulation.player(for: carrier),
              holder.alive else {
            bomb.isHidden = true
            bombPoint = nil
            return
        }
        // Perch on top of the token so its mark stays readable; hop quickly on a pass.
        let target = scene.point(holder.position + ArcadeVector(x: 0, y: HotFuseSimulation.playerRadius + 4))
        let current = bombPoint ?? target
        let point = CGPoint(x: current.x + ((target.x - current.x) * 0.45), y: current.y + ((target.y - current.y) * 0.45))
        bombPoint = point
        bomb.isHidden = false
        bomb.position = point

        // Pulse speed comes from the elapsed fraction, never the exact time left.
        let wave = 0.5 + (0.5 * sin(simulation.pulsePhase))
        let urgency = simulation.fuseProgress
        bomb.setScale(CGFloat(1 + (0.14 * wave)))
        bombGlow.alpha = CGFloat(0.35 + (0.6 * wave))
        bombGlow.setScale(CGFloat(1 + ((0.25 + (0.35 * urgency)) * wave)))
        bombSpark.alpha = Int(simulation.elapsed * 20).isMultiple(of: 2) ? 1 : 0.5
    }

    private func explode(at point: CGPoint, in scene: ArcadeScene) {
        let flash = SKShapeNode(circleOfRadius: 60)
        flash.position = point
        flash.fillColor = SKColor(red: 1, green: 0.92, blue: 0.7, alpha: 0.95)
        flash.strokeColor = .clear
        flash.zPosition = 9
        scene.gameLayer.addChild(flash)
        flash.run(.sequence([.group([.scale(to: 5, duration: 0.4), .fadeOut(withDuration: 0.4)]), .removeFromParent()]))

        ring(at: point, radius: 40, color: bombRed, scale: 9, duration: 0.6, in: scene)
        ring(at: point, radius: 34, color: blastOrange, scale: 7, duration: 0.5, delay: 0.08, in: scene)

        let scorch = SKShapeNode(circleOfRadius: 70)
        scorch.position = point
        scorch.fillColor = SKColor(white: 0, alpha: 0.45)
        scorch.strokeColor = bombRed.withAlphaComponent(0.35)
        scorch.lineWidth = 2
        scorch.zPosition = 0.5
        scene.gameLayer.addChild(scorch)
        scorch.run(.sequence([.wait(forDuration: 1.2), .fadeOut(withDuration: 0.6), .removeFromParent()]))

        let shake = SKAction.sequence([
            .moveBy(x: 14, y: -8, duration: 0.03),
            .moveBy(x: -24, y: 14, duration: 0.04),
            .moveBy(x: 18, y: -12, duration: 0.04),
            .moveBy(x: -8, y: 6, duration: 0.04),
        ])
        scene.gameLayer.removeAction(forKey: "hot-fuse.shake")
        scene.gameLayer.position = .zero
        scene.gameLayer.run(.sequence([shake, .move(to: .zero, duration: 0.02)]), withKey: "hot-fuse.shake")
    }

    private func ring(
        at point: CGPoint,
        radius: CGFloat,
        color: SKColor,
        scale: CGFloat,
        duration: Double,
        delay: Double = 0,
        in scene: ArcadeScene
    ) {
        let ring = SKShapeNode(circleOfRadius: radius)
        ring.position = point
        ring.strokeColor = color
        ring.fillColor = .clear
        ring.lineWidth = 8
        ring.glowWidth = 14
        ring.zPosition = 9
        ring.alpha = delay > 0 ? 0 : 1
        scene.gameLayer.addChild(ring)
        ring.run(.sequence([
            .wait(forDuration: delay),
            .fadeIn(withDuration: 0),
            .group([.scale(to: scale, duration: duration), .fadeOut(withDuration: duration)]),
            .removeFromParent(),
        ]))
    }
}
