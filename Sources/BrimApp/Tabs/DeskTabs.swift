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
                                    .font(.brim(12)).foregroundStyle(delta <= 0 ? Palette.green : theme.f(0.5))
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
    @ObservedObject var clipboard: ClipboardService
    @State private var query = ""
    @State private var selected: String?
    @Environment(\.islandTheme) private var theme

    private var shown: [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return clipboard.items.filter { q.isEmpty || $0.text.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        if !clipboard.enabled {
            ConnectCard(symbol: "doc.on.clipboard", color: Palette.blue, title: "Keep a clipboard history",
                        message: "Brim remembers what you copy so you can find it again. It skips anything password managers mark as private, and forgets everything except pins when you quit.",
                        actions: [.init(title: "Turn on") { clipboard.enable() }])
        } else {
            HStack(spacing: 10) {
                IslandCard(padding: EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)) {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            IslandField(placeholder: "Search what you copied", text: $query, symbol: "magnifyingglass")
                            IslandButton(title: "Clear", height: 30, fontSize: 11.5) { clipboard.clear() }
                        }
                        if shown.isEmpty {
                            Spacer()
                            Text(clipboard.items.isEmpty ? "Copy something and it shows up here." : "Nothing matches.")
                                .font(.brim(12.5, .bold)).foregroundStyle(theme.f(0.45))
                            Spacer()
                        }
                        IslandScroll {
                            VStack(spacing: 2) {
                                ForEach(shown) { item in row(item) }
                            }
                        }
                    }
                }
                preview.frame(width: 300)
            }
        }
    }

    private func row(_ item: ClipItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol).font(.system(size: 11, weight: .semibold)).frame(width: 16).opacity(0.6)
            Text(item.text.replacingOccurrences(of: "\n", with: " ")).font(.brim(12.5, .bold)).lineLimit(1)
            Spacer(minLength: 6)
            if item.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Palette.amber) }
            Text(Format.ago(item.date)).font(.brim(10.5, .bold)).foregroundStyle(theme.f(0.4)).fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .hoverFill(10, base: selected == item.id ? theme.f(0.1) : .clear, hover: theme.f(0.08))
        .onTapGesture { selected = item.id }
        .simultaneousGesture(TapGesture(count: 2).onEnded { clipboard.copy(item) })
        .contextMenu {
            Button("Copy") { clipboard.copy(item) }
            Button(item.pinned ? "Unpin" : "Pin") { clipboard.togglePin(item) }
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
                SectionTitle(title: "Preview", aside: item?.app)
                if let item {
                    if let data = item.image, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        Text(item.text).font(item.kind == .text && item.text.contains("(") ? .system(size: 12, design: .monospaced) : .brim(13, .bold))
                            .lineLimit(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        IslandButton(title: "Copy", style: .primary, height: 28) { clipboard.copy(item) }
                        IslandButton(title: item.pinned ? "Unpin" : "Pin", height: 28) { clipboard.togglePin(item) }
                        if item.kind == .link, let url = URL(string: Links.normalized(item.text)) {
                            IslandButton(title: "Open", height: 28) { NSWorkspace.shared.open(url) }
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
}

// MARK: - Shelf

/// Shelf: drop files in to keep them handy, drag them out anywhere else.
struct ShelfTabView: View {
    @ObservedObject var shelf: ShelfService
    @State private var targeted = false
    @Environment(\.islandTheme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            if shelf.files.isEmpty {
                dropZone(big: true)
            } else {
                HStack {
                    Text("\(shelf.files.count) file\(shelf.files.count == 1 ? "" : "s") on the shelf").font(.brim(12.5))
                    Spacer()
                    IslandButton(title: "AirDrop", height: 28, fontSize: 11.5, symbol: "airplayaudio") { shelf.airDrop(shelf.files) }
                    IslandButton(title: "Show in Finder", height: 28, fontSize: 11.5) { shelf.reveal(shelf.files) }
                    IslandButton(title: "Clear", height: 28, fontSize: 11.5) { shelf.clear() }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                    ForEach(shelf.files, id: \.self) { url in tile(url) }
                }
                Spacer(minLength: 0)
                dropZone(big: false)
            }
        }
        .fileDrop(isTargeted: $targeted) { providers in
            load(providers)
            return true
        }
    }

    private func dropZone(big: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: big ? 26 : 15, weight: .semibold))
            Text(big ? "Drop files here" : "Drop more files").font(.brim(big ? 16 : 12.5))
            if big {
                Text("They stay on the shelf until you drag them out or clear it. Nothing is copied or moved.")
                    .font(.brim(12.5, .bold)).foregroundStyle(theme.f(0.55))
            }
        }
        .foregroundStyle(targeted ? theme.fg : theme.f(0.7))
        .frame(maxWidth: .infinity, maxHeight: big ? .infinity : 52)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(theme.f(targeted ? 0.12 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(theme.f(targeted ? 0.6 : 0.25), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
    }

    private func tile(_ url: URL) -> some View {
        VStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 48, height: 48)
            Text(url.lastPathComponent).font(.brim(11, .bold)).lineLimit(2).multilineTextAlignment(.center)
            Text(Bytes.format(Double(ImageConverter.size(url)))).font(.brim(10, .bold)).foregroundStyle(theme.f(0.4))
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 116)
        .hoverFill(14, base: theme.f(0.06), hover: theme.f(0.11))
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { shelf.reveal([url]) }
            Button("AirDrop") { shelf.airDrop([url]) }
            Divider()
            Button("Remove from shelf") { shelf.remove(url) }
        }
        .help(url.path)
    }

    private func load(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in shelf.add([url]) }
            }
        }
    }
}

// MARK: - Files

/// Files: drop images to convert and shrink them to JPEG, PNG, HEIC or a PDF.
struct FilesTabView: View {
    @State private var format: ImageConverter.Format = .jpeg
    @State private var quality = 0.8
    @State private var maxSide = 0
    @State private var results: [ImageConverter.Result] = []
    @State private var targeted = false
    @State private var working = false
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 10) {
                VStack(spacing: 8) {
                    if working {
                        Spinner(size: 22, line: 3)
                        Text("Converting…").font(.brim(14))
                    } else {
                        Image(systemName: "wand.and.stars").font(.system(size: 26, weight: .semibold)).foregroundStyle(Palette.purple)
                        Text("Drop images to convert").font(.brim(16))
                        Text("New files go next to the originals, which stay as they are.").font(.brim(12.5, .bold)).foregroundStyle(theme.f(0.55))
                        IslandButton(title: "Choose images…", height: 30) { choose() }.padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(theme.f(targeted ? 0.12 : 0.05)))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(theme.f(targeted ? 0.6 : 0.25), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                .fileDrop(isTargeted: $targeted) { providers in
                    collect(providers)
                    return true
                }
                if !results.isEmpty {
                    IslandCard(padding: EdgeInsets(top: 10, leading: 12, bottom: 8, trailing: 12)) {
                        VStack(alignment: .leading, spacing: 2) {
                            SectionTitle(title: "Done", aside: "before → after").padding(.horizontal, 4).padding(.bottom, 4)
                            ForEach(results.prefix(3)) { result in
                                HStack(spacing: 8) {
                                    Image(systemName: result.error == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(result.error == nil ? Palette.green : Palette.amber)
                                    Text(result.output?.lastPathComponent ?? result.source.lastPathComponent).font(.brim(12, .bold)).lineLimit(1)
                                    Spacer()
                                    Text(result.error ?? "\(Bytes.format(Double(result.before))) → \(Bytes.format(Double(result.after)))")
                                        .font(.brim(11.5)).foregroundStyle(theme.f(0.6))
                                    if let output = result.output {
                                        Image(systemName: "magnifyingglass")
                                            .font(.system(size: 10, weight: .bold))
                                            .frame(width: 20, height: 20)
                                            .hoverFill(10, hover: theme.f(0.1))
                                            .onTapGesture { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                                            .accessibilityLabel("Show in Finder")
                                    }
                                }
                                .frame(height: 24)
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            IslandCard {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(title: "Convert to")
                    SegmentedPills(options: ImageConverter.Format.allCases.map { ($0, $0.title) }, selection: $format, look: .strong)
                    if format == .jpeg || format == .heic {
                        HStack {
                            Text("Quality").font(.brim(12.5, .bold)).foregroundStyle(theme.f(0.7))
                            Spacer()
                            Text("\(Int(quality * 100))%").font(.brim(12.5))
                        }
                        IslandSlider(value: $quality, range: 0.3...1, label: "Quality")
                    }
                    SectionTitle(title: "Longest side").padding(.top, 4)
                    SegmentedPills(options: [(0, "Original"), (3000, "3000"), (1600, "1600"), (800, "800")], selection: $maxSide, height: 24)
                    Spacer(minLength: 0)
                    Text("HEIC keeps photos small with little loss. PDF puts every dropped image on its own page.")
                        .font(.brim(11.5, .bold)).foregroundStyle(theme.f(0.45)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 320)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { convert(panel.urls) }
    }

    private func collect(_ providers: [NSItemProvider]) {
        var urls: [URL] = []
        let group = DispatchGroup()
        let lock = NSLock()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { convert(urls) }
    }

    private func convert(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        working = true
        let format = self.format, quality = self.quality, maxSide = self.maxSide
        Task.detached {
            let done = ImageConverter.convert(urls, to: format, quality: quality, maxSide: maxSide)
            await MainActor.run {
                results = done + results
                working = false
            }
        }
    }
}
