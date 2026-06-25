import AVFoundation
import Foundation

/// Wraps `AVAudioEngine` with a player node and a 10-band parametric EQ so the
/// app can offer a configurable equalizer (which `AVAudioPlayer` cannot do).
///
/// Kept on the main actor so it can be driven directly from `PlayerViewModel`.
/// The player node's render-thread completion handler hops back to the main
/// actor before touching any state.
@MainActor
final class AudioPlaybackEngine {
    /// Invoked when the current track reaches its natural end (not on seek/stop).
    var onPlaybackFinished: (() -> Void)?

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let equalizer: AVAudioUnitEQ

    private var audioFile: AVAudioFile?
    private var fileSampleRate: Double = 44_100
    private var totalFrames: AVAudioFramePosition = 0
    /// Frame the current segment was scheduled from; the anchor for `currentTime`.
    private var seekFrame: AVAudioFramePosition = 0
    /// Bumped whenever we (re)schedule audio so stale completion handlers are ignored.
    private var scheduleGeneration = 0
    private var isPlayerPlaying = false
    private var storedVolume: Float = 1

    init() {
        equalizer = AVAudioUnitEQ(numberOfBands: EqualizerSettings.frequencies.count)
        for (index, frequency) in EqualizerSettings.frequencies.enumerated() {
            let band = equalizer.bands[index]
            band.filterType = .parametric
            band.frequency = frequency
            band.bandwidth = 0.5
            band.gain = 0
            band.bypass = false
        }
        equalizer.globalGain = 0

        engine.attach(playerNode)
        engine.attach(equalizer)
    }

    var hasLoadedTrack: Bool { audioFile != nil }

    var duration: TimeInterval {
        guard fileSampleRate > 0 else { return 0 }
        return Double(totalFrames) / fileSampleRate
    }

    var currentTime: TimeInterval {
        guard fileSampleRate > 0 else { return 0 }
        var frame = seekFrame
        if let nodeTime = playerNode.lastRenderTime,
           let playerTime = playerNode.playerTime(forNodeTime: nodeTime) {
            frame = seekFrame + playerTime.sampleTime
        }
        let clamped = max(0, min(frame, totalFrames))
        return Double(clamped) / fileSampleRate
    }

    var volume: Float {
        get { storedVolume }
        set {
            storedVolume = newValue
            engine.mainMixerNode.outputVolume = newValue
        }
    }

    func load(url: URL) throws {
        let file = try AVAudioFile(forReading: url)

        playerNode.stop()
        scheduleGeneration &+= 1
        if engine.isRunning {
            engine.stop()
        }

        audioFile = file
        fileSampleRate = file.processingFormat.sampleRate
        totalFrames = file.length
        seekFrame = 0
        isPlayerPlaying = false

        let format = file.processingFormat
        engine.connect(playerNode, to: equalizer, format: format)
        engine.connect(equalizer, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = storedVolume

        engine.prepare()
        try engine.start()
        scheduleSegment(fromFrame: 0)
    }

    func play() {
        guard hasLoadedTrack else { return }
        if !engine.isRunning {
            try? engine.start()
        }
        playerNode.play()
        isPlayerPlaying = true
    }

    func pause() {
        guard hasLoadedTrack else { return }
        playerNode.pause()
        isPlayerPlaying = false
    }

    func seek(to time: TimeInterval) {
        guard hasLoadedTrack, fileSampleRate > 0 else { return }
        let wasPlaying = isPlayerPlaying
        let targetFrame = max(0, min(AVAudioFramePosition(time * fileSampleRate), totalFrames))

        playerNode.stop()
        scheduleSegment(fromFrame: targetFrame)
        if wasPlaying {
            playerNode.play()
        }
    }

    func stop() {
        playerNode.stop()
        scheduleGeneration &+= 1
        if engine.isRunning {
            engine.stop()
        }
        audioFile = nil
        totalFrames = 0
        seekFrame = 0
        isPlayerPlaying = false
    }

    /// Pushes the user's equalizer configuration onto the audio graph.
    func applyEqualizer(_ settings: EqualizerSettings) {
        equalizer.bypass = !settings.isEnabled
        equalizer.globalGain = settings.isEnabled ? settings.preamp : 0
        for (index, band) in equalizer.bands.enumerated() {
            guard index < settings.bands.count else { break }
            band.gain = settings.isEnabled ? settings.bands[index].gain : 0
        }
    }

    private func scheduleSegment(fromFrame startFrame: AVAudioFramePosition) {
        guard let file = audioFile else { return }
        seekFrame = startFrame

        let framesToPlay = totalFrames - startFrame
        guard framesToPlay > 0 else { return }

        scheduleGeneration &+= 1
        let generation = scheduleGeneration

        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: AVAudioFrameCount(framesToPlay),
            at: nil
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleSegmentCompletion(generation: generation)
            }
        }
    }

    private func handleSegmentCompletion(generation: Int) {
        // Ignore completions from segments that were superseded by a seek/load/stop.
        guard generation == scheduleGeneration else { return }
        guard isPlayerPlaying else { return }
        isPlayerPlaying = false
        onPlaybackFinished?()
    }
}
