import Foundation
import Network
import PartyNet
import PartyNetTestSupport

private typealias FaultServerProtocol = Coder<FaultControlResponse, FaultControlRequest, NetworkJSONCoder>
private typealias FaultClientProtocol = Coder<FaultControlRequest, FaultControlResponse, NetworkJSONCoder>

private func faultServerStack() -> FaultServerProtocol {
    Coder(sending: FaultControlResponse.self, receiving: FaultControlRequest.self, using: .json) {
        TCP().noDelay(true).connectionTimeout(5)
    }
}

private func faultClientStack() -> FaultClientProtocol {
    Coder(sending: FaultControlRequest.self, receiving: FaultControlResponse.self, using: .json) {
        TCP().noDelay(true).connectionTimeout(5)
    }
}

private actor FaultControlServer {
    private let rig: FaultRig
    private let readyFile: URL
    private var metadata: FaultRigMetadata
    private var listenerTask: Task<Void, Never>?

    init(rig: FaultRig, readyFile: URL, metadata: FaultRigMetadata) {
        self.rig = rig
        self.readyFile = readyFile
        self.metadata = metadata
    }

    func start() async throws -> UInt16 {
        let parameters = NWParametersBuilder.parameters { faultServerStack() }
            .localEndpoint(.hostPort(host: "127.0.0.1", port: .any))
            .localOnly(true)
            .peerToPeerIncluded(false)
        let listener = try NetworkListener<FaultServerProtocol>(for: nil, using: parameters)
        let server = self
        listenerTask = Task { [listener, server] in
            do {
                try await listener.run { connection in
                    await server.handle(connection)
                }
            } catch {}
        }
        do {
            return try await waitForBoundPort(
                of: listener,
                operation: "starting the fault-control listener"
            )
        } catch {
            listenerTask?.cancel()
            listenerTask = nil
            throw error
        }
    }

    func waitUntilStopped() async {
        await listenerTask?.value
    }

    func writeReadyFile(controlPort: UInt16) throws {
        metadata = FaultRigMetadata(
            host: metadata.host,
            tcpPort: metadata.tcpPort,
            udpPort: metadata.udpPort,
            controlPort: controlPort,
            hostInstanceID: metadata.hostInstanceID
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: readyFile, options: .atomic)
    }

    private func handle(_ connection: NetworkConnection<FaultServerProtocol>) async {
        do {
            let request = try await withTimeout(
                .seconds(5),
                timeoutError: { PartyFaultError.timedOut }
            ) {
                try await connection.receive().content
            }
            let response = await execute(request)
            try await withTimeout(
                .seconds(5),
                timeoutError: { PartyFaultError.timedOut }
            ) {
                try await connection.send(response)
            }
        } catch {
            let metrics = await rig.proxy.currentMetrics()
            try? await withTimeout(
                .seconds(5),
                timeoutError: { PartyFaultError.timedOut }
            ) {
                try await connection.send(FaultControlResponse(
                    succeeded: false,
                    message: error.localizedDescription,
                    metrics: metrics
                ))
            }
        }
    }

    private func execute(_ request: FaultControlRequest) async -> FaultControlResponse {
        do {
            let message: String
            switch request {
            case .reset:
                await rig.proxy.reset()
                message = "fault profile and counters reset"
            case let .udp(dropRate, delay, jitter, reorderWindow):
                let current = await rig.proxy.currentProfile()
                let profile = FaultProfile(
                    seed: current.seed,
                    udpDropPolicy: .rate(dropRate),
                    delayMilliseconds: delay,
                    jitterMilliseconds: jitter,
                    reorderWindow: reorderWindow
                )
                await rig.proxy.setProfile(profile)
                message = "UDP fault profile updated"
            case .cutTCP:
                await rig.proxy.cutTCP()
                message = "TCP sessions cut"
            case .restartHost:
                let restarted = try await rig.restartHost()
                metadata = FaultRigMetadata(
                    host: restarted.host,
                    tcpPort: restarted.tcpPort,
                    udpPort: restarted.udpPort,
                    controlPort: metadata.controlPort,
                    hostInstanceID: restarted.hostInstanceID
                )
                if let controlPort = metadata.controlPort { try writeReadyFile(controlPort: controlPort) }
                message = "upstream host restarted"
            case .metrics:
                message = "current metrics"
            }
            return FaultControlResponse(
                succeeded: true,
                message: message,
                metadata: metadata,
                profile: await rig.proxy.currentProfile(),
                metrics: await rig.proxy.currentMetrics()
            )
        } catch {
            return FaultControlResponse(
                succeeded: false,
                message: error.localizedDescription,
                metadata: metadata,
                profile: await rig.proxy.currentProfile(),
                metrics: await rig.proxy.currentMetrics()
            )
        }
    }

}

private enum PartyFaultError: Error, LocalizedError, Sendable {
    case usage(String)
    case invalidAddress
    case timedOut
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case let .usage(message): message
        case .invalidAddress: "Expected an address in HOST:PORT form."
        case .timedOut: "Timed out waiting for a listener."
        case let .commandFailed(message): message
        }
    }
}

@main
enum PartyFaultCommand {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let verb = arguments.first else { throw usageError() }
            switch verb {
            case "serve":
                try await serve(Array(arguments.dropFirst()))
            case "control":
                try await control(Array(arguments.dropFirst()))
            default:
                throw usageError()
            }
        } catch {
            FileHandle.standardError.write(Data("partyfault: \(error.localizedDescription)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    @MainActor
    private static func serve(_ arguments: [String]) async throws {
        guard let readyPath = option("--ready-file", in: arguments) else { throw usageError() }
        let seed: UInt64
        if let value = option("--seed", in: arguments) {
            guard let parsed = UInt64(value) else { throw PartyFaultError.usage("Invalid --seed value: \(value)") }
            seed = parsed
        } else {
            seed = 1
        }
        let rig = FaultRig(profile: FaultProfile(seed: seed))
        let metadata = try await rig.start()
        do {
            let server = FaultControlServer(
                rig: rig,
                readyFile: URL(fileURLWithPath: readyPath),
                metadata: metadata
            )
            let controlPort = try await server.start()
            try await server.writeReadyFile(controlPort: controlPort)
            print("partyfault ready tcp=\(metadata.tcpPort) udp=\(metadata.udpPort) control=\(controlPort)")
            fflush(stdout)
            await server.waitUntilStopped()
        } catch {
            await rig.stop()
            throw error
        }
        await rig.stop()
    }

    private static func control(_ arguments: [String]) async throws {
        guard let address = option("--address", in: arguments),
              let commandIndex = firstCommandIndex(in: arguments) else { throw usageError() }
        guard let endpoint = HostAddress(parsing: address),
              let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw PartyFaultError.invalidAddress
        }
        let command = arguments[commandIndex]
        let trailing = Array(arguments.dropFirst(commandIndex + 1))
        let request: FaultControlRequest
        switch command {
        case "reset":
            request = .reset
        case "udp":
            request = .udp(
                dropRate: try numericOption("--drop", in: trailing, default: 0),
                delayMilliseconds: try numericOption("--delay-ms", in: trailing, default: 0),
                jitterMilliseconds: try numericOption("--jitter-ms", in: trailing, default: 0),
                reorderWindow: try numericOption("--reorder-window", in: trailing, default: 1)
            )
        case "cut-tcp":
            request = .cutTCP
        case "restart-host":
            request = .restartHost
        case "metrics":
            request = .metrics
        default:
            throw usageError()
        }

        let connection = NetworkConnection<FaultClientProtocol>(
            to: .hostPort(host: NWEndpoint.Host(endpoint.host), port: port),
            using: .parameters { faultClientStack() }.peerToPeerIncluded(false)
        )
        let response = try await withTimeout(
            .seconds(5),
            timeoutError: { PartyFaultError.timedOut }
        ) {
            try await connection.send(request)
            return try await connection.receive().content
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(response), as: UTF8.self))
        guard response.succeeded else { throw PartyFaultError.commandFailed(response.message) }
    }

    private static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func firstCommandIndex(in arguments: [String]) -> Int? {
        let commands: Set<String> = ["reset", "udp", "cut-tcp", "restart-host", "metrics"]
        return arguments.firstIndex { commands.contains($0) }
    }

    private static func numericOption<T: LosslessStringConvertible>(
        _ name: String,
        in arguments: [String],
        default defaultValue: T
    ) throws -> T {
        guard let value = option(name, in: arguments) else { return defaultValue }
        guard let parsed = T(value) else {
            throw PartyFaultError.usage("Invalid \(name) value: \(value)")
        }
        return parsed
    }

    private static func usageError() -> PartyFaultError {
        .usage("""
        usage:
          partyfault serve --ready-file PATH [--seed N]
          partyfault control --address HOST:PORT reset
          partyfault control --address HOST:PORT udp [--drop RATE] [--delay-ms N] [--jitter-ms N] [--reorder-window N]
          partyfault control --address HOST:PORT cut-tcp|restart-host|metrics
        """)
    }
}
