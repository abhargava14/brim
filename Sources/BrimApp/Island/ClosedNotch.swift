import AppKit
import Combine
import IslandCore
import IslandSystem
import SwiftUI

/// What the closed notch shows when it isn't showing AI usage.
@MainActor
final class ClosedNotchState: ObservableObject {
    struct Notice: Equatable {
        let id: String
        let symbol: String
        let tint: Color
        let title: String
        let detail: String
        /// The tab a click opens.
        let tab: TabID
        let until: Date
    }

    enum Mode: Equatable {
        case ai
        case music
        case timer
        case notice(Notice)

        /// Modes that need the wider wings from the design (118pt).
        var wide: Bool { self != .ai }
    }

    @Published private(set) var mode: Mode = .ai
    private var notices: [Notice] = []
    private var seenProblems = Set<String>()
    private var seenEvents = Set<String>()
    private var lastFinished: String?
    private var timer: Timer?
    private weak var hub: BrimHub?
    /// How long each rotating item stays.
    static let rotation: TimeInterval = 8

    func start(_ hub: BrimHub) {
        self.hub = hub
        // Problems that exist at launch were seen before; only new ones interrupt.
        seenProblems = Set(AIAccounts(model: hub.model, settings: hub.settings).items.filter { $0.problem != nil }.map(\.id))
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        update()
    }

    /// Shows one mode and stops rotating (snapshot renders).
    func force(_ mode: Mode) {
        timer?.invalidate()
        timer = nil
        self.mode = mode
    }

    func push(_ notice: Notice) {
        guard !notices.contains(where: { $0.id == notice.id }) else { return }
        notices.append(notice)
        update()
    }

    func dismissNotice() {
        if case .notice(let current) = mode { notices.removeAll { $0.id == current.id } }
        update()
    }

    private func update() {
        guard let hub else { return }
        let settings = hub.settings
        let now = Date()
        collectNotices(hub, now: now)
        notices.removeAll { $0.until <= now }

        var next: Mode
        if let notice = notices.first {
            next = .notice(notice)
        } else if settings.closedTimer, hub.timers.state.pomodoroRunning || hub.timers.state.countdownRunning {
            next = .timer
        } else {
            var rotation: [Mode] = []
            if settings.closedMusic, hub.music.track?.playing == true { rotation.append(.music) }
            if settings.closedAI { rotation.append(.ai) }
            if rotation.isEmpty { rotation = settings.closedMusic && hub.music.track != nil ? [.music] : [.ai] }
            next = rotation[Int(now.timeIntervalSince1970 / Self.rotation) % rotation.count]
        }
        if next != mode { mode = next }
    }

    private func collectNotices(_ hub: BrimHub, now: Date) {
        let settings = hub.settings
        // Timer finished.
        if let finished = hub.timers.finished, finished != lastFinished {
            lastFinished = finished
            push(Notice(id: "timer-\(now.timeIntervalSince1970)", symbol: "timer", tint: Palette.coral, title: "Timer",
                        detail: finished.replacingOccurrences(of: ".", with: ""), tab: .timers, until: now.addingTimeInterval(6)))
        } else if hub.timers.finished == nil {
            lastFinished = nil
        }
        // A new account problem, once.
        if settings.interruptAccounts {
            for account in AIAccounts(model: hub.model, settings: settings).items where account.problem != nil && !seenProblems.contains(account.id) {
                seenProblems.insert(account.id)
                push(Notice(id: "problem-\(account.id)", symbol: "exclamationmark.circle.fill", tint: Palette.amber, title: account.label,
                            detail: account.problem == .signedOut ? "sign in again" : account.problem?.short.lowercased() ?? "needs attention",
                            tab: .ai, until: now.addingTimeInterval(6)))
            }
        }
        // An event about to start, with a Join link.
        if settings.interruptEvents, let event = hub.calendar.nextEvent, !seenEvents.contains(event.id) {
            let lead = event.start.timeIntervalSince(now)
            if lead > 0, lead <= 5 * 60 {
                seenEvents.insert(event.id)
                push(Notice(id: "event-\(event.id)", symbol: "calendar", tint: Palette.green, title: event.title,
                            detail: event.meeting != nil ? "join " + When.until(event.start) : When.until(event.start),
                            tab: .home, until: event.start.addingTimeInterval(60)))
            }
        }
    }
}

/// The closed notch for music, timers, messages and notices. Content stays out from under the notch.
struct ClosedNotchView: View {
    let mode: ClosedNotchState.Mode
    @ObservedObject var hub: BrimHub
    @ObservedObject var music: NowPlaying
    @ObservedObject var timers: TimerService
    @ObservedObject var state: IslandState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            left.frame(maxWidth: .infinity, alignment: .leading)
            if state.hasNotch { Spacer().frame(width: state.notchWidth) }
            right.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .font(.brim(12.5))
        .monospacedDigit()
        .foregroundStyle(.white)
        .lineLimit(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(modeKey)
        .transition(.opacity.combined(with: .offset(y: 5)))
    }

    private var modeKey: String {
        switch mode {
        case .ai: return "ai"
        case .music: return "music"
        case .timer: return "timer"
        case .notice(let notice): return notice.id
        }
    }

    @ViewBuilder
    private var left: some View {
        switch mode {
        case .music:
            HStack(spacing: 7) {
                Group {
                    if let art = music.artwork {
                        Image(nsImage: art).resizable().scaledToFill()
                    } else {
                        Color(red: 0.75, green: 0.36, blue: 0.29)
                    }
                }
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(music.track?.title ?? "").truncationMode(.tail)
            }
        case .timer:
            let state = timers.state
            let fraction = state.pomodoroRunning
                ? state.pomodoroRemaining(at: timers.now) / max(state.phaseLength(state.phase), 1)
                : state.countdownRemaining(at: timers.now) / max(state.countdownTotal, 1)
            HStack(spacing: 6) {
                ZStack {
                    Circle().stroke(Palette.coral.opacity(0.3), lineWidth: 2.4)
                    Circle().trim(from: 0, to: fraction).stroke(Palette.coral, style: StrokeStyle(lineWidth: 2.4, lineCap: .round)).rotationEffect(.degrees(-90))
                }
                .frame(width: 12, height: 12)
                Text(state.pomodoroRunning ? state.phase.title : "Timer")
            }
        case .notice(let notice):
            HStack(spacing: 6) {
                Image(systemName: notice.symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(notice.tint)
                Text(notice.title).truncationMode(.tail)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var right: some View {
        switch mode {
        case .music:
            HStack(spacing: 7) {
                EqualizerBars(playing: music.track?.playing == true && !reduceMotion)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, (music.track?.duration ?? 0) - (music.track?.elapsed(at: context.date) ?? 0))
                    Text("-" + Clock.mmss(left).trimmingLeadingZero).foregroundStyle(.white.opacity(0.6))
                }
            }
        case .timer:
            let state = timers.state
            Text(Clock.mmss(state.pomodoroRunning ? state.pomodoroRemaining(at: timers.now) : state.countdownRemaining(at: timers.now)))
        case .notice(let notice):
            Text(notice.detail).foregroundStyle(notice.tint)
        default:
            EmptyView()
        }
    }
}

/// Four bars that bounce while music plays.
struct EqualizerBars: View {
    let playing: Bool
    @State private var phase = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(red: 0.86, green: 0.46, blue: 0.38))
                    .frame(width: 2.5, height: playing ? (phase ? [12, 6, 10, 4][index] : [5, 12, 4, 10][index]) : 4)
                    .animation(playing ? .easeInOut(duration: 0.45 + Double(index) * 0.13).repeatForever(autoreverses: true) : .default, value: phase)
            }
        }
        .frame(height: 12)
        .onAppear { phase = true }
        .accessibilityHidden(true)
    }
}
