import IslandCore
import SwiftUI

/// Timers: Pomodoro, countdown, stopwatch and hydration. Running timers also show in the closed notch.
struct TimersTabView: View {
    enum Sub: String, CaseIterable { case pomodoro, countdown, stopwatch, water }

    @ObservedObject var timers: TimerService
    @State private var sub: Sub
    @Environment(\.islandTheme) private var theme

    init(timers: TimerService, sub: String? = nil) {
        self.timers = timers
        _sub = State(initialValue: sub.flatMap(Sub.init(rawValue:)) ?? (timers.state.countdownRunning ? .countdown : timers.state.stopwatchRunning ? .stopwatch : .pomodoro))
    }

    private var state: TimerState { timers.state }
    private var now: Date { timers.now }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                SegmentedPills(options: [(Sub.pomodoro, "Pomodoro"), (.countdown, "Countdown"), (.stopwatch, "Stopwatch"), (.water, "Hydration")],
                               selection: $sub, dot: { running($0) ? theme.fg : nil })
                Spacer()
                Text("Running timers show in the closed notch")
                    .font(.brim(11, .bold))
                    .foregroundStyle(theme.f(0.45))
            }
            HStack(spacing: 10) {
                IslandCard(padding: EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18)) {
                    main.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .layoutPriority(1)
                IslandCard(padding: EdgeInsets(top: 14, leading: 12, bottom: 8, trailing: 12)) {
                    side
                }
                .frame(width: 330)
            }
        }
        .onAppear { Notifier.requestIfNeeded() }
    }

    /// Glasses of 250 ml as litres: 1.25, 2, 0.5.
    static func litres(_ glasses: Int) -> String {
        var text = String(format: "%.2f", Double(glasses) * 0.25)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    private func running(_ sub: Sub) -> Bool {
        switch sub {
        case .pomodoro: return state.pomodoroRunning
        case .countdown: return state.countdownRunning
        case .stopwatch: return state.stopwatchRunning
        case .water: return false
        }
    }

    // MARK: Main

    @ViewBuilder
    private var main: some View {
        switch sub {
        case .pomodoro:
            let remaining = state.pomodoroRemaining(at: now)
            let fraction = remaining / max(state.phaseLength(state.phase), 1)
            VStack(spacing: 14) {
                ZStack {
                    Circle().stroke(theme.f(0.08), lineWidth: 9)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(theme.fg, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: fraction)
                    VStack(spacing: 2) {
                        Text(Clock.mmss(remaining)).font(.brim(40)).monospacedDigit()
                        Text(state.phase.title).font(.brim(12)).foregroundStyle(theme.f(0.6))
                    }
                }
                .frame(width: 170, height: 170)
                buttons([
                    ("Reset", nil, { timers.state.resetPomodoro() }),
                    (state.pomodoroRunning ? "Pause" : "Start", theme.fg, { timers.state.togglePomodoro() }),
                    ("Skip", nil, { timers.state.advancePomodoro() }),
                ])
            }
        case .countdown:
            let remaining = state.countdownRemaining(at: now)
            VStack(spacing: 14) {
                Text(Clock.mmss(remaining)).font(.brim(54)).monospacedDigit()
                Text(state.countdownRunning ? "Running" : "Pick a length").font(.brim(12)).foregroundStyle(theme.f(0.5))
                MiniBar(fraction: remaining / max(state.countdownTotal, 1), height: 6)
                    .frame(maxWidth: 360)
                buttons([
                    ("Reset", nil, { timers.state.resetCountdown() }),
                    (state.countdownRunning ? "Pause" : "Start", theme.fg, { timers.state.toggleCountdown() }),
                ])
            }
        case .stopwatch:
            VStack(spacing: 14) {
                Text(Clock.tenths(state.stopwatchElapsed(at: now))).font(.brim(54)).monospacedDigit()
                Text("\(state.laps.count) lap\(state.laps.count == 1 ? "" : "s")").font(.brim(12)).foregroundStyle(theme.f(0.5))
                buttons([
                    ("Lap", nil, { timers.state.lap() }),
                    (state.stopwatchRunning ? "Stop" : "Start", theme.fg, { timers.state.toggleStopwatch() }),
                    ("Reset", nil, { timers.state.resetStopwatch() }),
                ])
            }
        case .water:
            let glassW: CGFloat = state.glassGoal > 8 || state.hydrationRowCount == 2 ? 26 : 34
            let glassH: CGFloat = state.hydrationRowCount == 2 ? 40 : (state.glassGoal > 8 ? 48 : 56)
            let gap: CGFloat = state.hydrationRowCount == 2 ? 5 : 8
            VStack(spacing: 12) {
                if let notice = state.yesterdayIncompleteMessage {
                    Text(notice)
                        .font(.brim(12, .bold))
                        .foregroundStyle(theme.f(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(spacing: gap) {
                    ForEach(0..<state.hydrationRowCount, id: \.self) { row in
                        let filled = state.filledGlasses(inRow: row)
                        HStack(spacing: gap) {
                            ForEach(0..<state.glassGoal, id: \.self) { index in
                                ZStack(alignment: .bottom) {
                                    UnevenGlass().stroke(theme.f(0.2), lineWidth: 1.4)
                                    UnevenGlass()
                                        .fill(theme.f(row == 0 ? 0.85 : 0.55))
                                        .frame(height: index < filled ? glassH : 0)
                                        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: state.glasses)
                                }
                                .frame(width: glassW, height: glassH)
                                .clipShape(UnevenGlass())
                            }
                        }
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Self.litres(state.glasses) + " L").font(.brim(30))
                    Text("of \(Self.litres(state.glassGoal)) L today").font(.brim(13, .bold)).foregroundStyle(theme.f(0.5))
                }
                buttons([
                    ("−", nil, { timers.state.addGlass(-1) }),
                    ("+ Glass", theme.fg, { timers.state.addGlass(1) }),
                ])
            }
        }
    }

    private func buttons(_ items: [(String, Color?, () -> Void)]) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                IslandButton(title: item.0, style: item.1 == nil ? .secondary : .primary, height: 34, fontSize: 13, action: item.2)
            }
        }
    }

    // MARK: Side

    @ViewBuilder
    private var side: some View {
        switch sub {
        case .pomodoro:
            VStack(alignment: .leading, spacing: 4) {
                SectionTitle(title: "Today", aside: "\(state.sessionsToday % state.sessionsPerSet) of \(state.sessionsPerSet) sessions")
                    .padding(.horizontal, 6).padding(.bottom, 6)
                HStack(spacing: 6) {
                    ForEach(0..<state.sessionsPerSet, id: \.self) { i in
                        Capsule().fill(i < state.sessionsToday % state.sessionsPerSet ? theme.fg : theme.f(0.12)).frame(width: 22, height: 8)
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 8)
                StepRow(title: "Focus", value: $timers.state.focusMinutes, range: 5...90, step: 5)
                StepRow(title: "Short break", value: $timers.state.shortBreakMinutes, range: 1...30, step: 1)
                StepRow(title: "Long break", value: $timers.state.longBreakMinutes, range: 5...60, step: 5)
                DetailRow(key: "Focus today", value: Clock.hm(TimeInterval(state.sessionsToday * state.focusMinutes * 60)), height: 32)
            }
        case .countdown:
            VStack(alignment: .leading, spacing: 4) {
                SectionTitle(title: "Presets").padding(.horizontal, 6).padding(.bottom, 6)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach([1, 5, 10, 15, 25, 45], id: \.self) { minutes in
                        let on = Int(state.countdownTotal / 60) == minutes
                        Text("\(minutes) min")
                            .font(.brim(13))
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .foregroundStyle(on ? theme.bg : theme.fg)
                            .hoverFill(12, base: on ? theme.fg : theme.f(0.08), hover: on ? theme.fg : theme.f(0.14))
                            .onTapGesture { timers.state.setCountdown(minutes: minutes) }
                            .accessibilityAddTraits(.isButton)
                    }
                }
                .padding(.horizontal, 4).padding(.bottom, 8)
                DetailRow(key: "Sound", value: "Glass", height: 32)
                DetailRow(key: "Show in notch", value: "On", height: 32)
            }
        case .stopwatch:
            VStack(alignment: .leading, spacing: 2) {
                SectionTitle(title: "Laps").padding(.horizontal, 6).padding(.bottom, 6)
                if state.laps.isEmpty {
                    DetailRow(key: "No laps yet", value: "", height: 32)
                }
                IslandScroll {
                    VStack(spacing: 2) {
                        ForEach(Array(state.laps.enumerated()), id: \.offset) { index, lap in
                            DetailRow(key: "Lap \(state.laps.count - index)", value: Clock.tenths(lap), height: 32)
                                .background(RoundedRectangle(cornerRadius: 11).fill(index == 0 ? theme.f(0.08) : .clear))
                        }
                    }
                }
            }
        case .water:
            VStack(alignment: .leading, spacing: 4) {
                SectionTitle(title: "Schedule").padding(.horizontal, 6).padding(.bottom, 6)
                StepRow(title: "Remind every", value: $timers.state.remindEveryMinutes, range: 0...120, step: 15, unit: "min", offText: "Off")
                StepRow(title: "Goal", value: $timers.state.glassGoal, range: 4...12, step: 1, unit: "glasses")
                DetailRow(key: "Today", value: "\(state.glasses) of \(state.glassGoal) glasses", height: 32)
                if let notice = state.yesterdayIncompleteMessage {
                    DetailRow(key: "Yesterday", value: notice.replacingOccurrences(of: "Yesterday: ", with: ""), height: 32)
                }
                DetailRow(key: "Glass size", value: "250 ml", height: 32)
            }
        }
    }
}

/// A row with a value and − / + controls.
struct StepRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var unit = "min"
    var offText: String?
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.brim(12.5, .bold)).foregroundStyle(theme.f(0.7))
            Spacer()
            stepper("minus", enabled: value > range.lowerBound) { value = max(range.lowerBound, value - step) }
            Text(value == 0 && offText != nil ? offText! : "\(value) \(unit)")
                .font(.brim(12.5))
                .monospacedDigit()
                .frame(minWidth: 62, alignment: .center)
            stepper("plus", enabled: value < range.upperBound) { value = min(range.upperBound, value + step) }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 32)
    }

    private func stepper(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .heavy))
            .frame(width: 20, height: 20)
            .opacity(enabled ? 0.8 : 0.25)
            .hoverFill(10, base: theme.f(0.08), hover: theme.f(0.16))
            .onTapGesture { if enabled { action() } }
            .accessibilityLabel(symbol == "plus" ? "More \(title)" : "Less \(title)")
            .accessibilityAddTraits(.isButton)
    }
}

/// A glass: square top, rounder bottom.
struct UnevenGlass: Shape {
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerSize: CGSize(width: 10, height: 10), style: .continuous)
    }
}
