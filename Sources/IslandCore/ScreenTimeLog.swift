import Foundation

/// Brim's own screen time: seconds per app and per hour for each day, counted while an app is in
/// front and you're not idle. Apple doesn't let apps read Screen Time, so this starts empty.
public struct ScreenTimeLog: Codable, Equatable, Sendable {
    public struct Day: Codable, Equatable, Sendable {
        /// Bundle ID → seconds.
        public var apps: [String: Double] = [:]
        /// Hour of day (0–23) → seconds.
        public var hours: [Int: Double] = [:]

        public var total: Double { apps.values.reduce(0, +) }
    }

    /// "yyyy-MM-dd" → day.
    public var days: [String: Day] = [:]
    /// Bundle ID → app name, as last seen.
    public var names: [String: String] = [:]
    public var startedAt: Date?

    public init() {}

    /// Adds time to an app, split across the hours it spans.
    public mutating func add(seconds: Double, app: String, name: String, endingAt end: Date, calendar: Calendar = .current) {
        guard seconds > 0 else { return }
        if startedAt == nil { startedAt = end.addingTimeInterval(-seconds) }
        names[app] = name
        var remaining = seconds
        var cursor = end
        while remaining > 0 {
            let hourStart = calendar.dateInterval(of: .hour, for: cursor.addingTimeInterval(-0.001))?.start ?? cursor
            let chunk = min(remaining, cursor.timeIntervalSince(hourStart))
            let take = chunk > 0 ? chunk : remaining
            let key = QuotaHistory.key(for: cursor.addingTimeInterval(-0.001), calendar: calendar)
            let hour = calendar.component(.hour, from: cursor.addingTimeInterval(-0.001))
            var day = days[key] ?? Day()
            day.apps[app, default: 0] += take
            day.hours[hour, default: 0] += take
            days[key] = day
            remaining -= take
            cursor = cursor.addingTimeInterval(-take)
        }
        prune(keeping: 35)
    }

    public func day(_ date: Date, calendar: Calendar = .current) -> Day {
        days[QuotaHistory.key(for: date, calendar: calendar)] ?? Day()
    }

    /// The last seven days, oldest first, with their short weekday names.
    public func week(endingOn date: Date = Date(), calendar: Calendar = .current) -> [(label: String, day: Day)] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return (0..<7).reversed().map { back in
            let d = calendar.date(byAdding: .day, value: -back, to: date) ?? date
            return (formatter.string(from: d), day(d, calendar: calendar))
        }
    }

    /// Apps by time, longest first, summed over the given days.
    public func topApps(_ days: [Day], limit: Int = 6) -> [(id: String, name: String, seconds: Double)] {
        var totals: [String: Double] = [:]
        for day in days { for (app, seconds) in day.apps { totals[app, default: 0] += seconds } }
        return totals.sorted { $0.value > $1.value }.prefix(limit).map { ($0.key, names[$0.key] ?? $0.key, $0.value) }
    }

    mutating func prune(keeping count: Int) {
        guard days.count > count else { return }
        for key in days.keys.sorted().prefix(days.count - count) { days[key] = nil }
    }
}

// MARK: - Weather

/// A forecast from Open-Meteo (open data, no key). WeatherKit can replace the provider later.
public struct Forecast: Codable, Equatable, Sendable {
    public struct Current: Codable, Equatable, Sendable {
        public var temperature: Double
        public var feelsLike: Double
        public var humidity: Double
        public var windSpeed: Double
        public var uvIndex: Double
        public var code: Int
        public var isDay: Bool
        /// Degrees the wind comes from (0 = north).
        public var windDirection: Double?
        /// US AQI, from Open-Meteo's air-quality service.
        public var airQuality: Int?
        /// Millimetres of rain or snow in the last hour.
        public var precipitation: Double?

        public init(temperature: Double, feelsLike: Double, humidity: Double, windSpeed: Double, uvIndex: Double, code: Int, isDay: Bool,
                    windDirection: Double? = nil, airQuality: Int? = nil, precipitation: Double? = nil) {
            self.temperature = temperature
            self.feelsLike = feelsLike
            self.humidity = humidity
            self.windSpeed = windSpeed
            self.uvIndex = uvIndex
            self.code = code
            self.isDay = isDay
            self.windDirection = windDirection
            self.airQuality = airQuality
            self.precipitation = precipitation
        }
    }

    public struct Hour: Codable, Equatable, Sendable {
        public var time: Date
        public var temperature: Double
        public var code: Int
        public var precipitation: Double

        public init(time: Date, temperature: Double, code: Int, precipitation: Double) {
            self.time = time
            self.temperature = temperature
            self.code = code
            self.precipitation = precipitation
        }
    }

    public struct Day: Codable, Equatable, Sendable {
        public var date: Date
        public var high: Double
        public var low: Double
        public var code: Int
        public var precipitation: Double
        public var sunrise: Date?
        public var sunset: Date?

        public init(date: Date, high: Double, low: Double, code: Int, precipitation: Double, sunrise: Date?, sunset: Date?) {
            self.date = date
            self.high = high
            self.low = low
            self.code = code
            self.precipitation = precipitation
            self.sunrise = sunrise
            self.sunset = sunset
        }
    }

    public var current: Current
    public var hours: [Hour]
    public var days: [Day]
    public var fetchedAt: Date
    public var place: String

    public init(current: Current, hours: [Hour], days: [Day], fetchedAt: Date, place: String) {
        self.current = current
        self.hours = hours
        self.days = days
        self.fetchedAt = fetchedAt
        self.place = place
    }

    /// The 24 hours of one day (local to the place), for the day chart.
    public func hours(on day: Date, calendar: Calendar = .current) -> [Hour] {
        hours.filter { calendar.isDate($0.time, inSameDayAs: day) }
    }

    /// The next hours starting with the current one.
    public func upcomingHours(_ count: Int = 7, now: Date = Date()) -> [Hour] {
        let start = hours.firstIndex { $0.time.addingTimeInterval(3600) > now } ?? 0
        return Array(hours.dropFirst(start).prefix(count))
    }
}

public enum OpenMeteo {
    public static func forecastURL(latitude: Double, longitude: Double, fahrenheit: Bool) -> URL? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.3f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.3f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,wind_direction_10m,uv_index,is_day,precipitation"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "7"),
            URLQueryItem(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
            URLQueryItem(name: "wind_speed_unit", value: fahrenheit ? "mph" : "kmh"),
        ]
        return components?.url
    }

    /// Current US AQI and PM2.5 (https://open-meteo.com/en/docs/air-quality-api).
    public static func airQualityURL(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents(string: "https://air-quality-api.open-meteo.com/v1/air-quality")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.3f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.3f", longitude)),
            URLQueryItem(name: "current", value: "us_aqi,pm2_5"),
        ]
        return components?.url
    }

    public static func parseAirQuality(_ data: Data) -> Int? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let current = json["current"] as? [String: Any],
              let aqi = (current["us_aqi"] as? NSNumber)?.doubleValue else { return nil }
        return Int(aqi.rounded())
    }

    /// US AQI bands.
    public static func airQualityText(_ aqi: Int) -> String {
        switch aqi {
        case ..<51: return "Good"
        case ..<101: return "Moderate"
        case ..<151: return "Poor for some"
        case ..<201: return "Unhealthy"
        case ..<301: return "Very unhealthy"
        default: return "Hazardous"
        }
    }

    /// 0° → "N", 225° → "SW".
    public static func compass(_ degrees: Double) -> String {
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((degrees.truncatingRemainder(dividingBy: 360) + 360 + 22.5) / 45) % 8
        return points[index]
    }

    public static func searchURL(_ query: String) -> URL? {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        components?.queryItems = [URLQueryItem(name: "name", value: query), URLQueryItem(name: "count", value: "6"),
                                  URLQueryItem(name: "language", value: "en"), URLQueryItem(name: "format", value: "json")]
        return components?.url
    }

    public struct Place: Codable, Equatable, Sendable, Identifiable {
        public var name: String
        public var region: String
        public var latitude: Double
        public var longitude: Double
        public var id: String { "\(name)|\(latitude)|\(longitude)" }

        public init(name: String, region: String, latitude: Double, longitude: Double) {
            self.name = name
            self.region = region
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    public static func parsePlaces(_ data: Data) -> [Place] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { item in
            guard let name = item["name"] as? String, let lat = item["latitude"] as? Double, let lon = item["longitude"] as? Double else { return nil }
            let region = [item["admin1"] as? String, item["country"] as? String].compactMap { $0 }.joined(separator: ", ")
            return Place(name: name, region: region, latitude: lat, longitude: lon)
        }
    }

    /// Reads Open-Meteo's response. Times are local to the place (`timezone=auto`).
    public static func parse(_ data: Data, place: String, now: Date = Date()) -> Forecast? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let current = json["current"] as? [String: Any],
              let hourly = json["hourly"] as? [String: Any],
              let daily = json["daily"] as? [String: Any] else { return nil }
        let offset = json["utc_offset_seconds"] as? Int ?? 0
        let zone = TimeZone(secondsFromGMT: offset) ?? .current
        let minute = DateFormatter()
        minute.locale = Locale(identifier: "en_US_POSIX")
        minute.timeZone = zone
        minute.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = zone
        day.dateFormat = "yyyy-MM-dd"

        func doubles(_ object: [String: Any], _ key: String) -> [Double] {
            (object[key] as? [Any] ?? []).map { ($0 as? NSNumber)?.doubleValue ?? 0 }
        }
        func ints(_ object: [String: Any], _ key: String) -> [Int] {
            (object[key] as? [Any] ?? []).map { ($0 as? NSNumber)?.intValue ?? 0 }
        }
        func number(_ key: String) -> Double { (current[key] as? NSNumber)?.doubleValue ?? 0 }

        let now = Forecast.Current(temperature: number("temperature_2m"), feelsLike: number("apparent_temperature"),
                                   humidity: number("relative_humidity_2m"), windSpeed: number("wind_speed_10m"),
                                   uvIndex: number("uv_index"), code: Int(number("weather_code")), isDay: number("is_day") != 0,
                                   windDirection: current["wind_direction_10m"] == nil ? nil : number("wind_direction_10m"),
                                   precipitation: current["precipitation"] == nil ? nil : number("precipitation"))
        let hourTimes = (hourly["time"] as? [String] ?? []).map { minute.date(from: $0) }
        let hourTemps = doubles(hourly, "temperature_2m"), hourCodes = ints(hourly, "weather_code")
        let hourRain = doubles(hourly, "precipitation_probability")
        var hours: [Forecast.Hour] = []
        for (index, time) in hourTimes.enumerated() {
            guard let time, index < hourTemps.count, index < hourCodes.count else { continue }
            hours.append(Forecast.Hour(time: time, temperature: hourTemps[index], code: hourCodes[index],
                                       precipitation: index < hourRain.count ? hourRain[index] : 0))
        }
        let dayTimes = (daily["time"] as? [String] ?? []).map { day.date(from: $0) }
        let highs = doubles(daily, "temperature_2m_max"), lows = doubles(daily, "temperature_2m_min")
        let codes = ints(daily, "weather_code"), rain = doubles(daily, "precipitation_probability_max")
        let sunrise = (daily["sunrise"] as? [String] ?? []).map { minute.date(from: $0) }
        let sunset = (daily["sunset"] as? [String] ?? []).map { minute.date(from: $0) }
        var days: [Forecast.Day] = []
        for (index, date) in dayTimes.enumerated() {
            guard let date, index < highs.count, index < lows.count, index < codes.count else { continue }
            days.append(Forecast.Day(date: date, high: highs[index], low: lows[index], code: codes[index],
                                     precipitation: index < rain.count ? rain[index] : 0,
                                     sunrise: index < sunrise.count ? sunrise[index] : nil,
                                     sunset: index < sunset.count ? sunset[index] : nil))
        }
        guard !days.isEmpty else { return nil }
        return Forecast(current: now, hours: hours, days: days, fetchedAt: Date(), place: place)
    }

    /// WMO weather code → short words.
    public static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55, 56, 57: return "Drizzle"
        case 61, 63, 66: return "Rain"
        case 65, 67: return "Heavy rain"
        case 71, 73, 75, 77: return "Snow"
        case 80, 81: return "Showers"
        case 82: return "Heavy showers"
        case 85, 86: return "Snow showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm, hail"
        default: return "Cloudy"
        }
    }

    /// WMO weather code → SF Symbol.
    public static func symbol(_ code: Int, isDay: Bool = true) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 65, 66, 67, 80, 81, 82: return "cloud.rain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
}

// MARK: - Meetings

public enum MeetingLink {
    /// The first video-call link in an event's URL, location or notes (Meet, Zoom, Teams, Webex, …).
    public static func find(in texts: [String?]) -> URL? {
        let hosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com", "meet.jit.si", "around.co", "facetime.apple.com"]
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in texts.compactMap({ $0 }) {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, range: range) {
                guard let url = match.url, let host = url.host?.lowercased() else { continue }
                if hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
            }
        }
        return nil
    }

    /// "Google Meet", "Zoom"… for the event line.
    public static func service(_ url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        if host.contains("meet.google") { return "Google Meet" }
        if host.contains("zoom") { return "Zoom" }
        if host.contains("teams") { return "Teams" }
        if host.contains("webex") { return "Webex" }
        if host.contains("facetime") { return "FaceTime" }
        return "Video call"
    }
}
