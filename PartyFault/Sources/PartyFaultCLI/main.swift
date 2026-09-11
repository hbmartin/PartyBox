import Foundation
import Network
import OSLog
import PartyFault

private typealias ControlServerProtocol = Coder<ControlResponse, ControlRequest, NetworkJSONCoder>
private typealias ControlClientProtocol = Coder<ControlRequest, ControlResponse, NetworkJSONCoder>

private actor ControlServer {
    private let proxy: GenericFaultProxy
    private let port: NWEndpoint.Port
    private let logger = Logger(subsystem: "PartyFault", category: "ControlServer")
    private var task: Task<Void, Error>?
    private var listenerFailureDescription: String?

    init(proxy: GenericFaultProxy, port: UInt16) throws {
        guard let port = NWEndpoint.Port(rawValue: port) else { throw PartyFaultError.invalidPort }
        self.proxy = proxy
        self.port = port
    }

    func start() async throws -> UInt16 {
        let stack = Coder(sending: ControlResponse.self, receiving: ControlRequest.self, using: .json) {
            TCP().noDelay(true).connectionTimeout(5)
        }
        let parameters = NWParametersBuilder.parameters { stack }
            .localEndpoint(.hostPort(host: "127.0.0.1", port: port))
            .localOnly(true)
            .peerToPeerIncluded(false)
        let listener = try NetworkListener<ControlServerProtocol>(for: nil, using: parameters)
        task = Task { [listener] in
            do {
                try await listener.run { await self.handle($0) }
            } catch where Task.isCancelled {
                throw CancellationError()
            } catch {
                self.recordListenerFailure(error)
                throw error
            }
        }
        do {
            return try await PartyFaultNetworkSupport.waitForBoundPort(listener) {
                await self.listenerFailureDescription
            }
        } catch {
            task?.cancel()
            throw error
        }
    }

    func wait() async throws { try await task?.value }

    private func recordListenerFailure(_ error: any Error) {
        let description = error.localizedDescription
        listenerFailureDescription = listenerFailureDescription ?? description
        logger.error("Control listener failed: \(description, privacy: .public)")
    }

    private func handle(_ connection: NetworkConnection<ControlServerProtocol>) async {
        do {
            let request = try await connection.receive().content
            let message: String
            switch request {
            case .profile(let value):
                await proxy.setProfile(value)
                message = "profile updated"
            case .metrics:
                message = "current metrics"
            case .resetMetrics:
                await proxy.resetMetrics()
                message = "metrics reset"
            case .cutConnections:
                await proxy.cutConnections()
                message = "connections cut"
            }
            try await connection.send(ControlResponse(
                succeeded: true,
                message: message,
                profile: await proxy.currentProfile(),
                metrics: await proxy.currentMetrics()
            ))
        } catch {
            try? await connection.send(ControlResponse(
                succeeded: false,
                message: error.localizedDescription,
                profile: await proxy.currentProfile(),
                metrics: await proxy.currentMetrics()
            ))
        }
    }
}

private enum CLIError: LocalizedError {
    case usage
    case invalidAddress
    case invalidProfile

    var errorDescription: String? {
        switch self {
        case .usage: Self.help
        case .invalidAddress: "Expected HOST:PORT."
        case .invalidProfile: "The profile file did not contain a valid PartyFault FaultProfile."
        }
    }

    static let help = """
    usage:
      partyfault serve --upstream-host HOST --tcp PORT --udp PORT [--bind HOST] [--control PORT]
      partyfault control HOST:PORT metrics|reset|cut
      partyfault control HOST:PORT profile PROFILE.json
    """
}

@main
private enum PartyFaultCommand {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            switch arguments.first {
            case "serve": try await serve(Array(arguments.dropFirst()))
            case "control": try await control(Array(arguments.dropFirst()))
            default: throw CLIError.usage
            }
        } catch {
            FileHandle.standardError.write(Data("partyfault: \(error.localizedDescription)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func serve(_ arguments: [String]) async throws {
        let upstreamHost = option("--upstream-host", in: arguments) ?? "127.0.0.1"
        let bindHost = option("--bind", in: arguments) ?? "127.0.0.1"
        guard let tcp = option("--tcp", in: arguments).flatMap(UInt16.init),
              let udp = option("--udp", in: arguments).flatMap(UInt16.init) else { throw CLIError.usage }
        let control = option("--control", in: arguments).flatMap(UInt16.init) ?? 9_900
        let proxy = GenericFaultProxy()
        let endpoints = try await proxy.start(
            upstreamHost: upstreamHost,
            upstreamTCPPort: tcp,
            upstreamUDPPort: udp,
            bindHost: bindHost
        )
        let server = try ControlServer(proxy: proxy, port: control)
        let controlPort = try await server.start()
        let metadata = ProxyEndpoints(
            host: bindHost,
            tcpPort: endpoints.tcp,
            udpPort: endpoints.udp,
            controlHost: "127.0.0.1",
            controlPort: controlPort
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(metadata))
        FileHandle.standardOutput.write(Data("\n".utf8))
        try await server.wait()
    }

    private static func control(_ arguments: [String]) async throws {
        guard arguments.count >= 2 else { throw CLIError.usage }
        let endpoint = try parseAddress(arguments[0])
        let request: ControlRequest
        switch arguments[1] {
        case "metrics": request = .metrics
        case "reset": request = .resetMetrics
        case "cut": request = .cutConnections
        case "profile":
            guard arguments.count == 3,
                  let data = FileManager.default.contents(atPath: arguments[2]),
                  let value = try? JSONDecoder().decode(FaultProfile.self, from: data) else { throw CLIError.invalidProfile }
            request = .profile(value)
        default: throw CLIError.usage
        }
        let stack = Coder(sending: ControlRequest.self, receiving: ControlResponse.self, using: .json) {
            TCP().noDelay(true).connectionTimeout(5)
        }
        let connection = NetworkConnection<ControlClientProtocol>(
            to: .hostPort(host: NWEndpoint.Host(endpoint.host), port: endpoint.port),
            using: .parameters { stack }.peerToPeerIncluded(false)
        )
        try await connection.send(request)
        let response = try await connection.receive().content
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(response))
        FileHandle.standardOutput.write(Data("\n".utf8))
        if !response.succeeded { Foundation.exit(EXIT_FAILURE) }
    }

    private static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func parseAddress(_ value: String) throws -> (host: String, port: NWEndpoint.Port) {
        guard let separator = value.lastIndex(of: ":"),
              let portValue = UInt16(value[value.index(after: separator)...]),
              let port = NWEndpoint.Port(rawValue: portValue) else { throw CLIError.invalidAddress }
        let host = String(value[..<separator])
        guard !host.isEmpty else { throw CLIError.invalidAddress }
        return (host, port)
    }
}
