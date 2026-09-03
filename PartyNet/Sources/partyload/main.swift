import Darwin
import Foundation
import PartyNet

private struct LoadConfiguration {
    var count = PartyNetConstants.maximumControllers
    var frequency = 60
    var seconds = 30
    var address: String?
    var hostName: String?

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            if option == "--help" || option == "-h" { throw LoadError.help }
            guard index + 1 < arguments.count else { throw LoadError.missingValue(option) }
            let value = arguments[index + 1]
            switch option {
            case "--count": count = Int(value) ?? 0
            case "--hz": frequency = Int(value) ?? 0
            case "--seconds": seconds = Int(value) ?? 0
            case "--address": address = value
            case "--host": hostName = value
            default: throw LoadError.unknownOption(option)
            }
            index += 2
        }
        let (_, runLengthOverflows) = seconds.multipliedReportingOverflow(by: frequency)
        guard (1...PartyNetConstants.maximumControllers).contains(count),
              (1...240).contains(frequency),
              seconds > 0,
              !runLengthOverflows else {
            throw LoadError.invalidNumbers
        }
        guard address != nil || hostName != nil else { throw LoadError.missingHost }
    }
}

private enum LoadError: Error, LocalizedError {
    case help
    case missingValue(String)
    case unknownOption(String)
    case invalidNumbers
    case missingHost
    case discoveryTimeout(String)
    case invalidAddress
    case connectionFailed(Int, String)
    case unexpectedDisconnect(Int, String)

    var errorDescription: String? {
        switch self {
        case .help: Self.usage
        case let .missingValue(option): "Missing value for \(option).\n\n\(Self.usage)"
        case let .unknownOption(option): "Unknown option \(option).\n\n\(Self.usage)"
        case .invalidNumbers:
            "Count must be 1–\(PartyNetConstants.maximumControllers), Hz 1–240, and the run length must be representable."
        case .missingHost: "Provide either --address HOST:PORT or --host BONJOUR-NAME.\n\n\(Self.usage)"
        case let .discoveryTimeout(name): "Could not discover a compatible host named “\(name)” within 10 seconds."
        case .invalidAddress: "Address must be formatted as HOST:PORT."
        case let .connectionFailed(index, reason): "Controller \(index) failed to connect: \(reason)"
        case let .unexpectedDisconnect(index, reason): "Controller \(index) disconnected during the run: \(reason)"
        }
    }

    static let usage = """
    partyload --address HOST:PORT [--count \(PartyNetConstants.maximumControllers)] [--hz 60] [--seconds 30]
    partyload --host BONJOUR-NAME [--count \(PartyNetConstants.maximumControllers)] [--hz 60] [--seconds 30]
    """
}

@main
private struct PartyLoad {
    @MainActor
    static func main() async {
        do {
            let configuration = try LoadConfiguration(arguments: Array(CommandLine.arguments.dropFirst()))
            try await run(configuration)
        } catch let error as LoadError {
            print(error.localizedDescription)
            if case .help = error { return }
            exit(EXIT_FAILURE)
        } catch {
            print("partyload failed: \(error.localizedDescription)")
            exit(EXIT_FAILURE)
        }
    }

    @MainActor
    private static func run(_ configuration: LoadConfiguration) async throws {
        let interval = Duration.nanoseconds(Int64(1_000_000_000 / configuration.frequency))
        let clients = (1...configuration.count).map {
            PartyClient(
                controllerID: loadControllerID(index: $0),
                displayName: "Load \($0)",
                inputSendInterval: interval
            )
        }

        if let address = configuration.address {
            guard let endpoint = HostAddress(parsing: address) else { throw LoadError.invalidAddress }
            for (index, client) in clients.enumerated() {
                await client.connect(host: endpoint.host, port: endpoint.port)
                try requireConnected(client, index: index + 1)
            }
            print("Connected \(clients.count) controllers to \(endpoint.host):\(endpoint.port)")
        } else if let requestedName = configuration.hostName {
            let probe = clients[0]
            await probe.startBrowsing()
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(10))
            var discovered: DiscoveredHost?
            while clock.now < deadline {
                discovered = probe.hosts.first {
                    $0.isCompatible && $0.name.localizedCaseInsensitiveCompare(requestedName) == .orderedSame
                }
                if discovered != nil { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            guard let discovered else { throw LoadError.discoveryTimeout(requestedName) }
            await probe.connect(to: discovered)
            try requireConnected(probe, index: 1)
            for (index, client) in clients.dropFirst().enumerated() {
                await client.connect(to: discovered)
                try requireConnected(client, index: index + 2)
            }
            print("Connected \(clients.count) controllers to \(discovered.name)")
        }

        let totalTicks = configuration.seconds * configuration.frequency
        var rttSamples: [Double] = []
        var lastRTTSampleCounts = clients.map(\.rttSampleCount)
        let startingInputCounts = clients.map(\.inputFramesSent)
        let clock = ContinuousClock()
        let started = clock.now
        for tick in 0..<totalTicks {
            let elapsed = Double(tick) / Double(configuration.frequency)
            for (index, client) in clients.enumerated() {
                let phase = (Double(index) / Double(max(1, clients.count))) * 2 * Double.pi
                client.setInput(axisX: Float(sin((elapsed * 2.1) + phase)))
                if client.rttSampleCount != lastRTTSampleCounts[index], let rtt = client.rttMilliseconds {
                    rttSamples.append(rtt)
                    lastRTTSampleCounts[index] = client.rttSampleCount
                }
                try requireConnected(client, index: index + 1, duringRun: true)
            }
            let target = started.advanced(by: interval * (tick + 1))
            try await clock.sleep(until: target)
        }

        // Allow the clients' coalescing input loops to flush the final requested frame.
        try await clock.sleep(for: interval * 2)
        for (index, client) in clients.enumerated() {
            try requireConnected(client, index: index + 1, duringRun: true)
        }

        let inputSendCounts = zip(clients, startingInputCounts).map { client, startingCount in
            client.inputFramesSent - startingCount
        }
        for client in clients { await client.disconnect() }
        let sorted = rttSamples.sorted()
        let p50 = percentile(0.50, values: sorted)
        let p95 = percentile(0.95, values: sorted)
        let maximum = sorted.last ?? 0
        let minimumSends = inputSendCounts.min() ?? 0
        let maximumSends = inputSendCounts.max() ?? 0
        print("Issued \(totalTicks) requested input updates per controller at \(configuration.frequency) Hz for \(configuration.seconds)s")
        print("Observed transport sends per controller: \(minimumSends)–\(maximumSends)")
        print(String(format: "Ping RTT: p50 %.2f ms  p95 %.2f ms  max %.2f ms  (%d samples)", p50, p95, maximum, sorted.count))
        if sorted.isEmpty {
            print("Warning: run was too short to collect a ping sample (pings begin after two seconds).")
        } else if p95 >= 50 {
            print("FAIL: p95 RTT is above the 50 ms acceptance target.")
            exit(EXIT_FAILURE)
        } else {
            print("PASS: no unexpected disconnects; p95 RTT is below 50 ms.")
        }
    }

    @MainActor
    private static func requireConnected(_ client: PartyClient, index: Int, duringRun: Bool = false) throws {
        guard case .connected = client.state else {
            let reason: String
            switch client.state {
            case let .rejected(message), let .disconnected(message), let .reconnecting(message): reason = message
            case let .connecting(name), let .connected(name): reason = name
            case .browsing: reason = "not connected"
            }
            if duringRun { throw LoadError.unexpectedDisconnect(index, reason) }
            throw LoadError.connectionFailed(index, reason)
        }
    }

    private static func loadControllerID(index: Int) -> ControllerID {
        let value = String(format: "50415254-5942-4F58-8000-%012X", index)
        // `count` is validated above, so the fixed-width UUID is guaranteed to parse.
        return ControllerID(rawValue: UUID(uuidString: value)!)
    }

    private static func percentile(_ fraction: Double, values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let index = min(values.count - 1, Int(ceil(fraction * Double(values.count))) - 1)
        return values[max(0, index)]
    }
}
