import Foundation
import CoreLocation

/// Lightweight, `Sendable` geographic coordinate used across models and the UI.
struct Coordinate: Hashable, Sendable, Codable {
    var latitude: Double
    var longitude: Double

    var clLocationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init?(latitude: Double?, longitude: Double?) {
        guard let latitude, let longitude,
              latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        self.latitude = latitude
        self.longitude = longitude
    }
}

extension CLLocationCoordinate2D {
    var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }
}
