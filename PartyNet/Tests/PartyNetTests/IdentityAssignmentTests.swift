import Foundation
import Dependencies
import Testing
@testable import PartyNet

@Suite("Host-owned player identity")
@MainActor
struct IdentityAssignmentTests {
    private actor WelcomeFailure {
        private var welcomeCount = 0

        func shouldFail() -> Bool {
            welcomeCount += 1
            return welcomeCount == 2
        }
    }

    private actor WelcomeGate {
        private let blockedWelcome: Int
        private var welcomeCount = 0
        private(set) var isBlocking = false
        private var continuation: CheckedContinuation<Void, Never>?

        init(blockedWelcome: Int) {
            self.blockedWelcome = blockedWelcome
        }

        func pauseIfNeeded() async {
            welcomeCount += 1
            guard welcomeCount == blockedWelcome else { return }
            isBlocking = true
            await withCheckedContinuation { continuation = $0 }
        }

        func resume() {
            continuation?.resume()
            continuation = nil
            isBlocking = false
        }
    }

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

    @Test func trustedBotIdentitySurvivesExpirationUntilExplicitlyUnregistered() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let host = PartyHost(reconnectGrace: .milliseconds(50))
            let port = try await host.start(hostName: "Bot Trust Test", advertise: false)
            let botID = ControllerID()
            host.registerLocalBot(controllerID: botID)
            let first = PartyClient(controllerID: botID, displayName: "Bot 1")
            await first.connect(host: "127.0.0.1", port: port)
            try await waitUntil { host.players.first?.kind == .bot }

            await first.stop()
            try await waitUntil { host.players.isEmpty }

            let replacement = PartyClient(controllerID: botID, displayName: "Bot 1 Again")
            await replacement.connect(host: "127.0.0.1", port: port)
            try await waitUntil { host.players.first?.displayName == "Bot 1 Again" }
            #expect(host.players.first?.kind == .bot)

            await replacement.stop()
            host.unregisterLocalBot(controllerID: botID)
            await host.stop()
        }
    }

    @Test func failedHumanHandshakeDoesNotDisplaceAnExistingBotsMark() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let failure = WelcomeFailure()
            let host = PartyHost(transportFactory: { inputs in
                HostTransport(
                    inputs: inputs,
                    controlSender: { connection, message in
                        if case .welcome = message, await failure.shouldFail() {
                            throw CancellationError()
                        }
                        try await connection.send(message)
                    }
                )
            })
            let port = try await host.start(hostName: "Mark Rollback Test", advertise: false)
            let botID = ControllerID()
            host.registerLocalBot(controllerID: botID)
            let bot = PartyClient(controllerID: botID, displayName: "Bot", preferredMark: .circle)
            await bot.connect(host: "127.0.0.1", port: port)
            try await waitUntil { host.players.first?.mark == .circle }

            let human = PartyClient(displayName: "Human", preferredMark: .circle)
            await human.connect(host: "127.0.0.1", port: port)
            try await waitUntil { host.players.count == 1 }

            #expect(host.players.first?.kind == .bot)
            #expect(host.players.first?.mark == .circle)

            await human.stop()
            await bot.stop()
            await host.stop()
        }
    }

    @Test func pendingHumanDisplacementReservesTheBotsCurrentMark() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
        } operation: {
            let gate = WelcomeGate(blockedWelcome: 3)
            let host = PartyHost(transportFactory: { inputs in
                HostTransport(
                    inputs: inputs,
                    controlSender: { connection, message in
                        if case .welcome = message { await gate.pauseIfNeeded() }
                        try await connection.send(message)
                    }
                )
            })
            let port = try await host.start(hostName: "Mark Reservation Test", advertise: false)
            let botID = ControllerID()
            let selectorID = ControllerID()
            host.registerLocalBot(controllerID: botID)
            let bot = PartyClient(controllerID: botID, displayName: "Bot", preferredMark: .circle)
            let selector = PartyClient(
                controllerID: selectorID,
                displayName: "Selector",
                preferredMark: .star
            )
            let entrant = PartyClient(displayName: "Entrant", preferredMark: .circle)
            var entrantConnection: Task<Void, Never>?

            do {
                await bot.connect(host: "127.0.0.1", port: port)
                await selector.connect(host: "127.0.0.1", port: port)
                try await waitUntil { host.players.count == 2 }
                entrantConnection = Task {
                    await entrant.connect(host: "127.0.0.1", port: port)
                }
                try await waitUntilAsync { await gate.isBlocking }

                let selectorPlayer = try #require(
                    host.players.first { host.controllerID(for: $0.id) == selectorID }
                )
                #expect(!host.assignMark(.circle, to: selectorPlayer.id))

                await gate.resume()
                await entrantConnection?.value
                try await waitUntil { host.players.count == 3 }
                #expect(Set(host.players.map(\.mark)).count == host.players.count)

                await entrant.stop()
                await selector.stop()
                await bot.stop()
                await host.stop()
            } catch {
                await gate.resume()
                await entrantConnection?.value
                await entrant.stop()
                await selector.stop()
                await bot.stop()
                await host.stop()
                throw error
            }
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

    private func waitUntilAsync(
        timeout: Duration = .seconds(3),
        condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(await condition())
    }
}
