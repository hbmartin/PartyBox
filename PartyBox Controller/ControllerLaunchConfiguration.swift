import Foundation

struct ControllerLaunchConfiguration {
    struct HostAddress {
        let host: String
        let port: UInt16
    }

    let isUITesting: Bool
    let scenario: String?
    let disableAnimations: Bool
    let disableEffects: Bool
    let seed: UInt64
    let controllerID: UUID?
    let displayName: String?
    let hostAddress: HostAddress?
    let defaultsSuite: String?

    static var current: Self { Self(arguments: ProcessInfo.processInfo.arguments) }

    init(arguments: [String]) {
#if DEBUG
        isUITesting = arguments.contains("--ui-testing")
        scenario = Self.option("--scenario", in: arguments)
        disableAnimations = arguments.contains("--disable-animations")
        disableEffects = arguments.contains("--disable-effects")
        seed = UInt64(Self.option("--seed", in: arguments) ?? "1") ?? 1
        controllerID = Self.option("--controller-id", in: arguments).flatMap(UUID.init(uuidString:))
        displayName = Self.option("--display-name", in: arguments)
        defaultsSuite = Self.option("--defaults-suite", in: arguments)
        hostAddress = Self.option("--host", in: arguments).flatMap(Self.parseHost)
#else
        isUITesting = false
        scenario = nil
        disableAnimations = false
        disableEffects = false
        seed = 1
        controllerID = nil
        displayName = nil
        defaultsSuite = nil
        hostAddress = nil
#endif
    }

    nonisolated private static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    nonisolated private static func parseHost(_ value: String) -> HostAddress? {
        guard let separator = value.lastIndex(of: ":"),
              let port = UInt16(value[value.index(after: separator)...]), port != 0 else { return nil }
        return HostAddress(host: String(value[..<separator]), port: port)
    }
}
