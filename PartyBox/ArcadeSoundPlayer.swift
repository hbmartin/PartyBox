import AVFoundation
import OSLog

@MainActor
final class ArcadeSoundPlayer {
    private enum Tone: Hashable {
        case paddleHit
        case lostLife
        case eliminated
        case gameOver
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let logger = Logger(subsystem: "PartyBox", category: "ArcadeSoundPlayer")
    private var notificationTokens: [NSObjectProtocol] = []
    private var toneBuffers: [Tone: AVAudioPCMBuffer] = [:]

    init() {
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        let specifications: [(Tone, Double, Double, Double)] = [
            (.paddleHit, 620, 0.055, 1.8),
            (.lostLife, 180, 0.18, 0.5),
            (.eliminated, 105, 0.42, 0.25),
            (.gameOver, 880, 0.5, 1.5),
        ]
        for (tone, frequency, duration, overtone) in specifications {
            toneBuffers[tone] = Self.makeToneBuffer(
                format: format,
                frequency: frequency,
                duration: duration,
                overtone: overtone
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

    deinit {
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    }

    func play(_ event: PongEvent) {
        guard ensureEngineRunning() else { return }
        let tone = switch event {
        case .paddleHit: Tone.paddleHit
        case .lostLife: Tone.lostLife
        case .eliminated, .forfeited: Tone.eliminated
        case .gameOver: Tone.gameOver
        }
        guard let buffer = toneBuffers[tone] else { return }
        player.scheduleBuffer(buffer)
        if !player.isPlaying { player.play() }
    }

    private static func makeToneBuffer(
        format: AVAudioFormat,
        frequency: Double,
        duration: Double,
        overtone: Double
    ) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = frameCount
        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            let envelope = Float(pow(max(0, 1 - (time / duration)), 2))
            let base = sin(2 * Double.pi * frequency * time)
            let harmonic = sin(2 * Double.pi * frequency * overtone * time) * 0.24
            samples[frame] = Float(base + harmonic) * envelope * 0.18
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
