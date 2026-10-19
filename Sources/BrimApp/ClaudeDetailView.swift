import AppKit
import IslandCore
import IslandServices
import SwiftUI

// Claude cards: the full view (what Claude Code's /usage shows, per account) and the pieces the
// short card adds. Percentages are always used, never left.

/// The full view: plan limits with resets, tokens by kind, and tokens per model.
struct ClaudeDetailView: View {
    let tool: ToolSnapshot
    @ObservedObject var model: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                RollingText(text: Format.tokens(tool.today.total))
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                Text("tokens today")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text("\(tool.todaySessions) sessions · \(tool.todayRequests) req")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .monospacedDigit()

            ClaudeSectionTitle(text: "Plan usage")
            if tool.planWindows.isEmpty {
                ClaudeLimitsNote(tool: tool)
            } else {
                VStack(spacing: 7) {
                    ForEach(tool.planWindows, id: \.label) { window in
                        ClaudeLimitRow(window: window)
                    }
                }
                ClaudeLimitsNote(tool: tool)
            }

            ClaudeSectionTitle(text: "Tokens")
            TokenBreakdown(tokens: tool.today, tint: tool.kind.tint)
            ClaudeTokenTable(rows: [("today", tool.today), ("7 days", tool.week)])

            if !tool.models.isEmpty {
                ClaudeSectionTitle(text: "By model · 7 days")
                VStack(spacing: 6) {
                    ForEach(tool.models.prefix(6)) { usage in
                        ClaudeModelRow(usage: usage, peak: tool.models.first?.week.total ?? 1, tint: tool.kind.tint)
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
            .padding(.top, 2)
    }
}

/// One limit: name, a used bar, "16% used" and the reset.
struct ClaudeLimitRow: View {
    let window: PlanWindow
    @State private var filled = false

    var body: some View {
        HStack(spacing: 8) {
            Text(ClaudeUsageResponse.title(for: window))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .frame(width: 118, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(PlanBar.color(for: window.usedPercent))
                        .frame(width: max(4, geometry.size.width * (filled ? min(window.usedPercent, 100) : 0) / 100))
                }
            }
            .frame(height: 6)
            Text(Format.used(window))
                .foregroundStyle(window.usedPercent >= 80 ? PlanBar.color(for: window.usedPercent) : .white.opacity(0.6))
                .lineLimit(1)
                .frame(minWidth: 62, alignment: .trailing)
            Text(window.resetsAt.map { Format.reset($0) } ?? "")
                .foregroundStyle(.white.opacity(0.35))
                .lineLimit(1)
                .frame(width: 84, alignment: .trailing)
        }
        .font(.system(size: 11.5, weight: .bold, design: .rounded))
        .monospacedDigit()
        .onAppear {
            withAnimation(.timingCurve(0.25, 1, 0.4, 1, duration: 0.9).delay(0.3)) { filled = true }
        }
    }
}

/// "as of 2h ago · Open Claude Code to refresh", or why there are no limits.
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

/// Input, output, cache write and cache read for a few periods.
struct ClaudeTokenTable: View {
    let rows: [(String, TokenCounts)]

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 4) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                ForEach(["input", "output", "cache write", "cache read", "total"], id: \.self) { Text($0) }
            }
            .foregroundStyle(.white.opacity(0.35))
            ForEach(rows, id: \.0) { name, tokens in
                GridRow {
                    Text(name).foregroundStyle(.white.opacity(0.6)).gridColumnAlignment(.leading)
                    ForEach(Array([tokens.input, tokens.output, tokens.cacheWrite, tokens.cacheRead].enumerated()), id: \.offset) { _, value in
                        Text(Format.tokens(value)).foregroundStyle(.white.opacity(0.6))
                    }
                    Text(Format.tokens(tokens.total)).foregroundStyle(.white)
                }
            }
        }
        .font(.system(size: 10.5, weight: .bold, design: .rounded))
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One model: name, a bar split by token kind (scaled to the busiest model), 7-day and today totals.
struct ClaudeModelRow: View {
    let usage: ModelUsage
    let peak: Int64
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(Format.modelName(usage.model))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)
            GeometryReader { geometry in
                let width = geometry.size.width * CGFloat(Double(usage.week.total) / Double(max(peak, 1)))
                HStack(spacing: 1) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        Rectangle().fill(part.1)
                            .frame(width: max(part.0 > 0 ? 1.5 : 0, width * CGFloat(Double(part.0) / Double(max(usage.week.total, 1)))))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 6)
            Text(Format.tokens(usage.week.total))
                .foregroundStyle(.white)
                .frame(width: 44, alignment: .trailing)
            Text(usage.today.isZero ? "–" : Format.tokens(usage.today.total))
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 44, alignment: .trailing)
                .help("today")
        }
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .monospacedDigit()
    }

    private var parts: [(Int64, Color)] {
        [(usage.week.input, Color.white.opacity(0.9)), (usage.week.output, tint),
         (usage.week.cacheWrite, tint.opacity(0.55)), (usage.week.cacheRead, tint.opacity(0.28))]
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
