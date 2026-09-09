import AVFoundation
import OSLog
import PartyBoxCore

@MainActor
final class ArcadeSoundPlayer {
    private enum Tone: Hashable, Sendable {
        case paddleHit
        case lostLife
        case eliminated
        case gameOver
    }

    private struct ToneSpecification: Sendable {
        let tone: Tone
        let frequency: Double
        let duration: Double
        let overtone: Double
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let logger = Logger(subsystem: "PartyBox", category: "ArcadeSoundPlayer")
    private var notificationTokens: [NSObjectProtocol] = []
    private var toneBuffers: [Tone: AVAudioPCMBuffer] = [:]

    static func prepare() async -> ArcadeSoundPlayer? {
        let specifications = toneSpecifications
        let samples = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: specifications.map { specification in
                (
                    specification.tone,
                    makeToneSamples(
                        sampleRate: 44_100,
                        frequency: specification.frequency,
                        duration: specification.duration,
                        overtone: specification.overtone
                    )
                )
            })
        }.value
        guard !Task.isCancelled else { return nil }
        return ArcadeSoundPlayer(samples: samples)
    }

    private init(samples: [Tone: [Float]]) {
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        for (tone, values) in samples {
            toneBuffers[tone] = Self.makeToneBuffer(
                format: format,
                samples: values
            )
        }
#if os(tvOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            logger.error("Audio session setup failed: \(error.localizedDescription)")
        }
#endif
        observeAudioChanges()
        _ = ensureEngineRunning()
    }

    isolated deinit {
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    }

    func play(_ event: HapticPattern) {
        guard ensureEngineRunning() else { return }
        let tone = switch event {
        case .lightImpact: Tone.paddleHit
        case .heavyImpact: Tone.lostLife
        case .error: Tone.eliminated
        case .success: Tone.gameOver
        }
        guard let buffer = toneBuffers[tone] else { return }
        player.scheduleBuffer(buffer)
        if !player.isPlaying { player.play() }
    }

    nonisolated private static let toneSpecifications: [ToneSpecification] = [
        .init(tone: .paddleHit, frequency: 620, duration: 0.055, overtone: 1.8),
        .init(tone: .lostLife, frequency: 180, duration: 0.18, overtone: 0.5),
        .init(tone: .eliminated, frequency: 105, duration: 0.42, overtone: 0.25),
        .init(tone: .gameOver, frequency: 880, duration: 0.5, overtone: 1.5),
    ]

    nonisolated private static func makeToneSamples(
        sampleRate: Double,
        frequency: Double,
        duration: Double,
        overtone: Double
    ) -> [Float] {
        let frameCount = Int(sampleRate * duration)
        return (0..<frameCount).map { frame in
            let time = Double(frame) / sampleRate
            let envelope = Float(pow(max(0, 1 - (time / duration)), 2))
            let base = sin(2 * Double.pi * frequency * time)
            let harmonic = sin(2 * Double.pi * frequency * overtone * time) * 0.24
            return Float(base + harmonic) * envelope * 0.18
        }
    }

    private static func makeToneBuffer(
        format: AVAudioFormat,
        samples: [Float]
    ) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let destination = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = frameCount
        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            destination.update(from: baseAddress, count: samples.count)
        }
        return buffer
    }

    @discardableResult
    private func ensureEngineRunning() -> Bool {
        if engine.isRunning { return true }
        do {
#if os(tvOS)
            try AVAudioSession.sharedInstance().setActive(true)
#endif
            try engine.start()
            return true
        } catch {
            logger.error("Audio engine startup failed: \(error.localizedDescription)")
            return false
        }
    }

    private func observeAudioChanges() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in _ = self?.ensureEngineRunning() }
        })
#if os(tvOS)
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: rawType) == .ended,
                  let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                  AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            else { return }
            Task { @MainActor [weak self] in _ = self?.ensureEngineRunning() }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
                Task { @MainActor [weak self] in _ = self?.ensureEngineRunning() }
        })
#endif
    }
}
