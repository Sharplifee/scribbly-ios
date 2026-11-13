import Foundation
import UIKit

/// One place that knows whether Scribbly® should be doing background-ish work
/// right now, so every poller and timer can back off together.
///
/// Why: on Nov 13 (build 260) iOS killed the app mid-recording with a 0x8BADF00D
/// "scene-update watchdog" while the phone was at thermal state CRITICAL.
/// While recording in the background the app was still running every
/// foreground poller (live status every 15 s, Activity every 2–5 s, batch
/// panels every 5 s, Home progress every 2 s) plus a 20 Hz meter driving
/// SwiftUI — all useless with the screen off, all adding heat and radio time.
final class PowerGovernor {
    static let shared = PowerGovernor()

    private(set) var inBackground = UIApplication.shared.applicationState == .background
    private(set) var thermal = ProcessInfo.processInfo.thermalState

    /// Network pollers (status, Activity, batch panels, Home progress) run only
    /// while the app is on screen and the phone isn't hot.
    var allowsPolling: Bool { !inBackground && thermal.rawValue < ProcessInfo.ThermalState.serious.rawValue }
    /// Live Activity waveform pushes stop when the phone is hot; the timer on
    /// the Island keeps ticking on its own.
    var allowsWaveform: Bool { thermal.rawValue < ProcessInfo.ThermalState.serious.rawValue }
    var isHot: Bool { thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue }

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.inBackground = true
            NotificationCenter.default.post(name: .scribblyPowerChanged, object: nil)
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.inBackground = false
            NotificationCenter.default.post(name: .scribblyPowerChanged, object: nil)
        }
        nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let old = self.thermal
            self.thermal = ProcessInfo.processInfo.thermalState
            EventLog.shared.log(.system, "power.thermal", status: self.isHot ? "warn" : "ok",
                                payload: ["from": Self.name(old), "to": Self.name(self.thermal),
                                          "background": self.inBackground,
                                          "recording": "\(Recorder.shared.state)",
                                          "low_power": ProcessInfo.processInfo.isLowPowerModeEnabled])
            CrashReporter.shared.add("thermal \(Self.name(self.thermal))")
            NotificationCenter.default.post(name: .scribblyPowerChanged, object: nil)
        }
    }

    /// Call once at launch so the observers exist.
    func start() {}

    static func name(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

extension Notification.Name {
    static let scribblyPowerChanged = Notification.Name("scribbly.power.changed")
}
