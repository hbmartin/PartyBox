import Foundation

public enum PaddleEdge: String, Codable, CaseIterable, Hashable, Sendable {
    case bottom
    case top
    case left
    case right
}

public struct PaddleLayout: Codable, Equatable, Sendable {
    public let edge: PaddleEdge
    public let colorHex: String
    public let label: String

    public init(edge: PaddleEdge, colorHex: String, label: String) {
        self.edge = edge
        self.colorHex = colorHex
        self.label = label
    }
}

public struct SpectatorLayout: Codable, Equatable, Sendable {
    public let queuePosition: Int
    public let message: String

    public init(queuePosition: Int, message: String = "Winner stays — you're in the queue") {
        self.queuePosition = queuePosition
        self.message = message
    }
}

public enum ControllerLayout: Codable, Equatable, Sendable {
    case lobby
    case menu(items: [String], selected: Int)
    case paddle(PaddleLayout)
    case spectator(SpectatorLayout)
    case gameOver(title: String, subtitle: String)
}
