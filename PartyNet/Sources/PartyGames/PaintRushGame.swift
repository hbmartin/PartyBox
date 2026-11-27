import PartyBoxCore
import PartyGameRuntime
import PartyNet
import SpriteKit

@MainActor
struct PaintRushGame: PartyGame {
    let descriptor = GameDescriptor(
        id: "paint-rush",
        title: "PAINT RUSH",
        summary: "1–8 players  •  Claim the most floor in 45 seconds",
        minimumPlayers: 1,
        maximumPlayers: 8,
        estimatedDurationSeconds: 50,
        supportsMotion: true
    )

    static let controls: [ScreenComponent] = [
        .text(.init(id: "paint.rule", text: "PAINT THE FLOOR • STEAL THEIR COLOR", style: .caption, tint: .secondary)),
        .axisSurface(.init(
            id: "paint.steer",
            binding: .twoDimensional,
            instruction: "DRAG TO MOVE  •  MOTION OPTIONAL",
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
            simulation: PaintRushSimulation(players: context.participants.map(\.player.id), seed: context.seed),
            renderer: PaintRushRenderer(),
            onEvents: onEvents
        )
    }
}

@MainActor
final class PaintRushRenderer: ArcadeRenderer {
    private static let tileGap: CGFloat = 2
    /// Live stacked share bar, below the arena border and inside the scene.
    private static let barRect = CGRect(
        x: PaintRushSimulation.origin.x,
        y: 60,
        width: PaintRushSimulation.boardSize.x,
        height: 32
    )

    private let neutralColor = SKColor(red: 0.07, green: 0.1, blue: 0.2, alpha: 1)
    private let calmFrameColor = SKColor(red: 0.25, green: 0.9, blue: 1, alpha: 0.5)
    private let tileLayer = SKNode()
    private let powerUpLayer = SKNode()
    private let boardFrame = SKShapeNode(rect: CGRect(
        x: PaintRushSimulation.origin.x,
        y: PaintRushSimulation.origin.y,
        width: PaintRushSimulation.boardSize.x,
        height: PaintRushSimulation.boardSize.y
    ))
    private var tileSprites: [SKSpriteNode] = []
    /// Owner each tile sprite currently shows, diffed against the simulation.
    private var shownOwners: [Int8] = []
    private var paintColors: [SKColor] = []
    private var pucks: [PlayerID: SKShapeNode] = [:]
    private var boostRings: [PlayerID: SKShapeNode] = [:]
    private var brushRings: [PlayerID: SKShapeNode] = [:]
    private var powerUpNodes: [Int: SKNode] = [:]
    private var powerUpKinds: [Int: PaintRushSimulation.PowerUpKind] = [:]
    private var barSegments: [SKSpriteNode] = []
    private var barLabels: [SKLabelNode] = []
    private var shownCounts: [Int] = []
    private var frenzyShown = false

    func build(in scene: ArcadeScene, simulation: PaintRushSimulation) {
        let board = SKSpriteNode(
            color: SKColor(red: 0.02, green: 0.03, blue: 0.08, alpha: 1),
            size: CGSize(width: PaintRushSimulation.boardSize.x, height: PaintRushSimulation.boardSize.y)
        )
        board.position = scene.point(ArcadeArena.center)
        board.zPosition = 0
        scene.gameLayer.addChild(board)

        tileLayer.zPosition = 1
        scene.gameLayer.addChild(tileLayer)
        let side = CGFloat(PaintRushSimulation.tileSize) - Self.tileGap
        tileSprites.reserveCapacity(PaintRushSimulation.tileCount)
        for tile in 0..<PaintRushSimulation.tileCount {
            let sprite = SKSpriteNode(color: neutralColor, size: CGSize(width: side, height: side))
            sprite.position = scene.point(PaintRushSimulation.tileCenter(tile))
            tileLayer.addChild(sprite)
            tileSprites.append(sprite)
        }
        shownOwners = Array(repeating: -1, count: PaintRushSimulation.tileCount)
        paintColors = simulation.pucks.map { scene.color(for: $0.playerID).withAlphaComponent(0.78) }

        boardFrame.strokeColor = calmFrameColor
        boardFrame.fillColor = .clear
        boardFrame.lineWidth = 3
        boardFrame.glowWidth = 6
        boardFrame.zPosition = 2
        scene.gameLayer.addChild(boardFrame)

        powerUpLayer.zPosition = 3
        scene.gameLayer.addChild(powerUpLayer)

        for puck in simulation.pucks {
            let token = scene.makeToken(for: puck.playerID, radius: CGFloat(PaintRushSimulation.puckRadius))
            token.zPosition = 5
            scene.gameLayer.addChild(token)
            pucks[puck.playerID] = token

            let brush = SKShapeNode(circleOfRadius: CGFloat(PaintRushSimulation.brushRadius * PaintRushSimulation.frenzyBrushMultiplier))
            brush.strokeColor = scene.color(for: puck.playerID).withAlphaComponent(0.7)
            brush.fillColor = scene.color(for: puck.playerID).withAlphaComponent(0.12)
            brush.lineWidth = 3
            brush.zPosition = -1
            brush.isHidden = true
            token.addChild(brush)
            brushRings[puck.playerID] = brush

            let boost = SKShapeNode(circleOfRadius: CGFloat(PaintRushSimulation.puckRadius) + 9)
            boost.strokeColor = .partyHex(PaintRushSimulation.boostColor)
            boost.fillColor = .clear
            boost.lineWidth = 4
            boost.glowWidth = 8
            boost.zPosition = 2
            boost.isHidden = true
            boost.run(.repeatForever(.sequence([.scale(to: 1.15, duration: 0.15), .scale(to: 1, duration: 0.15)])))
            token.addChild(boost)
            boostRings[puck.playerID] = boost
        }

        buildBar(in: scene, simulation: simulation)
    }

    func render(_ simulation: PaintRushSimulation, events: [ArcadeEvent], in scene: ArcadeScene) {
        syncTiles(simulation)

        if simulation.isFrenzy != frenzyShown {
            frenzyShown = simulation.isFrenzy
            boardFrame.strokeColor = frenzyShown ? .partyHex(PaintRushSimulation.frenzyColor) : calmFrameColor
            boardFrame.glowWidth = frenzyShown ? 14 : 6
        }

        for puck in simulation.pucks {
            guard let token = pucks[puck.playerID] else { continue }
            token.position = scene.point(puck.position)
            token.alpha = puck.active ? 1 : 0.25
            boostRings[puck.playerID]?.isHidden = !(puck.active && puck.isBoosted)
            brushRings[puck.playerID]?.isHidden = !(puck.active && frenzyShown)
        }

        syncPowerUps(simulation, in: scene)

        if simulation.tileCounts != shownCounts {
            shownCounts = simulation.tileCounts
            layoutBar(counts: shownCounts)
        }

        for case let .cue(playerID, _, _) in events {
            pucks[playerID]?.run(.sequence([.scale(to: 1.35, duration: 0.08), .scale(to: 1, duration: 0.2)]))
        }
    }

    // MARK: Tiles

    private func syncTiles(_ simulation: PaintRushSimulation) {
        let owners = simulation.owners
        for tile in owners.indices where owners[tile] != shownOwners[tile] {
            let owner = Int(owners[tile])
            shownOwners[tile] = owners[tile]
            tileSprites[tile].color = paintColors.indices.contains(owner) ? paintColors[owner] : neutralColor
        }
    }

    // MARK: Power-ups

    private func syncPowerUps(_ simulation: PaintRushSimulation, in scene: ArcadeScene) {
        var live: Set<Int> = []
        for powerUp in simulation.powerUps {
            live.insert(powerUp.id)
            guard powerUpNodes[powerUp.id] == nil else { continue }
            let node = makePowerUpNode(powerUp, in: scene)
            powerUpLayer.addChild(node)
            powerUpNodes[powerUp.id] = node
            powerUpKinds[powerUp.id] = powerUp.kind
        }
        for (id, node) in powerUpNodes where !live.contains(id) {
            powerUpNodes.removeValue(forKey: id)
            let kind = powerUpKinds.removeValue(forKey: id) ?? .boost
            burst(at: node.position, kind: kind, in: scene)
            node.removeFromParent()
        }
    }

    private func makePowerUpNode(_ powerUp: PaintRushSimulation.PowerUp, in scene: ArcadeScene) -> SKNode {
        let container = SKNode()
        container.position = scene.point(powerUp.position)
        let color = SKColor.partyHex(powerUp.kind.colorHex)
        let radius = CGFloat(PaintRushSimulation.powerUpRadius)

        let shape: SKShapeNode
        switch powerUp.kind {
        case .boost:
            shape = SKShapeNode(rectOf: CGSize(width: radius * 1.5, height: radius * 1.5), cornerRadius: 5)
            shape.zRotation = .pi / 4
        case .splat:
            shape = SKShapeNode(circleOfRadius: radius)
        }
        shape.fillColor = color
        shape.strokeColor = .white
        shape.lineWidth = 3
        shape.glowWidth = 10
        shape.run(.repeatForever(.sequence([.scale(to: 1.15, duration: 0.35), .scale(to: 1, duration: 0.35)])))
        container.addChild(shape)

        let glyph = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        glyph.text = powerUp.kind == .boost ? "B" : "S"
        glyph.fontSize = 24
        glyph.fontColor = .black.withAlphaComponent(0.85)
        glyph.verticalAlignmentMode = .center
        glyph.horizontalAlignmentMode = .center
        glyph.zPosition = 1
        container.addChild(glyph)

        let caption = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        caption.text = powerUp.kind.label
        caption.fontSize = 15
        caption.fontColor = color
        caption.verticalAlignmentMode = .center
        caption.horizontalAlignmentMode = .center
        caption.position = CGPoint(x: 0, y: -radius - 16)
        caption.zPosition = 1
        container.addChild(caption)

        container.setScale(0.2)
        container.run(.scale(to: 1, duration: 0.2))
        return container
    }

    private func burst(at position: CGPoint, kind: PaintRushSimulation.PowerUpKind, in scene: ArcadeScene) {
        let ring = SKShapeNode(circleOfRadius: CGFloat(PaintRushSimulation.powerUpRadius))
        ring.position = position
        ring.strokeColor = .partyHex(kind.colorHex)
        ring.fillColor = .clear
        ring.lineWidth = 5
        ring.glowWidth = 10
        ring.zPosition = 6
        scene.gameLayer.addChild(ring)
        let reach = kind == .splat
            ? (Double(PaintRushSimulation.splatRadiusTiles) + 0.5) * PaintRushSimulation.tileSize
            : PaintRushSimulation.puckRadius * 2.5
        let scale = CGFloat(reach / PaintRushSimulation.powerUpRadius)
        ring.run(.sequence([.group([.scale(to: scale, duration: 0.35), .fadeOut(withDuration: 0.35)]), .removeFromParent()]))
    }

    // MARK: Share bar

    private func buildBar(in scene: ArcadeScene, simulation: PaintRushSimulation) {
        let rect = Self.barRect
        let track = SKSpriteNode(color: neutralColor, size: rect.size)
        track.anchorPoint = CGPoint(x: 0, y: 0.5)
        track.position = CGPoint(x: rect.minX, y: rect.midY)
        track.zPosition = 6
        scene.gameLayer.addChild(track)

        let outline = SKShapeNode(rect: rect.insetBy(dx: -3, dy: -3), cornerRadius: 6)
        outline.strokeColor = calmFrameColor
        outline.fillColor = .clear
        outline.lineWidth = 2
        outline.zPosition = 8
        scene.gameLayer.addChild(outline)

        for puck in simulation.pucks {
            let segment = SKSpriteNode(color: scene.color(for: puck.playerID), size: CGSize(width: 0, height: rect.height))
            segment.anchorPoint = CGPoint(x: 0, y: 0.5)
            segment.position = CGPoint(x: rect.minX, y: rect.midY)
            segment.zPosition = 7
            scene.gameLayer.addChild(segment)
            barSegments.append(segment)

            let label = SKLabelNode(fontNamed: "AvenirNext-Heavy")
            label.fontSize = 20
            label.fontColor = .black.withAlphaComponent(0.85)
            label.verticalAlignmentMode = .center
            label.horizontalAlignmentMode = .center
            label.zPosition = 9
            label.isHidden = true
            scene.gameLayer.addChild(label)
            barLabels.append(label)
        }
        shownCounts = simulation.tileCounts
        layoutBar(counts: shownCounts)
    }

    private func layoutBar(counts: [Int]) {
        let rect = Self.barRect
        let total = CGFloat(PaintRushSimulation.tileCount)
        var x = rect.minX
        for (index, count) in counts.enumerated() where barSegments.indices.contains(index) {
            let width = rect.width * CGFloat(count) / total
            barSegments[index].position = CGPoint(x: x, y: rect.midY)
            barSegments[index].size = CGSize(width: width, height: rect.height)
            let label = barLabels[index]
            let text = "\(PaintRushSimulation.percent(count))%"
            if label.text != text { label.text = text }
            label.isHidden = width < 60
            label.position = CGPoint(x: x + (width / 2), y: rect.midY)
            x += width
        }
    }

    var tileSpriteCountForTesting: Int { tileSprites.count }
    var shownOwnersForTesting: [Int8] { shownOwners }
    var barWidthsForTesting: [CGFloat] { barSegments.map(\.size.width) }

    func tileColorForTesting(_ tile: Int) -> SKColor { tileSprites[tile].color }
}
