import PartyNet
import SpriteKit
import SwiftUI

struct ContentView: View {
    @Bindable var coordinator: HostCoordinator
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            PartyBackdrop()
            switch coordinator.phase {
            case .lobby:
                LobbyView(coordinator: coordinator)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            case .gameMenu:
                GameMenuView(coordinator: coordinator)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            case .playing:
                if let scene = coordinator.pongScene {
                    SpriteView(scene: scene, options: [.ignoresSiblingOrder])
                        .transition(.opacity)
                }
            case let .gameOver(result):
                GameOverView(result: result)
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
            }
            keyboardButtons
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: coordinator.phase)
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        .onMoveCommand { direction in
            switch direction {
            case .up: coordinator.perform(.up)
            case .down: coordinator.perform(.down)
            case .left: coordinator.perform(.left)
            case .right: coordinator.perform(.right)
            @unknown default: break
            }
        }
        .onExitCommand { coordinator.perform(.back) }
        .onTapGesture { coordinator.perform(.select) }
    }

    @ViewBuilder
    private var keyboardButtons: some View {
#if os(macOS)
        VStack {
            Button("") { coordinator.perform(.select) }
                .keyboardShortcut(.return, modifiers: [])
            Button("") { coordinator.perform(.select) }
                .keyboardShortcut(.space, modifiers: [])
            Button("") { coordinator.perform(.up) }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("") { coordinator.perform(.down) }
                .keyboardShortcut(.downArrow, modifiers: [])
            Button("") { coordinator.perform(.left) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { coordinator.perform(.right) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { coordinator.perform(.back) }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
#endif
    }
}

private struct LobbyView: View {
    @Bindable var coordinator: HostCoordinator

    var body: some View {
        VStack(spacing: 26) {
            PartyWordmark(kicker: "LOCAL ARCADE", title: "PARTYBOX")
            Text("Open PartyBox Controller on iPhone and choose this host")
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(0.72))
            Text(coordinator.host.hostName)
                .font(.title2.monospaced().weight(.bold))
                .foregroundStyle(PartyTheme.cyan)
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(.black.opacity(0.34), in: Capsule())

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 4), spacing: 18) {
                ForEach(0..<8, id: \.self) { index in
                    let player = coordinator.host.players.first { $0.id.rawValue == UInt8(index) }
                    PlayerCard(number: index + 1, player: player, isActive: player.map {
                        coordinator.seatQueue.active.contains($0.id)
                    } ?? false)
                }
            }
            .frame(maxWidth: 1_220)

            HStack(spacing: 18) {
                Circle().fill(coordinator.canStart ? PartyTheme.lime : .gray).frame(width: 12, height: 12)
                Text(coordinator.canStart ? "PRESS SELECT TO CHOOSE A GAME" : "WAITING FOR A CONTROLLER")
                    .font(.headline.monospaced().weight(.bold))
            }
            .foregroundStyle(.white)
            Text(coordinator.statusMessage)
                .font(.subheadline.monospaced())
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(48)
    }
}

private struct GameMenuView: View {
    @Bindable var coordinator: HostCoordinator

    var body: some View {
        VStack(spacing: 42) {
            PartyWordmark(kicker: "CHOOSE YOUR CHAOS", title: "GAME SELECT")
            ForEach(Array(coordinator.menuItems.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 24) {
                    Text(index == coordinator.menuSelection ? "▶" : "")
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item).font(.system(size: 48, weight: .black, design: .rounded))
                        Text("1–4 players  •  Three lives  •  Winner stays")
                            .font(.title3.monospaced())
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .foregroundStyle(index == coordinator.menuSelection ? PartyTheme.magenta : .white)
                .padding(34)
                .frame(maxWidth: 850, alignment: .leading)
                .background(.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(PartyTheme.magenta.opacity(0.6), lineWidth: 2))
            }
            Text("SELECT TO PLAY  •  MENU/ESC TO RETURN")
                .font(.headline.monospaced().weight(.bold))
                .foregroundStyle(.white.opacity(0.72))
        }
        .padding(64)
    }
}

private struct GameOverView: View {
    let result: GameResult

    var body: some View {
        VStack(spacing: 26) {
            Text("ROUND COMPLETE")
                .font(.headline.monospaced().weight(.bold))
                .foregroundStyle(PartyTheme.cyan)
            Text(result.title)
                .font(.system(size: 72, weight: .black, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .shadow(color: PartyTheme.magenta, radius: 22)
            Text(result.subtitle)
                .font(.title2.monospaced())
                .foregroundStyle(.white.opacity(0.74))
            Text("SELECT: NEXT MATCH   •   MENU/ESC: GAME SELECT")
                .font(.headline.monospaced().weight(.bold))
                .padding(.top, 36)
                .foregroundStyle(PartyTheme.lime)
        }
        .padding(64)
    }
}

private struct PlayerCard: View {
    let number: Int
    let player: PlayerInfo?
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("P\(number)").font(.title2.monospaced().weight(.black))
                Spacer()
                Circle()
                    .fill(player.map { Color.partyHex($0.colorHex) } ?? .white.opacity(0.12))
                    .frame(width: 16, height: 16)
                    .shadow(color: player.map { Color.partyHex($0.colorHex) } ?? .clear, radius: 10)
            }
            Text(player?.displayName ?? "OPEN")
                .font(.headline.weight(.bold))
                .lineLimit(1)
            Text(player == nil ? "AVAILABLE" : (isActive ? "ACTIVE SEAT" : "SPECTATOR QUEUE"))
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(.white.opacity(0.52))
            if let player, !player.isConnected {
                Text("RECONNECTING…").font(.caption2.monospaced().weight(.bold)).foregroundStyle(.orange)
            }
        }
        .foregroundStyle(player == nil ? .white.opacity(0.34) : .white)
        .padding(20)
        .frame(minHeight: 128, alignment: .topLeading)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(
            player.map { Color.partyHex($0.colorHex).opacity(0.7) } ?? .white.opacity(0.12), lineWidth: 2
        ))
    }
}

private struct PartyWordmark: View {
    let kicker: String
    let title: String

    var body: some View {
        VStack(spacing: 6) {
            Text(kicker).font(.headline.monospaced().weight(.bold)).foregroundStyle(PartyTheme.cyan)
            Text(title)
                .font(.system(size: 70, weight: .black, design: .rounded))
                .tracking(4)
                .foregroundStyle(.white)
                .shadow(color: PartyTheme.magenta.opacity(0.8), radius: 22)
        }
    }
}

private struct PartyBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.015, green: 0.02, blue: 0.08), Color(red: 0.08, green: 0.018, blue: 0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(colors: [PartyTheme.cyan.opacity(0.13), .clear], center: .topTrailing, startRadius: 20, endRadius: 700)
            RadialGradient(colors: [PartyTheme.magenta.opacity(0.12), .clear], center: .bottomLeading, startRadius: 20, endRadius: 650)
        }
        .ignoresSafeArea()
    }
}

enum PartyTheme {
    static let cyan = Color(red: 0.20, green: 0.90, blue: 1)
    static let magenta = Color(red: 1, green: 0.31, blue: 0.85)
    static let lime = Color(red: 0.43, green: 1, blue: 0.47)
}

extension Color {
    static func partyHex(_ value: String) -> Color {
        let hex = value.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard hex.count == 6, let number = UInt64(hex, radix: 16) else { return .white }
        return Color(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }
}
