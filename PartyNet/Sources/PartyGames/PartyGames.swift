import PartyGameRuntime

@MainActor
public enum PartyGames {
    public static func all() -> [any PartyGame] {
        [PongGame(), SnakePitGame(), LastLightGame(), BumperBrawlGame(), PaintRushGame(), SkyHopGame(), HotFuseGame(), TurboLoopGame()]
    }
}
