import PartyNet
import SwiftUI

struct ContentView: View {
    @Bindable var coordinator: ControllerCoordinator

    var body: some View {
        ZStack {
            ControllerBackdrop()
            Group {
                switch coordinator.client.state {
                case .browsing:
                    HostPickerView(coordinator: coordinator)
                case let .connecting(name):
                    ConnectionView(
                        title: "CONNECTING", detail: name, spinning: true,
                        accessibilityIdentifier: "controller.state.connecting"
                    )
                case let .connected(name):
                    ConnectedControllerView(coordinator: coordinator, hostName: name)
                case let .reconnecting(detail):
                    ConnectionView(
                        title: "RECONNECTING", detail: detail, spinning: true,
                        accessibilityIdentifier: "controller.state.reconnecting"
                    )
                case let .rejected(message):
                    ConnectionErrorView(
                        title: "CAN'T JOIN", detail: message, coordinator: coordinator,
                        accessibilityIdentifier: "controller.state.rejected"
                    )
                case let .disconnected(message):
                    ConnectionErrorView(
                        title: "CONNECTION LOST", detail: friendly(message), coordinator: coordinator,
                        accessibilityIdentifier: "controller.state.disconnected"
                    )
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
        .animation(coordinator.configuration.disableAnimations ? nil : .easeOut(duration: 0.24), value: coordinator.client.state)
        .preferredColorScheme(.dark)
    }

    private func friendly(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("denied") || lower.contains("policy") {
            return "Local Network access is off. Enable it for PartyBox Controller in Settings, then try again."
        }
        return message.isEmpty ? "The host is no longer reachable." : message
    }
}

private struct HostPickerView: View {
    @Bindable var coordinator: ControllerCoordinator
    @FocusState private var editingName: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ControllerWordmark(kicker: "IPHONE CONTROLLER", title: "PARTYBOX")

                VStack(alignment: .leading, spacing: 10) {
                    Text("YOUR NAME").font(.caption.monospaced().weight(.black)).foregroundStyle(.white.opacity(0.55))
                    HStack {
                        TextField("Player", text: $coordinator.displayName)
                            .accessibilityIdentifier("controller.name.field")
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .focused($editingName)
                            .onSubmit { Task { await coordinator.rename() } }
                        Button("SAVE") {
                            editingName = false
                            Task { await coordinator.rename() }
                        }
                        .accessibilityIdentifier("controller.name.save")
                        .font(.caption.monospaced().weight(.black))
                    }
                    .padding(16)
                    .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 16))
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("CHOOSE A HOST")
                            .font(.headline.monospaced().weight(.black))
                            .accessibilityIdentifier("controller.hostPicker")
                        Spacer()
                        ProgressView().tint(ControllerTheme.cyan)
                    }
                    if coordinator.client.hosts.isEmpty {
                        VStack(spacing: 15) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: 42))
                                .foregroundStyle(ControllerTheme.cyan)
                            Text("Looking for PartyBox on your local network…")
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                    } else {
                        ForEach(coordinator.client.hosts) { host in
                            Button {
                                Task { await coordinator.connect(to: host) }
                            } label: {
                                HStack(spacing: 16) {
                                    Image(systemName: "tv")
                                        .font(.title2)
                                        .foregroundStyle(host.isCompatible ? ControllerTheme.cyan : .orange)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(host.name).font(.headline.weight(.bold))
                                        Text(host.isCompatible ? "READY TO JOIN" : "INCOMPATIBLE VERSION")
                                            .font(.caption.monospaced().weight(.bold))
                                            .foregroundStyle(.white.opacity(0.5))
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                }
                                .padding(18)
                                .background(.black.opacity(0.36), in: RoundedRectangle(cornerRadius: 18))
                                .overlay(RoundedRectangle(cornerRadius: 18).stroke(ControllerTheme.cyan.opacity(0.34), lineWidth: 1.5))
                            }
                            .buttonStyle(.plain)
                            .disabled(!host.isCompatible)
                            .accessibilityIdentifier("controller.host.\(host.id)")
                        }
                    }
                }

                if (coordinator.discoveryHelpVisible || coordinator.client.discoveryErrorMessage != nil),
                   coordinator.client.hosts.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(coordinator.client.discoveryErrorMessage == nil ? "NO HOSTS FOUND" : "DISCOVERY ERROR")
                            .font(.headline.monospaced().weight(.black))
                            .foregroundStyle(.orange)
                        Text(discoveryHelpMessage)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                        HStack {
                            Button("TRY AGAIN") {
                                Task { await coordinator.retryDiscovery() }
                            }
                            .buttonStyle(ArcadeButtonStyle(color: ControllerTheme.cyan))
                            Button("OPEN SETTINGS") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                            .buttonStyle(ArcadeButtonStyle(color: .orange))
                        }
                    }
                    .padding(18)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityIdentifier("controller.discovery.help")
                }
            }
            .padding(24)
        }
    }

    private var discoveryHelpMessage: String {
        guard let message = coordinator.client.discoveryErrorMessage else {
            return "Make sure the host is open on the same Wi‑Fi network. If asked, allow Local Network access. You can change that permission in Settings."
        }
        let lower = message.lowercased()
        if lower.contains("denied") || lower.contains("policy") {
            return "Local Network access is off. Enable it for PartyBox Controller in Settings, then try again."
        }
        return message
    }
}

private struct ConnectedControllerView: View {
    @Bindable var coordinator: ControllerCoordinator
    let hostName: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(hostName)
                        .font(.caption.monospaced().weight(.bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .accessibilityIdentifier("controller.state.connected")
                    Text(playerLabel).font(.headline.weight(.black))
                }
                Spacer()
                if let rtt = coordinator.client.rttMilliseconds {
                    Text("\(Int(rtt.rounded())) MS")
                        .font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(rtt < 50 ? ControllerTheme.lime : .orange)
                }
                Button {
                    Task { await coordinator.returnToPicker() }
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 10)

            switch coordinator.client.layout {
            case .lobby:
                LobbyControllerView(coordinator: coordinator)
            case let .menu(items, selected):
                MenuControllerView(items: items, selected: selected, coordinator: coordinator)
            case let .paddle(layout):
                PaddleControllerView(layout: layout, coordinator: coordinator)
            case let .spectator(layout):
                SpectatorControllerView(layout: layout)
            case let .gameOver(title, subtitle):
                GameOverControllerView(title: title, subtitle: subtitle, coordinator: coordinator)
            }
        }
    }

    private var playerLabel: String {
        guard let player = coordinator.client.player else { return coordinator.displayName }
        return "P\(player.number)  \(player.displayName)"
    }
}

private struct LobbyControllerView: View {
    @Bindable var coordinator: ControllerCoordinator

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                Spacer(minLength: 20)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(ControllerTheme.lime)
                    .shadow(color: ControllerTheme.lime.opacity(0.6), radius: 18)
                Text("YOU'RE IN")
                    .font(.system(size: 38, weight: .black, design: .rounded))
                    .accessibilityIdentifier("controller.layout.lobby")
                Text("Anyone connected can move the party forward.")
                    .foregroundStyle(.white.opacity(0.64))
                    .multilineTextAlignment(.center)

                RosterView(players: coordinator.client.roster)

                Button("OPEN GAME MENU") { Task { await coordinator.client.sendMenu(.select) } }
                    .buttonStyle(ArcadeButtonStyle(color: ControllerTheme.magenta))
                    .accessibilityIdentifier("controller.lobby.openMenu")
            }
            .padding(24)
        }
    }
}

private struct MenuControllerView: View {
    let items: [String]
    let selected: Int
    @Bindable var coordinator: ControllerCoordinator

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Text("GAME SELECT")
                .font(.caption.monospaced().weight(.black))
                .foregroundStyle(ControllerTheme.cyan)
                .accessibilityIdentifier("controller.layout.menu")
            Text(items.indices.contains(selected) ? items[selected] : "PARTYBOX")
                .font(.system(size: 34, weight: .black, design: .rounded))
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                MenuPadButton(symbol: "chevron.up", action: .up, coordinator: coordinator)
                    .accessibilityIdentifier("controller.menu.up")
                MenuPadButton(symbol: "chevron.down", action: .down, coordinator: coordinator)
                    .accessibilityIdentifier("controller.menu.down")
            }
            Button("SELECT") { Task { await coordinator.client.sendMenu(.select) } }
                .buttonStyle(ArcadeButtonStyle(color: ControllerTheme.magenta))
                .accessibilityIdentifier("controller.menu.select")
            Button("BACK") { Task { await coordinator.client.sendMenu(.back) } }
                .buttonStyle(ArcadeButtonStyle(color: .white.opacity(0.35)))
                .accessibilityIdentifier("controller.menu.back")
            Spacer()
        }
        .padding(24)
    }
}

private struct MenuPadButton: View {
    let symbol: String
    let action: MenuAction
    @Bindable var coordinator: ControllerCoordinator

    var body: some View {
        Button { Task { await coordinator.client.sendMenu(action) } } label: {
            Image(systemName: symbol).font(.title.weight(.black)).frame(width: 70, height: 62)
        }
        .buttonStyle(ArcadeButtonStyle(color: ControllerTheme.cyan))
    }
}

private struct PaddleControllerView: View {
    let layout: PaddleLayout
    @Bindable var coordinator: ControllerCoordinator
    @State private var localAxis: Float = 0

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text(layout.label)
                .font(.title2.weight(.black))
                .foregroundStyle(Color.controllerHex(layout.colorHex))
                .accessibilityIdentifier("controller.layout.paddle.\(layout.edge.rawValue)")
            Text(edgeInstruction)
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(.white.opacity(0.56))

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14)).frame(height: 10)
                    Capsule()
                        .fill(Color.controllerHex(layout.colorHex))
                        .frame(width: 72, height: 150)
                        .shadow(color: Color.controllerHex(layout.colorHex), radius: 22)
                        .offset(x: ((CGFloat(localAxis) + 1) * 0.5 * (width - 72)))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let axis = Float(min(max((value.location.x / width) * 2 - 1, -1), 1))
                    localAxis = axis
                    coordinator.client.setInput(axisX: axis)
                })
                .accessibilityIdentifier("controller.paddle.track")
            }
            .frame(height: 170)
            .padding(.horizontal, 4)

            Text("DRAG ANYWHERE ON THE TRACK")
                .font(.caption.monospaced().weight(.black))
                .foregroundStyle(.white.opacity(0.45))
            Text(String(format: "%.3f", localAxis))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
                .accessibilityIdentifier("controller.paddle.value")
            Spacer()
        }
        .padding(.horizontal, 16)
        .onAppear { coordinator.client.setInput(axisX: localAxis) }
    }

    private var edgeInstruction: String {
        switch layout.edge {
        case .bottom, .top: "LEFT  ←  PADDLE  →  RIGHT"
        case .left, .right: "BOTTOM  ←  PADDLE  →  TOP"
        }
    }
}

private struct SpectatorControllerView: View {
    let layout: SpectatorLayout

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "person.3.sequence.fill").font(.system(size: 62)).foregroundStyle(ControllerTheme.cyan)
            Text("SPECTATING")
                .font(.system(size: 36, weight: .black, design: .rounded))
                .accessibilityIdentifier("controller.layout.spectator")
            Text("#\(layout.queuePosition) IN QUEUE").font(.title2.monospaced().weight(.black)).foregroundStyle(ControllerTheme.lime)
                .accessibilityIdentifier("controller.spectator.position")
            Text(layout.message).foregroundStyle(.white.opacity(0.62)).multilineTextAlignment(.center)
            Spacer()
        }
        .padding(30)
    }
}

private struct GameOverControllerView: View {
    let title: String
    let subtitle: String
    @Bindable var coordinator: ControllerCoordinator

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Text(title)
                .font(.system(size: 36, weight: .black, design: .rounded))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("controller.layout.gameOver")
            Text(subtitle).foregroundStyle(.white.opacity(0.62)).multilineTextAlignment(.center)
            Button("NEXT MATCH") { Task { await coordinator.client.sendMenu(.select) } }
                .buttonStyle(ArcadeButtonStyle(color: ControllerTheme.lime))
                .accessibilityIdentifier("controller.gameOver.next")
            Button("GAME MENU") { Task { await coordinator.client.sendMenu(.back) } }
                .buttonStyle(ArcadeButtonStyle(color: .white.opacity(0.35)))
                .accessibilityIdentifier("controller.gameOver.menu")
            Spacer()
        }
        .padding(24)
    }
}

private struct RosterView: View {
    let players: [PlayerInfo]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(players) { player in
                HStack {
                    Circle().fill(Color.controllerHex(player.colorHex)).frame(width: 12, height: 12)
                    Text("P\(player.number)").font(.caption.monospaced().weight(.black))
                    Text(player.displayName).font(.subheadline.weight(.bold)).lineLimit(1)
                    Spacer()
                    Text(player.isConnected ? "READY" : "RECONNECTING")
                        .font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(player.isConnected ? ControllerTheme.lime : .orange)
                }
                .padding(12)
                .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("controller.roster.player.\(player.number)")
            }
        }
    }
}

private struct ConnectionView: View {
    let title: String
    let detail: String
    let spinning: Bool
    let accessibilityIdentifier: String

    var body: some View {
        VStack(spacing: 22) {
            if spinning { ProgressView().controlSize(.large).tint(ControllerTheme.cyan) }
            Text(title)
                .font(.system(size: 34, weight: .black, design: .rounded))
                .accessibilityIdentifier(accessibilityIdentifier)
            Text(detail).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center)
        }
        .padding(30)
    }
}

private struct ConnectionErrorView: View {
    let title: String
    let detail: String
    @Bindable var coordinator: ControllerCoordinator
    let accessibilityIdentifier: String

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 58)).foregroundStyle(.orange)
            Text(title)
                .font(.system(size: 34, weight: .black, design: .rounded))
                .accessibilityIdentifier(accessibilityIdentifier)
            Text(detail).foregroundStyle(.white.opacity(0.68)).multilineTextAlignment(.center)
                .accessibilityIdentifier("controller.error.message")
            Button("BACK TO HOST PICKER") { Task { await coordinator.returnToPicker() } }
                .buttonStyle(ArcadeButtonStyle(color: ControllerTheme.cyan))
                .accessibilityIdentifier("controller.error.back")
        }
        .padding(30)
    }
}

private struct ControllerWordmark: View {
    let kicker: String
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kicker).font(.caption.monospaced().weight(.black)).foregroundStyle(ControllerTheme.cyan)
            Text(title).font(.system(size: 44, weight: .black, design: .rounded)).tracking(2).shadow(color: ControllerTheme.magenta, radius: 14)
        }
    }
}

private struct ControllerBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [Color(red: 0.01, green: 0.02, blue: 0.08), Color(red: 0.12, green: 0.015, blue: 0.14)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(RadialGradient(colors: [ControllerTheme.cyan.opacity(0.14), .clear], center: .topTrailing, startRadius: 20, endRadius: 500))
        .ignoresSafeArea()
    }
}

private struct ArcadeButtonStyle: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.monospaced().weight(.black))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(color.opacity(configuration.isPressed ? 0.45 : 0.78), in: RoundedRectangle(cornerRadius: 16))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

private enum ControllerTheme {
    static let cyan = Color.controllerHex(ArcadePalette.cyan)
    static let magenta = Color.controllerHex(ArcadePalette.magenta)
    static let lime = Color.controllerHex(ArcadePalette.lime)
}

private extension Color {
    static func controllerHex(_ value: String) -> Color {
        guard let rgb = ArcadePalette.rgb(value) else { return .white }
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
