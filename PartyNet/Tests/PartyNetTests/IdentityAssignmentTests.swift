import Foundation
import Dependencies
import Testing
@testable import PartyNet

@Suite("Host-owned player identity")
@MainActor
struct IdentityAssignmentTests {
    @Test func marksAreUniqueHumansDisplaceBotsAndBotKindIsTrusted() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let host = PartyHost(reconnectGrace: .milliseconds(100))
            let port = try await host.start(hostName: "Identity Test", advertise: false)
            let botID = ControllerID()
            host.registerLocalBot(controllerID: botID)
            let bot = PartyClient(controllerID: botID, displayName: "Bot 1", preferredMark: .circle)
            await bot.connect(host: "127.0.0.1", port: port)

            let humanID = ControllerID()
            let human = PartyClient(controllerID: humanID, displayName: "Ada", preferredMark: .circle)
            await human.connect(host: "127.0.0.1", port: port)

            let untrusted = PartyClient(displayName: "Remote Bot", preferredMark: .star)
            await untrusted.connect(host: "127.0.0.1", port: port)
            let contested = PartyClient(displayName: "Grace", preferredMark: .circle)
            await contested.connect(host: "127.0.0.1", port: port)
            try await waitUntil { host.players.count == 4 }

            let humanPlayer = try #require(host.players.first { host.controllerID(for: $0.id) == humanID })
            let botPlayer = try #require(host.players.first { host.controllerID(for: $0.id) == botID })
            let untrustedPlayer = try #require(host.players.first { $0.displayName == "Remote Bot" })
            let fallbackPlayer = try #require(host.players.first { $0.displayName == "Grace" })
            #expect(humanPlayer.mark == .circle)
            #expect(botPlayer.mark == .square)
            #expect(fallbackPlayer.mark == .diamond)
            #expect(Set(host.players.map(\.mark)).count == host.players.count)
            #expect(botPlayer.kind == .bot)
            #expect(humanPlayer.kind == .human)
            #expect(untrustedPlayer.kind == .human)
            #expect(!host.assignMark(.circle, to: untrustedPlayer.id))

            let replacement = PartyClient(
                controllerID: humanID,
                displayName: "Ada Reconnected",
                preferredMark: .ring
            )
            await replacement.connect(host: "127.0.0.1", port: port)
            try await waitUntil {
                host.players.first { host.controllerID(for: $0.id) == humanID }?.displayName == "Ada Reconnected"
            }
            #expect(host.players.first { host.controllerID(for: $0.id) == humanID }?.mark == .circle)

            await replacement.stop()
            await human.stop()
            await contested.stop()
            await untrusted.stop()
            await bot.stop()
            await host.stop()
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition())
    }
}
