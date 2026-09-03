import Dependencies
import Foundation

/// Installs the production clock before an application constructs any PartyNet objects.
///
/// Xcode unit-test hosts run the app entry point in a test dependency context. Preparing the
/// live clock here establishes the process-wide default for work that is not already running
/// inside an explicit dependency override.
public func preparePartyNetLiveClock() {
  prepareDependencies {
    $0.continuousClock = ContinuousClock()
  }
}
