import Foundation
#if !DEBUG
import Sentry
#endif

@MainActor
enum CrashReporting {
    static func start(app: String) {
        #if !DEBUG
        let bundle = Bundle.main
        guard let dsn = bundle.object(forInfoDictionaryKey: "PartyBoxSentryDSN") as? String,
              let url = URLComponents(string: dsn),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              let key = url.user, !key.isEmpty, url.password == nil,
              let project = url.path.split(separator: "/").last, UInt64(project) != nil else {
            return
        }

        #if os(macOS)
        let platform = "macos"
        #elseif os(tvOS)
        let platform = "tvos"
        #else
        let platform = "ios"
        #endif

        let options = Options()
        options.dsn = dsn
        guard options.parsedDsn != nil else { return }
        let environment = (bundle.object(forInfoDictionaryKey: "PartyBoxSentryEnvironment") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        options.environment = environment.isEmpty ? "local" : environment
        options.sendDefaultPii = false
        options.sendClientReports = false
        #if os(macOS)
        options.enableUncaughtNSExceptionReporting = true
        #else
        options.enableSwizzling = false
        #endif
        options.enableAutoSessionTracking = false
        options.enableAutoBreadcrumbTracking = false
        options.enableCaptureFailedRequests = false
        options.enableNetworkBreadcrumbs = false
        options.maxBreadcrumbs = 0
        options.enableAppHangTracking = false
        options.enableWatchdogTerminationTracking = false
        options.tracesSampleRate = 0
        options.beforeSend = { @Sendable event in
            event.user = nil
            var tags = event.tags ?? [:]
            tags["app"] = app
            tags["app_platform"] = platform
            // Crash reports can be delivered by a later build. This context
            // describes the process that crashed, even after an app update.
            let recordedBuild = event.context?["app"]?["app_build"] as? String
            let build = recordedBuild.flatMap { $0.isEmpty ? nil : $0 }
            tags["build"] = build
            event.dist = build.map { "\(platform)-\($0)" }
            event.tags = tags
            return event
        }
        SentrySDK.start(options: options)
        #endif
    }
}
