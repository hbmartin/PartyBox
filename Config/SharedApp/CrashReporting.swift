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
              let project = url.path.split(separator: "/").last, UInt64(project) != nil,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
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
        options.environment = "testflight"
        options.dist = "\(platform)-\(build)"
        options.sendDefaultPii = false
        options.sendClientReports = false
        options.enableSwizzling = false
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
            tags["build"] = build
            event.tags = tags
            return event
        }
        SentrySDK.start(options: options)
        #endif
    }
}
