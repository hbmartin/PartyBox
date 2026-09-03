import AVFoundation
import OSLog

@MainActor
final class ArcadeSoundPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let logger = Logger(subsystem: "PartyBox", category: "ArcadeSoundPlayer")
    private var notificationTokens: [NSObjectProtocol] = []

    init() {
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
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
        switch event {
        case .paddleHit: tone(frequency: 620, duration: 0.055, overtone: 1.8)
        case .lostLife: tone(frequency: 180, duration: 0.18, overtone: 0.5)
        case .eliminated, .forfeited: tone(frequency: 105, duration: 0.42, overtone: 0.25)
        case .gameOver: tone(frequency: 880, duration: 0.5, overtone: 1.5)
        }
    }

    private func tone(frequency: Double, duration: Double, overtone: Double) {
        let sampleRate = 44_100.0
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = frameCount
        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            let envelope = Float(pow(max(0, 1 - (time / duration)), 2))
            let base = sin(2 * Double.pi * frequency * time)
            let harmonic = sin(2 * Double.pi * frequency * overtone * time) * 0.24
            samples[frame] = Float(base + harmonic) * envelope * 0.18
        }
        player.scheduleBuffer(buffer)
        if !player.isPlaying { player.play() }
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
