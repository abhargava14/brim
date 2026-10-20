import AppKit
import IslandCore
import IslandServices
import ServiceManagement
import SwiftUI

/// First-launch flow: pick tools found on this Mac, then how the island should look.
struct FirstRunView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var settings: AppSettings
    let finished: () -> Void

    @State private var step = 0
    @State private var logTools: [DetectedTool] = []
    @State private var signInTools: [DetectedTool] = []
    @State private var selected = Set<ToolKind>()
    @State private var plans: [ToolKind: String] = [:]
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var signingIn: ToolKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if step == 0 { findTools } else { howItLooks }
            footer
        }
        .padding(22)
        .frame(width: 520)
        .task { await scan() }
    }

    // MARK: Step 1

    private var findTools: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(
                title: "Welcome to Brim",
                subtitle: logTools.isEmpty && signInTools.isEmpty
                    ? "No AI tools found yet. Sign in to one below, or skip and add them later."
                    : "We found these tools on your Mac. Choose which ones to show in the notch."
            )

            if !logTools.isEmpty {
                sectionTitle("Found on this Mac")
                VStack(spacing: 0) {
                    ForEach(logTools) { tool in
                        foundRow(tool)
                        if tool.id != logTools.last?.id { Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
            }

            if !signInTools.isEmpty {
                sectionTitle("Needs sign-in")
                VStack(spacing: 0) {
                    ForEach(signInTools) { tool in
                        signInRow(tool)
                        if tool.id != signInTools.last?.id { Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
            }

            Text("Local logs stay on this Mac. Add Windsurf, OpenRouter and second accounts later in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func foundRow(_ tool: DetectedTool) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { selected.contains(tool.kind) },
                set: { on in
                    if on { selected.insert(tool.kind) } else { selected.remove(tool.kind) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            ToolGlyph(kind: tool.kind, mood: .idle, size: 16, playful: settings.playful)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.kind.displayName).font(.body.weight(.semibold))
                Text(tool.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Picker("", selection: Binding(
                get: { plans[tool.kind] ?? Plans.automatic },
                set: { plans[tool.kind] = $0 }
            )) {
                Text("Automatic").tag(Plans.automatic)
                ForEach(Plans.options(for: tool.kind)) { tier in
                    Text(tier.name).tag(tier.id)
                }
            }
            .labelsHidden()
            .frame(width: 120)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func signInRow(_ tool: DetectedTool) -> some View {
        HStack(spacing: 10) {
            ToolGlyph(kind: tool.kind, mood: .idle, size: 16, playful: settings.playful)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.kind.displayName).font(.body.weight(.semibold))
                Text(tool.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(signingIn == tool.kind ? "Signing in…" : "Sign in…") {
                signingIn = tool.kind
                selected.insert(tool.kind)
                _ = model.addAccount(tool.kind)
                signingIn = nil
            }
            .disabled(signingIn != nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Step 2

    private var howItLooks: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(title: "How should it look?", subtitle: "You can change all of this in Settings.")

            islandPreview
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))

            VStack(spacing: 0) {
                lookRow(title: "Style", detail: "Playful animates icons and moments. Calm stays still.") {
                    Picker("", selection: $settings.playful) {
                        Text("Playful").tag(true)
                        Text("Calm").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 160)
                }
                Divider()
                lookRow(title: "Show in", detail: nil) {
                    Picker("", selection: $settings.placement) {
                        ForEach(IslandPlacement.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                Divider()
                lookRow(title: "Open at login", detail: nil) {
                    Toggle("", isOn: $launchAtLogin).labelsHidden()
                        .onChange(of: launchAtLogin) { enabled in
                            guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
                            try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
        }
    }

    private var islandPreview: some View {
        let kinds = previewKinds
        return VStack(spacing: 8) {
            HStack(spacing: 0) {
                previewWing(kinds.first, sample: "84%")
                Capsule().fill(Color.black.opacity(0.15)).frame(width: 72, height: 10)
                previewWing(kinds.count > 1 ? kinds[1] : nil, sample: "22%", trailing: true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.black))
            .frame(width: 280)
            Text(kinds.isEmpty ? "Preview · connect a tool to see it here" : "Preview · your \(kinds.count) connection\(kinds.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var previewKinds: [ToolKind] {
        let ordered = (logTools.map(\.kind) + signInTools.map(\.kind)).filter(selected.contains)
        return ordered.isEmpty ? Array(selected) : ordered
    }

    private func previewWing(_ kind: ToolKind?, sample: String, trailing: Bool = false) -> some View {
        HStack(spacing: 5) {
            if trailing { Spacer(minLength: 0) }
            if let kind {
                ToolGlyph(kind: kind, mood: .idle, size: 12, playful: settings.playful)
                Text(sample)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            if !trailing { Spacer(minLength: 0) }
        }
        .frame(width: 72)
    }

    // MARK: Shared

    private func header(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.bold())
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func lookRow<Trailing: View>(title: String, detail: String?, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Text(step == 0 ? "Step 1 of 2" : "Step 2 of 2")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if step == 0 {
                Button("Skip") { skip() }
                Button("Continue") { applySelection(); step = 1 }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Back") { step = 0 }
                Button("Done") { done() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.top, 18)
    }

    // MARK: Actions

    private func scan() async {
        let logs = await Task.detached { ToolDetection.logTools() }.value
        var signIns: [DetectedTool] = []
        let foundKinds = await Task.detached { LocalSignIns.found() }.value
        for kind in [ToolKind.cursor, .copilot, .windsurf] where foundKinds.contains(kind) || kind == .cursor || kind == .copilot {
            if logs.contains(where: { $0.kind == kind }) { continue }
            let detail: String
            switch kind {
            case .cursor: detail = LocalSignIns.appStatus(.cursor).isSignedIn ? "Signed in on this Mac" : "Usage from your Cursor account"
            case .copilot: detail = "Premium requests from GitHub"
            case .windsurf: detail = LocalSignIns.appStatus(.windsurf).isSignedIn ? "Signed in on this Mac" : "Usage from Windsurf"
            default: detail = kind.blurb
            }
            // Always offer Cursor and Copilot; Windsurf only when found.
            if kind == .windsurf, !foundKinds.contains(kind) { continue }
            signIns.append(DetectedTool(kind: kind, detail: detail, recentlyActive: true, needsSignIn: true))
        }
        logTools = logs
        signInTools = signIns
        selected = Set(logs.filter(\.shouldPreCheck).map(\.kind))
        for tool in logs { plans[tool.kind] = Plans.automatic }
    }

    private func applySelection() {
        for kind in selected {
            if settings.connections.contains(where: { $0.kind == kind }) { continue }
            var connection = settings.add(kind)
            if let plan = plans[kind] { connection.planID = plan; settings.update(connection) }
            model.connect(connection.id)
        }
        // Disconnect kinds the user unchecked that we just would have added — only leave enabled what they picked among log tools.
        for tool in logTools where !selected.contains(tool.kind) {
            for connection in settings.connections where connection.kind == tool.kind {
                model.disconnect(connection.id)
            }
        }
    }

    private func skip() {
        UserDefaults.standard.set(true, forKey: "didOnboard")
        settings.pendingIslandTip = true
        finished()
    }

    private func done() {
        applySelection()
        UserDefaults.standard.set(true, forKey: "didOnboard")
        settings.pendingIslandTip = true
        finished()
    }
}
