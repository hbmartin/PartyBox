import PartyBoxCore
import PartyGameRuntime
import PartyNet
import SpriteKit

@MainActor
struct TurboLoopGame: PartyGame {
    let descriptor = GameDescriptor(
        id: "turbo-loop",
        title: "TURBO LOOP",
        summary: "1–8 players  •  Five quick laps, first across the line wins",
        minimumPlayers: 1,
        maximumPlayers: 8,
        estimatedDurationSeconds: 60,
        supportsMotion: true
    )

    static let controls: [ScreenComponent] = [
        .text(.init(id: "turbo.rule", text: "FIVE LAPS • HIT THE BOOST PADS", style: .caption, tint: .secondary)),
        .axisSurface(.init(
            id: "turbo.steer",
            binding: .twoDimensional,
            instruction: "POINT WHERE TO DRIVE  •  MOTION OPTIONAL",
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
            simulation: TurboLoopSimulation(players: context.participants.map(\.player.id), seed: context.seed),
            renderer: TurboLoopRenderer(),
            onEvents: onEvents
        )
    }
}

@MainActor
final class TurboLoopRenderer: ArcadeRenderer {
    private struct CarNodes {
        let root: SKNode
        let chassis: SKNode
        let flame: SKSpriteNode
        let wrongWay: SKLabelNode
        let flag: SKNode
    }

    private var carNodes: [PlayerID: CarNodes] = [:]
    private var lastDust: [PlayerID: Double] = [:]
    private let dustLayer = SKNode()
    private let asphalt = SKColor(red: 0.16, green: 0.17, blue: 0.22, alpha: 1)
    private let boostOrange = SKColor.partyHex(TurboLoopSimulation.boostColor)

    func build(in scene: ArcadeScene, simulation: TurboLoopSimulation) {
        let track = simulation.track
        let halfWidth = CGFloat(TurboLoopTrack.halfWidth)

        // Infield grass; also covers the shared arena border, which the
        // circuit overhangs.
        let ground = SKShapeNode(rect: CGRect(x: 96, y: 88, width: 1_728, height: 888), cornerRadius: 40)
        ground.fillColor = SKColor(red: 0.04, green: 0.13, blue: 0.08, alpha: 1)
        ground.strokeColor = SKColor(red: 0.25, green: 0.9, blue: 1, alpha: 0.3)
        ground.lineWidth = 3
        ground.zPosition = 0
        scene.gameLayer.addChild(ground)

        let path = CGMutablePath()
        for (index, sample) in track.samples.enumerated() {
            let point = scene.point(sample.position)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()

        let edges = SKShapeNode(path: path)
        edges.strokeColor = SKColor(white: 0.92, alpha: 1)
        edges.lineWidth = (halfWidth * 2) + 10
        edges.lineJoin = .round
        edges.fillColor = .clear
        edges.zPosition = 1
        scene.gameLayer.addChild(edges)

        let road = SKShapeNode(path: path)
        road.strokeColor = asphalt
        road.lineWidth = halfWidth * 2
        road.lineJoin = .round
        road.fillColor = .clear
        road.zPosition = 2
        scene.gameLayer.addChild(road)

        let dashes = SKShapeNode(path: path.copy(dashingWithPhase: 0, lengths: [24, 30]))
        dashes.strokeColor = SKColor(white: 1, alpha: 0.18)
        dashes.lineWidth = 3
        dashes.zPosition = 3
        scene.gameLayer.addChild(dashes)

        buildStartLine(track: track, in: scene)
        for pad in track.pads { buildPad(pad, in: scene) }

        dustLayer.zPosition = 4
        scene.gameLayer.addChild(dustLayer)
        for car in simulation.cars {
            carNodes[car.playerID] = makeCar(car, in: scene)
        }
    }

    func render(_ simulation: TurboLoopSimulation, events: [ArcadeEvent], in scene: ArcadeScene) {
        for car in simulation.cars {
            guard let nodes = carNodes[car.playerID] else { continue }
            nodes.root.isHidden = car.forfeited
            nodes.root.position = scene.point(car.position)
            nodes.chassis.zRotation = CGFloat(car.heading)
            nodes.root.alpha = car.isFinished ? 0.55 : 1
            nodes.flame.isHidden = !car.isBoosting
            nodes.wrongWay.isHidden = !car.isWrongWay
            nodes.flag.isHidden = !car.isFinished
            kickUpDust(for: car, at: simulation.elapsed, in: scene)
        }
        for case let .cue(playerID, colorHex, _) in events where colorHex == TurboLoopSimulation.boostColor {
            carNodes[playerID]?.chassis.run(.sequence([.scale(to: 1.3, duration: 0.06), .scale(to: 1, duration: 0.2)]))
        }
    }

    // MARK: Track furniture

    private func buildStartLine(track: TurboLoopTrack, in scene: ArcadeScene) {
        let line = SKNode()
        let start = track.samples[0]
        line.position = scene.point(start.position)
        line.zRotation = CGFloat(start.tangent.angle)
        line.zPosition = 3
        let columns = 12
        let cell = CGFloat(TurboLoopTrack.halfWidth * 2) / CGFloat(columns)
        for row in 0..<2 {
            for column in 0..<columns {
                let white = (row + column).isMultiple(of: 2)
                let square = SKSpriteNode(
                    color: white ? .white : SKColor(white: 0.05, alpha: 1),
                    size: CGSize(width: cell, height: cell)
                )
                square.position = CGPoint(
                    x: (CGFloat(row) - 0.5) * cell,
                    y: -CGFloat(TurboLoopTrack.halfWidth) + ((CGFloat(column) + 0.5) * cell)
                )
                line.addChild(square)
            }
        }
        scene.gameLayer.addChild(line)
    }

    private func buildPad(_ pad: TurboLoopTrack.BoostPad, in scene: ArcadeScene) {
        let node = SKNode()
        node.position = scene.point(pad.position)
        node.zRotation = CGFloat(pad.heading)
        node.zPosition = 3
        let length = CGFloat(TurboLoopTrack.padHalfLength * 2)
        let width = CGFloat(TurboLoopTrack.padHalfWidth * 2)
        let base = SKShapeNode(rectOf: CGSize(width: length, height: width), cornerRadius: 8)
        base.fillColor = boostOrange.withAlphaComponent(0.28)
        base.strokeColor = boostOrange
        base.lineWidth = 3
        node.addChild(base)

        let chevrons = CGMutablePath()
        for offset in [-20.0, 0, 20] {
            chevrons.move(to: CGPoint(x: offset - 7, y: 17))
            chevrons.addLine(to: CGPoint(x: offset + 7, y: 0))
            chevrons.addLine(to: CGPoint(x: offset - 7, y: -17))
        }
        let arrows = SKShapeNode(path: chevrons)
        arrows.strokeColor = SKColor(red: 1, green: 0.9, blue: 0.3, alpha: 1)
        arrows.lineWidth = 5
        arrows.lineCap = .round
        arrows.lineJoin = .round
        node.addChild(arrows)
        node.run(.repeatForever(.sequence([.fadeAlpha(to: 0.55, duration: 0.35), .fadeAlpha(to: 1, duration: 0.35)])))
        scene.gameLayer.addChild(node)
    }

    // MARK: Cars

    private func makeCar(_ car: TurboLoopSimulation.Car, in scene: ArcadeScene) -> CarNodes {
        let root = SKNode()
        root.zPosition = 10
        scene.gameLayer.addChild(root)

        let chassis = SKNode()
        root.addChild(chassis)
        let outline = SKSpriteNode(color: .white, size: CGSize(width: 48, height: 30))
        chassis.addChild(outline)
        let body = SKSpriteNode(color: scene.color(for: car.playerID), size: CGSize(width: 44, height: 26))
        body.zPosition = 1
        chassis.addChild(body)
        let windshield = SKSpriteNode(color: SKColor(white: 0, alpha: 0.55), size: CGSize(width: 8, height: 18))
        windshield.position = CGPoint(x: 10, y: 0)
        windshield.zPosition = 2
        chassis.addChild(windshield)
        let flame = SKSpriteNode(color: boostOrange, size: CGSize(width: 16, height: 14))
        flame.position = CGPoint(x: -31, y: 0)
        flame.zPosition = -1
        flame.isHidden = true
        flame.run(.repeatForever(.sequence([.scaleX(to: 1.5, duration: 0.05), .scaleX(to: 0.8, duration: 0.05)])))
        chassis.addChild(flame)

        if let info = scene.info(for: car.playerID) {
            let mark = SKLabelNode(fontNamed: "AvenirNext-Heavy")
            mark.text = info.mark.glyph
            mark.fontSize = 17
            mark.fontColor = SKColor(white: 0, alpha: 0.85)
            mark.verticalAlignmentMode = .center
            mark.horizontalAlignmentMode = .center
            mark.zPosition = 3
            root.addChild(mark)
        }

        let wrongWay = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        wrongWay.text = "WRONG WAY"
        wrongWay.fontSize = 22
        wrongWay.fontColor = .partyHex(ArcadeOutcomeBuilder.eliminatedColor)
        wrongWay.verticalAlignmentMode = .center
        wrongWay.position = CGPoint(x: 0, y: 42)
        wrongWay.zPosition = 4
        wrongWay.isHidden = true
        root.addChild(wrongWay)

        let flag = makeFlag()
        flag.position = CGPoint(x: 0, y: 30)
        flag.zPosition = 4
        flag.isHidden = true
        root.addChild(flag)

        return CarNodes(root: root, chassis: chassis, flame: flame, wrongWay: wrongWay, flag: flag)
    }

    /// A small checkered flag on a pole.
    private func makeFlag() -> SKNode {
        let flag = SKNode()
        let pole = SKSpriteNode(color: .white, size: CGSize(width: 3, height: 30))
        pole.position = CGPoint(x: -12, y: 8)
        flag.addChild(pole)
        let cell: CGFloat = 7
        for row in 0..<3 {
            for column in 0..<4 {
                let square = SKSpriteNode(
                    color: (row + column).isMultiple(of: 2) ? .white : .black,
                    size: CGSize(width: cell, height: cell)
                )
                square.position = CGPoint(x: -7 + (CGFloat(column) * cell), y: 9 + (CGFloat(row) * cell))
                flag.addChild(square)
            }
        }
        return flag
    }

    /// Puffs of dust behind cars running on the grass, a few per second.
    private func kickUpDust(for car: TurboLoopSimulation.Car, at time: Double, in scene: ArcadeScene) {
        guard car.isRacing, !car.isOnTrack, car.speed > 90 else { return }
        guard time - (lastDust[car.playerID] ?? -1) >= 0.09 else { return }
        lastDust[car.playerID] = time
        let puff = SKSpriteNode(color: SKColor(red: 0.55, green: 0.45, blue: 0.3, alpha: 0.7), size: CGSize(width: 12, height: 12))
        puff.position = scene.point(car.position - (car.direction * 22))
        puff.zRotation = CGFloat(time * 7)
        dustLayer.addChild(puff)
        puff.run(.sequence([
            .group([.scale(to: 2.2, duration: 0.45), .fadeOut(withDuration: 0.45)]),
            .removeFromParent(),
        ]))
    }
}
