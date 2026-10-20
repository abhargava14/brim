import AppKit
import IslandCore
import IslandServices
import SwiftUI

// Claude cards: the full view (what Claude Code's /usage shows, per account) and the pieces the
// short card adds. Percentages are always used, never left.

/// The full view: plan limits with resets, tokens by kind, tokens per model, and today's sessions.
struct ClaudeDetailView: View {
    let tool: ToolSnapshot
    @ObservedObject var model: UsageModel

    /// Primary 5h / week-all-models always stay; empty per-model week rows are dropped.
    private var visiblePlanWindows: [PlanWindow] {
        tool.planWindows.filter { window in
            window.model == nil || window.usedPercent > 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                RollingText(text: Format.tokens(tool.today.total))
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                Text("tokens today")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 8)
                Text(tool.sessions.isEmpty
                      ? "\(tool.todaySessions) sessions · \(tool.todayRequests) req"
                      : tool.sessionSummary())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
            }
            .monospacedDigit()

            ClaudeSectionTitle(text: "Plan usage")
            if visiblePlanWindows.isEmpty {
                ClaudeLimitsNote(tool: tool)
            } else {
                VStack(spacing: 5) {
                    ForEach(Array(visiblePlanWindows.enumerated()), id: \.offset) { _, window in
                        ClaudeLimitRow(window: window)
                    }
                }
                ClaudeLimitsNote(tool: tool)
            }

            ClaudeSectionTitle(text: "Tokens")
            ClaudeTokensSummary(today: tool.today, week: tool.week, tint: tool.kind.tint)

            if !tool.models.isEmpty {
                ClaudeSectionTitle(text: "By model · 7 days")
                VStack(spacing: 5) {
                    let peak = tool.models.map(\.week.total).max() ?? 1
                    ForEach(tool.models.prefix(6)) { usage in
                        ClaudeModelRow(usage: usage, peak: peak, tint: tool.kind.tint)
                    }
                }
            }

            if !tool.sessions.isEmpty {
                ClaudeSectionTitle(text: "Sessions today")
                VStack(spacing: 5) {
                    let peak = tool.sessions.map(\.today.total).max() ?? 1
                    ForEach(tool.sessions.prefix(8)) { session in
                        ClaudeSessionRow(session: session, peak: peak, tint: tool.kind.tint)
                    }
                }
            }

            ClaudeStyleToggle(tool: tool, model: model)
        }
    }
}

struct ClaudeSectionTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .tracking(0.6)
            .foregroundStyle(.white.opacity(0.35))
            .padding(.top, 4)
    }
}

/// One limit: name, a used bar, "16% used" and the reset.
struct ClaudeLimitRow: View {
    let window: PlanWindow
    @State private var filled = false

    var body: some View {
        HStack(spacing: 6) {
            Text(ClaudeUsageResponse.title(for: window))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .frame(width: 108, alignment: .leading)
                .layoutPriority(1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                GeometryReader { geometry in
                    Capsule()
                        .fill(PlanBar.color(for: window.usedPercent))
                        .frame(width: max(4, geometry.size.width * (filled ? min(window.usedPercent, 100) : 0) / 100))
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: 6)
            .layoutPriority(-1)
            Text(Format.used(window))
                .foregroundStyle(window.usedPercent >= 80 ? PlanBar.color(for: window.usedPercent) : .white.opacity(0.6))
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
            Text(window.resetsAt.map { Format.reset($0) } ?? "")
                .foregroundStyle(.white.opacity(0.35))
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
        }
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .monospacedDigit()
        .onAppear {
            withAnimation(.timingCurve(0.25, 1, 0.4, 1, duration: 0.9).delay(0.3)) { filled = true }
        }
    }
}

/// "as of 2h ago · Open Claude Code once to refresh", or why there are no limits.
struct ClaudeLimitsNote: View {
    let tool: ToolSnapshot

    var body: some View {
        if tool.limitsAsOf != nil || tool.limitsNote != nil {
            HStack(spacing: 5) {
                if let asOf = tool.limitsAsOf {
                    Image(systemName: "clock").foregroundStyle(Brand.attention)
                    Text("as of \(Format.ago(asOf))").foregroundStyle(Brand.attention)
                    if tool.limitsNote != nil { Text("·").foregroundStyle(.white.opacity(0.35)) }
                }
                if let note = tool.limitsNote {
                    Text(note).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10.5, weight: .bold, design: .rounded))
        }
    }
}

/// Today's token mix as a bar + legend; 7-day total as a quiet one-liner.
struct ClaudeTokensSummary: View {
    let today: TokenCounts
    let week: TokenCounts
    let tint: Color

    private struct Part: Identifiable {
        let name: String
        let short: String
        let value: Int64
        let color: Color
        var id: String { name }
    }

    private var parts: [Part] {
        [
            Part(name: "input", short: "in", value: today.input, color: Color.white.opacity(0.9)),
            Part(name: "output", short: "out", value: today.output, color: tint),
            Part(name: "cache write", short: "cache↑", value: today.cacheWrite, color: tint.opacity(0.55)),
            Part(name: "cache read", short: "cache↓", value: today.cacheRead, color: tint.opacity(0.28)),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geometry in
                HStack(spacing: 1.5) {
                    ForEach(parts.filter { $0.value > 0 }) { part in
                        Rectangle()
                            .fill(part.color)
                            .frame(width: max(2, geometry.size.width * CGFloat(part.value) / CGFloat(max(today.total, 1))))
                    }
                }
            }
            .frame(height: 6)
            .clipShape(Capsule())

            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                    if index > 0 { Spacer(minLength: 4) }
                    HStack(spacing: 3) {
                        Circle().fill(part.color).frame(width: 5, height: 5)
                        Text("\(part.short) \(Format.tokens(part.value))")
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .monospacedDigit()

            Text("7 days · \(Format.tokens(week.total))")
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
                .monospacedDigit()
        }
    }
}

/// Segmented token bar drawn inside a measured width (never under trailing labels).
struct ClaudeTokenBar: View {
    let parts: [(Int64, Color)]
    let total: Int64
    let fraction: Double
    var width: CGFloat

    var body: some View {
        Canvas { context, size in
            let full = size.width * CGFloat(min(1, max(0, fraction)))
            guard full > 0, total > 0 else { return }
            var x: CGFloat = 0
            for part in parts where part.0 > 0 {
                let share = full * CGFloat(Double(part.0) / Double(total))
                let segment = max(1.5, share)
                let rect = CGRect(x: x, y: 0, width: min(segment, max(0, full - x)), height: size.height)
                context.fill(Path(rect), with: .color(part.1))
                x += segment + 1
                if x >= full { break }
            }
        }
        .frame(width: max(0, width), height: 6, alignment: .leading)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

/// Leading labels + flexible middle bar + fixed trailing values (Spacer reserves the gap).
private struct ClaudeBarRow<Leading: View, Trailing: View>: View {
    let parts: [(Int64, Color)]
    let total: Int64
    let fraction: Double
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            leading()
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
                .frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        ClaudeTokenBar(parts: parts, total: total, fraction: fraction, width: geometry.size.width)
                    }
                }
                .clipped()
            trailing()
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One model: name, a bar split by token kind (scaled to the busiest model), 7-day and today totals.
struct ClaudeModelRow: View {
    let usage: ModelUsage
    let peak: Int64
    let tint: Color

    var body: some View {
        let fraction = min(1, Double(usage.week.total) / Double(max(peak, 1)))
        ClaudeBarRow(parts: parts, total: usage.week.total, fraction: fraction) {
            Text(Format.modelName(usage.model))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .frame(width: 78, alignment: .leading)
        } trailing: {
            HStack(spacing: 6) {
                Text(Format.tokens(usage.week.total)).foregroundStyle(.white)
                Text(usage.today.isZero ? "–" : Format.tokens(usage.today.total))
                    .foregroundStyle(.white.opacity(0.35))
                    .help("today")
            }
            .lineLimit(1)
        }
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .monospacedDigit()
    }

    private var parts: [(Int64, Color)] {
        [(usage.week.input, Color.white.opacity(0.9)), (usage.week.output, tint),
         (usage.week.cacheWrite, tint.opacity(0.55)), (usage.week.cacheRead, tint.opacity(0.28))]
    }
}

/// One Claude session: project, model, today's tokens (cache split), last activity, working dot.
struct ClaudeSessionRow: View {
    let session: SessionUsage
    let peak: Int64
    let tint: Color
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let fraction = min(1, Double(session.today.total) / Double(max(peak, 1)))
        ClaudeBarRow(parts: parts, total: session.today.total, fraction: fraction) {
            HStack(spacing: 6) {
                Circle()
                    .fill(session.isActive() ? tint : Color.white.opacity(0.15))
                    .frame(width: 6, height: 6)
                    .opacity(session.isActive() && pulse ? 0.35 : 1)
                Text(session.project ?? "—")
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(width: 56, alignment: .leading)
                Text(session.model.map(Format.modelName) ?? "—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .frame(width: 64, alignment: .leading)
            }
        } trailing: {
            HStack(spacing: 6) {
                Text(Format.tokens(session.today.total)).foregroundStyle(.white)
                Text(Format.ago(session.lastActivity)).foregroundStyle(.white.opacity(0.35))
            }
            .lineLimit(1)
        }
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .monospacedDigit()
        .help(sessionHelp)
        .onAppear {
            guard session.isActive(), !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private var parts: [(Int64, Color)] {
        [(session.today.input, Color.white.opacity(0.9)), (session.today.output, tint),
         (session.today.cacheWrite, tint.opacity(0.55)), (session.today.cacheRead, tint.opacity(0.28))]
    }

    private var sessionHelp: String {
        let kinds = [
            "in \(Format.tokens(session.today.input))",
            "out \(Format.tokens(session.today.output))",
            "cache↑ \(Format.tokens(session.today.cacheWrite))",
            "cache↓ \(Format.tokens(session.today.cacheRead))",
        ].joined(separator: " · ")
        return "\(session.requests) replies · \(kinds)"
    }
}

/// "Full usage" / "Less" at the bottom of a Claude card.
struct ClaudeStyleToggle: View {
    let tool: ToolSnapshot
    @ObservedObject var model: UsageModel

    var body: some View {
        let isFull = model.claudeStyle(for: tool.id) == .full
        Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { model.toggleClaudeStyle(for: tool.id) }
        } label: {
            HStack(spacing: 4) {
                Text(isFull ? "Less" : "Full usage")
                Image(systemName: isFull ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .heavy))
            }
            .font(.system(size: 10.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.35))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Adding a Claude account

/// Signs another Claude account in (Claude Code's own browser sign-in, in its own config folder)
/// and connects it. Self-contained, so it can sit in Settings, first run or the island's "+".
struct AddClaudeAccountView: View {
    @ObservedObject var model: UsageModel
    var onDone: () -> Void = {}

    private enum Phase: Equatable {
        case idle
        case signingIn(URL?)
        case done(String)
        case failed(String)
    }

    @State private var label = "personal"
    @State private var phase = Phase.idle
    @State private var task: Task<Void, Never>?
    private let installed = ClaudeCode.executable() != nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ToolGlyph(kind: .claude, mood: .idle, size: 18, playful: false, name: "Claude")
                Text("Add a Claude account").font(.headline)
            }
            Text("Signs in with Claude Code's own browser sign-in, in a separate folder, so this account's limits and logs stay apart from your others. Brim never sees your password or token.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !installed {
                Label("Claude Code isn't installed on this Mac. Install it from claude.com/claude-code, then try again.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Brand.attention)
            } else {
                TextField("Name", text: $label, prompt: Text("personal"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(phase != .idle && !isFailed)
                Text("Folder: ~/\(ClaudeAccounts.newConfigDir(label: label).lastPathComponent)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            switch phase {
            case .idle:
                EmptyView()
            case .signingIn(let url):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser…")
                    if let url {
                        Button("Open sign-in page") { NSWorkspace.shared.open(url) }.buttonStyle(.link)
                    }
                }
            case .done(let name):
                Label("\(name) connected", systemImage: "checkmark.circle.fill").foregroundStyle(Brand.good)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Brand.attention)
            }

            HStack {
                Spacer()
                if case .signingIn = phase {
                    Button("Cancel") { task?.cancel() }
                } else if case .done = phase {
                    Button("Done") { onDone() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { onDone() }
                    Button("Sign in with Claude…") { start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!installed)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .onDisappear { task?.cancel() }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func start() {
        phase = .signingIn(nil)
        let label = self.label
        task = Task {
            do {
                let account = try await ClaudeAccountSetup.addAccount(label: label) { url in
                    Task { @MainActor in if case .signingIn = phase { phase = .signingIn(url) } }
                }
                let connection = model.addClaudeConnection(for: account)
                phase = .done(connection.name)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
