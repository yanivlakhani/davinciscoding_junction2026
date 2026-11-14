import Foundation
import CoreLocation
import Observation
import ModalTransport

@MainActor @Observable
final class AlertLocationProvider: NSObject, @preconcurrency CLLocationManagerDelegate {
    private(set) var status = "Location not enabled · alerts will say unavailable"
    @ObservationIgnored private let manager = CLLocationManager()
    private var latest: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var sample: AlertLocation? {
        guard let latest, (0...1000).contains(latest.horizontalAccuracy),
              (0...900).contains(Date().timeIntervalSince(latest.timestamp)) else { return nil }
        return AlertLocation(latitude: latest.coordinate.latitude, longitude: latest.coordinate.longitude,
            accuracy: latest.horizontalAccuracy, capturedAt: latest.timestamp.timeIntervalSince1970)
    }

    func requestPermissionAndLocation() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else { refreshIfAuthorized() }
    }

    func refreshIfAuthorized() {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            status = "Requesting phone location"
            manager.requestLocation()
        case .denied, .restricted: status = "Location denied · alerts will say unavailable"
        default: break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { refreshIfAuthorized() }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let fix = locations.last(where: { (0...1000).contains($0.horizontalAccuracy) }) { latest = fix }
        status = sample == nil ? "No recent location · alerts will say unavailable" :
            "Phone location available · timestamp and accuracy included in alert"
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        status = sample == nil ? "Location unavailable" : "Using timestamped last known phone location"
    }
}
