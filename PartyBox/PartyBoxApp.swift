//
//  PartyBoxApp.swift
//  PartyBox
//
//  Created by Harold Martin on 9/2/26.
//

import SwiftUI

@main
struct PartyBoxApp: App {
    @State private var coordinator = HostCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView(coordinator: coordinator)
                .task { await coordinator.start() }
        }
#if os(macOS)
        .defaultSize(width: 1280, height: 720)
#endif
    }
}
