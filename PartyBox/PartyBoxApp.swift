//
//  PartyBoxApp.swift
//  PartyBox
//
//  Created by Harold Martin on 9/2/26.
//

import SwiftUI
import PartyNet

@main
struct PartyBoxApp: App {
    @State private var coordinator: HostCoordinator

    init() {
        preparePartyNetLiveClock()
        _coordinator = State(initialValue: HostCoordinator())
    }

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
        }
#if os(macOS)
        .defaultSize(width: 1280, height: 720)
#endif
    }
}
