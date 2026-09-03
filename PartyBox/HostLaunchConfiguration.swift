import Foundation

struct HostLaunchConfiguration {
    let isUITesting: Bool
    let scenario: String?
    let disableAnimations: Bool
    let disableEffects: Bool
    let seed: UInt64
    let hostName: String?
    let botCount: Int

    static var current: Self { Self(arguments: ProcessInfo.processInfo.arguments) }

    init(arguments: [String]) {
#if DEBUG
        isUITesting = arguments.contains("--ui-testing")
        scenario = Self.option("--scenario", in: arguments)
        disableAnimations = arguments.contains("--disable-animations")
        disableEffects = arguments.contains("--disable-effects")
        seed = UInt64(Self.option("--seed", in: arguments) ?? "5782994480227372888") ?? 5782994480227372888
        hostName = Self.option("--host-name", in: arguments)
        botCount = min(max(Int(Self.option("--bot-count", in: arguments) ?? "0") ?? 0, 0), 8)
#else
        isUITesting = false
        scenario = nil
        disableAnimations = false
        disableEffects = false
        seed = 5782994480227372888
        hostName = nil
        botCount = 0
#endif
    }

    nonisolated private static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
