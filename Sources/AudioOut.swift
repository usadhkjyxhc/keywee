import AVFoundation

/// Spielt die 12-kHz-Mono-PCM-Daten des KiwiSDR ab.
final class AudioOut {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 12000, channels: 1,
                                       interleaved: false)!

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func start() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()
        player.play()
    }

    func stop() {
        player.stop()
        engine.stop()
    }

    func setVolume(_ v: Float) { engine.mainMixerNode.outputVolume = v }

    /// Big-endian Int16 Samples
    func push(_ bytes: [UInt8]) {
        let n = bytes.count / 2
        guard n > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))
        else { return }
        buf.frameLength = AVAudioFrameCount(n)
        let out = buf.floatChannelData![0]
        for i in 0..<n {
            let v = Int16(bitPattern: UInt16(bytes[2 * i]) << 8 | UInt16(bytes[2 * i + 1]))
            out[i] = Float(v) / 32768
        }
        player.scheduleBuffer(buf, completionHandler: nil)
    }
}
