import Foundation
import CoreLocation

/// Grabs one location fix when a recording starts and turns it into a short
/// human place label ("Thanksgiving Point, Lehi" / "Main St, Lehi"). Used to
/// title voice memos by WHERE they happened instead of "Voice Memo 152".
final class PlaceTagger: NSObject, CLLocationManagerDelegate {
    static let shared = PlaceTagger()
    private let manager = CLLocationManager()
    private var pending: [(String?) -> Void] = []
    private(set) var lastPlace: String?
    /// When `lastPlace` was resolved.
    private(set) var lastPlaceAt: Date?

    /// Settings › "Title recordings by place" (default on).
    static var enabled: Bool {
        (UserDefaults.standard.object(forKey: "titleByPlace") as? Bool) ?? true
    }

    /// `lastPlace` only if it was resolved in the last 15 minutes — an old fix
    /// (you've since driven home) must never title a new recording.
    var recentPlace: String? {
        guard Self.enabled, let at = lastPlaceAt, Date().timeIntervalSince(at) < 15 * 60 else { return nil }
        return lastPlace
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Resolves quickly (a few seconds) or with nil; never blocks recording.
    func tag(_ completion: @escaping (String?) -> Void) {
        guard Self.enabled else { completion(nil); return }
        pending.append(completion)
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: flush(nil)
        default: manager.requestLocation()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.flush(self?.recentPlace) }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        guard !pending.isEmpty else { return }
        switch m.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: m.requestLocation()
        case .denied, .restricted: flush(nil)
        default: break
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { flush(nil); return }
        CLGeocoder().reverseGeocodeLocation(loc) { [weak self] marks, _ in
            let p = marks?.first
            var parts: [String] = []
            if let name = p?.name, !name.isEmpty { parts.append(name) }
            else if let street = p?.thoroughfare { parts.append(street) }
            if let city = p?.locality, !parts.contains(city) { parts.append(city) }
            let label = parts.isEmpty ? nil : parts.joined(separator: ", ")
            if let label {
                self?.lastPlace = label
                self?.lastPlaceAt = Date()
            }
            self?.flush(label)
        }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError e: Error) { flush(recentPlace) }

    private func flush(_ value: String?) {
        let cbs = pending; pending = []
        cbs.forEach { $0(value) }
    }
}
