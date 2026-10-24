import AppKit
import IslandCore
import IslandSystem
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Screen Time

/// Screen Time: where the day (or week) went, app by app. Brim keeps its own count from the day
/// you first open this tab.
struct ScreenTimeTabView: View {
    enum Sub: String { case today, week }

    @ObservedObject var tracker: ScreenTimeTracker
    @State private var sub: Sub
    @Environment(\.islandTheme) private var theme

    init(tracker: ScreenTimeTracker, sub: String? = nil) {
        self.tracker = tracker
        _sub = State(initialValue: sub.flatMap(Sub.init(rawValue:)) ?? .today)
    }

    var body: some View {
        if !tracker.enabled {
            ConnectCard(symbol: "hourglass", color: Palette.purple, title: "See where the day goes",
                        message: "Brim can note which app is in front, on this Mac only. Nothing leaves your Mac, and window titles are never read.",
                        actions: [.init(title: "Start tracking") { tracker.enable() }],
                        note: "Apple doesn't let apps read Screen Time, so Brim keeps its own count from today.")
        } else if tracker.log.day(Date()).total < 60 && sub == .today && tracker.log.days.count <= 1 {
            ConnectCard(symbol: "hourglass", color: Palette.purple, title: "Tracking started",
                        message: "Brim notes which app is in front, on this Mac only. Check back in an hour to see where the day went.",
                        actions: [.init(title: "Turn off", primary: false) { tracker.disable() }])
        } else {
            content
        }
    }

    private var content: some View {
        let log = tracker.log
        let today = log.day(Date())
        let yesterday = log.day(Date().addingTimeInterval(-86_400))
        let week = log.week()
        let days = sub == .today ? [today] : week.map(\.day)
        let apps = log.topApps(days)
        let total = days.reduce(0) { $0 + $1.total }
        return VStack(spacing: 10) {
            HStack {
                SegmentedPills(options: [(Sub.today, "Today"), (.week, "This week")], selection: $sub)
                Spacer()
                if let start = log.startedAt {
                    Text("Tracked by Brim since \(DateFormatter.localizedString(from: start, dateStyle: .medium, timeStyle: .none))")
                        .font(.brim(11, .bold)).foregroundStyle(theme.f(0.45))
                }
            }
            HStack(spacing: 10) {
                IslandCard(padding: EdgeInsets(top: 14, leading: 18, bottom: 12, trailing: 18)) {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionTitle(title: sub == .today ? "Today" : "This week")
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(Clock.hm(total)).font(.brim(32))
                            if sub == .today {
                                let delta = today.total - yesterday.total
                                Text(yesterday.total > 0 ? "\(Clock.hm(abs(delta))) \(delta <= 0 ? "less" : "more") than yesterday" : "first day")
                                    .font(.brim(12)).foregroundStyle(theme.f(0.5))
                            } else {
                                Text("avg \(Clock.hm(total / 7)) a day").font(.brim(12)).foregroundStyle(theme.f(0.5))
                            }
                        }
                        BarColumns(bars: bars(today: today, week: week))
                            .padding(.top, 8)
                    }
                }
                IslandCard(padding: EdgeInsets(top: 14, leading: 12, bottom: 8, trailing: 12)) {
                    VStack(alignment: .leading, spacing: 2) {
                        SectionTitle(title: "Apps").padding(.horizontal, 6).padding(.bottom, 6)
                        let top = apps.first?.seconds ?? 1
                        ForEach(apps, id: \.id) { app in
                            HStack(spacing: 10) {
                                Group {
                                    if let icon = ScreenTimeTracker.icon(for: app.id), !AppSettings.isSnapshot {
                                        Image(nsImage: icon).resizable()
                                    } else {
                                        Text(String(app.name.prefix(1))).font(.brim(11))
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                            .background(RoundedRectangle(cornerRadius: 7).fill(theme.f(0.1)))
                                    }
                                }
                                .frame(width: 24, height: 24)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(app.name).font(.brim(12.5, .bold)).lineLimit(1)
                                    MiniBar(fraction: app.seconds / top, height: 4)
                                }
                                Text(Clock.hm(app.seconds)).font(.brim(12.5)).frame(width: 56, alignment: .trailing)
                            }
                            .padding(.horizontal, 6)
                            .frame(height: 34)
                        }
                    }
                }
                .frame(width: 330)
            }
        }
    }

    private func bars(today: ScreenTimeLog.Day, week: [(label: String, day: ScreenTimeLog.Day)]) -> [BarColumns.Bar] {
        if sub == .week {
            return week.enumerated().map { index, item in
                BarColumns.Bar(value: item.day.total, label: item.label, highlight: index == week.count - 1)
            }
        }
        let current = Calendar.current.component(.hour, from: Date())
        let first = min(today.hours.keys.min() ?? 8, 8)
        let last = max(current, first + 8)
        return (first...last).map { hour in
            BarColumns.Bar(value: today.hours[hour] ?? 0, label: hour % 4 == 0 ? "\(hour)" : "", highlight: hour == current)
        }
    }
}

// MARK: - Clipboard

/// Clipboard: everything you copied, searchable. Click to copy again; pin what you reuse.
struct ClipboardTabView: View {
    enum Filter: String, CaseIterable { case all, text, link, image, files, pinned

        var title: String {
            switch self {
            case .all: return "All"
            case .text: return "Text"
            case .link: return "Links"
            case .image: return "Images"
            case .files: return "Files"
            case .pinned: return "Pinned"
            }
        }

        func matches(_ item: ClipItem) -> Bool {
            switch self {
            case .all: return true
            case .pinned: return item.pinned
            case .text: return item.kind == .text
            case .link: return item.kind == .link
            case .image: return item.kind == .image
            case .files: return item.kind == .files
            }
        }
    }

    @ObservedObject var clipboard: ClipboardService
    @State private var query = ""
    @State private var selected: String?
    @State private var filter: Filter = .all
    @State private var showIgnored = false
    @Environment(\.islandTheme) private var theme

    private var shown: [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return clipboard.items.filter { filter.matches($0) && (q.isEmpty || $0.text.localizedCaseInsensitiveContains(q) || ($0.app ?? "").localizedCaseInsensitiveContains(q)) }
    }

    var body: some View {
        if !clipboard.enabled {
            ConnectCard(symbol: "doc.on.clipboard", color: Palette.blue, title: "Keep a clipboard history",
                        message: "Brim remembers what you copy so you can find it again. It skips anything password managers mark as private, and forgets everything except pins when you quit.",
                        actions: [.init(title: "Turn on") { clipboard.enable() }])
        } else {
            HStack(spacing: 10) {
                IslandCard(padding: EdgeInsets(top: 10, leading: 10, bottom: 8, trailing: 10)) {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            IslandField(placeholder: "Search text or app", text: $query, symbol: "magnifyingglass")
                            IslandButton(title: "Clear", height: 30, fontSize: 11.5) { clipboard.clear() }
                        }
                        filters
                        if showIgnored {
                            ignoredList
                        } else if shown.isEmpty {
                            Spacer()
                            Text(clipboard.items.isEmpty ? "Copy something and it shows up here." : "Nothing matches.")
                                .font(.brim(12.5, .bold)).foregroundStyle(theme.f(0.45))
                            Spacer()
                        } else {
                            IslandScroll {
                                VStack(spacing: 2) {
                                    ForEach(shown) { item in row(item) }
                                }
                            }
                        }
                        footer
                    }
                }
                preview.frame(width: 300)
            }
        }
    }

    private var filters: some View {
        HStack(spacing: 2) {
            ForEach(Filter.allCases, id: \.self) { option in
                let count = clipboard.items.filter(option.matches).count
                if option == .all || count > 0 {
                    HStack(spacing: 4) {
                        Text(option.title).font(.brim(11))
                        if option != .all { Text("\(count)").font(.brim(10, .bold)).opacity(0.55) }
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .foregroundStyle(filter == option ? theme.bg : theme.f(0.65))
                    .background(Capsule().fill(filter == option ? theme.fg : .clear))
                    .contentShape(Capsule())
                    .onTapGesture { filter = option }
                    .accessibilityLabel("\(option.title), \(count)")
                    .accessibilityAddTraits(filter == option ? [.isButton, .isSelected] : .isButton)
                }
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "hand.raised.fill").font(.system(size: 9, weight: .bold))
                Text("Ignoring \(clipboard.ignoredInstalled.count) app\(clipboard.ignoredInstalled.count == 1 ? "" : "s")").font(.brim(10.5, .bold))
                Image(systemName: showIgnored ? "chevron.down" : "chevron.up").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(theme.f(0.5))
            .padding(.horizontal, 6)
            .frame(height: 20)
            .hoverFill(6, hover: theme.f(0.08))
            .onTapGesture { showIgnored.toggle() }
            .help("Copies made in these apps are never kept")
            .accessibilityAddTraits(.isButton)
            Spacer()
            Text("Keep after quitting").font(.brim(10.5, .bold)).foregroundStyle(theme.f(0.5))
            IslandSwitch(isOn: $clipboard.keepHistory, label: "Keep history after quitting")
                .scaleEffect(0.8)
        }
        .padding(.horizontal, 4)
        .frame(height: 20)
    }

    /// Apps whose copies are never kept; right-click any item to add its app.
    private var ignoredList: some View {
        IslandScroll {
            VStack(alignment: .leading, spacing: 2) {
                Text("Copies made in these apps are never kept. Right-click an item to add its app.")
                    .font(.brim(11, .bold)).foregroundStyle(theme.f(0.5)).padding(.horizontal, 10).padding(.bottom, 4)
                ForEach(clipboard.ignoredInstalled, id: \.self) { bundle in
                    HStack(spacing: 9) {
                        if let icon = ClipboardService.appIcon(bundle) {
                            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "app").font(.system(size: 11, weight: .semibold)).frame(width: 16).opacity(0.6)
                        }
                        Text(ClipboardService.appName(bundle)).font(.brim(12.5, .bold)).lineLimit(1)
                        Spacer()
                        IslandButton(title: "Stop ignoring", height: 22, fontSize: 10.5) { clipboard.unignore(bundle) }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                }
            }
        }
    }

    private func row(_ item: ClipItem) -> some View {
        HStack(spacing: 9) {
            if let icon = ClipboardService.appIcon(item.bundle) {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: item.symbol).font(.system(size: 11, weight: .semibold)).frame(width: 16).opacity(0.6)
            }
            if let color = ClipText.hexColor(item.text) {
                RoundedRectangle(cornerRadius: 3).fill(Color(red: color.red, green: color.green, blue: color.blue)).frame(width: 12, height: 12)
            }
            Text(item.text.replacingOccurrences(of: "\n", with: " ")).font(.brim(12.5, .bold)).lineLimit(1)
            Spacer(minLength: 6)
            if item.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(theme.f(0.7)) }
            Text(Format.ago(item.date)).font(.brim(10.5, .bold)).foregroundStyle(theme.f(0.4)).fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .hoverFill(10, base: selected == item.id ? theme.f(0.1) : .clear, hover: theme.f(0.08))
        .onTapGesture { selected = item.id }
        .simultaneousGesture(TapGesture(count: 2).onEnded { clipboard.copy(item) })
        .contextMenu {
            Button("Copy") { clipboard.copy(item) }
            Button(item.pinned ? "Unpin" : "Pin") { clipboard.togglePin(item) }
            if let bundle = item.bundle {
                Button("Never keep from \(item.app ?? ClipboardService.appName(bundle))") { clipboard.ignore(bundle) }
            }
            Divider()
            Button("Delete", role: .destructive) { clipboard.delete(item) }
        }
        .help("Double-click to copy")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var preview: some View {
        let item = clipboard.items.first { $0.id == selected } ?? shown.first
        IslandCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Preview", aside: item.map { [$0.app, Format.ago($0.date)].compactMap { $0 }.joined(separator: " · ") })
                if let item {
                    if let data = item.image, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 10))
                    } else if let color = ClipText.hexColor(item.text) {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 12).fill(Color(red: color.red, green: color.green, blue: color.blue))
                                .frame(width: 64, height: 64)
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.f(0.15)))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.text.uppercased()).font(.system(size: 15, weight: .bold, design: .monospaced))
                                Text("rgb(\(Int(color.red * 255)), \(Int(color.green * 255)), \(Int(color.blue * 255)))")
                                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(theme.f(0.55))
                            }
                        }
                    } else {
                        Text(item.text).font(item.kind == .text && item.text.contains("(") ? .system(size: 12, design: .monospaced) : .brim(13, .bold))
                            .lineLimit(7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                    Text(detail(item)).font(.brim(10.5, .bold)).foregroundStyle(theme.f(0.45)).lineLimit(1)
                    HStack(spacing: 6) {
                        IslandButton(title: "Copy", style: .primary, height: 28) { clipboard.copy(item) }
                        IslandButton(title: item.pinned ? "Unpin" : "Pin", height: 28) { clipboard.togglePin(item) }
                        if item.kind == .link, let url = URL(string: Links.normalized(item.text)) {
                            IslandButton(title: "Open", height: 28) { NSWorkspace.shared.open(url) }
                        } else if ClipText.isEmail(item.text), let url = URL(string: "mailto:" + item.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            IslandButton(title: "Email", height: 28) { NSWorkspace.shared.open(url) }
                        } else if item.kind == .files, let first = item.files.first {
                            IslandButton(title: "Reveal", height: 28) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: first)]) }
                        }
                        Spacer()
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 26, height: 26)
                            .hoverFill(13, hover: theme.f(0.1))
                            .onTapGesture { clipboard.delete(item) }
                            .accessibilityLabel("Delete")
                    }
                } else {
                    Spacer()
                }
            }
        }
    }

    private func detail(_ item: ClipItem) -> String {
        switch item.kind {
        case .image: return item.text
        case .files: return "\(item.files.count) file\(item.files.count == 1 ? "" : "s")"
        case .link: return URL(string: Links.normalized(item.text))?.host ?? "Link"
        case .text: return ClipText.isEmail(item.text) ? "Email address" : ClipText.hexColor(item.text) != nil ? "Colour" : ClipText.stats(item.text)
        }
    }
}

// MARK: - Files

/// Files: drop images (here or on the closed notch), pick a format, convert. New files land next to
/// the originals, which stay as they are, and can be dragged straight out.
struct FilesTabView: View {
    @ObservedObject var converter: ConvertService
    @State private var targeted = false
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            filesPanel
            convertPanel.frame(width: 470)
        }
    }

    // MARK: Queue

    private var filesPanel: some View {
        IslandCard(padding: EdgeInsets(top: 12, leading: 10, bottom: 10, trailing: 10)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 11, weight: .semibold)).opacity(0.6)
                    SectionTitle(title: "Files").fixedSize()
                    Spacer()
                    if converter.queuedBytes > 0 {
                        Text(Bytes.format(Double(converter.queuedBytes))).font(.brim(11, .bold)).foregroundStyle(theme.f(0.45))
                    }
                    IconButton(symbol: "plus", help: "Add images", size: 24) { choose() }
                    if !converter.queue.isEmpty {
                        IconButton(symbol: "xmark", help: "Clear", size: 24) { converter.clear() }
                    }
                }
                .padding(.horizontal, 4)
                if converter.queue.isEmpty && converter.results.isEmpty {
                    dropZone
                } else {
                    IslandScroll {
                        VStack(spacing: 4) {
                            ForEach(converter.queue, id: \.self) { url in
                                fileRow(url, detail: ImageConverter.size(url) > 0 ? Bytes.format(Double(ImageConverter.size(url))) : url.pathExtension.uppercased()) { converter.remove(url) }
                            }
                            if !converter.results.isEmpty {
                                HStack {
                                    SectionTitle(title: "Converted", aside: "drag out or reveal")
                                    Text("Clear").font(.brim(11, .bold)).foregroundStyle(theme.f(0.45))
                                        .onTapGesture { converter.clearResults() }
                                        .accessibilityAddTraits(.isButton)
                                }
                                .padding(.horizontal, 6)
                                .padding(.top, 8)
                                ForEach(converter.results) { result in resultRow(result) }
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(theme.f(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
        }
        .fileDrop(isTargeted: $targeted) { providers in
            load(providers)
            return true
        }
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 24, weight: .semibold)).opacity(0.7)
            Text("Drop images here").font(.brim(15))
            Text("Or drag them onto the closed notch.").font(.brim(12, .bold)).foregroundStyle(theme.f(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileRow(_ url: URL, detail: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).font(.brim(12.5, .bold)).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.brim(11, .bold)).foregroundStyle(theme.f(0.45))
            }
            Spacer(minLength: 4)
            Image(systemName: "minus")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(theme.f(0.1)))
                .onTapGesture(perform: remove)
                .accessibilityLabel("Remove \(url.lastPathComponent)")
                .accessibilityAddTraits(.isButton)
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.f(0.05)))
    }

    private func resultRow(_ result: ImageConverter.Result) -> some View {
        HStack(spacing: 10) {
            Image(systemName: result.error == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(result.error == nil ? Palette.green : Palette.amber)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.output?.lastPathComponent ?? result.source.lastPathComponent).font(.brim(12.5, .bold)).lineLimit(1).truncationMode(.middle)
                Text(result.error ?? "\(Bytes.format(Double(result.before))) → \(Bytes.format(Double(result.after)))\(Self.saving(result))")
                    .font(.brim(11, .bold)).foregroundStyle(theme.f(0.5))
            }
            Spacer(minLength: 4)
            if let output = result.output {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
                    .hoverFill(11, hover: theme.f(0.1))
                    .onTapGesture { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                    .help("Show in Finder")
                    .accessibilityLabel("Show in Finder")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.f(0.05)))
        .onDrag { result.output.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
    }

    static func saving(_ result: ImageConverter.Result) -> String {
        guard result.before > 0, result.after > 0, result.after < result.before else { return "" }
        return " · \(Int((1 - Double(result.after) / Double(result.before)) * 100))% smaller"
    }

    // MARK: Convert

    private var convertPanel: some View {
        IslandCard(padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11, weight: .semibold)).opacity(0.6)
                    SectionTitle(title: "Convert to")
                }
                HStack(spacing: 8) {
                    ForEach(ImageConverter.Format.allCases) { format in
                        let on = format == converter.format
                        VStack(spacing: 8) {
                            Image(systemName: Self.symbol(format)).font(.system(size: 18, weight: .semibold))
                            Text(format.title).font(.brim(12))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 76)
                        .foregroundStyle(on ? theme.bg : theme.fg)
                        .hoverFill(14, base: on ? theme.fg : theme.f(0.07), hover: on ? theme.fg : theme.f(0.12))
                        .onTapGesture { converter.format = format }
                        .accessibilityLabel(format.title)
                        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                    }
                }
                if converter.format == .jpeg || converter.format == .heic {
                    HStack(spacing: 12) {
                        Text("QUALITY").font(.brim(10)).kerning(1.2).foregroundStyle(theme.f(0.45)).frame(width: 70, alignment: .leading)
                        IslandSlider(value: $converter.quality, range: 0.3...1, label: "Quality")
                        Text("\(Int(converter.quality * 100))%").font(.brim(12)).frame(width: 36, alignment: .trailing)
                    }
                }
                HStack(spacing: 12) {
                    Text("MAX SIZE").font(.brim(10)).kerning(1.2).foregroundStyle(theme.f(0.45)).frame(width: 70, alignment: .leading)
                    SegmentedPills(options: [(0, "Original"), (1024, "1,024px"), (1920, "1,920px"), (2560, "2,560px")],
                                   selection: $converter.maxSide, look: .strong, height: 24)
                }
                Text("macOS reads WebP but can't write it. HEIC is usually smallest; JPEG is the safe choice for the web. PDF puts each image on its own page.")
                    .font(.brim(11.5, .bold)).foregroundStyle(theme.f(0.45)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack {
                    if converter.working { Spinner(size: 12); Text("Converting…").font(.brim(12, .bold)) }
                    Spacer()
                    IslandButton(title: converter.queue.isEmpty ? "Add images to convert" : "Convert \(converter.queue.count) to \(converter.format.title)",
                                 style: converter.queue.isEmpty ? .secondary : .primary, height: 32, fontSize: 12.5) {
                        if converter.queue.isEmpty { choose() } else { converter.convert() }
                    }
                }
            }
        }
    }

    static func symbol(_ format: ImageConverter.Format) -> String {
        switch format {
        case .jpeg: return "photo"
        case .png: return "photo.on.rectangle"
        case .heic: return "photo.stack"
        case .pdf: return "doc.richtext"
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { converter.add(panel.urls) }
    }

    private func load(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in converter.add([url]) }
            }
        }
    }
}
