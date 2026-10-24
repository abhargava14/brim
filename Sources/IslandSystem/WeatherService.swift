import Combine
import CoreLocation
import Foundation
import IslandCore

/// Where forecasts come from. Open-Meteo today; WeatherKit once there's a paid developer account.
public protocol WeatherProvider: Sendable {
    func forecast(latitude: Double, longitude: Double, place: String, fahrenheit: Bool) async throws -> Forecast
    func search(_ query: String) async throws -> [OpenMeteo.Place]
}

public enum WeatherError: LocalizedError {
    case badResponse

    public var errorDescription: String? { "The weather service didn't answer." }
}

/// Open-Meteo: open data, no account, no key.
public struct OpenMeteoProvider: WeatherProvider {
    public init() {}

    public func forecast(latitude: Double, longitude: Double, place: String, fahrenheit: Bool) async throws -> Forecast {
        guard let url = OpenMeteo.forecastURL(latitude: latitude, longitude: longitude, fahrenheit: fahrenheit) else { throw WeatherError.badResponse }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, var forecast = OpenMeteo.parse(data, place: place) else { throw WeatherError.badResponse }
        // Air quality is a separate service; the forecast still shows without it.
        if let airURL = OpenMeteo.airQualityURL(latitude: latitude, longitude: longitude),
           let (airData, _) = try? await URLSession.shared.data(from: airURL) {
            forecast.current.airQuality = OpenMeteo.parseAirQuality(airData)
        }
        return forecast
    }

    public func search(_ query: String) async throws -> [OpenMeteo.Place] {
        guard let url = OpenMeteo.searchURL(query) else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        return OpenMeteo.parsePlaces(data)
    }
}

/// The forecast for where you are (city-level location) or for a city you picked.
@MainActor
public final class WeatherService: NSObject, ObservableObject, CLLocationManagerDelegate {
    public struct Saved: Codable {
        var place: OpenMeteo.Place?
        var useLocation: Bool
        var fahrenheit: Bool
        var forecast: Forecast?
        /// Cities kept as pills, newest last.
        var places: [OpenMeteo.Place]?
    }

    /// How many cities stay saved as pills.
    public static let placeLimit = 5

    @Published public private(set) var forecast: Forecast?
    @Published public private(set) var access: Access = .notAsked
    @Published public private(set) var failed = false
    @Published public private(set) var loading = false
    @Published public private(set) var place: OpenMeteo.Place?
    @Published public private(set) var useLocation = false
    /// Saved cities, shown as pills to switch between.
    @Published public private(set) var places: [OpenMeteo.Place] = []
    /// Last forecast per place ("here" for your location), so switching is instant.
    private var cache: [String: Forecast] = [:]
    @Published public var fahrenheit = false {
        didSet { if oldValue != fahrenheit { save(); refresh() } }
    }

    private let provider: WeatherProvider
    private let manager = CLLocationManager()
    private let file: JSONFile<Saved>
    private var timer: Timer?
    private var located: CLLocation?
    private let persist: Bool

    public init(provider: WeatherProvider = OpenMeteoProvider(), directory: URL = JSONFile<Saved>.supportDirectory, persist: Bool = true) {
        self.provider = provider
        self.persist = persist
        file = JSONFile("weather.json", directory: directory)
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        if let saved = file.load() {
            place = saved.place
            useLocation = saved.useLocation
            fahrenheit = saved.fahrenheit
            forecast = saved.forecast
            places = saved.places ?? saved.place.map { [$0] } ?? []
            if let forecast { cache[cacheKey] = forecast }
        } else {
            fahrenheit = Locale.current.measurementSystem == .us
        }
        updateAccess()
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if configured { refresh() }
    }

    /// A city or allowed location is set.
    public var configured: Bool { place != nil || (useLocation && access == .allowed) }

    /// The forecast is older than an hour (shown with a banner).
    public var stale: Bool { failed && forecast != nil }

    private func updateAccess() {
        switch manager.authorizationStatus {
        case .notDetermined: access = canAsk("NSLocationUsageDescription") || canAsk("NSLocationWhenInUseUsageDescription") ? .notAsked : .unavailable
        case .denied, .restricted: access = .denied
        default: access = .allowed
        }
    }

    public func useMyLocation() {
        useLocation = true
        save()
        updateAccess()
        switch access {
        case .notAsked: manager.requestWhenInUseAuthorization()
        case .allowed: manager.requestLocation()
        default: break
        }
    }

    public func choose(_ place: OpenMeteo.Place) {
        if !places.contains(where: { $0.id == place.id }) {
            places.append(place)
            if places.count > Self.placeLimit { places.removeFirst(places.count - Self.placeLimit) }
        }
        select(place)
    }

    /// Switches to a saved city (or to your location with nil), showing its last forecast at once.
    public func select(_ place: OpenMeteo.Place?) {
        if let place {
            self.place = place
            useLocation = false
        } else {
            useLocation = true
            updateAccess()
            if access == .notAsked { manager.requestWhenInUseAuthorization() }
        }
        if let cached = cache[cacheKey] { forecast = cached }
        save()
        refresh()
    }

    public func removePlace(_ place: OpenMeteo.Place) {
        places.removeAll { $0.id == place.id }
        cache[place.id] = nil
        if self.place?.id == place.id {
            if let next = places.last { select(next) } else { self.place = nil; save() }
        } else {
            save()
        }
    }

    /// Whether the pill for this place (nil = your location) is the one showing.
    public func isShowing(_ place: OpenMeteo.Place?) -> Bool {
        place == nil ? useLocation : (!useLocation && self.place?.id == place?.id)
    }

    private var cacheKey: String { useLocation ? "here" : place?.id ?? "" }

    public func search(_ query: String) async -> [OpenMeteo.Place] {
        (try? await provider.search(query)) ?? []
    }

    public func refresh() {
        if useLocation, access == .allowed {
            if let located { fetch(latitude: located.coordinate.latitude, longitude: located.coordinate.longitude, name: forecast?.place ?? "Here") }
            manager.requestLocation()
        } else if let place {
            fetch(latitude: place.latitude, longitude: place.longitude, name: place.name)
        }
    }

    private func fetch(latitude: Double, longitude: Double, name: String) {
        loading = true
        let provider = self.provider, fahrenheit = self.fahrenheit, key = cacheKey
        Task {
            do {
                let next = try await provider.forecast(latitude: latitude, longitude: longitude, place: name, fahrenheit: fahrenheit)
                cache[key] = next
                // A switch may have happened while this was loading.
                if key == cacheKey { forecast = next }
                failed = false
            } catch {
                failed = true
            }
            loading = false
            save()
        }
    }

    private func save() {
        guard persist else { return }
        file.save(Saved(place: place, useLocation: useLocation, fahrenheit: fahrenheit, forecast: forecast, places: places))
    }

    // MARK: CLLocationManagerDelegate

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.updateAccess()
            if self.useLocation, self.access == .allowed { self.manager.requestLocation() }
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.located = location
            let geocoder = CLGeocoder()
            let marks = try? await geocoder.reverseGeocodeLocation(location)
            let name = marks?.first?.locality ?? marks?.first?.name ?? "Here"
            self.fetch(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, name: name)
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.failed = self.forecast != nil }
    }

    /// Fixture data for snapshot renders.
    public func loadSample() {
        let calendar = Calendar.current
        let now = Date()
        let midnight = calendar.startOfDay(for: now)
        let temps: [Double] = [13, 12.5, 12, 12, 11.5, 11, 11, 12, 13, 14.5, 16, 17.5, 18.5, 19.5, 20.5, 21, 20.5, 19.5, 18, 16.5, 15.5, 14.5, 14, 13.5]
        let hours = (0..<(24 * 7)).map { i in
            let hour = i % 24, day = i / 24
            return Forecast.Hour(time: calendar.date(byAdding: .hour, value: i, to: midnight)!,
                                 temperature: temps[hour] + Double([0, -3, -2, 0, 1, 2, 0][day]),
                                 code: day == 1 && (8..<18).contains(hour) ? 61 : [1, 2, 2, 3, 3, 2, 2, 1, 1, 2, 2, 3, 3, 3, 2, 2, 1, 1, 1, 0, 0, 0, 0, 0][hour],
                                 precipitation: day == 1 ? [0, 0, 5, 10, 20, 30, 50, 70, 80, 80, 75, 60, 55, 50, 40, 30, 20, 10, 5, 5, 0, 0, 0, 0][hour]
                                     : [0, 0, 0, 0, 0, 5, 5, 10, 10, 15, 20, 25, 30, 30, 25, 20, 10, 5, 0, 0, 0, 0, 0, 0][hour])
        }
        let days = (0..<7).map { i in
            Forecast.Day(date: calendar.date(byAdding: .day, value: i, to: calendar.startOfDay(for: now))!,
                         high: [21, 17, 18, 20, 22, 23, 21][i], low: [13, 12, 12, 13, 14, 14, 13][i],
                         code: [2, 61, 3, 0, 0, 1, 2][i], precipitation: [10, 80, 30, 0, 0, 5, 10][i],
                         sunrise: calendar.date(bySettingHour: 7, minute: 21, second: 0, of: now),
                         sunset: calendar.date(bySettingHour: 18, minute: 29, second: 0, of: now))
        }
        forecast = Forecast(current: .init(temperature: 18, feelsLike: 17, humidity: 71, windSpeed: 12, uvIndex: 3, code: 2, isDay: true,
                                           windDirection: 250, airQuality: 38, precipitation: 0),
                            hours: hours, days: days, fetchedAt: now.addingTimeInterval(-240), place: "San Francisco")
        place = OpenMeteo.Place(name: "San Francisco", region: "California, United States", latitude: 37.77, longitude: -122.42)
        places = [place!, OpenMeteo.Place(name: "London", region: "England, United Kingdom", latitude: 51.51, longitude: -0.13),
                  OpenMeteo.Place(name: "Bengaluru", region: "Karnataka, India", latitude: 12.97, longitude: 77.59)]
        access = .allowed
    }
}
