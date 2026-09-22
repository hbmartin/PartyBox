import PartyGameRuntime

@MainActor
public enum PartyGames {
    public static func all() -> [any PartyGame] {
        [PongGame(), SignalSnapGame(), GravityGrabGame(), SnakePitGame(), LastLightGame()]
    }
}
