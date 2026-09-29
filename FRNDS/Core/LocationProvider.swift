import CoreLocation
import FRNDSAPI
import MapKit

enum LocationError: LocalizedError {
    case denied
    case unavailable

    var errorDescription: String? {
        switch self {
        case .denied: String(localized: "Location access is off for FRNDS. You can allow it in Settings.")
        case .unavailable: String(localized: "Your location couldn't be determined.")
        }
    }
}

/// One-shot location + reverse geocoding for tagging posts.
enum LocationProvider {
    /// Asks for "While Using" permission if needed and returns the first good fix.
    static func currentLocation(timeout: Duration = .seconds(15)) async throws -> CLLocation {
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }

        return try await withThrowingTaskGroup(of: CLLocation.self) { group in
            group.addTask {
                // The stream can end while the permission alert is up; restart it until the timeout wins.
                while !Task.isCancelled {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if update.authorizationRequestInProgress { continue }
                        if update.authorizationDenied || update.authorizationDeniedGlobally {
                            throw LocationError.denied
                        }
                        if let location = update.location, location.horizontalAccuracy >= 0,
                           location.horizontalAccuracy < 1_000 {
                            return location
                        }
                    }
                    try await Task.sleep(for: .milliseconds(300))
                }
                throw CancellationError()
            }
            group.addTask {
                // Don't count the time someone spends reading the permission alert.
                while await authorizationPending {
                    try await Task.sleep(for: .milliseconds(300))
                }
                try await Task.sleep(for: timeout)
                throw LocationError.unavailable
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw LocationError.unavailable }
            return first
        }
    }

    private static let manager = CLLocationManager()

    /// `true` until the user has answered the location permission alert.
    static var authorizationPending: Bool {
        manager.authorizationStatus == .notDetermined
    }

    /// A short place name like "Hamburg, Germany", or `nil` if the lookup fails.
    static func placeName(latitude: Double, longitude: Double) async -> String? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first
        else { return nil }
        return item.addressRepresentations?.cityWithContext ?? item.name
    }

    /// Adds a place name to a coordinate.
    static func named(_ location: PostLocation) async -> PostLocation {
        var named = location
        named.placeName = await placeName(latitude: location.latitude, longitude: location.longitude)
        return named
    }
}
