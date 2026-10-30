import SwiftUI

// optimal ranges, same as data/growTargets.ts in the phone app
struct Range { let min: Double; let max: Double }
struct Targets { let temperature: Range; let humidity: Range }

enum GrowTargets {
    static let veg = Targets(temperature: Range(min: 24, max: 27), humidity: Range(min: 52, max: 62))
    static let flowerOn = Targets(temperature: Range(min: 22, max: 26), humidity: Range(min: 40, max: 55))
    static let flowerOff = Targets(temperature: Range(min: 18, max: 22), humidity: Range(min: 40, max: 55))
}

// last 24 h: temperature and humidity on their own fixed scales, target
// bands behind them (veg before the flowering start, flowering by the light
// schedule after it) and a dashed line where flowering began
struct ChartCard: View {
    let model: BoxModel

    // down to 15 °C like the app: early mornings with the lights off get that cold
    private static let temperatureScale = Range(min: 15, max: 30)
    private static let humidityScale = Range(min: 30, max: 90)
    private static let span: TimeInterval = 24 * 60 * 60
    private static let bandStep: TimeInterval = 5 * 60

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    legend(Palette.yellow, "Temp")
                    legend(Palette.blue, "Humidity")
                    if model.floweringStart != nil { legend(Palette.purple, "Flower") }
                    Spacer()
                    Text("24 h").font(.system(size: 10)).foregroundStyle(Palette.textMuted)
                }

                Canvas { context, size in draw(context, size) }
                    .frame(height: 90)
                    // readings outside the fixed scales must not spill over the card
                    .clipped()
                    .overlay(alignment: .topLeading) { scaleLabel("30°", Palette.yellow) }
                    .overlay(alignment: .bottomLeading) { scaleLabel("15°", Palette.yellow) }
                    .overlay(alignment: .topTrailing) { scaleLabel("90%", Palette.blue) }
                    .overlay(alignment: .bottomTrailing) { scaleLabel("30%", Palette.blue) }
                    .overlay {
                        if model.readings.isEmpty && (model.isLoading || model.isSyncingHistory) {
                            Loader(text: "Loading 24 h history…")
                        }
                    }
            }
        }
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 10, height: 2)
            Text(label).font(.system(size: 10)).foregroundStyle(Palette.textMuted)
        }
    }

    private func scaleLabel(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 9)).foregroundStyle(color.opacity(0.8)).padding(2)
    }

    private func targets(at time: Date) -> Targets {
        guard let start = model.floweringStart, time >= start else { return GrowTargets.veg }
        return isLightOn(time) ? GrowTargets.flowerOn : GrowTargets.flowerOff
    }

    private func isLightOn(_ time: Date) -> Bool {
        guard let item = model.response?.config.lightSchedule.first else { return true }

        func minutes(_ value: String) -> Int {
            let parts = value.split(separator: ":").compactMap { Int($0) }
            return (parts.first ?? 0) * 60 + (parts.dropFirst().first ?? 0)
        }

        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let now = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let on = minutes(item.on)
        let off = minutes(item.off)

        return on < off ? (now >= on && now < off) : (now >= on || now < off)
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize) {
        let end = model.readings.last?.time ?? Date()
        let start = end.addingTimeInterval(-Self.span)

        func x(_ time: Date) -> CGFloat {
            CGFloat(time.timeIntervalSince(start) / Self.span) * size.width
        }

        func y(_ value: Double, _ scale: Range) -> CGFloat {
            size.height - CGFloat((value - scale.min) / (scale.max - scale.min)) * size.height
        }

        // target bands: 5-min steps merged into stretches with the same
        // targets, so the translucent fills don't overlap into stripes
        var stretches: [(from: Date, to: Date, band: Targets)] = []
        var time = start
        while time < end {
            let next = min(time.addingTimeInterval(Self.bandStep), end)
            let band = targets(at: time)

            if let last = stretches.last, last.band.temperature.min == band.temperature.min,
               last.band.humidity.min == band.humidity.min {
                stretches[stretches.count - 1].to = next
            } else {
                stretches.append((time, next, band))
            }
            time = next
        }

        for stretch in stretches {
            let left = x(stretch.from)
            let width = x(stretch.to) - left

            let hTop = y(stretch.band.humidity.max, Self.humidityScale)
            context.fill(
                Path(CGRect(x: left, y: hTop, width: width, height: y(stretch.band.humidity.min, Self.humidityScale) - hTop)),
                with: .color(Palette.blue.opacity(0.1))
            )
            let tTop = y(stretch.band.temperature.max, Self.temperatureScale)
            context.fill(
                Path(CGRect(x: left, y: tTop, width: width, height: y(stretch.band.temperature.min, Self.temperatureScale) - tTop)),
                with: .color(Palette.yellow.opacity(0.14))
            )
        }

        // grid every 6 h
        var mark = Calendar.current.dateInterval(of: .hour, for: start)?.end ?? start
        while mark < end {
            if Calendar.current.component(.hour, from: mark) % 6 == 0 {
                var line = Path()
                line.move(to: CGPoint(x: x(mark), y: 0))
                line.addLine(to: CGPoint(x: x(mark), y: size.height))
                context.stroke(line, with: .color(Palette.border), lineWidth: 1)
            }
            mark.addTimeInterval(3600)
        }

        // flowering start
        if let flower = model.floweringStart, flower > start, flower <= end {
            var line = Path()
            line.move(to: CGPoint(x: x(flower), y: 0))
            line.addLine(to: CGPoint(x: x(flower), y: size.height))
            context.stroke(line, with: .color(Palette.purple), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
        }

        // every 4th reading (20 min), counted back from the newest, like the
        // phone app - the raw 5-min log is too jumpy at this size
        let all = model.readings.filter { $0.time >= start }
        let points = all.enumerated()
            .filter { (all.count - 1 - $0.offset) % 4 == 0 }
            .map(\.element)

        func curve(_ value: (Reading) -> Double, _ scale: Range) -> Path {
            var path = Path()
            for (index, reading) in points.enumerated() {
                let point = CGPoint(x: x(reading.time), y: y(value(reading), scale))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            return path
        }

        context.stroke(curve({ $0.humidity }, Self.humidityScale), with: .color(Palette.blue), lineWidth: 1.3)
        context.stroke(curve({ $0.temperature }, Self.temperatureScale), with: .color(Palette.yellow), lineWidth: 1.3)
    }
}
