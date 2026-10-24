import AVFoundation
import Combine
import SwiftUI

/// Ambient sounds made on the fly from filtered noise, so Brim ships no audio files.
enum AmbientSound: String, CaseIterable, Identifiable {
    case rain, ocean, stream, wind, fire, thunder, brown, pink, white

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rain: return "Rain"
        case .ocean: return "Ocean"
        case .stream: return "Stream"
        case .wind: return "Wind"
        case .fire: return "Fireplace"
        case .thunder: return "Thunder"
        case .brown: return "Brown noise"
        case .pink: return "Pink noise"
        case .white: return "White noise"
        }
    }

    var color: Color {
        switch self {
        case .rain: return Palette.cyan
        case .ocean: return Palette.blue
        case .stream: return Palette.green
        case .wind: return Color(red: 0.68, green: 0.68, blue: 0.7)
        case .fire: return Palette.coral
        case .thunder: return Palette.yellow
        case .brown: return Color(red: 0.67, green: 0.56, blue: 0.41)
        case .pink: return Palette.purple
        case .white: return Color(white: 0.85)
        }
    }
}

/// Mixes the chosen sounds, each at its own volume, under one master volume with an optional fade-out.
@MainActor
final class SoundsService: ObservableObject {
    @Published private(set) var levels: [AmbientSound: Double] = [:]
    @Published var master: Double = 0.7 { didSet { mixer.master = Float(master) } }
    /// Minutes until everything fades out; 0 means never.
    @Published var fadeMinutes = 0 { didSet { scheduleFade() } }
    @Published private(set) var fadeEnds: Date?

    private let engine = AVAudioEngine()
    private let mixer = NoiseMixer()
    private var node: AVAudioSourceNode?
    private var fadeTask: Task<Void, Never>?

    var playing: Bool { !levels.isEmpty }

    init() {
        if AppSettings.isSnapshot { levels = [.rain: 0.6, .brown: 0.35] }
    }

    func toggle(_ sound: AmbientSound) {
        if levels[sound] != nil {
            levels[sound] = nil
            mixer.set(sound, 0)
        } else {
            levels[sound] = 0.5
            mixer.set(sound, 0.5)
            start()
        }
        if levels.isEmpty { stopEngine() }
    }

    func setLevel(_ sound: AmbientSound, _ value: Double) {
        guard levels[sound] != nil else { return }
        levels[sound] = value
        mixer.set(sound, Float(value))
    }

    func stopAll() {
        for sound in levels.keys { mixer.set(sound, 0) }
        levels = [:]
        fadeMinutes = 0
        stopEngine()
    }

    private func start() {
        guard !AppSettings.isSnapshot else { return }
        if node == nil {
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
            let mixer = self.mixer
            let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
                mixer.render(frames: Int(frameCount), buffers: UnsafeMutableAudioBufferListPointer(bufferList))
                return noErr
            }
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: format)
            node = source
        }
        mixer.master = Float(master)
        if !engine.isRunning { try? engine.start() }
    }

    private func stopEngine() {
        guard engine.isRunning else { return }
        // Let the smoothing ramp down before stopping, so it doesn't click.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, self.levels.isEmpty else { return }
            self.engine.pause()
        }
    }

    private func scheduleFade() {
        fadeTask?.cancel()
        guard fadeMinutes > 0 else {
            fadeEnds = nil
            mixer.fade = 1
            return
        }
        let ends = Date().addingTimeInterval(TimeInterval(fadeMinutes * 60))
        fadeEnds = ends
        fadeTask = Task { [weak self] in
            // The last 30 seconds ramp down.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                let left = ends.timeIntervalSinceNow
                self.mixer.fade = Float(max(0, min(1, left / 30)))
                if left <= 0 {
                    self.stopAll()
                    self.mixer.fade = 1
                    return
                }
            }
        }
    }
}

/// Real-time noise generators. Written for the audio thread: no allocation, no locks; the main
/// thread only writes target volumes, which the render loop eases towards.
final class NoiseMixer: @unchecked Sendable {
    var master: Float = 0.7
    var fade: Float = 1
    private var targets = [Float](repeating: 0, count: AmbientSound.allCases.count)
    private var current = [Float](repeating: 0, count: AmbientSound.allCases.count)
    private var seed: UInt32 = 0x1234_5678

    // Filter memories.
    private var pink = [Float](repeating: 0, count: 7)
    private var brown: Float = 0
    private var low1: Float = 0, low2: Float = 0, low3: Float = 0, high1: Float = 0
    private var phase: Float = 0, phase2: Float = 0
    private var drop: Float = 0, crackle: Float = 0, rumble: Float = 0, rumbleEnv: Float = 0
    private var rumbleWait: Int = 44_100 * 8

    func set(_ sound: AmbientSound, _ volume: Float) {
        targets[AmbientSound.allCases.firstIndex(of: sound)!] = volume
    }

    @inline(__always) private func white() -> Float {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Float(Int32(bitPattern: seed)) / Float(Int32.max)
    }

    @inline(__always) private func chance(_ p: Float) -> Bool { (white() + 1) * 0.5 < p }

    func render(frames: Int, buffers: UnsafeMutableAudioBufferListPointer) {
        let rate: Float = 44_100
        let count = targets.count
        for frame in 0..<frames {
            for i in 0..<count { current[i] += (targets[i] - current[i]) * 0.0005 }
            let w = white()
            // Pink (Paul Kellet) and brown noise.
            pink[0] = 0.99886 * pink[0] + w * 0.0555179
            pink[1] = 0.99332 * pink[1] + w * 0.0750759
            pink[2] = 0.96900 * pink[2] + w * 0.1538520
            pink[3] = 0.86650 * pink[3] + w * 0.3104856
            pink[4] = 0.55000 * pink[4] + w * 0.5329522
            pink[5] = -0.7616 * pink[5] - w * 0.0168980
            let p = (pink[0] + pink[1] + pink[2] + pink[3] + pink[4] + pink[5] + pink[6] + w * 0.5362) * 0.11
            pink[6] = w * 0.115926
            brown = (brown + w * 0.02) * 0.998
            let b = brown * 3.5

            phase += 0.08 / rate
            if phase > 1 { phase -= 1 }
            phase2 += 0.17 / rate
            if phase2 > 1 { phase2 -= 1 }
            let swell = 0.55 + 0.45 * sin(phase * 2 * .pi)
            let gust = 0.5 + 0.5 * sin(phase2 * 2 * .pi)

            // Rain: bright hiss plus droplets.
            high1 = 0.7 * (high1 + p - low1)
            low1 = p
            if chance(0.0008) { drop = 0.6 + 0.4 * (w + 1) * 0.5 }
            drop *= 0.992
            let rain = high1 * 0.9 + w * drop * 0.5
            // Ocean: brown noise that swells.
            let ocean = b * swell * 1.2
            // Stream: pink noise, gently rippled.
            low2 += 0.25 * (p - low2)
            let stream = low2 * (0.8 + 0.2 * sin(phase2 * 40))
            // Wind: low-passed noise whose cutoff gusts.
            low3 += (0.02 + 0.08 * gust) * (w - low3)
            let wind = low3 * (0.6 + 0.8 * gust) * 1.6
            // Fireplace: low rumble with crackles.
            if chance(0.0003) { crackle = 1 }
            crackle *= 0.985
            let fire = b * 0.5 + w * crackle * 0.8
            // Thunder: an occasional long rumble.
            rumbleWait -= 1
            if rumbleWait <= 0 {
                rumbleEnv = 1
                rumbleWait = Int(rate * (18 + 20 * (w + 1) * 0.5))
            }
            rumbleEnv *= 0.99997
            rumble += 0.01 * (b - rumble)
            let thunder = rumble * rumbleEnv * 6 + b * 0.3

            // Gains bring every sound to about the same loudness.
            let mix = rain * 2.3 * current[0] + ocean * 0.33 * current[1] + stream * 1.6 * current[2] + wind * 0.8 * current[3]
                + fire * 0.65 * current[4] + thunder * 1.1 * current[5] + b * 0.33 * current[6] + p * 1.15 * current[7]
                + w * 0.42 * current[8]
            let out = max(-1, min(1, mix * master * fade * 0.6))
            for buffer in buffers {
                buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = out
            }
        }
    }
}
