import Dependencies
import Foundation

/// Installs the production clock before an application constructs any PartyNet objects.
///
/// Xcode unit-test hosts run the app entry point in a test dependency context. Preparing the
/// live clock here keeps the app's background networking independent from each test's scoped
/// `TestClock` overrides.
public func preparePartyNetLiveClock() {
  prepareDependencies {
    $0.continuousClock = ContinuousClock()
  }
}
