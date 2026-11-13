import Foundation
import UserNotifications
import AVFoundation

// MARK: - What Scribbly® notifies about

/// Each kind of alert has its own on/off, tone and vibration, like iOS
/// Sounds & Haptics (Ringtone · Text Tone · New Mail …).
enum NotifyKind: String, CaseIterable, Identifiable, Codable {
    case transcriptReady, recordingSaved, needsAttention, batchFinished, watchMemo
    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcriptReady: return "Transcript Ready"
        case .recordingSaved:  return "Recording Uploaded"
        case .needsAttention:  return "Needs Attention"
        case .batchFinished:   return "Batch Finished"
        case .watchMemo:       return "Apple Watch Memo"
        }
    }
    var detail: String {
        switch self {
        case .transcriptReady: return "A recording, video or file is transcribed, summarized and in your library."
        case .recordingSaved:  return "A recording left this iPhone and is on the Scribbly® server."
        case .needsAttention:  return "Something didn't work — no speech found, or a job failed."
        case .batchFinished:   return "A channel, playlist or set of links finished fetching."
        case .watchMemo:       return "A memo recorded on your Apple Watch arrived on this iPhone."
        }
    }
    var icon: String {
        switch self {
        case .transcriptReady: return "text.bubble.fill"
        case .recordingSaved:  return "icloud.and.arrow.up.fill"
        case .needsAttention:  return "exclamationmark.triangle.fill"
        case .batchFinished:   return "square.stack.fill"
        case .watchMemo:       return "applewatch"
        }
    }
    var defaultTone: String {
        switch self {
        case .transcriptReady: return "scribbly"
        case .recordingSaved:  return "ripple"
        case .needsAttention:  return "glass"
        case .batchFinished:   return "marimba"
        case .watchMemo:       return "pebble"
        }
    }
    var defaultHaptic: String {
        switch self {
        case .transcriptReady: return "synced"
        case .recordingSaved:  return "pulse"
        case .needsAttention:  return "heartbeat"
        case .batchFinished:   return "synced"
        case .watchMemo:       return "synced"
        }
    }
    /// Notification Center groups each kind into its own stack.
    var threadID: String { "scribbly.\(rawValue)" }
}

// MARK: - Tones

struct Tone: Identifiable, Hashable {
    let id: String
    let name: String
    /// Seconds where each note starts — "Synchronized" vibration taps on these.
    let onsets: [Double]
}

struct CustomTone: Codable, Identifiable, Hashable {
    let id: String      // "custom:<uuid>"
    var name: String
    let file: String    // file name in Library/Sounds
}

enum ToneLibrary {
    static let systemID = "system"
    static let noneID = "none"

    /// The three Scribbly® defaults, shown first.
    static let defaults: [Tone] = [
        Tone(id: "scribbly", name: "Scribbly", onsets: [0, 0.11, 0.22]),
        Tone(id: "ripple", name: "Ripple", onsets: [0, 0.07, 0.14, 0.21, 0.28, 0.35]),
        Tone(id: "glass", name: "Glass", onsets: [0, 0.09]),
    ]
    /// Every other bundled tone (synthesized for Scribbly®, all under 3 s).
    static let alerts: [Tone] = [
        Tone(id: "aurora", name: "Aurora", onsets: [0, 0.16, 0.32, 0.48]),
        Tone(id: "beacon", name: "Beacon", onsets: [0, 0.32, 0.64]),
        Tone(id: "bloom", name: "Bloom", onsets: [0, 0.05, 0.1, 0.15, 0.2]),
        Tone(id: "breeze", name: "Breeze", onsets: [0, 0.12, 0.24]),
        Tone(id: "cascade", name: "Cascade", onsets: [0, 0.06, 0.12, 0.18, 0.24, 0.3, 0.36, 0.42]),
        Tone(id: "chord", name: "Chord", onsets: [0]),
        Tone(id: "crystal", name: "Crystal", onsets: [0, 0.08, 0.16]),
        Tone(id: "echo", name: "Echo", onsets: [0, 0.22, 0.44, 0.66, 0.88]),
        Tone(id: "ember", name: "Ember", onsets: [0, 0.14]),
        Tone(id: "halo", name: "Halo", onsets: [0]),
        Tone(id: "lumen", name: "Lumen", onsets: [0, 0.1]),
        Tone(id: "marimba", name: "Marimba", onsets: [0, 0.13, 0.26, 0.39]),
        Tone(id: "nova", name: "Nova", onsets: [0, 0.045, 0.09, 0.135, 0.18, 0.225]),
        Tone(id: "pebble", name: "Pebble", onsets: [0, 0.12]),
        Tone(id: "pulse", name: "Pulse", onsets: [0, 0.14, 0.28, 0.42]),
        Tone(id: "quill", name: "Quill", onsets: [0, 0.07, 0.14, 0.21]),
        Tone(id: "signal", name: "Signal", onsets: [0, 0.18, 0.36, 0.54]),
        Tone(id: "spark", name: "Spark", onsets: [0, 0.05, 0.1]),
        Tone(id: "tide", name: "Tide", onsets: [0, 0.2, 0.4, 0.6]),
        Tone(id: "whisper", name: "Whisper", onsets: [0, 0.15]),
    ]
    static var bundled: [Tone] { defaults + alerts }

    // Custom tones live in Library/Sounds — the one folder iOS reads
    // notification sounds from besides the app bundle.
    static var soundsDir: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let d = lib.appendingPathComponent("Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static let customKey = "notify.customTones"
    static var customs: [CustomTone] {
        get {
            guard let d = UserDefaults.standard.data(forKey: customKey),
                  let v = try? JSONDecoder().decode([CustomTone].self, from: d) else { return [] }
            return v.filter { FileManager.default.fileExists(atPath: soundsDir.appendingPathComponent($0.file).path) }
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: customKey) }
    }

    static func name(_ id: String) -> String {
        if id == systemID { return "iOS Default" }
        if id == noneID { return "None" }
        if let t = bundled.first(where: { $0.id == id }) { return t.name }
        if let c = customs.first(where: { $0.id == id }) { return c.name }
        return "Scribbly"
    }
    static func onsets(_ id: String) -> [Double] {
        if let t = bundled.first(where: { $0.id == id }) { return t.onsets }
        return [0, 0.15]
    }
    static func fileName(_ id: String) -> String? {
        if bundled.contains(where: { $0.id == id }) { return "scribbly-\(id).caf" }
        return customs.first(where: { $0.id == id })?.file
    }
    static func url(_ id: String) -> URL? {
        if bundled.contains(where: { $0.id == id }) {
            return Bundle.main.url(forResource: "scribbly-\(id)", withExtension: "caf")
        }
        if let c = customs.first(where: { $0.id == id }) { return soundsDir.appendingPathComponent(c.file) }
        return nil
    }
    /// What the notification itself plays. nil = silent.
    static func sound(_ id: String) -> UNNotificationSound? {
        if id == noneID { return nil }
        if id == systemID { return .default }
        guard let f = fileName(id) else { return .default }
        return UNNotificationSound(named: UNNotificationSoundName(f))
    }

    /// Imports any audio file as a notification tone: converted to 16-bit PCM
    /// CAF (a format iOS plays for notifications) and trimmed to 29 seconds
    /// (iOS falls back to the default sound past 30).
    static func importTone(from src: URL, name: String) throws -> CustomTone {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        let input = try AVAudioFile(forReading: src)
        let fmt = input.processingFormat
        let uuid = UUID().uuidString
        let file = "custom-\(uuid).caf"
        let dst = soundsDir.appendingPathComponent(file)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: fmt.sampleRate,
            AVNumberOfChannelsKey: min(fmt.channelCount, 2),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let out = try AVAudioFile(forWriting: dst, settings: settings,
                                  commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
        let maxFrames = AVAudioFramePosition(fmt.sampleRate * 29)
        var written: AVAudioFramePosition = 0
        let chunk: AVAudioFrameCount = 8192
        while input.framePosition < input.length, written < maxFrames {
            let want = AVAudioFrameCount(min(Int64(chunk), maxFrames - written))
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: want) else { break }
            try input.read(into: buf, frameCount: want)
            if buf.frameLength == 0 { break }
            try out.write(from: buf)
            written += AVAudioFramePosition(buf.frameLength)
        }
        let tone = CustomTone(id: "custom:\(uuid)", name: name.isEmpty ? "Custom Tone" : name, file: file)
        customs = customs + [tone]
        return tone
    }

    static func deleteCustom(_ id: String) {
        guard let c = customs.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: soundsDir.appendingPathComponent(c.file))
        customs = customs.filter { $0.id != id }
    }
}
