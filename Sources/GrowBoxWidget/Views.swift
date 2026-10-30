import AppKit
import CoreText
import SwiftUI

// same palette as the phone app (constants/Colors.ts)
enum Palette {
    static let background = Color(hex: 0x011515)
    static let surface = Color(hex: 0x041C1B)
    static let text = Color(hex: 0xF2F5F4)
    static let textMuted = Color(hex: 0x8A9B9B)
    static let green = Color(hex: 0x00E95A)
    static let blue = Color(hex: 0x78BFFF)
    static let yellow = Color(hex: 0xFFD21C)
    static let purple = Color(hex: 0xB18CFF)
    static let red = Color(hex: 0xFF6070)
    static let border = Color(hex: 0x123333)
    static let off = Color(hex: 0x2A4A3E)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.border, lineWidth: 1))
    }
}

struct WidgetView: View {
    let model: BoxModel

    var body: some View {
        VStack(spacing: 10) {
            header
            SensorCard(model: model)
            ChartCard(model: model)
            StatusCard(model: model)
            FeedingCard(model: model)
        }
        .padding(12)
        .frame(width: 340)
        .background(Palette.background.opacity(0.94), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.border, lineWidth: 1))
    }

    private var header: some View {
        HStack {
            Text("Box Panel").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.text)
            Spacer()
            if model.isSearching {
                Loader(text: "Searching for the box…")
            } else if model.response == nil && model.error == nil {
                Loader(text: "Connecting…")
            } else if let error = model.error {
                Text(error).font(.system(size: 11)).foregroundStyle(Palette.red)
            } else {
                Text(model.isFlowering ? "AUTO" : "MANUAL")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.green)
            }
        }
        .padding(.horizontal, 4)
    }
}

// small spinner plus a label, for the header and the cards
struct Loader: View {
    var text: String?

    var body: some View {
        HStack(spacing: 6) {
            // a turning arc - drawn in SwiftUI, so it also shows in --snapshot
            TimelineView(.animation) { timeline in
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(Palette.green, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(
                        timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360
                    ))
            }
            .frame(width: 12, height: 12)
            if let text {
                Text(text).font(.system(size: 11)).foregroundStyle(Palette.textMuted)
            }
        }
    }
}

struct SensorCard: View {
    let model: BoxModel

    var body: some View {
        Card {
            HStack(spacing: 0) {
                item(
                    icon: model.lightOn ? .sunnyOutline : .moonOutline,
                    color: model.lightOn ? Palette.yellow : Palette.text,
                    value: model.response?.sensor.temperature.map { String(format: "%.1f°C", $0) },
                    label: "Temperature"
                )
                Rectangle().fill(Palette.border).frame(width: 1, height: 34).padding(.horizontal, 10)
                item(
                    icon: .waterOutline,
                    color: Palette.blue,
                    value: model.response?.sensor.humidity.map { String(format: "%.1f%%", $0) },
                    label: "Humidity"
                )
            }
        }
    }

    private func item(icon: Ionicon, color: Color, value: String?, label: String) -> some View {
        HStack(spacing: 10) {
            icon.view(size: 28).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                if value == nil && model.isLoading {
                    Loader().frame(height: 24)
                } else {
                    Text(value ?? "--").font(.system(size: 20, weight: .semibold)).foregroundStyle(Palette.text)
                }
                Text(label).font(.system(size: 11)).foregroundStyle(color == Palette.text ? Palette.textMuted : color)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

struct StatusCard: View {
    let model: BoxModel

    var body: some View {
        Card {
            if model.response == nil {
                // nothing known yet - no "off" fan or empty humidifier
                placeholder.frame(height: 82)
            } else {
                columns
            }
        }
    }

    @ViewBuilder private var placeholder: some View {
        if model.isLoading { Loader() } else { Text("--").foregroundStyle(Palette.textMuted) }
    }

    private var columns: some View {
            HStack(alignment: .top, spacing: 0) {
                if let week = model.floweringWeek {
                    column(label: "Week", detail: "\(Int((week.progress * 100).rounded()))% of week \(week.week)") {
                        Ring(progress: week.progress, color: Palette.green, thin: true) {
                            Text("\(week.week)").font(.system(size: 17, weight: .bold)).foregroundStyle(Palette.green)
                        }
                    }
                    divider
                }

                column(label: "Fan", detail: model.fanOn ? "\(model.fanLevel)%" : "off · \(model.fanSetLevel)%") {
                    Ring(progress: Double(model.fanLevel) / 100, color: Palette.green) {
                        SpinningFan(level: model.fanLevel)
                    }
                }

                if let humidifier = model.response?.status.humidifier {
                    divider
                    humidifierColumn(humidifier)
                }
            }
    }

    private var divider: some View {
        Rectangle().fill(Palette.border).frame(width: 1).frame(maxHeight: .infinity)
    }

    private func humidifierColumn(_ status: HumidifierStatus) -> some View {
        let isOn = status.online && status.on
        let band = model.humidifierBand
        let detail = !status.online
            ? "offline"
            : band.map { $0.enabled ? "\(Int($0.min))–\(Int($0.max))%" : "disabled" } ?? ""

        return column(label: "Humidifier", detail: detail, detailColor: status.online ? Palette.textMuted : Palette.red) {
            Ring(progress: isOn ? 1 : 0, color: Palette.blue) {
                (isOn ? Ionicon.water : .waterOutline)
                    .view(size: 20)
                    .foregroundStyle(isOn ? Palette.blue : Palette.off)
            }
        }
    }

    private func column<Icon: View>(
        label: String,
        detail: String,
        detailColor: Color = Palette.textMuted,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        VStack(spacing: 6) {
            Text(label).font(.system(size: 11)).foregroundStyle(Palette.textMuted)
            icon()
            Text(detail).font(.system(size: 10)).foregroundStyle(detailColor).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

// thin full circle plus a thick arc for the progress; thin: false draws
// the arc at the same width as the track (fan / humidifier)
struct Ring<Center: View>: View {
    let progress: Double
    let color: Color
    var thin = false
    @ViewBuilder let center: Center

    var body: some View {
        ZStack {
            Circle()
                .stroke(thin ? color.opacity(0.5) : Palette.border, lineWidth: thin ? 2 : 4)
            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: thin ? 6 : 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center
        }
        .frame(width: 44, height: 44)
    }
}

// the phone app's fan: three blades + hub (components/FanGauge.tsx, 48 pt
// viewBox), turning faster with the level - 2.4 s per turn near 0 %, 1.08 s
// at 100 %
struct FanBlade: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 48
        var path = Path()
        path.move(to: CGPoint(x: 24 * s, y: 24 * s))
        path.addCurve(
            to: CGPoint(x: 24 * s, y: 4 * s),
            control1: CGPoint(x: 19 * s, y: 17 * s),
            control2: CGPoint(x: 18 * s, y: 7 * s)
        )
        path.addCurve(
            to: CGPoint(x: 24 * s, y: 24 * s),
            control1: CGPoint(x: 31 * s, y: 3 * s),
            control2: CGPoint(x: 32 * s, y: 14 * s)
        )
        path.closeSubpath()
        return path
    }
}

struct SpinningFan: View {
    let level: Int

    var body: some View {
        let color = level == 0 ? Palette.off : Palette.green
        let secondsPerTurn = 2.4 - 1.32 * Double(level) / 100

        TimelineView(.animation(paused: level == 0)) { timeline in
            let angle = level == 0
                ? 0
                : timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: secondsPerTurn) / secondsPerTurn * 360

            ZStack {
                ForEach([0.0, 120.0, 240.0], id: \.self) { blade in
                    FanBlade().fill(color).rotationEffect(.degrees(blade))
                }
                Circle().fill(color).frame(width: 10 * 22 / 48, height: 10 * 22 / 48)
                Circle().fill(Palette.surface).frame(width: 4 * 22 / 48, height: 4 * 22 / 48)
            }
            .frame(width: 22, height: 22)
            .rotationEffect(.degrees(angle))
        }
    }
}

// the phone app's icons (Ionicons via @expo/vector-icons); the font ships in
// Resources/Ionicons.ttf and is registered at launch
enum Ionicon: UInt32 {
    case sunnyOutline = 0xF5AE
    case moonOutline = 0xF461
    case waterOutline = 0xF62F
    case water = 0xF62E
    case leafOutline = 0xF3B3

    static func registerFont() {
        let candidates = [
            Bundle.main.url(forResource: "Ionicons", withExtension: "ttf"),
            // swift run / plain executable: next to the sources
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/Ionicons.ttf"),
        ]

        if let url = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    var glyph: String { String(UnicodeScalar(rawValue)!) }

    func view(size: CGFloat) -> Text {
        Text(glyph).font(.custom("Ionicons", size: size))
    }

    // template image for the menu bar
    func image(size: CGFloat) -> NSImage {
        let font = NSFont(name: "Ionicons", size: size) ?? .systemFont(ofSize: size)
        let text = NSAttributedString(string: glyph, attributes: [.font: font, .foregroundColor: NSColor.black])
        let bounds = text.size()
        let image = NSImage(size: bounds, flipped: false) { _ in
            text.draw(at: .zero)
            return true
        }
        image.isTemplate = true
        return image
    }
}

// last watering like the app's card, without the button: a done badge for
// 24 h after feeding, a yellow frame on day 3 without a feeding, red on day 4
struct FeedingCard: View {
    let model: BoxModel

    var body: some View {
        let loaded = model.response != nil
        let status = model.feedingStatus
        let accent: Color? = !loaded ? nil : status == .overdue ? Palette.red : status == .late ? Palette.yellow : nil

        HStack(spacing: 10) {
            Ionicon.waterOutline.view(size: 22).foregroundStyle(accent ?? Palette.blue)

            VStack(alignment: .leading, spacing: 0) {
                Text("Last fed").font(.system(size: 11)).foregroundStyle(Palette.textMuted)
                if !loaded {
                    if model.isLoading {
                        Loader().frame(height: 21)
                    } else {
                        Text("--").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.text)
                    }
                } else {
                (Text(model.lastFedLabel).font(.system(size: 16, weight: .semibold)).foregroundColor(accent ?? Palette.text)
                    + Text(" · \(model.feedingCount) \(model.feedingCount == 1 ? "feed" : "feeds")")
                        .font(.system(size: 11)).foregroundColor(Palette.textMuted))
                }
            }

            Spacer(minLength: 0)

            if !loaded {
                EmptyView()
            } else if model.fedRecently {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green)
                    Text("Feeded").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.green)
                }
            } else if let accent {
                Text(status == .overdue ? "Feed me now!" : "Time to feed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent ?? Palette.border, lineWidth: 1))
    }
}
