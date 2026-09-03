//
//  PartyBox_ControllerApp.swift
//  PartyBox Controller
//
//  Created by Harold Martin on 9/2/26.
//

import PartyNet
import SwiftUI

@main
struct PartyBox_ControllerApp: App {
    @State private var coordinator = ControllerCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(coordinator: coordinator)
                .task {
                    await coordinator.start()
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(3_600)) } catch { break }
                    }
                    await coordinator.stop()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { coordinator.client.reconnectAfterForeground() }
                }
                .onChange(of: coordinator.client.state) { _, _ in
                    coordinator.updateIdleTimer()
                }
        }
    }
}
