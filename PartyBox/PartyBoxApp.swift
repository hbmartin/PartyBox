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
final class PartyBoxApplicationLifecycle {
    let coordinator: HostCoordinator
    private var runTask: Task<Void, Never>?

    init(coordinator: HostCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        guard runTask == nil else { return }
        runTask = Task { @MainActor [coordinator] in
            await coordinator.start()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3_600)) } catch { break }
            }
        }
    }

    func cancel() {
        runTask?.cancel()
    }

    func stop() async {
        let activeRunTask = runTask
        runTask = nil
        activeRunTask?.cancel()
        await activeRunTask?.value
        await coordinator.stop()
    }
}

@MainActor
final class ApplicationTerminationGate {
    enum BeginResult: Equatable {
        case started
        case alreadyPending
        case alreadyFinished
    }

    private var shutdownTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var didReply = false

    func begin(
        timeout: Duration,
        shutdown: @escaping @MainActor () async -> Void,
        reply: @escaping @MainActor () -> Void
    ) -> BeginResult {
        if didReply { return .alreadyFinished }
        guard shutdownTask == nil else { return .alreadyPending }
        shutdownTask = Task { @MainActor [weak self] in
            await shutdown()
            self?.finish(reply: reply)
        }
        timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            self?.finish(reply: reply)
        }
        return .started
    }

    private func finish(reply: @MainActor () -> Void) {
        guard !didReply else { return }
        didReply = true
        shutdownTask?.cancel()
        timeoutTask?.cancel()
        shutdownTask = nil
        timeoutTask = nil
        reply()
    }
}

@MainActor
private final class PartyBoxApplicationDelegate: NSObject, NSApplicationDelegate {
    private let lifecycle: PartyBoxApplicationLifecycle
    private let terminationGate = ApplicationTerminationGate()
    private var window: NSWindow?

    override init() {
        preparePartyNetLiveClock()
        lifecycle = PartyBoxApplicationLifecycle(coordinator: HostCoordinator())
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = ContentView(coordinator: lifecycle.coordinator)
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
        lifecycle.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        lifecycle.cancel()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let result = terminationGate.begin(
            timeout: .seconds(10),
            shutdown: { [lifecycle] in await lifecycle.stop() },
            reply: { sender.reply(toApplicationShouldTerminate: true) }
        )
        switch result {
        case .started, .alreadyPending:
            return .terminateLater
        case .alreadyFinished:
            return .terminateNow
        }
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
