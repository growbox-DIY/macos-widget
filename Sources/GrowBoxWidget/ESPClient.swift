import Foundation

// Settings live outside the repo: ~/.config/growbox/widget.json
// {"url": "http://192.168.18.85", "token": "..."}
struct WidgetSettings: Decodable {
    let url: String
    let token: String

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/growbox/widget.json")

    static func load() throws -> WidgetSettings {
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(WidgetSettings.self, from: data)
    }
}

// --- /api/config (only the fields the widget shows) ---

struct ESPResponse: Decodable {
    let config: ESPConfig
    let sensor: ESPSensor
    let status: ESPStatus
}

struct ESPSensor: Decodable {
    let temperature: Double?
    let humidity: Double?
}

struct ESPStatus: Decodable {
    let mode: String
    let fanLevel: Int?
    let humidifier: HumidifierStatus?
}

struct HumidifierStatus: Decodable {
    let online: Bool
    let want: Bool
    let on: Bool
}

struct ESPConfig: Decodable {
    let auto: AutoConfig
    let relayLight: Relay
    let relayFan: Relay
    let humidifier: HumidifierConfig?
    let lightSchedule: [LightScheduleItem]
    let feeding: FeedingConfig?
}

struct FeedingConfig: Decodable {
    let lastFedAt: String?
    let count: Int
    let history: [String]?
}

struct Relay: Decodable {
    let state: Int
}

struct AutoConfig: Decodable {
    let enabled: Bool
    let floweringStartDate: String?
    let floweringStartedAt: String?
}

struct HumidifierBand: Decodable {
    let enabled: Bool
    let min: Double
    let max: Double
}

struct HumidifierConfig: Decodable {
    let manual: HumidifierBand
    let auto: HumidifierBand
}

struct LightScheduleItem: Decodable {
    let on: String
    let off: String
}

// --- /api/environment ---

struct EnvironmentRow: Decodable {
    let datetime: String
    let temperature: Double
    let humidity: Double
}

struct EnvironmentPage: Decodable {
    let data: [EnvironmentRow]
    let has_more: Bool?
    let next_since: String?
}

enum ESPDate {
    // the ESP logs local time as "YYYY-MM-DD HH:MM:SS"
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func parse(_ value: String) -> Date? {
        formatter.date(from: value)
    }

    static func format(_ date: Date) -> String {
        formatter.string(from: date)
    }
}

struct ESPClient {
    let url: String
    let token: String

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(string: url + path)!
        if !query.isEmpty { components.queryItems = query }

        var request = URLRequest(url: components.url!, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func config() async throws -> ESPResponse {
        try await get("/api/config")
    }

    // readings since a time, following the ESP's 100-row pages
    func environment(since: Date) async throws -> [EnvironmentRow] {
        var rows: [EnvironmentRow] = []
        var cursor = ESPDate.format(since)

        for _ in 0..<20 {
            let page: EnvironmentPage = try await get(
                "/api/environment",
                [URLQueryItem(name: "since", value: cursor), URLQueryItem(name: "limit", value: "100")]
            )
            rows += page.data

            guard page.has_more == true, let next = page.next_since, next != cursor else { break }
            cursor = next
            // a breather between pages, like the app - the ESP reads them
            // from the SD card one at a time
            try await Task.sleep(for: .seconds(1))
        }

        return rows
    }
}

// After a router reset the ESP may come back under a new IP (DHCP). Scan
// the known address' /24, nearest first, for something that answers
// /api/config like the ESP.
enum ESPDiscovery {
    static func find(near url: String, token: String) async -> String? {
        guard let components = URLComponents(string: url),
              let host = components.host else { return nil }

        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return nil }

        let prefix = octets[0..<3].map(String.init).joined(separator: ".")
        let hosts = (1...254)
            .filter { $0 != octets[3] }
            .sorted { abs($0 - octets[3]) < abs($1 - octets[3]) }

        let session = URLSession(configuration: {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 1.5
            return config
        }())

        func candidate(_ last: Int) -> String {
            var copy = components
            copy.host = "\(prefix).\(last)"
            return copy.string ?? url
        }

        func probe(_ base: String) async -> Bool {
            guard let probeURL = URL(string: base + "/api/config") else { return false }
            var request = URLRequest(url: probeURL)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            return (try? JSONDecoder().decode(ESPResponse.self, from: data)) != nil
        }

        return await withTaskGroup(of: String?.self) { group in
            var index = 0
            let parallel = 24

            for _ in 0..<parallel where index < hosts.count {
                let base = candidate(hosts[index])
                index += 1
                group.addTask { await probe(base) ? base : nil }
            }

            while let result = await group.next() {
                if let result {
                    group.cancelAll()
                    return result
                }
                if index < hosts.count {
                    let base = candidate(hosts[index])
                    index += 1
                    group.addTask { await probe(base) ? base : nil }
                }
            }
            return nil
        }
    }
}
