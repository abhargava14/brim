import IslandCore
import SwiftUI

/// Clocks: your time plus up to three cities, each with an analog face, its offset and whether
/// people there are likely working. Drag the planner to see every clock at another time.
struct ClocksTabView: View {
    @ObservedObject var store: ClocksStore
    @State private var shift: Double = 0
    @State private var adding = false
    @State private var query = ""
    @Environment(\.islandTheme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let date = context.date.addingTimeInterval(shift * 3600)
                HStack(spacing: 10) {
                    tile(nil, date: date)
                    ForEach(store.clocks) { clock in tile(clock, date: date) }
                    if store.canAdd { addTile }
                }
            }
            planner
        }
    }

    // MARK: Tiles

    private func tile(_ clock: WorldClock?, date: Date) -> some View {
        let zone = clock?.timeZone ?? .current
        let hours = WorldClocks.hours(in: zone, at: date)
        return IslandCard(padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text(clock?.label ?? "Here").font(.brim(13)).lineLimit(1)
                    Spacer(minLength: 4)
                    if clock == nil {
                        Image(systemName: "location.fill").font(.system(size: 9, weight: .bold)).opacity(0.45)
                            .accessibilityLabel("Your time")
                    } else if let clock {
                        IconButton(symbol: "xmark", help: "Remove \(clock.label)", size: 20) { store.remove(clock.id) }
                    }
                }
                .frame(height: 20)
                .help(clock?.zone ?? TimeZone.current.identifier)
                AnalogClock(date: date, zone: zone)
                    .frame(width: 112, height: 112)
                    .padding(.top, 12)
                Text(Self.time(date, zone: zone)).font(.brim(24)).monospacedDigit().padding(.top, 12)
                Text(clock == nil ? Self.day(date, zone: zone)
                     : "\(WorldClocks.dayText(zone, base: .current, at: date)) · \(WorldClocks.offsetText(WorldClocks.offset(zone, from: .current, at: date)))")
                    .font(.brim(11, .bold)).foregroundStyle(theme.f(0.5)).padding(.top, 2)
                HStack(spacing: 5) {
                    Circle().fill(hours == .working ? theme.fg : hours == .evening ? theme.f(0.45) : theme.f(0.2)).frame(width: 6, height: 6)
                    Text(hours.title).font(.brim(11, .bold)).foregroundStyle(theme.f(0.6))
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
        }
        .contextMenu {
            if let clock {
                Button("Move left") { store.move(clock.id, by: -1) }
                Button("Move right") { store.move(clock.id, by: 1) }
                Divider()
                Button("Remove", role: .destructive) { store.remove(clock.id) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var addTile: some View {
        IslandCard(padding: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)) {
            if adding {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        IslandField(placeholder: "City", text: $query, symbol: "magnifyingglass", height: 28, fontSize: 12) {
                            if let first = WorldClocks.search(query).first { pick(first) }
                        }
                        IconButton(symbol: "xmark", help: "Cancel", size: 24) { adding = false; query = "" }
                    }
                    ForEach(WorldClocks.search(query, limit: 5)) { result in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(result.label).font(.brim(12))
                            Text(WorldClocks.offsetText(WorldClocks.offset(result.timeZone, from: .current, at: Date())) + " · " + result.zone)
                                .font(.brim(10, .bold)).foregroundStyle(theme.f(0.45)).lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                        .hoverFill(9, hover: theme.f(0.1))
                        .onTapGesture { pick(result) }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 18, weight: .semibold))
                    Text("Add a city").font(.brim(12.5))
                    Text("Up to \(WorldClocks.limit) next to yours").font(.brim(11, .bold)).foregroundStyle(theme.f(0.45))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { adding = true }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
            }
        }
    }

    private func pick(_ clock: WorldClock) {
        store.add(clock)
        adding = false
        query = ""
    }

    // MARK: Planner

    private var planner: some View {
        IslandCard(padding: EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionTitle(title: "Plan a time")
                    Text(shift == 0 ? "Drag to move every clock" : "\(WorldClocks.offsetText(Int(shift * 3600)).replacingOccurrences(of: "Same time", with: "Now")) from now")
                        .font(.brim(11.5, .bold)).foregroundStyle(theme.f(0.5))
                }
                .frame(width: 170, alignment: .leading)
                PlannerRuler(shift: $shift)
                IslandButton(title: "Now", style: shift == 0 ? .secondary : .primary, height: 28) {
                    withAnimation(.easeOut(duration: 0.2)) { shift = 0 }
                }
                .opacity(shift == 0 ? 0.4 : 1)
                .disabled(shift == 0)
            }
        }
        .frame(height: 64)
    }

    static func time(_ date: Date, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: date)
    }

    static func day(_ date: Date, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return formatter.string(from: date)
    }
}

/// A 24-hour ruler from −12h to +12h; drag snaps to half hours.
struct PlannerRuler: View {
    @Binding var shift: Double
    @Environment(\.islandTheme) private var theme

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let x = width * (shift + 12) / 24
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(0...24, id: \.self) { index in
                        Rectangle()
                            .fill(index == 12 ? theme.f(0.6) : theme.f(index % 6 == 0 ? 0.35 : 0.15))
                            .frame(width: 1.5, height: index % 6 == 0 ? 14 : 8)
                        if index < 24 { Spacer(minLength: 0) }
                    }
                }
                .frame(height: 16)
                Capsule().fill(theme.fg).frame(width: 4, height: 26).offset(x: x - 2)
                HStack {
                    Text("−12h"); Spacer(); Text("Now"); Spacer(); Text("+12h")
                }
                .font(.brim(9.5, .bold))
                .foregroundStyle(theme.f(0.4))
                .offset(y: 18)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let raw = (value.location.x / max(width, 1)) * 24 - 12
                shift = min(12, max(-12, (raw * 2).rounded() / 2))
            })
        }
        .frame(height: 40)
        .accessibilityElement()
        .accessibilityLabel("Time shift")
        .accessibilityValue(WorldClocks.offsetText(Int(shift * 3600)))
        .accessibilityAdjustableAction { direction in
            shift = min(12, max(-12, shift + (direction == .increment ? 0.5 : -0.5)))
        }
    }
}

/// A monochrome analog face; filled by day, outlined at night.
struct AnalogClock: View {
    let date: Date
    let zone: TimeZone
    @Environment(\.islandTheme) private var theme

    var body: some View {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hour = Double(parts.hour ?? 0), minute = Double(parts.minute ?? 0), second = Double(parts.second ?? 0)
        let day = (7..<19).contains(Int(hour))
        let fg = theme.fg, dim = theme.f(0.35), face = day ? theme.f(0.12) : theme.f(0.02), ring = theme.f(day ? 0 : 0.18)
        return Canvas { context, size in
            let r = min(size.width, size.height) / 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            context.fill(circle, with: .color(face))
            context.stroke(circle, with: .color(ring), lineWidth: 1)
            for tick in 0..<12 {
                let angle = Double(tick) / 12 * 2 * .pi
                let outer = r - 5, inner = r - (tick % 3 == 0 ? 11 : 8)
                var path = Path()
                path.move(to: CGPoint(x: c.x + sin(angle) * inner, y: c.y - cos(angle) * inner))
                path.addLine(to: CGPoint(x: c.x + sin(angle) * outer, y: c.y - cos(angle) * outer))
                context.stroke(path, with: .color(tick % 3 == 0 ? fg.opacity(0.7) : dim), style: StrokeStyle(lineWidth: tick % 3 == 0 ? 2 : 1.2, lineCap: .round))
            }
            func hand(_ fraction: Double, length: CGFloat, width: CGFloat, color: Color) {
                let angle = fraction * 2 * .pi
                var path = Path()
                path.move(to: c)
                path.addLine(to: CGPoint(x: c.x + sin(angle) * length, y: c.y - cos(angle) * length))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            hand((hour.truncatingRemainder(dividingBy: 12) + minute / 60) / 12, length: r * 0.5, width: 3.5, color: fg)
            hand((minute + second / 60) / 60, length: r * 0.74, width: 2.5, color: fg)
            hand(second / 60, length: r * 0.82, width: 1, color: dim)
            context.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(fg))
        }
        .accessibilityHidden(true)
    }
}
