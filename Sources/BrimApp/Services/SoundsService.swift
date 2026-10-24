import AVFoundation
import Combine
import IslandCore
import SwiftUI

/// Ambient sounds made on the fly from filtered noise, so Brim ships no audio files. New cases go
/// at the end: the mixer indexes its gains by position.
enum AmbientSound: String, CaseIterable, Identifiable {
    case rain, ocean, stream, wind, fire, thunder, brown, pink, white, night, birds

    /// The order tiles show in.
    static let shown: [AmbientSound] = [.rain, .thunder, .ocean, .stream, .wind, .fire, .night, .birds, .brown, .pink, .white]

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
        case .night: return "Night"
        case .birds: return "Birdsong"
        }
    }

    var symbol: String {
        switch self {
        case .rain: return "cloud.rain"
        case .ocean: return "water.waves"
        case .stream: return "drop"
        case .wind: return "wind"
        case .fire: return "flame"
        case .thunder: return "cloud.bolt"
        case .brown: return "speaker.wave.1"
        case .pink: return "speaker.wave.2"
        case .white: return "speaker.wave.3"
        case .night: return "moon.stars"
        case .birds: return "bird"
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
        case .night: return Palette.purple
        case .birds: return Palette.green
        }
    }
}

/// An audio file you added, looped in the mix next to the generated sounds.
struct CustomSound: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    /// File name inside the Sounds folder.
    var file: String
}

/// A saved combination of sounds and levels. Keys are `AmbientSound` raw values or "custom:<id>".
struct SoundMix: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var levels: [String: Double]
    var builtIn = false

    static let builtIns: [SoundMix] = [
        SoundMix(id: "mix-focus", name: "Deep focus", levels: ["brown": 0.55, "stream": 0.3], builtIn: true),
        SoundMix(id: "mix-storm", name: "Rainy night", levels: ["rain": 0.6, "thunder": 0.35, "night": 0.2], builtIn: true),
        SoundMix(id: "mix-cabin", name: "Cabin", levels: ["fire": 0.55, "wind": 0.3, "rain": 0.25], builtIn: true),
        SoundMix(id: "mix-sea", name: "Seaside", levels: ["ocean": 0.6, "birds": 0.25, "wind": 0.2], builtIn: true),
        SoundMix(id: "mix-forest", name: "Forest morning", levels: ["birds": 0.5, "stream": 0.4], builtIn: true),
    ]
}

/// Mixes the chosen sounds, each at its own volume, under one master volume with an optional fade-out.
@MainActor
final class SoundsService: ObservableObject {
    @Published private(set) var levels: [AmbientSound: Double] = [:]
    @Published var master: Double = 0.7 { didSet { mixer.master = Float(master); updateCustomVolumes() } }
    /// Minutes until everything fades out; 0 means never.
    @Published var fadeMinutes = 0 { didSet { scheduleFade() } }
    @Published private(set) var fadeEnds: Date?
    /// Your own audio files and how loud each is playing (absent = off).
    @Published private(set) var customs: [CustomSound] = []
    @Published private(set) var customLevels: [String: Double] = [:]
    /// Mixes you saved; the built-in ones come first in the list.
    @Published private(set) var mixes: [SoundMix] = []

    private let engine = AVAudioEngine()
    private let mixer = NoiseMixer()
    private var node: AVAudioSourceNode?
    private var fadeTask: Task<Void, Never>?
    private var players: [String: AVAudioPlayerNode] = [:]
    private var fade: Float = 1

    private struct Saved: Codable {
        var customs: [CustomSound]
        var mixes: [SoundMix]
    }

    private let file = JSONFile<Saved>("sounds.json", directory: LocalData.directory)
    static var folder: URL { LocalData.directory.appendingPathComponent("Sounds", isDirectory: true) }
    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aif", "aiff", "caf", "flac", "aac"]

    var playing: Bool { !levels.isEmpty || !customLevels.isEmpty }
    var playingCount: Int { levels.count + customLevels.count }

    init() {
        if AppSettings.isSnapshot {
            levels = [.rain: 0.6, .night: 0.3]
            customs = [CustomSound(id: "sample", name: "Café, Lisbon", file: "cafe.m4a")]
            mixes = [SoundMix(id: "saved", name: "Late night", levels: ["rain": 0.6, "night": 0.3])]
        } else if let saved = file.load() {
            customs = saved.customs.filter { FileManager.default.fileExists(atPath: Self.folder.appendingPathComponent($0.file).path) }
            mixes = saved.mixes
        }
    }

    /// Every level as mix keys, for saving and for spotting which mix is playing.
    var currentLevels: [String: Double] {
        var all = Dictionary(uniqueKeysWithValues: levels.map { ($0.key.rawValue, $0.value) })
        for (id, level) in customLevels { all["custom:" + id] = level }
        return all
    }

    /// The mix whose sounds match what's playing.
    var activeMix: SoundMix? {
        let keys = Set(currentLevels.keys)
        guard !keys.isEmpty else { return nil }
        return (SoundMix.builtIns + mixes).first { Set($0.levels.keys) == keys }
    }

    func apply(_ mix: SoundMix) {
        for sound in levels.keys { mixer.set(sound, 0) }
        levels = [:]
        for id in customLevels.keys { players[id]?.volume = 0 }
        customLevels = [:]
        for (key, level) in mix.levels {
            if key.hasPrefix("custom:") {
                let id = String(key.dropFirst(7))
                if customs.contains(where: { $0.id == id }) { setCustom(id, level) }
            } else if let sound = AmbientSound(rawValue: key) {
                levels[sound] = level
                mixer.set(sound, Float(level))
            }
        }
        if !levels.isEmpty { start() }
        if !playing { stopEngine() }
    }

    func saveMix(named name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !currentLevels.isEmpty else { return }
        mixes.append(SoundMix(name: clean, levels: currentLevels))
        save()
    }

    func deleteMix(_ id: String) {
        mixes.removeAll { $0.id == id }
        save()
    }

    // MARK: Your own sounds

    /// Copies audio files into Brim's Sounds folder and adds them as tiles. Returns how many were added.
    @discardableResult
    func addFiles(_ urls: [URL]) -> Int {
        let audio = urls.filter { Self.audioExtensions.contains($0.pathExtension.lowercased()) }
        guard !audio.isEmpty else { return 0 }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        for url in audio {
            let name = UUID().uuidString.prefix(8) + "-" + url.lastPathComponent
            let target = Self.folder.appendingPathComponent(String(name))
            guard (try? FileManager.default.copyItem(at: url, to: target)) != nil else { continue }
            customs.append(CustomSound(name: url.deletingPathExtension().lastPathComponent, file: target.lastPathComponent))
        }
        save()
        return audio.count
    }

    func removeCustom(_ id: String) {
        setCustom(id, nil)
        if let player = players.removeValue(forKey: id) {
            player.stop()
            engine.detach(player)
        }
        if let custom = customs.first(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(custom.file))
        }
        customs.removeAll { $0.id == id }
        save()
    }

    func toggleCustom(_ id: String) {
        setCustom(id, customLevels[id] == nil ? 0.5 : nil)
    }

    /// Sets a custom sound's level, or stops it with nil.
    func setCustom(_ id: String, _ level: Double?) {
        guard !AppSettings.isSnapshot else {
            customLevels[id] = level
            return
        }
        if let level {
            customLevels[id] = level
            start()
            guard let player = player(for: id) else {
                customLevels[id] = nil
                return
            }
            player.volume = Float(level * master) * fade
            if !player.isPlaying { player.play() }
        } else {
            customLevels[id] = nil
            players[id]?.pause()
            if !playing { stopEngine() }
        }
    }

    /// A looping player for one file, created the first time it plays.
    private func player(for id: String) -> AVAudioPlayerNode? {
        if let existing = players[id] { return existing }
        guard let custom = customs.first(where: { $0.id == id }),
              let audio = try? AVAudioFile(forReading: Self.folder.appendingPathComponent(custom.file)),
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)),
              (try? audio.read(into: buffer)) != nil else { return nil }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
        if !engine.isRunning { try? engine.start() }
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        players[id] = player
        return player
    }

    private func updateCustomVolumes() {
        for (id, level) in customLevels { players[id]?.volume = Float(level * master) * fade }
    }

    private func save() {
        guard !AppSettings.isSnapshot else { return }
        file.save(Saved(customs: customs, mixes: mixes))
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
        for id in customLevels.keys { players[id]?.pause() }
        customLevels = [:]
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
            guard let self, !self.playing else { return }
            self.engine.pause()
        }
    }

    private func scheduleFade() {
        fadeTask?.cancel()
        guard fadeMinutes > 0 else {
            fadeEnds = nil
            mixer.fade = 1
            fade = 1
            updateCustomVolumes()
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
                self.fade = self.mixer.fade
                self.updateCustomVolumes()
                if left <= 0 {
                    self.stopAll()
                    self.mixer.fade = 1
                    self.fade = 1
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
    // Crickets and birds.
    private var cricketPhase: Float = 0, cricketPhase2: Float = 0, cricketClock: Float = 0, cricketClock2: Float = 0.31
    private var birdPhase: Float = 0, birdT: Float = 0, birdDuration: Float = 0, birdFrom: Float = 0, birdTo: Float = 0
    private var birdNotes = 0, birdWait = 44_100

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

            // Night: two crickets chirping three pulses at a time over a soft bed.
            cricketClock += 1 / rate
            if cricketClock > 0.78 { cricketClock -= 0.78 }
            cricketClock2 += 1 / rate
            if cricketClock2 > 0.97 { cricketClock2 -= 0.97 }
            cricketPhase += 4_700 / rate
            if cricketPhase > 1 { cricketPhase -= 1 }
            cricketPhase2 += 5_300 / rate
            if cricketPhase2 > 1 { cricketPhase2 -= 1 }
            let pulse1: Float = cricketClock < 0.1 && cricketClock.truncatingRemainder(dividingBy: 0.033) < 0.016 ? 1 : 0
            let pulse2: Float = cricketClock2 < 0.1 && cricketClock2.truncatingRemainder(dividingBy: 0.03) < 0.014 ? 0.7 : 0
            let night = sin(cricketPhase * 2 * .pi) * pulse1 * 0.5 + sin(cricketPhase2 * 2 * .pi) * pulse2 * 0.4 + p * 0.12
            // Birds: short rising or falling chirps, sometimes a little run of them.
            if birdNotes > 0 && birdT >= birdDuration {
                birdNotes -= 1
                birdT = -0.045
            }
            if birdNotes == 0 {
                birdWait -= 1
                if birdWait <= 0 {
                    let r = (w + 1) * 0.5
                    birdNotes = 1 + Int(r * 4)
                    birdFrom = 2_300 + r * 1_400
                    birdTo = birdFrom * (r > 0.5 ? 1.45 : 0.75)
                    birdDuration = 0.07 + r * 0.06
                    birdT = 0
                    birdWait = Int(rate * (0.35 + r * 1.1))
                }
            }
            var bird: Float = 0
            if birdNotes > 0 {
                birdT += 1 / rate
                if birdT > 0 && birdT < birdDuration {
                    let progress = birdT / birdDuration
                    birdPhase += (birdFrom + (birdTo - birdFrom) * progress) / rate
                    if birdPhase > 1 { birdPhase -= 1 }
                    bird = sin(birdPhase * 2 * .pi) * sin(progress * .pi) * 0.6
                }
            }
            let birds = bird + low3 * 0.15

            // Gains bring every sound to about the same loudness.
            let mix = rain * 2.3 * current[0] + ocean * 0.33 * current[1] + stream * 1.6 * current[2] + wind * 0.8 * current[3]
                + fire * 0.65 * current[4] + thunder * 1.1 * current[5] + b * 0.33 * current[6] + p * 1.15 * current[7]
                + w * 0.42 * current[8] + night * 1.8 * current[9] + birds * 1.2 * current[10]
            let out = max(-1, min(1, mix * master * fade * 0.6))
            for buffer in buffers {
                buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = out
            }
        }
    }
}
