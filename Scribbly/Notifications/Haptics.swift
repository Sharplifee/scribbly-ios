import Foundation
import CoreHaptics
import UIKit

/// One tap (d == 0) or a held buzz (d > 0), like the dots and bars of iOS
/// "Create New Vibration".
struct HapticEvent: Codable, Hashable {
    var t: Double
    var d: Double = 0
    var i: Float = 1
    var s: Float = 0.5
}

struct VibrationPattern: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var events: [HapticEvent]
}

enum HapticLibrary {
    static let syncedID = "synced"
    static let noneID = "none"

    private static func taps(_ times: [Double], i: Float = 1, s: Float = 0.6) -> [HapticEvent] {
        times.map { HapticEvent(t: $0, i: i, s: s) }
    }

    /// The three defaults, shown first.
    static let defaults: [VibrationPattern] = [
        VibrationPattern(id: syncedID, name: "Synchronized (Default)", events: []),
        VibrationPattern(id: "heartbeat", name: "Heartbeat", events: [
            HapticEvent(t: 0, i: 1, s: 0.3), HapticEvent(t: 0.16, i: 0.7, s: 0.3),
            HapticEvent(t: 0.9, i: 1, s: 0.3), HapticEvent(t: 1.06, i: 0.7, s: 0.3)]),
        VibrationPattern(id: "pulse", name: "Pulse", events: [
            HapticEvent(t: 0, d: 0.12, i: 0.9, s: 0.4), HapticEvent(t: 0.3, d: 0.12, i: 0.9, s: 0.4),
            HapticEvent(t: 0.6, d: 0.12, i: 0.9, s: 0.4)]),
    ]
    static let standard: [VibrationPattern] = [
        VibrationPattern(id: "accent", name: "Accent", events: taps([0, 0.1], s: 0.9)),
        VibrationPattern(id: "alert", name: "Alert", events: [
            HapticEvent(t: 0, d: 0.4, i: 1, s: 0.5), HapticEvent(t: 0.6, d: 0.4, i: 1, s: 0.5)]),
        VibrationPattern(id: "drumroll", name: "Drumroll", events: taps(stride(from: 0.0, to: 0.6, by: 0.05).map { $0 }, i: 0.7, s: 0.8)
            + [HapticEvent(t: 0.7, i: 1, s: 1)]),
        VibrationPattern(id: "quick", name: "Quick", events: taps([0], s: 1)),
        VibrationPattern(id: "rapid", name: "Rapid", events: taps(stride(from: 0.0, to: 1.0, by: 0.1).map { $0 })),
        VibrationPattern(id: "ripple", name: "Ripple", events: (0..<6).map { HapticEvent(t: Double($0) * 0.08, i: 1 - Float($0) * 0.14, s: 0.5) }),
        VibrationPattern(id: "sos", name: "S.O.S.", events: taps([0, 0.15, 0.3])
            + [HapticEvent(t: 0.55, d: 0.3), HapticEvent(t: 0.95, d: 0.3), HapticEvent(t: 1.35, d: 0.3)]
            + taps([1.8, 1.95, 2.1])),
        VibrationPattern(id: "staccato", name: "Staccato", events: taps([0, 0.2, 0.4, 0.9, 1.1], s: 0.9)),
        VibrationPattern(id: "symphony", name: "Symphony", events: [
            HapticEvent(t: 0, d: 0.25, i: 0.6, s: 0.2), HapticEvent(t: 0.3, i: 1, s: 0.8),
            HapticEvent(t: 0.45, d: 0.25, i: 0.8, s: 0.3), HapticEvent(t: 0.75, i: 1, s: 1),
            HapticEvent(t: 0.9, d: 0.5, i: 1, s: 0.4)]),
    ]

    private static let customKey = "notify.customVibrations"
    static var customs: [VibrationPattern] {
        get {
            guard let d = UserDefaults.standard.data(forKey: customKey),
                  let v = try? JSONDecoder().decode([VibrationPattern].self, from: d) else { return [] }
            return v
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: customKey) }
    }

    static func name(_ id: String) -> String {
        if id == noneID { return "None" }
        if id == syncedID { return "Synchronized" }
        return (defaults + standard + customs).first(where: { $0.id == id })?.name ?? "Synchronized"
    }
    static func events(_ id: String, tone: String) -> [HapticEvent] {
        if id == noneID { return [] }
        if id == syncedID || !(defaults + standard + customs).contains(where: { $0.id == id }) {
            // Synchronized: one tap on every note of the tone.
            return ToneLibrary.onsets(tone).enumerated().map { HapticEvent(t: $1, i: $0 == 0 ? 1 : 0.8, s: 0.7) }
        }
        return (defaults + standard + customs).first(where: { $0.id == id })?.events ?? []
    }
}

/// Plays vibration patterns with Core Haptics (falls back to a simple
/// notification buzz on devices without a Taptic Engine).
final class HapticPlayer {
    static let shared = HapticPlayer()
    private var engine: CHHapticEngine?
    private var player: CHHapticPatternPlayer?
    private var continuous: CHHapticAdvancedPatternPlayer?
    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    private func ready() -> CHHapticEngine? {
        guard supported else { return nil }
        if engine == nil {
            engine = try? CHHapticEngine()
            engine?.playsHapticsOnly = true
            engine?.isAutoShutdownEnabled = true
            engine?.resetHandler = { [weak self] in try? self?.engine?.start() }
            engine?.stoppedHandler = { _ in }
        }
        try? engine?.start()
        return engine
    }

    func play(_ events: [HapticEvent]) {
        guard !events.isEmpty else { return }
        guard let e = ready() else {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return
        }
        let hs: [CHHapticEvent] = events.map { ev in
            let p = [CHHapticEventParameter(parameterID: .hapticIntensity, value: ev.i),
                     CHHapticEventParameter(parameterID: .hapticSharpness, value: ev.s)]
            return ev.d > 0
                ? CHHapticEvent(eventType: .hapticContinuous, parameters: p, relativeTime: ev.t, duration: ev.d)
                : CHHapticEvent(eventType: .hapticTransient, parameters: p, relativeTime: ev.t)
        }
        do {
            try player?.stop(atTime: CHHapticTimeImmediate)
            let pattern = try CHHapticPattern(events: hs, parameters: [])
            player = try e.makePlayer(with: pattern)
            try player?.start(atTime: CHHapticTimeImmediate)
        } catch {}
    }

    func play(haptic id: String, tone: String) { play(HapticLibrary.events(id, tone: tone)) }

    /// Held buzz while a finger is down on the "Create New Vibration" pad.
    func beginHold() {
        guard let e = ready() else { return }
        let ev = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)], relativeTime: 0, duration: 30)
        continuous = try? e.makeAdvancedPlayer(with: try CHHapticPattern(events: [ev], parameters: []))
        try? continuous?.start(atTime: CHHapticTimeImmediate)
    }
    func endHold() {
        try? continuous?.stop(atTime: CHHapticTimeImmediate)
        continuous = nil
    }
    func stop() { try? player?.stop(atTime: CHHapticTimeImmediate); endHold() }
}
