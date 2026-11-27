import Foundation
import PartyNet

/// Replay state for accepted datagrams in one loss scope.
package struct UDPDecisionStream: Sendable {
    private let profile: FaultProfile
    private var ordinal: UInt64 = 0
    private var dropState: UInt64
    private var jitterState: UInt64

    package init(profile: FaultProfile, controllerID: ControllerID? = nil) {
        self.profile = profile
        var seed = profile.seed
        if let controllerID {
            // FNV-1a on the 16 UUID bytes is stable across launches and architectures.
            let identityHash = withUnsafeBytes(of: controllerID.rawValue.uuid) { bytes in
                bytes.reduce(0xcbf2_9ce4_8422_2325 as UInt64) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
            }
            seed ^= identityHash
            dropState = Self.mix(seed ^ 0x6c6f_7373) // "loss"
        } else {
            // Keep the original shared loss sequence for existing seeds.
            dropState = seed
        }
        jitterState = Self.mix(seed ^ 0x6a69_7474_6572) // "jitter"
    }

    package mutating func consumeDropDecision() -> Bool {
        ordinal &+= 1
        switch profile.udpDropPolicy {
        case .none:
            return false
        case let .every(interval):
            return ordinal.isMultiple(of: UInt64(interval))
        case let .rate(rate):
            let draw = Double(Self.next(&dropState) >> 11) / Double(UInt64(1) << 53)
            return draw < rate
        }
    }

    package mutating func nextDelayMilliseconds() -> Int {
        guard profile.jitterMilliseconds > 0 else { return profile.delayMilliseconds }
        let width = profile.jitterMilliseconds * 2 + 1
        let offset = Int(Self.next(&jitterState) % UInt64(width)) - profile.jitterMilliseconds
        return max(profile.delayMilliseconds + offset, 0)
    }

    private static func next(_ state: inout UInt64) -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    // SplitMix64's finalizer separates the controller and purpose seeds before the first draw.
    private static func mix(_ value: UInt64) -> UInt64 {
        let first = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
        let second = (first ^ (first >> 27)) &* 0x94d0_49bb_1331_11eb
        return second ^ (second >> 31)
    }
}
