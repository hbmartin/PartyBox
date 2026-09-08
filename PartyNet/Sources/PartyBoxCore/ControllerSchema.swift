import Foundation

public struct RequestedInputs: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let orientation = RequestedInputs(rawValue: 1 << 0)
}

public enum ScreenTextStyle: String, Codable, Sendable {
    case title, headline, body, caption
}

public enum ScreenTint: String, Codable, Sendable {
    case accent, secondary, success, warning, plain
}

public struct TextComponent: Codable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let style: ScreenTextStyle
    public let tint: ScreenTint

    public init(id: String, text: String, style: ScreenTextStyle, tint: ScreenTint = .plain) {
        self.id = id
        self.text = text
        self.style = style
        self.tint = tint
    }
}

public struct StatusComponent: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let value: String

    public init(id: String, label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

public enum AxisBinding: String, Codable, Sendable {
    case horizontal, twoDimensional
}

public struct AxisSurfaceComponent: Codable, Equatable, Sendable {
    public let id: String
    public let binding: AxisBinding
    public let instruction: String

    public init(id: String, binding: AxisBinding, instruction: String) {
        self.id = id
        self.binding = binding
        self.instruction = instruction
    }
}

public enum ActionRoute: Codable, Equatable, Sendable {
    case game(String)
    case spectatorVote
    case spectatorReaction
}

public struct ActionButtonComponent: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let route: ActionRoute

    public init(id: String, label: String, route: ActionRoute) {
        self.id = id
        self.label = label
        self.route = route
    }
}

public struct ChoiceItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String?
    public let tally: Int?

    public init(id: String, title: String, detail: String? = nil, tally: Int? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.tally = tally
    }
}

public struct ChoiceGroupComponent: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let choices: [ChoiceItem]
    public let selection: String?
    public let route: ActionRoute

    public init(id: String, title: String, choices: [ChoiceItem], selection: String?, route: ActionRoute) {
        self.id = id
        self.title = title
        self.choices = choices
        self.selection = selection
        self.route = route
    }
}

public struct EmojiPaletteComponent: Codable, Equatable, Sendable {
    public let id: String
    public let emojis: [String]
    public let cooldownMilliseconds: Int

    public init(id: String, emojis: [String], cooldownMilliseconds: Int = 1_000) {
        self.id = id
        self.emojis = emojis
        self.cooldownMilliseconds = cooldownMilliseconds
    }
}

public enum ScreenComponent: Codable, Equatable, Sendable {
    case text(TextComponent)
    case status(StatusComponent)
    case axisSurface(AxisSurfaceComponent)
    case actionButton(ActionButtonComponent)
    case choiceGroup(ChoiceGroupComponent)
    case emojiPalette(EmojiPaletteComponent)
}

public struct ControllerScreen: Codable, Equatable, Sendable {
    public static let schemaVersion: UInt16 = 1

    public let accessibilityID: String
    public let accentColorHex: String
    public let requestedInputs: RequestedInputs
    public let components: [ScreenComponent]

    public init(
        accessibilityID: String,
        accentColorHex: String,
        requestedInputs: RequestedInputs = [],
        components: [ScreenComponent]
    ) {
        self.accessibilityID = accessibilityID
        self.accentColorHex = accentColorHex
        self.requestedInputs = requestedInputs
        self.components = components
    }

    public var isValid: Bool {
        guard accessibilityID.count <= 80,
              accentColorHex.count == 7,
              accentColorHex.hasPrefix("#"),
              accentColorHex.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit }),
              components.count <= 32 else { return false }
        var ids = Set<String>()
        for component in components {
            let id: String = switch component {
            case .text(let value): value.id
            case .status(let value): value.id
            case .axisSurface(let value): value.id
            case .actionButton(let value): value.id
            case .choiceGroup(let value): value.id
            case .emojiPalette(let value): value.id
            }
            guard !id.isEmpty, id.count <= 80, ids.insert(id).inserted else { return false }
        }
        return true
    }
}

public enum ControllerActionValue: Codable, Equatable, Sendable {
    case trigger
    case choice(String)
}

public struct ControllerAction: Codable, Equatable, Sendable {
    public let id: String
    public let value: ControllerActionValue

    public init(id: String, value: ControllerActionValue) {
        self.id = id
        self.value = value
    }
}
