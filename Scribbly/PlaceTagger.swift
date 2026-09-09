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

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Resolves quickly (a few seconds) or with nil; never blocks recording.
    func tag(_ completion: @escaping (String?) -> Void) {
        pending.append(completion)
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: flush(nil)
        default: manager.requestLocation()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.flush(self?.lastPlace) }
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
            self?.lastPlace = label ?? self?.lastPlace
            self?.flush(label)
        }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError e: Error) { flush(lastPlace) }

    private func flush(_ value: String?) {
        let cbs = pending; pending = []
        cbs.forEach { $0(value) }
    }
}
