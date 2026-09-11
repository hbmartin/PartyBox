import PartyNet
import PartyBoxCore
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
            if let cue = coordinator.currentDeviceCue {
                Color.controllerHex(cue.colorHex)
                    .opacity(0.42)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .animation(coordinator.configuration.disableAnimations ? nil : .easeOut(duration: 0.24), value: coordinator.client.state)
        .preferredColorScheme(.dark)
    }

    private func friendly(_ message: String) -> String {
        if let help = localNetworkPermissionHelp(for: message) { return help }
        return message.isEmpty ? "The host is no longer reachable." : message
    }
}

private func localNetworkPermissionHelp(for message: String) -> String? {
    let lower = message.lowercased()
    guard lower.contains("denied") || lower.contains("policy") else { return nil }
    return "Local Network access is off. Enable it for PartyBox Controller in Settings, then try again."
}

private struct HostPickerView: View {
    @Bindable var coordinator: ControllerCoordinator
    @FocusState private var editingName: Bool
    @State private var showingHistory = false

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
                        .accessibilityValue("Saved \(coordinator.savedDisplayName)")
                        .font(.caption.monospaced().weight(.black))
                    }
                    .padding(16)
                    .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 16))
                }

                Button("MY HISTORY") { showingHistory = true }
                    .buttonStyle(ArcadeButtonStyle(color: ControllerTheme.magenta))
                    .accessibilityIdentifier("controller.history.open")

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
        .sheet(isPresented: $showingHistory) {
            PersonalHistoryView(coordinator: coordinator) { showingHistory = false }
        }
    }

    private var discoveryHelpMessage: String {
        guard let message = coordinator.client.discoveryErrorMessage else {
            return "Make sure the host is open on the same Wi‑Fi network. If asked, allow Local Network access. You can change that permission in Settings."
        }
        if let help = localNetworkPermissionHelp(for: message) { return help }
        return message
    }
}

private struct ConnectedControllerView: View {
    @Bindable var coordinator: ControllerCoordinator
    let hostName: String
    @State private var showingHistory = false
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(hostName)
                        .font(.caption.monospaced().weight(.bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .accessibilityIdentifier("controller.state.connected")
                    HStack(spacing: 7) {
                        if let player = coordinator.currentPlayer {
                            Image(systemName: player.mark.systemImageName)
                                .foregroundStyle(Color.controllerHex(player.colorHex))
                        }
                        Text(playerLabel).font(.headline.weight(.black))
                    }
                }
                Spacer()
                if let rtt = coordinator.client.rttMilliseconds {
                    Text("\(Int(rtt.rounded())) MS")
                        .font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(rtt < 50 ? ControllerTheme.lime : .orange)
                }
                Button { showingHistory = true } label: {
                    Image(systemName: "clock.arrow.circlepath").font(.title3).foregroundStyle(.white.opacity(0.55))
                }
                .accessibilityIdentifier("controller.history.open")
                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape.fill").font(.title3).foregroundStyle(.white.opacity(0.55))
                }
                .accessibilityIdentifier("controller.settings.open")
                Button {
                    Task { await coordinator.returnToPicker() }
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 10)

            switch coordinator.layout {
            case let .lobby(layout):
                LobbyControllerView(layout: layout, coordinator: coordinator)
            case let .menu(layout):
                MenuControllerView(layout: layout, coordinator: coordinator)
            case let .game(envelope):
                GameControllerView(
                    gameID: envelope.gameID,
                    screen: coordinator.controllerScreen,
                    coordinator: coordinator
                )
            case let .gameOver(layout):
                GameOverControllerView(layout: layout, coordinator: coordinator)
            case .historyNavigation:
                PersonalHistoryView(coordinator: coordinator) {
                    Task { await coordinator.sendMenu(.back) }
                }
            }
        }
        .sheet(isPresented: $showingHistory) {
            PersonalHistoryView(coordinator: coordinator) { showingHistory = false }
        }
        .sheet(isPresented: $showingSettings) {
            ControllerSettingsView(coordinator: coordinator) { showingSettings = false }
        }
    }

    private var playerLabel: String {
        guard let player = coordinator.currentPlayer else { return coordinator.displayName }
        return "\(player.mark.glyph)  P\(player.number)  \(player.displayName)"
    }
}

private struct LobbyControllerView: View {
    let layout: LobbyLayout
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
                Text(layout.isCaptain ? "You’re the party captain." : "The captain controls shared navigation.")
                    .foregroundStyle(.white.opacity(0.64))
                    .multilineTextAlignment(.center)

                MarkPicker(coordinator: coordinator)

                RosterView(players: coordinator.roster, captainID: layout.captainID)

                VStack(spacing: 10) {
                    HStack {
                        Text("BOTS").font(.caption.monospaced().weight(.black))
                        Spacer()
                        Button { Task { await coordinator.setBotFillTarget(layout.botFillTarget - 1) } } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .disabled(!layout.isCaptain || layout.botFillTarget == 0)
                        .accessibilityIdentifier("controller.lobby.bots.decrease")
                        Text("\(layout.activeBotCount) / \(layout.botFillTarget)")
                            .font(.headline.monospaced().weight(.black))
                            .frame(minWidth: 58)
                        Button { Task { await coordinator.setBotFillTarget(layout.botFillTarget + 1) } } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(!layout.isCaptain || layout.botFillTarget >= layout.maximumBotCount)
                        .accessibilityIdentifier("controller.lobby.bots.increase")
                    }
                    Text("DIFFICULTY  \(layout.botDifficulty)")
                        .font(.caption.monospaced().weight(.black))
                        .foregroundStyle(ControllerTheme.cyan)
                        .accessibilityIdentifier("controller.lobby.botDifficulty")
                }
                .padding(16)
                .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 16))

                if layout.isCaptain {
                    Button("OPEN GAME MENU") { Task { await coordinator.sendMenu(.select) } }
                        .buttonStyle(ArcadeButtonStyle(color: ControllerTheme.magenta))
                        .accessibilityIdentifier("controller.lobby.openMenu")
                } else {
                    Text("WAITING FOR CAPTAIN")
                        .font(.headline.monospaced().weight(.black))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(24)
        }
    }
}

private struct MenuControllerView: View {
    let layout: MenuLayout
    @Bindable var coordinator: ControllerCoordinator

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Text(layout.kind == .cupSetup ? "PARTY CUP SETUP" : "GAME SELECT")
                .font(.caption.monospaced().weight(.black))
                .foregroundStyle(ControllerTheme.cyan)
                .accessibilityIdentifier("controller.layout.menu")
            Text(layout.items.indices.contains(layout.selected) ? layout.items[layout.selected] : "PARTYBOX")
                .font(.system(size: 34, weight: .black, design: .rounded))
                .multilineTextAlignment(.center)
            if layout.details.indices.contains(layout.selected) {
                Text(layout.details[layout.selected])
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            ControlStatusView(status: layout.control)
            if layout.control.isCaptain {
                HStack(spacing: 16) {
                    MenuPadButton(symbol: "chevron.up", action: .up, coordinator: coordinator)
                        .accessibilityIdentifier("controller.menu.up")
                    MenuPadButton(symbol: "chevron.down", action: .down, coordinator: coordinator)
                        .accessibilityIdentifier("controller.menu.down")
                }
                Button("SELECT") { Task { await coordinator.sendMenu(.select) } }
                    .buttonStyle(ArcadeButtonStyle(color: ControllerTheme.magenta))
                    .accessibilityIdentifier("controller.menu.select")
                Button("BACK") { Task { await coordinator.sendMenu(.back) } }
                    .buttonStyle(ArcadeButtonStyle(color: .white.opacity(0.35)))
                    .accessibilityIdentifier("controller.menu.back")
            } else if layout.control.canToggleReady {
                Button(layout.control.isReady ? "CANCEL READY" : "READY") {
                    Task { await coordinator.sendMenu(.select) }
                }
                .buttonStyle(ArcadeButtonStyle(color: layout.control.isReady ? .orange : ControllerTheme.lime))
                .accessibilityIdentifier("controller.menu.ready")
            }
            Spacer()
        }
        .padding(24)
    }
}

private struct MenuPadButton: View {
    let symbol: String
    let action: PartyBoxCore.MenuAction
    @Bindable var coordinator: ControllerCoordinator

    var body: some View {
        Button { Task { await coordinator.sendMenu(action) } } label: {
            Image(systemName: symbol).font(.title.weight(.black)).frame(width: 70, height: 62)
        }
        .buttonStyle(ArcadeButtonStyle(color: ControllerTheme.cyan))
    }
}

private struct GameControllerView: View {
    let gameID: String
    let screen: ControllerScreen?
    @Bindable var coordinator: ControllerCoordinator

    var body: some View {
        if let screen {
            ScrollView {
                VStack(spacing: 20) {
                    Spacer(minLength: 12)
                    ForEach(Array(screen.components.enumerated()), id: \.offset) { _, component in
                        ControllerComponentView(
                            component: component,
                            accent: Color.controllerHex(screen.accentColorHex),
                            gameID: gameID,
                            coordinator: coordinator
                        )
                    }
                    Spacer(minLength: 12)
                }
                .padding(20)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(screen.accessibilityID)
            }
        } else {
            ConnectionView(title: "CONTROLLER UNAVAILABLE", detail: "This game sent an unsupported controller layout.", spinning: false, accessibilityIdentifier: "controller.layout.unsupported")
        }
    }
}

private struct ControllerComponentView: View {
    let component: ScreenComponent
    let accent: Color
    let gameID: String
    @Bindable var coordinator: ControllerCoordinator

    var body: some View {
        switch component {
        case .text(let value):
            Text(value.text)
                .font(font(for: value.style))
                .foregroundStyle(color(for: value.tint))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier(value.id)
        case .status(let value):
            HStack {
                Text(value.label).foregroundStyle(.white.opacity(0.55))
                Spacer()
                Text(value.value).fontWeight(.black)
            }
            .font(.subheadline.monospaced())
            .accessibilityIdentifier(value.id)
        case .axisSurface(let value):
            AxisSurface(component: value, accent: accent, coordinator: coordinator)
        case .actionButton(let value):
            Button(value.label) { trigger(value) }
                .buttonStyle(ArcadeButtonStyle(color: accent))
                .accessibilityIdentifier(value.id)
        case .directionPad(let value):
            DirectionPad(component: value, accent: accent, gameID: gameID, coordinator: coordinator)
        case .choiceGroup(let value):
            VStack(spacing: 10) {
                Text(value.title).font(.caption.monospaced().weight(.black)).foregroundStyle(.white.opacity(0.6))
                ForEach(value.choices) { choice in
                    Button { choose(choice.id, route: value.route) } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(choice.title).font(.headline.weight(.black))
                                if let detail = choice.detail { Text(detail).font(.caption).foregroundStyle(.white.opacity(0.6)) }
                            }
                            Spacer()
                            if let tally = choice.tally { Text("\(tally)").font(.title3.monospaced().weight(.black)) }
                            if value.selection == choice.id { Image(systemName: "checkmark.circle.fill") }
                        }
                        .padding(14)
                        .background((value.selection == choice.id ? accent.opacity(0.45) : .black.opacity(0.3)), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("\(value.id).\(choice.id)")
                }
            }
        case .emojiPalette(let value):
            VStack(spacing: 9) {
                Text("SEND A REACTION").font(.caption.monospaced().weight(.black)).foregroundStyle(.white.opacity(0.6))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 10) {
                    ForEach(value.emojis, id: \.self) { emoji in
                        Button(emoji) { Task { await coordinator.sendSpectator(.reaction(emoji)) } }
                            .font(.system(size: 34))
                            .frame(maxWidth: .infinity, minHeight: 58)
                            .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
                            .accessibilityIdentifier("\(value.id).\(emoji)")
                    }
                }
            }
        }
    }

    private func trigger(_ button: ActionButtonComponent) {
        switch button.route {
        case .game(let actionID):
            Task { await coordinator.sendGameAction(id: actionID, value: .trigger, gameID: gameID) }
        case .spectatorVote:
            Task { await coordinator.sendSpectator(.vote(button.id)) }
        case .spectatorReaction:
            Task { await coordinator.sendSpectator(.reaction(button.label)) }
        }
    }

    private func choose(_ choiceID: String, route: ActionRoute) {
        switch route {
        case .game(let actionID):
            Task { await coordinator.sendGameAction(id: actionID, value: .choice(choiceID), gameID: gameID) }
        case .spectatorVote:
            Task { await coordinator.sendSpectator(.vote(choiceID)) }
        case .spectatorReaction:
            Task { await coordinator.sendSpectator(.reaction(choiceID)) }
        }
    }

    private func font(for style: ScreenTextStyle) -> Font {
        switch style {
        case .title: .system(size: 36, weight: .black, design: .rounded)
        case .headline: .title2.weight(.black)
        case .body: .body
        case .caption: .caption.monospaced().weight(.bold)
        }
    }

    private func color(for tint: ScreenTint) -> Color {
        switch tint {
        case .accent: accent
        case .secondary: .white.opacity(0.58)
        case .success: ControllerTheme.lime
        case .warning: .orange
        case .plain: .white
        }
    }
}

private struct DirectionPad: View {
    let component: DirectionPadComponent
    let accent: Color
    let gameID: String
    @Bindable var coordinator: ControllerCoordinator

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Spacer()
                directionButton("arrow.up", label: component.upLabel, value: "up")
                Spacer()
            }
            HStack(spacing: 54) {
                directionButton("arrow.left", label: component.leftLabel, value: "left")
                directionButton("arrow.right", label: component.rightLabel, value: "right")
            }
            HStack {
                Spacer()
                directionButton("arrow.down", label: component.downLabel, value: "down")
                Spacer()
            }
            Text(component.instruction)
                .font(.caption.monospaced().weight(.black))
                .foregroundStyle(.white.opacity(0.55))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(component.id)
    }

    private func directionButton(_ symbol: String, label: String, value: String) -> some View {
        Button {
            Task { await coordinator.sendGameAction(id: component.id, value: .choice(value), gameID: gameID) }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.title2.weight(.black))
                Text(label).font(.caption2.monospaced().weight(.black))
            }
            .frame(width: 82, height: 64)
        }
        .buttonStyle(ArcadeButtonStyle(color: accent))
        .accessibilityIdentifier("\(component.id).\(value)")
    }
}

private struct AxisSurface: View {
    let component: AxisSurfaceComponent
    let accent: Color
    @Bindable var coordinator: ControllerCoordinator

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let height = max(proxy.size.height, 1)
                let knobDiameter = AxisSurfaceGeometry.knobDiameter
                let knobRadius = knobDiameter / 2
                ZStack {
                    RoundedRectangle(cornerRadius: 28).fill(.white.opacity(0.1))
                    ZStack {
                        Circle().fill(accent).frame(width: knobDiameter, height: knobDiameter).shadow(color: accent, radius: 20)
                        if let player = coordinator.currentPlayer {
                            Image(systemName: player.mark.systemImageName)
                                .font(.title2.weight(.black))
                                .foregroundStyle(.black.opacity(0.8))
                        }
                    }
                        .position(
                            x: (CGFloat(coordinator.displayedInputAxisX) + 1) * 0.5 * max(width - knobDiameter, 0) + knobRadius,
                            y: component.binding == .twoDimensional
                                ? (1 - CGFloat(coordinator.client.inputAxisY)) * 0.5 * max(height - knobDiameter, 0) + knobRadius
                                : height / 2
                        )
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let x = AxisSurfaceGeometry.normalizedCoordinate(
                        location: value.location.x,
                        extent: width
                    )
                    let y = component.binding == .twoDimensional
                        ? -AxisSurfaceGeometry.normalizedCoordinate(
                            location: value.location.y,
                            extent: height
                        ) : 0
                    coordinator.client.setInput(axisX: x, axisY: y)
                })
                .accessibilityIdentifier(component.id)
                .accessibilityValue(String(format: "%.3f, %.3f", coordinator.displayedInputAxisX, coordinator.client.inputAxisY))
            }
            .frame(height: component.binding == .twoDimensional ? 250 : 170)
            Text(component.instruction).font(.caption.monospaced().weight(.black)).foregroundStyle(.white.opacity(0.48))
        }
    }
}

enum AxisSurfaceGeometry {
    static let knobDiameter: CGFloat = 70

    static func normalizedCoordinate(
        location: CGFloat,
        extent: CGFloat,
        knobDiameter: CGFloat = AxisSurfaceGeometry.knobDiameter
    ) -> Float {
        let diameter = min(max(knobDiameter, 0), max(extent, 0))
        let travel = max(extent - diameter, 0)
        guard travel > 0 else { return 0 }
        let progress = min(max((location - diameter / 2) / travel, 0), 1)
        return Float((progress * 2) - 1)
    }
}

private struct GameOverControllerView: View {
    let layout: GameOverLayout
    @Bindable var coordinator: ControllerCoordinator

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Text(layout.title)
                .font(.system(size: 36, weight: .black, design: .rounded))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("controller.layout.gameOver")
            Text(layout.subtitle).foregroundStyle(.white.opacity(0.62)).multilineTextAlignment(.center)
            if let difficulty = layout.botDifficultyChange {
                Text(difficulty)
                    .font(.headline.monospaced().weight(.black))
                    .foregroundStyle(ControllerTheme.cyan)
                    .accessibilityIdentifier("controller.gameOver.botDifficulty")
            }
            if let nextUp = layout.nextUp {
                Text("NEXT: \(nextUp)").font(.headline.monospaced().weight(.black)).foregroundStyle(ControllerTheme.cyan)
            }
            ControlStatusView(status: layout.control)
            if layout.control.isCaptain || layout.control.canToggleReady {
                Button(layout.control.isCaptain ? "NEXT MATCH" : (layout.control.isReady ? "CANCEL READY" : "READY")) {
                    Task { await coordinator.sendMenu(.select) }
                }
                    .buttonStyle(ArcadeButtonStyle(color: ControllerTheme.lime))
                    .accessibilityIdentifier("controller.gameOver.next")
            }
            if layout.control.isCaptain {
                Button("GAME MENU") { Task { await coordinator.sendMenu(.back) } }
                    .buttonStyle(ArcadeButtonStyle(color: .white.opacity(0.35)))
                    .accessibilityIdentifier("controller.gameOver.menu")
            }
            Spacer()
        }
        .padding(24)
    }
}

private struct PersonalHistoryView: View {
    @Bindable var coordinator: ControllerCoordinator
    let dismiss: () -> Void
    @State private var confirmingClear = false
    @State private var diagnosticsURL: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 16) {
                        statistic(title: "PARTY", value: coordinator.personalStatistics.played)
                        statistic(title: "PARTY WINS", value: coordinator.personalStatistics.won)
                    }
                    HStack(spacing: 16) {
                        statistic(title: "SOLO", value: coordinator.soloStatistics.played)
                        statistic(title: "SOLO WINS", value: coordinator.soloStatistics.won)
                    }
                    HStack(spacing: 16) {
                        statistic(title: "CUPS", value: coordinator.cupStatistics.played)
                        statistic(title: "TROPHIES", value: coordinator.cupStatistics.won)
                    }
                    Text("Party totals require two humans. Solo totals track one-human bot matches.")
                        .font(.caption).foregroundStyle(.white.opacity(0.55))

                    if let error = coordinator.historyPersistenceError {
                        Label(error, systemImage: "externaldrive.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if coordinator.personalHistory.isEmpty {
                        ContentUnavailableView("No matches yet", systemImage: "trophy", description: Text("Matches played with this phone will appear here."))
                    } else {
                        ForEach(coordinator.personalHistory) { record in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text(record.gameTitle).font(.headline.weight(.black))
                                    Spacer()
                                    Text(record.ownOutcome.rawValue.uppercased())
                                        .font(.caption.monospaced().weight(.black))
                                        .foregroundStyle(record.ownOutcome == .won ? ControllerTheme.lime : .white.opacity(0.6))
                                }
                                Text(record.endedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption.monospaced()).foregroundStyle(.white.opacity(0.5))
                                Text(record.participants.map {
                                    "\($0.displayName)\($0.kind == .bot ? " [BOT]" : "")"
                                }.joined(separator: "  •  "))
                                    .font(.subheadline).foregroundStyle(.white.opacity(0.72))
                                if let modifier = record.modifierTitle {
                                    Text("Modifier: \(modifier)").font(.caption).foregroundStyle(ControllerTheme.cyan)
                                }
                            }
                            .padding(14)
                            .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }

                    if !coordinator.personalCupHistory.isEmpty {
                        Text("PARTY CUP TROPHIES")
                            .font(.headline.monospaced().weight(.black))
                            .foregroundStyle(ControllerTheme.cyan)
                        ForEach(coordinator.personalCupHistory) { record in
                            let cupTitle = record.isChampion ? "PARTY CUP CHAMPION" : "PARTY CUP — #\(record.rank)"
                            HStack {
                                Image(systemName: record.isChampion ? "trophy.fill" : "medal.fill")
                                    .foregroundStyle(record.isChampion ? .yellow : ControllerTheme.cyan)
                                VStack(alignment: .leading) {
                                    Text(cupTitle)
                                        .font(.headline.weight(.black))
                                    Text("\(record.points) points  •  \(record.eventWins) event wins")
                                        .font(.caption.monospaced()).foregroundStyle(.white.opacity(0.6))
                                }
                                Spacer()
                            }
                            .padding(14)
                            .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }

                    Button("CLEAR MY HISTORY", role: .destructive) { confirmingClear = true }
                        .buttonStyle(ArcadeButtonStyle(color: .red))
                    if let diagnosticsURL {
                        ShareLink("SHARE REDACTED DIAGNOSTICS", item: diagnosticsURL)
                            .buttonStyle(ArcadeButtonStyle(color: ControllerTheme.cyan))
                    } else {
                        Button("PREPARE REDACTED DIAGNOSTICS") {
                            diagnosticsURL = coordinator.makeRedactedDiagnosticsFile()
                        }
                        .buttonStyle(ArcadeButtonStyle(color: ControllerTheme.cyan))
                    }
                }
                .padding(20)
            }
            .background(ControllerBackdrop())
            .navigationTitle("My PartyBox History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("DONE", action: dismiss) }
            }
            .confirmationDialog("Clear this phone's complete match history?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear History", role: .destructive) { Task { await coordinator.clearPersonalHistory() } }
                Button("Cancel", role: .cancel) {}
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("controller.layout.history")
    }

    private func statistic(title: String, value: Int) -> some View {
        VStack(spacing: 5) {
            Text("\(value)").font(.system(size: 34, weight: .black, design: .rounded))
            Text(title).font(.caption.monospaced().weight(.black)).foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct ControllerSettingsView: View {
    @Bindable var coordinator: ControllerCoordinator
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("CONTROLS") {
                    Toggle("Motion controls", isOn: $coordinator.motionControlEnabled)
                    Button("CALIBRATE CURRENT POSITION") { coordinator.calibrateMotion() }
                        .disabled(!coordinator.motionControlEnabled)
                    Text("Touch is the default. Turn on motion to steer by tilting this phone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("PHONE EFFECTS") {
                    Toggle("Screen color cues", isOn: $coordinator.deviceEffectsEnabled)
                    Toggle("Haptics", isOn: $coordinator.hapticsEnabled)
                    Text("Cues are brief and gentle. PartyBox never uses the torch or phone speakers.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Controller Settings")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("DONE", action: dismiss) } }
        }
        .preferredColorScheme(.dark)
    }
}

private struct MarkPicker: View {
    @Bindable var coordinator: ControllerCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("YOUR MARK")
                .font(.caption.monospaced().weight(.black))
                .foregroundStyle(.white.opacity(0.6))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                ForEach(PlayerMark.allCases, id: \.self) { mark in
                    let selected = coordinator.currentPlayer?.mark == mark
                    Button {
                        Task { await coordinator.selectMark(mark) }
                    } label: {
                        Image(systemName: mark.systemImageName)
                            .font(.title2.weight(.black))
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(selected ? ControllerTheme.cyan.opacity(0.55) : .black.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(mark.title)
                    .accessibilityIdentifier("controller.mark.\(mark.rawValue)")
                }
            }
        }
    }
}

private struct ControlStatusView: View {
    let status: PartyControlStatus

    var body: some View {
        VStack(spacing: 5) {
            Label(status.isCaptain ? "YOU ARE CAPTAIN" : "CAPTAIN CONTROLS NAVIGATION", systemImage: "crown.fill")
            if status.requiredReadyCount > 1 {
                Text("READY \(status.readyCount)/\(status.requiredReadyCount)")
                if !status.isCaptain {
                    Text(status.canToggleReady
                         ? (status.isReady ? "YOU’RE READY" : "TAP READY TO VOTE")
                         : "WAITING FOR CAPTAIN")
                }
            }
        }
        .font(.caption.monospaced().weight(.black))
        .foregroundStyle(status.isCaptain ? .yellow : .white.opacity(0.62))
        .multilineTextAlignment(.center)
        .accessibilityIdentifier("controller.control.status")
    }
}

private struct RosterView: View {
    let players: [PlayerInfo]
    let captainID: PlayerID?

    var body: some View {
        VStack(spacing: 10) {
            ForEach(players) { player in
                HStack {
                    Image(systemName: player.mark.systemImageName)
                        .foregroundStyle(Color.controllerHex(player.colorHex))
                    Text("P\(player.number)").font(.caption.monospaced().weight(.black))
                    Text(player.displayName).font(.subheadline.weight(.bold)).lineLimit(1)
                    if player.kind == .bot {
                        Text("BOT").font(.caption2.monospaced().weight(.black))
                    }
                    if player.id == captainID { Image(systemName: "crown.fill").foregroundStyle(.yellow) }
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
