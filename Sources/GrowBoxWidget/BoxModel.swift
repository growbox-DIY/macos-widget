import Foundation
import Observation
import UserNotifications

struct Reading: Identifiable {
    let time: Date
    let temperature: Double
    let humidity: Double

    var id: Date { time }
}

// Polls the ESP: /api/config every 10 s, the climate log every 5 min (the
// ESP writes a reading every 5 min). Gentler than the phone app (5 s) - the
// ESP serves one request at a time and runs short of RAM with several
// clients polling at once.
@MainActor
@Observable
final class BoxModel {
    static let pollInterval: Duration = .seconds(10)
    static let historyInterval: TimeInterval = 5 * 60
    static let historySpan: TimeInterval = 24 * 60 * 60

    var response: ESPResponse?
    var readings: [Reading] = []
    var error: String?
    var lastUpdate: Date?
    // for the loaders: scanning the network for the ESP / loading the 24 h log
    var isSearching = false
    var isSyncingHistory = false

    private var client: ESPClient?
    private var lastHistorySync: Date?
    private var failures = 0
    private var lastDiscovery: Date?

    // where the ESP last answered; overrides the url from widget.json
    private static let urlKey = "espURL"
    private static let failuresBeforeSearch = 3
    private static let discoveryCooldown: TimeInterval = 60

    func start() {
        do {
            let settings = try WidgetSettings.load()
            let url = UserDefaults.standard.string(forKey: Self.urlKey) ?? settings.url
            client = ESPClient(url: url, token: settings.token)
        } catch {
            self.error = "No settings in ~/.config/growbox/widget.json"
            return
        }

        Task {
            while true {
                await poll()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    private func poll() async {
        guard let client else { return }

        do {
            response = try await client.config()
            lastUpdate = Date()
            error = nil
            failures = 0
            alertIfFeedingMissed()
        } catch {
            self.error = "ESP offline"
            failures += 1

            if failures >= Self.failuresBeforeSearch {
                await findESP(client: client)
            }
            return
        }

        let now = Date()

        if lastHistorySync.map({ now.timeIntervalSince($0) >= Self.historyInterval }) ?? true {
            await syncHistory(client: client, now: now)
        }
    }

    private func findESP(client: ESPClient) async {
        if let last = lastDiscovery, Date().timeIntervalSince(last) < Self.discoveryCooldown { return }
        lastDiscovery = Date()
        isSearching = true
        defer { isSearching = false }

        guard let found = await ESPDiscovery.find(near: client.url, token: client.token),
              found != client.url else { return }

        UserDefaults.standard.set(found, forKey: Self.urlKey)
        self.client = ESPClient(url: found, token: client.token)
        failures = 0
    }

    private func syncHistory(client: ESPClient, now: Date) async {
        let windowStart = now.addingTimeInterval(-Self.historySpan)
        let since = readings.last?.time ?? windowStart
        isSyncingHistory = true
        defer { isSyncingHistory = false }

        do {
            let rows = try await client.environment(since: since)
            var byTime = Dictionary(readings.map { ($0.time, $0) }, uniquingKeysWith: { a, _ in a })

            for row in rows {
                guard let time = ESPDate.parse(row.datetime) else { continue }
                byTime[time] = Reading(time: time, temperature: row.temperature, humidity: row.humidity)
            }

            readings = byTime.values
                .filter { $0.time >= windowStart }
                .sorted { $0.time < $1.time }
            lastHistorySync = now
        } catch {
            // keep the old curve, try again on the next poll
        }
    }

    // --- derived values for the views ---

    // nothing from the ESP yet - the first poll or a search is running
    var isLoading: Bool { response == nil && (error == nil || isSearching) }

    var isFlowering: Bool { response?.config.auto.enabled ?? false }

    var lightOn: Bool { (response?.config.relayLight.state ?? 0) == 1 }

    // the dimmer keeps its level while the fan relay is off - show 0 then
    var fanLevel: Int {
        guard fanOn else { return 0 }
        return fanSetLevel
    }

    var fanOn: Bool { (response?.config.relayFan.state ?? 0) == 1 }

    // the level the dimmer is set to, also while the relay keeps the fan off
    var fanSetLevel: Int { max(0, min(100, response?.status.fanLevel ?? 0)) }

    var humidifierBand: HumidifierBand? {
        guard let config = response?.config.humidifier else { return nil }
        return isFlowering ? config.auto : config.manual
    }

    // --- feeding, same rules as hooks/useFeedingStatus.ts in the app ---

    enum FeedingStatus { case ok, late, overdue }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func parseISO(_ value: String) -> Date? {
        isoFormatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    var feedings: [Date] {
        (response?.config.feeding?.history ?? []).compactMap(Self.parseISO).sorted()
    }

    var feedingCount: Int { response?.config.feeding?.count ?? 0 }

    // whole calendar days between two dates
    private func days(from: Date, to: Date) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
    }

    // day 3 without a feeding is late (yellow), day 4 missed (red)
    var feedingStatus: FeedingStatus {
        guard let last = feedings.last else { return .overdue }
        let since = days(from: last, to: Date())

        if since >= 4 { return .overdue }
        if since >= 3 { return .late }
        return .ok
    }

    // red: a notification every 2 h between 8:00 and 22:00 until the plant
    // is fed, like the phone's reminders
    private static let lastAlertKey = "feedingAlertAt"
    private static let alertInterval: TimeInterval = 2 * 60 * 60

    private func alertIfFeedingMissed() {
        // UNUserNotificationCenter needs an app bundle (not `swift run`)
        guard Bundle.main.bundleIdentifier != nil,
              feedingStatus == .overdue, let last = feedings.last else { return }

        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        guard (8...22).contains(hour) else { return }

        let defaults = UserDefaults.standard
        if let sent = defaults.object(forKey: Self.lastAlertKey) as? Date,
           sent > last, now.timeIntervalSince(sent) < Self.alertInterval - 60 { return }
        defaults.set(now, forKey: Self.lastAlertKey)

        let since = days(from: last, to: now)
        let content = UNMutableNotificationContent()
        content.title = "Watering missed"
        content.body = "The plant hasn't been watered for \(since) days. Feed it now!"
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: "feeding-missed", content: content, trigger: nil))
        }
    }

    // fed within the last 24 h - the app shows a done badge then
    var fedRecently: Bool {
        guard let last = feedings.last else { return false }
        return Date().timeIntervalSince(last) < 24 * 60 * 60
    }

    var lastFedLabel: String {
        guard let last = feedings.last else { return "Never" }
        switch days(from: last, to: Date()) {
        case ...0: return "Today"
        case 1: return "Yesterday"
        case let n: return "\(n) days ago"
        }
    }

    // exact start when the ESP has it, else midnight of the start date
    var floweringStart: Date? {
        guard let auto = response?.config.auto, auto.enabled else { return nil }

        if let startedAt = auto.floweringStartedAt, let date = ESPDate.parse(startedAt) {
            return date
        }

        guard let day = auto.floweringStartDate else { return nil }
        return ESPDate.parse(day + " 00:00:00")
    }

    // week 1...10 and how much of it is gone, counted from midnight of the
    // start date like the phone app
    var floweringWeek: (week: Int, progress: Double)? {
        guard let day = response?.config.auto.floweringStartDate,
              isFlowering,
              let start = ESPDate.parse(day + " 00:00:00") else { return nil }

        let weekSeconds: TimeInterval = 7 * 24 * 60 * 60
        let elapsed = max(0, Date().timeIntervalSince(start))
        let week = min(Int(elapsed / weekSeconds) + 1, 10)
        let progress = elapsed >= 10 * weekSeconds
            ? 1
            : elapsed.truncatingRemainder(dividingBy: weekSeconds) / weekSeconds

        return (week, progress)
    }
}
