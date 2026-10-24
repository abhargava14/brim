import AppKit
import IslandCore
import IslandSystem
import SwiftUI

// MARK: - Stats

/// Stats: CPU, memory, disk and network, then battery health and the busiest processes.
struct StatsTabView: View {
    @ObservedObject var stats: StatsService
    @Environment(\.islandTheme) private var theme

    private var s: SystemSample { stats.sample }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                card(key: "CPU", value: "\(Int(s.cpuPercent.rounded()))%",
                     sub: "\(s.cores) cores · load \(String(format: "%.1f", s.loadAverage))") {
                    CurveChart(values: stats.cpuHistory, color: s.cpuPercent > 85 ? Palette.amber : nil, fill: false, lineWidth: 2, padding: 3)
                        .frame(height: 30)
                        .padding(.top, 4)
                }
                card(key: "Memory", value: Bytes.format(Double(s.memoryUsed)),
                     sub: "of \(Bytes.format(Double(s.memoryTotal))) · pressure \(s.memoryPressure)") {
                    SegmentBar(segments: [("App", Double(s.memoryApp), theme.fg), ("Wired", Double(s.memoryWired), theme.f(0.55)),
                                          ("Compressed", Double(s.memoryCompressed), theme.f(0.3))],
                               total: Double(s.memoryTotal))
                }
                card(key: "Disk", value: Bytes.format(Double(s.diskFree)), sub: "free of \(Bytes.format(Double(s.diskTotal)))") {
                    SegmentBar(segments: [("Used", Double(s.diskTotal - s.diskFree), theme.fg), ("Purgeable", Double(s.diskPurgeable), theme.f(0.4))],
                               total: Double(s.diskTotal))
                }
                card(key: "Network", value: Bytes.speed(s.netDown), sub: "↓ down · ↑ \(Bytes.speed(s.netUp))") {
                    CurveChart(values: stats.netHistory, color: theme.f(0.7), fill: false, lineWidth: 2, padding: 3)
                        .frame(height: 30)
                        .padding(.top, 4)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                batteryCard
                processesCard.frame(width: 470)
            }
        }
        .onAppear { stats.watch() }
        .onDisappear { stats.unwatch() }
    }

    private func card<Extra: View>(key: String, value: String, sub: String, @ViewBuilder extra: () -> Extra) -> some View {
        IslandCard(padding: EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15)) {
            VStack(alignment: .leading, spacing: 3) {
                SectionTitle(title: key)
                Text(value).font(.brim(24)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                Text(sub).font(.brim(11, .bold)).foregroundStyle(theme.f(0.45)).lineLimit(1)
                extra()
            }
        }
    }

    private var batteryCard: some View {
        IslandCard(padding: EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)) {
            VStack(alignment: .leading, spacing: 7) {
                SectionTitle(title: stats.battery == nil ? "Power" : "Battery")
                if let battery = stats.battery {
                    HStack(spacing: 12) {
                        Text("\(battery.percent)%").font(.brim(28)).monospacedDigit()
                        BatteryGlyph(percent: battery.percent, charging: battery.charging)
                        Text(battery.charging ? "Charging" : battery.onPower ? "On power" : "On battery")
                            .font(.brim(12))
                            .foregroundStyle(theme.f(0.6))
                    }
                    DetailRow(key: battery.charging ? "Full in" : "Time left",
                              value: battery.minutesLeft.map { Clock.hm(TimeInterval($0 * 60)) } ?? (battery.onPower && !battery.charging ? "Charged" : "Estimating…"), height: 22)
                    DetailRow(key: "Health", value: battery.healthPercent.map { "\($0)%" } ?? "–", height: 22)
                    DetailRow(key: "Cycles", value: battery.cycles.map(String.init) ?? "–", height: 22)
                    DetailRow(key: "Temperature", value: battery.temperature.map { String(format: "%.0f°C", $0) } ?? "–", height: 22)
                } else {
                    Text("Plugged in").font(.brim(28))
                    Text("This Mac has no battery.").font(.brim(12, .bold)).foregroundStyle(theme.f(0.5))
                }
            }
        }
    }

    private var processesCard: some View {
        IslandCard(padding: EdgeInsets(top: 14, leading: 12, bottom: 8, trailing: 12)) {
            VStack(alignment: .leading, spacing: 2) {
                SectionTitle(title: "Top processes", aside: "CPU · memory").padding(.horizontal, 6).padding(.bottom, 6)
                if s.processes.isEmpty {
                    Text("Measuring…").font(.brim(12, .bold)).foregroundStyle(theme.f(0.45)).padding(.horizontal, 8)
                }
                let top = max(s.processes.first?.cpuPercent ?? 1, 1)
                ForEach(Array(s.processes.enumerated()), id: \.element.id) { index, process in
                    HStack(spacing: 10) {
                        Text(process.name).font(.brim(12.5, .bold)).lineLimit(1)
                        Spacer(minLength: 6)
                        MiniBar(fraction: process.cpuPercent / top).frame(width: 80)
                        Text("\(Int(process.cpuPercent.rounded()))%").font(.brim(12.5)).frame(width: 40, alignment: .trailing)
                        Text(Bytes.format(Double(process.memory))).font(.brim(12.5, .bold)).foregroundStyle(theme.f(0.5)).frame(width: 66, alignment: .trailing)
                    }
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 9).fill(index == 0 ? theme.f(0.08) : .clear))
                }
            }
        }
    }
}

/// A stacked bar with a legend underneath (memory, disk).
struct SegmentBar: View {
    let segments: [(String, Double, Color)]
    let total: Double
    @Environment(\.islandTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(segments, id: \.0) { _, value, color in
                        Rectangle().fill(color).frame(width: max(0, geo.size.width * value / max(total, 1) - 2))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 8)
            .background(theme.f(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.top, 10)
            HStack(spacing: 10) {
                ForEach(segments, id: \.0) { name, _, color in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 6, height: 6)
                        Text(name)
                    }
                }
            }
            .font(.brim(10.5, .bold))
            .foregroundStyle(theme.f(0.5))
            .lineLimit(1)
        }
    }
}

/// A small battery outline filled to the charge level.
struct BatteryGlyph: View {
    let percent: Int
    let charging: Bool
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.f(0.4), lineWidth: 1.6)
                .frame(width: 44, height: 20)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(percent <= 20 && !charging ? Palette.red : theme.fg)
                        .frame(width: 38 * CGFloat(percent) / 100, height: 14)
                        .padding(.leading, 3)
                }
            RoundedRectangle(cornerRadius: 1).fill(theme.f(0.4)).frame(width: 3, height: 8)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Sounds

/// Sounds: layer ambient noise, each with its own volume, and fade out on a timer.
struct SoundsTabView: View {
    @ObservedObject var sounds: SoundsService
    @Environment(\.islandTheme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(sounds.playing ? "\(sounds.levels.count) playing" : "Nothing playing").font(.brim(12.5)).fixedSize()
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 12)).opacity(0.6).padding(.leading, 8)
                IslandSlider(value: $sounds.master, label: "Volume").frame(width: 150)
                Spacer()
                Text(sounds.fadeEnds.map { "Fades at " + DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? "Fade out")
                    .font(.brim(11, .bold))
                    .foregroundStyle(theme.f(0.45))
                SegmentedPills(options: [(0, "Off"), (15, "15m"), (30, "30m"), (60, "1h")], selection: $sounds.fadeMinutes, look: .strong, height: 24)
                IslandButton(title: "Stop all", height: 28, fontSize: 11.5) { sounds.stopAll() }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(theme.f(0.06)))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(AmbientSound.allCases) { sound in
                    tile(sound)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func tile(_ sound: AmbientSound) -> some View {
        let level = sounds.levels[sound]
        let on = level != nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform").font(.system(size: 14, weight: .semibold)).foregroundStyle(on ? theme.fg : theme.f(0.5))
                Text(sound.title).font(.brim(13))
                Spacer()
                Text(level.map { "\(Int($0 * 100))%" } ?? "Off").font(.brim(11)).foregroundStyle(on ? theme.f(0.8) : theme.f(0.4))
            }
            if on {
                IslandSlider(value: Binding(get: { sounds.levels[sound] ?? 0.5 }, set: { sounds.setLevel(sound, $0) }),
                             label: "\(sound.title) volume")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(height: 84)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(on ? theme.f(0.1) : theme.f(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(on ? theme.f(0.5) : .clear, lineWidth: 1.5))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { sounds.toggle(sound) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(sound.title + (on ? ", playing" : ""))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Units

/// Units: type "5 km to mi" or "100 usd to inr", or pick a category and units.
struct UnitsTabView: View {
    @ObservedObject var currency: CurrencyService
    /// "currency" or a `UnitCategory` raw value.
    @State private var category: String
    @State private var input = "5"
    @State private var from: UnitChoice = UnitCategory.length.units[3]
    @State private var to: UnitChoice = UnitCategory.length.units[7]
    @State private var amount = "100"
    @State private var fromCode = "USD"
    @State private var toCode = "INR"
    @State private var currencyQuery = ""
    @State private var quick = ""
    @Environment(\.islandTheme) private var theme

    init(currency: CurrencyService, start: String? = nil) {
        self.currency = currency
        _category = State(initialValue: start ?? "currency")
    }

    private var value: Double? { Double(input.replacingOccurrences(of: ",", with: "")) }
    private var unitCategory: UnitCategory { UnitCategory(rawValue: category) ?? .length }

    var body: some View {
        VStack(spacing: 10) {
            IslandField(placeholder: "Type a conversion, like 100 usd to inr or 5 km to mi", text: $quick, symbol: "wand.and.stars",
                        height: 34, fontSize: 13) {}
                .onChange(of: quick) { applyQuick($0) }
            SegmentedPills(options: [("currency", "Currency")] + UnitCategory.allCases.map { ($0.rawValue, $0.title) }, selection: $category)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: category) { newValue in
                    guard let next = UnitCategory(rawValue: newValue), from.unit.dimension != next.units[0].unit.dimension else { return }
                    from = next.units[0]
                    to = next.units[min(1, next.units.count - 1)]
                }
            if category == "currency" { currencyBody } else { unitBody }
        }
        .onAppear { currency.refreshIfNeeded() }
    }

    // MARK: Units

    private var unitBody: some View {
        HStack(spacing: 10) {
            IslandCard(padding: EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18)) {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(title: "From")
                    HStack(spacing: 10) {
                        PlainTextField("0", text: $input, font: .brim(30)).frame(width: 150)
                        unitChips(selection: $from)
                    }
                    swapRow { swap(&from, &to) }
                    HStack(spacing: 10) {
                        result(value.map { UnitConverter.format(UnitConverter.convert($0, from: from, to: to)) } ?? "–")
                        unitChips(selection: $to)
                    }
                }
            }
            IslandCard(padding: EdgeInsets(top: 14, leading: 12, bottom: 8, trailing: 12)) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionTitle(title: "All \(unitCategory.title.lowercased())").padding(.horizontal, 6).padding(.bottom, 6)
                    ForEach(unitCategory.units) { unit in
                        DetailRow(key: unit.name, value: value.map { UnitConverter.format(UnitConverter.convert($0, from: from, to: unit)) + " " + unit.symbol } ?? "–",
                                  height: 26)
                    }
                }
            }
            .frame(width: 300)
        }
    }

    private func unitChips(selection: Binding<UnitChoice>) -> some View {
        HStack(spacing: 4) {
            ForEach(unitCategory.units) { unit in
                chip(unit.symbol, help: unit.name, on: unit == selection.wrappedValue) { selection.wrappedValue = unit }
            }
        }
    }

    // MARK: Currency

    @ViewBuilder
    private var currencyBody: some View {
        if let rates = currency.rates {
            let number = Double(amount.replacingOccurrences(of: ",", with: ""))
            HStack(spacing: 10) {
                IslandCard(padding: EdgeInsets(top: 14, leading: 18, bottom: 12, trailing: 18)) {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "From", aside: rates.name(fromCode))
                        HStack(spacing: 10) {
                            PlainTextField("0", text: $amount, font: .brim(30)).frame(width: 150)
                            currencyChips(rates, selection: $fromCode)
                        }
                        swapRow { swap(&fromCode, &toCode) }
                        HStack(spacing: 10) {
                            result(number.flatMap { rates.convert($0, from: fromCode, to: toCode) }.map { rates.format($0, toCode) } ?? "–")
                            currencyChips(rates, selection: $toCode)
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: 6) {
                            if currency.loading { Spinner(size: 10) }
                            Text(currency.failed ? "Couldn't refresh · rates from \(rates.date)" : "European Central Bank rates via Frankfurter · \(rates.date)")
                                .font(.brim(11, .bold))
                                .foregroundStyle(currency.failed ? Palette.amber : theme.f(0.4))
                        }
                    }
                }
                IslandCard(padding: EdgeInsets(top: 14, leading: 12, bottom: 8, trailing: 12)) {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionTitle(title: "\(amount.isEmpty ? "1" : amount) \(fromCode) is").padding(.horizontal, 6)
                        IslandField(placeholder: "Find a currency", text: $currencyQuery, symbol: "magnifyingglass", height: 28, fontSize: 12)
                        IslandScroll {
                            VStack(spacing: 0) {
                                ForEach(listCodes(rates), id: \.self) { code in
                                    HStack(spacing: 8) {
                                        Text(code).font(.brim(12.5)).frame(width: 38, alignment: .leading)
                                        Text(rates.name(code)).font(.brim(12, .bold)).foregroundStyle(theme.f(0.55)).lineLimit(1)
                                        Spacer(minLength: 6)
                                        Text(number.flatMap { rates.convert($0, from: fromCode, to: code) }.map { rates.format($0, code) } ?? "–")
                                            .font(.brim(12.5)).monospacedDigit()
                                    }
                                    .padding(.horizontal, 8)
                                    .frame(height: 26)
                                    .hoverFill(9, hover: theme.f(0.08))
                                    .onTapGesture { toCode = code }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityAddTraits(.isButton)
                                }
                            }
                        }
                    }
                }
                .frame(width: 330)
            }
        } else {
            ConnectCard(symbol: "dollarsign.arrow.circlepath", color: Palette.green, title: currency.failed ? "Couldn't get exchange rates" : "Getting exchange rates…",
                        message: "Brim uses the European Central Bank's daily rates through Frankfurter, an open service with no account.",
                        actions: currency.failed ? [.init(title: "Try again") { currency.refresh() }] : [],
                        waiting: currency.loading ? "Downloading today's rates…" : nil)
        }
    }

    private func currencyChips(_ rates: ExchangeRates, selection: Binding<String>) -> some View {
        let picks = Array(ExchangeRates.popular.filter { rates.codes.contains($0) }.prefix(7))
        let shown = picks.contains(selection.wrappedValue) ? picks : Array(picks.prefix(6)) + [selection.wrappedValue]
        return HStack(spacing: 4) {
            ForEach(shown, id: \.self) { code in
                chip(code, help: rates.name(code), on: code == selection.wrappedValue) { selection.wrappedValue = code }
            }
        }
    }

    private func listCodes(_ rates: ExchangeRates) -> [String] {
        let q = currencyQuery.trimmingCharacters(in: .whitespaces)
        let codes = rates.codes.filter { $0 != fromCode }
        guard !q.isEmpty else { return codes }
        return codes.filter { $0.localizedCaseInsensitiveContains(q) || rates.name($0).localizedCaseInsensitiveContains(q) }
    }

    // MARK: Shared

    private func swapRow(_ action: @escaping () -> Void) -> some View {
        HStack {
            SectionTitle(title: "To")
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 24, height: 24)
                .hoverFill(12, base: theme.f(0.08), hover: theme.f(0.16))
                .onTapGesture(perform: action)
                .accessibilityLabel("Swap")
                .accessibilityAddTraits(.isButton)
        }
    }

    private func result(_ text: String) -> some View {
        Text(text)
            .font(.brim(30))
            .foregroundStyle(theme.fg)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(width: 150, alignment: .leading)
            .textSelection(.enabled)
    }

    private func chip(_ label: String, help: String, on: Bool, action: @escaping () -> Void) -> some View {
        Text(label)
            .font(.brim(11.5))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .foregroundStyle(on ? theme.bg : theme.f(0.7))
            .background(Capsule().fill(on ? theme.fg : theme.f(0.08)))
            .onTapGesture(perform: action)
            .help(help)
            .accessibilityLabel(help)
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private func applyQuick(_ text: String) {
        if let rates = currency.rates, let parsed = rates.parse(text) {
            category = "currency"
            amount = UnitConverter.format(parsed.amount).replacingOccurrences(of: ",", with: "")
            fromCode = parsed.from
            if let target = parsed.to { toCode = target } else if toCode == parsed.from { toCode = parsed.from == "USD" ? "EUR" : "USD" }
            return
        }
        guard let parsed = UnitConverter.parse(text) else { return }
        category = parsed.category.rawValue
        from = parsed.from
        input = UnitConverter.format(parsed.value).replacingOccurrences(of: ",", with: "")
        if let target = parsed.to { to = target } else if to.unit.dimension != parsed.from.unit.dimension || to == parsed.from {
            to = parsed.category.units.first { $0 != parsed.from } ?? parsed.from
        }
    }
}

private extension Dimension {
    var dimension: String { String(describing: type(of: self)) }
}
