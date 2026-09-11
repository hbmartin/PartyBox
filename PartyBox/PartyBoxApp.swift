//
//  PartyBoxApp.swift
//  PartyBox
//
//  Created by Harold Martin on 9/2/26.
//

import SwiftUI
import PartyNet

#if os(macOS)
import AppKit

@MainActor
final class PartyBoxApplicationDelegate: NSObject, NSApplicationDelegate {
    private let coordinator: HostCoordinator
    private var window: NSWindow?
    private var lifecycleTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?

    override init() {
        preparePartyNetLiveClock()
        coordinator = HostCoordinator()
        super.init()
    }

    init(coordinator: HostCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = ContentView(coordinator: coordinator)
        let hostingView = NSHostingView(rootView: contentView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PartyBox"
        window.contentView = hostingView
        window.contentMinSize = NSSize(width: 960, height: 540)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        self.window = window

        NSApplication.shared.unhide(nil)
        NSApplication.shared.activate()
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        lifecycleTask = Task { @MainActor [coordinator] in
            await coordinator.start()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3_600)) } catch { break }
            }
            await coordinator.stop()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        lifecycleTask?.cancel()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task { @MainActor [weak self] in
            if let self { await self.stopForTermination() }
            sender.reply(toApplicationShouldTerminate: true)
            self?.terminationTask = nil
        }
        return .terminateLater
    }

    func stopForTermination() async {
        let activeLifecycleTask = lifecycleTask
        activeLifecycleTask?.cancel()
        if let activeLifecycleTask {
            await activeLifecycleTask.value
        } else {
            await coordinator.stop()
        }
        lifecycleTask = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
#endif

#if os(macOS)
@main
enum PartyBoxApp {
    static func main() {
        let application = NSApplication.shared
        let applicationDelegate = PartyBoxApplicationDelegate()
        application.delegate = applicationDelegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(applicationDelegate) {
            application.run()
        }
    }
}
#else
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
    }
}
#endif
