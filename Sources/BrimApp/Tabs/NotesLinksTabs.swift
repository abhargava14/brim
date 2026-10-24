import AppKit
import IslandCore
import SwiftUI

// MARK: - Notes

/// Notes: a searchable list on the left, the open note on the right. Saved on this Mac.
struct NotesTabView: View {
    @ObservedObject var store: NotesStore
    @State private var selected: String?
    @State private var query = ""
    @State private var confirmDelete = false
    @Environment(\.islandTheme) private var theme

    private var current: Note? {
        store.notes.first { $0.id == selected } ?? store.notes.first
    }

    var body: some View {
        if store.notes.isEmpty {
            ConnectCard(symbol: "note.text", color: Palette.yellow, title: "No notes yet",
                        message: "Longer thoughts, kept next to the notch. Notes are saved on this Mac.",
                        actions: [.init(title: "New note") { selected = store.add().id }])
        } else {
            HStack(spacing: 10) {
                list.frame(width: 250)
                editor
            }
        }
    }

    private var list: some View {
        IslandCard(padding: EdgeInsets(top: 12, leading: 10, bottom: 12, trailing: 10)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    SectionTitle(title: "Notes")
                        .fixedSize()
                    Text("\(store.notes.count)").font(.brim(11, .bold)).foregroundStyle(theme.f(0.35))
                    Spacer()
                    IconButton(symbol: "plus", help: "New note", size: 24) {
                        query = ""
                        selected = store.add().id
                    }
                }
                .padding(.horizontal, 6)
                IslandField(placeholder: "Search notes", text: $query)
                IslandScroll {
                    VStack(spacing: 2) {
                        ForEach(store.notes.filter { $0.matches(query) }) { note in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    if note.isPinned {
                                        Image(systemName: "pin.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.f(0.6))
                                    }
                                    Text(note.displayTitle).font(.brim(12.5)).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(Self.when(note.updated)).font(.brim(10.5, .bold)).foregroundStyle(theme.f(0.4))
                                }
                                Text(note.snippet).font(.brim(11.5, .bold)).foregroundStyle(theme.f(0.5)).lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .hoverFill(12, base: note.id == current?.id ? theme.f(0.1) : .clear, hover: theme.f(0.1))
                            .onTapGesture { selected = note.id }
                            .contextMenu {
                                Button(note.isPinned ? "Unpin" : "Pin to top") { store.togglePin(note.id) }
                                Button("Copy text") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString([note.title, note.body].filter { !$0.isEmpty }.joined(separator: "\n\n"), forType: .string)
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    store.delete(note.id)
                                    if selected == note.id { selected = nil }
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let note = current {
            IslandCard(padding: EdgeInsets(top: 14, leading: 18, bottom: 12, trailing: 18)) {
                VStack(alignment: .leading, spacing: 8) {
                    PlainTextField("Title", text: Binding(get: { note.title }, set: { store.update(note.id, title: $0) }), font: .brim(18))
                    NoteBodyEditor(text: Binding(get: { note.body }, set: { store.update(note.id, body: $0) }))
                    HStack(spacing: 8) {
                        Text(Self.when(note.updated))
                        Text("·")
                        Text("\(note.wordCount) words")
                        Spacer()
                        TimelineView(.periodic(from: .now, by: 5)) { context in
                            Text("Saved " + Format.ago(store.savedAt, now: context.date))
                        }
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .hoverFill(11, hover: theme.f(0.1))
                            .onTapGesture { confirmDelete = true }
                            .help("Delete note")
                            .accessibilityLabel("Delete note")
                            .accessibilityAddTraits(.isButton)
                    }
                    .font(.brim(11, .bold))
                    .foregroundStyle(theme.f(0.45))
                    .padding(.top, 8)
                    .overlay(alignment: .top) { Rectangle().fill(theme.f(0.08)).frame(height: 1) }
                }
            }
            .id(note.id)
            .confirmationDialog("Delete “\(note.displayTitle)”?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) {
                    store.delete(note.id)
                    selected = nil
                }
            }
        }
    }

    static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        if calendar.isDateInToday(date) {
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        formatter.setLocalizedDateFormatFromTemplate(date.timeIntervalSinceNow > -6 * 86_400 ? "EEE" : "d MMM")
        return formatter.string(from: date)
    }
}

/// The note body: a plain text editor with no background of its own.
struct NoteBodyEditor: View {
    @Binding var text: String
    var placeholder = "Start writing…"
    var size: CGFloat = 13.5
    @Environment(\.islandTheme) private var theme

    var body: some View {
        ZStack(alignment: .topLeading) {
            if AppSettings.isSnapshot {
                Text(text).font(.brim(size, .bold)).lineSpacing(4).opacity(0.88)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                TextEditor(text: $text)
                    .font(.brim(size, .bold))
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .opacity(0.88)
            }
            if text.isEmpty {
                Text(placeholder).font(.brim(size, .bold)).foregroundStyle(theme.f(0.35)).padding(.leading, 5).allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Links

/// Links: search the web with your engines, and keep the sites you use, sorted into folders.
struct LinksTabView: View {
    @ObservedObject var store: LinksStore
    @State private var query = ""
    @State private var engineID: String?
    @State private var folder = "All"
    @State private var adding = false
    @State private var managing = false
    @State private var draftTitle = ""
    @State private var draftURL = ""
    @State private var draftFolder = "Work"
    @Environment(\.islandTheme) private var theme

    init(store: LinksStore, managing: Bool = false) {
        self.store = store
        _managing = State(initialValue: managing)
    }

    private var shown: [SavedLink] {
        store.links.filter { (folder == "All" || $0.folder == folder) && $0.matches(query) }
    }

    /// The pill picked for this search, else the default.
    private var engine: SearchEngine { store.engines.first { $0.id == engineID } ?? store.defaultEngine }

    /// What Return will do with the text typed so far.
    private var resolved: (engine: SearchEngine, terms: String) {
        SearchEngines.resolve(query, engines: store.engines, fallback: engine)
    }

    var body: some View {
        VStack(spacing: 10) {
            searchCard
            if managing {
                EngineManager(store: store) { managing = false }
            } else {
                savedLinks
            }
        }
    }

    // MARK: Search

    private var searchCard: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .semibold)).opacity(0.6)
                PlainTextField("Search \(engine.name) or your links", text: $query, font: .brim(14, .bold), onSubmit: submit)
                Button(action: submit) {
                    HStack(spacing: 5) {
                        Image(systemName: Links.looksLikeURL(query) ? "arrow.up.right" : "return")
                        Text(Links.looksLikeURL(query) ? "Open" : resolved.engine.name)
                    }
                    .font(.brim(11.5))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .foregroundStyle(query.isEmpty ? theme.f(0.4) : theme.bg)
                    .background(RoundedRectangle(cornerRadius: 10).fill(query.isEmpty ? theme.f(0.08) : theme.fg))
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 14)
            .padding(.trailing, 7)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.f(0.07)))

            HStack(spacing: 4) {
                ForEach(store.pinned) { item in
                    let on = item.id == resolved.engine.id
                    HStack(spacing: 5) {
                        Text(item.name).lineLimit(1)
                        if item.id == store.defaultEngineID {
                            Circle().fill(on ? theme.bg : theme.f(0.5)).frame(width: 4, height: 4)
                        }
                    }
                    .font(.brim(12))
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .foregroundStyle(on ? theme.bg : theme.f(0.65))
                    .background(Capsule().fill(on ? theme.fg : .clear))
                    .contentShape(Capsule())
                    .onTapGesture { engineID = item.id }
                    .contextMenu {
                        Button("Make default") { store.setDefault(item.id) }
                            .disabled(item.id == store.defaultEngineID)
                        Button("Remove from bar") { store.setPinned(item.id, false) }
                            .disabled(item.id == store.defaultEngineID)
                    }
                    .help(item.keyword.isEmpty ? item.name : "\(item.name) · type “\(item.keyword) …”")
                    .accessibilityLabel(item.name + (item.id == store.defaultEngineID ? ", default" : ""))
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                }
                Image(systemName: managing ? "xmark" : "slider.horizontal.3")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 34, height: 28)
                    .foregroundStyle(managing ? theme.bg : theme.f(0.65))
                    .background(Capsule().fill(managing ? theme.fg : .clear))
                    .contentShape(Capsule())
                    .onTapGesture { managing.toggle() }
                    .help("Search engines")
                    .accessibilityLabel("Search engines")
                    .accessibilityAddTraits(.isButton)
            }
            .padding(3)
            .background(Capsule().fill(theme.f(0.05)))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(theme.f(0.05)))
    }

    private func submit() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let matches = shown
        if matches.count == 1, !text.contains(" ") {
            store.open(matches[0])
        } else if Links.looksLikeURL(text), let url = URL(string: Links.normalized(text)) {
            NSWorkspace.shared.open(url)
        } else if let url = resolved.engine.url(for: resolved.terms) {
            NSWorkspace.shared.open(url)
        }
        query = ""
    }

    // MARK: Saved links

    @ViewBuilder
    private var savedLinks: some View {
        IslandCard(padding: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "bookmark.fill").font(.system(size: 10, weight: .bold)).opacity(0.6)
                    SectionTitle(title: "Saved links").fixedSize()
                    if store.folders.count > 0, !store.links.isEmpty {
                        SegmentedPills(options: (["All"] + store.folders).map { ($0, $0) }, selection: $folder, height: 22)
                    }
                    Spacer()
                    Text("\(store.links.count)").font(.brim(11, .bold)).foregroundStyle(theme.f(0.45))
                    IconButton(symbol: "plus", help: "Add a link", size: 24, active: adding, rotation: adding ? 45 : 0) { adding.toggle() }
                }
                if adding { addForm }
                if store.links.isEmpty, !adding {
                    VStack(spacing: 6) {
                        Text("Keep the sites you open every day").font(.brim(14))
                        Text("Add a link with + and open it from here or by typing its name above.")
                            .font(.brim(12, .bold)).foregroundStyle(theme.f(0.5))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    IslandScroll {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                            ForEach(shown) { link in
                                LinkTile(link: link) { store.open(link) } delete: { store.delete(link.id) }
                            }
                        }
                    }
                }
            }
        }
    }

    private var addForm: some View {
        HStack(spacing: 8) {
            IslandField(placeholder: "linear.app", text: $draftURL, symbol: "link", onSubmit: saveDraft)
            IslandField(placeholder: "Title (optional)", text: $draftTitle, onSubmit: saveDraft)
                .frame(width: 170)
            SegmentedPills(options: store.folders.map { ($0, $0) }, selection: $draftFolder, height: 24)
            IslandButton(title: "Save", style: .primary, height: 30, action: saveDraft)
        }
    }

    private func saveDraft() {
        guard !draftURL.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.add(title: draftTitle, url: draftURL, folder: draftFolder)
        draftURL = ""
        draftTitle = ""
        adding = false
    }
}

/// Choose which engines show as pills, pick the default, and add your own.
struct EngineManager: View {
    @ObservedObject var store: LinksStore
    let close: () -> Void
    @State private var name = ""
    @State private var keyword = ""
    @State private var template = ""
    @State private var problem: String?
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            IslandCard(padding: EdgeInsets(top: 12, leading: 10, bottom: 8, trailing: 10)) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionTitle(title: "Engines", aside: "pill · default · keyword").padding(.horizontal, 6).padding(.bottom, 4)
                    IslandScroll {
                        VStack(spacing: 0) {
                            ForEach(store.engines) { engine in row(engine) }
                        }
                    }
                }
            }
            IslandCard(padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(title: "Add your own")
                    IslandField(placeholder: "Name, e.g. Stack Overflow", text: $name)
                    IslandField(placeholder: "Keyword, e.g. so", text: $keyword)
                    IslandField(placeholder: "https://stackoverflow.com/search?q=%s", text: $template, onSubmit: add)
                    if let problem {
                        Text(problem).font(.brim(11.5, .bold)).foregroundStyle(Palette.amber)
                    } else {
                        Text("Put %s where your search should go.").font(.brim(11.5, .bold)).foregroundStyle(theme.f(0.45))
                    }
                    Spacer(minLength: 0)
                    HStack {
                        Spacer()
                        IslandButton(title: "Done", height: 28, action: close)
                        IslandButton(title: "Add", style: .primary, height: 28, action: add)
                    }
                }
            }
            .frame(width: 320)
        }
    }

    private func row(_ engine: SearchEngine) -> some View {
        let isDefault = engine.id == store.defaultEngineID
        let pinned = store.pinned.contains { $0.id == engine.id }
        return HStack(spacing: 10) {
            IslandSwitch(isOn: Binding(get: { pinned }, set: { store.setPinned(engine.id, $0) }), label: "Show \(engine.name)")
                .opacity(isDefault ? 0.4 : 1)
            Text(engine.name).font(.brim(12.5, .bold)).lineLimit(1)
            if !engine.keyword.isEmpty {
                Text(engine.keyword)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(theme.f(0.1)))
                    .foregroundStyle(theme.f(0.6))
            }
            Spacer()
            Text(isDefault ? "Default" : "Make default")
                .font(.brim(11.5))
                .foregroundStyle(isDefault ? theme.fg : theme.f(0.45))
                .onTapGesture { store.setDefault(engine.id) }
                .accessibilityAddTraits(.isButton)
            if !engine.builtIn {
                Image(systemName: "trash")
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .hoverFill(11, hover: theme.f(0.1))
                    .onTapGesture { store.removeEngine(engine.id) }
                    .accessibilityLabel("Remove \(engine.name)")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
    }

    private func add() {
        problem = store.addEngine(name: name, keyword: keyword, template: template)
        if problem == nil { name = ""; keyword = ""; template = "" }
    }
}

struct LinkTile: View {
    let link: SavedLink
    let open: () -> Void
    let delete: () -> Void
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Text(String(link.title.prefix(1)).uppercased())
                .font(.brim(13))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9).fill(theme.f(0.1)))
            VStack(alignment: .leading, spacing: 1) {
                Text(link.title).font(.brim(12.5)).lineLimit(1)
                Text(link.host).font(.brim(11, .bold)).foregroundStyle(theme.f(0.45)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 54)
        .hoverFill(15, base: theme.f(0.06), hover: theme.f(0.11))
        .onTapGesture(perform: open)
        .contextMenu {
            Button("Open", action: open)
            Button("Copy link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Links.normalized(link.url), forType: .string)
            }
            Divider()
            Button("Delete", role: .destructive, action: delete)
        }
        .help(link.url)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Scratchpad

/// One always-there text box. Typing saves as you go; pin it and its first line stays in the notch.
struct ScratchpadTabView: View {
    @ObservedObject var store: ScratchStore
    @State private var copied = false
    @Environment(\.islandTheme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: store.pinned ? "pin.fill" : "pin")
                    Text(store.pinned ? "Pinned to notch" : "Pin to notch")
                }
                .font(.brim(12))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .foregroundStyle(store.pinned ? theme.bg : theme.f(0.7))
                .background(Capsule().fill(store.pinned ? theme.fg : theme.f(0.08)))
                .onTapGesture { store.pinned.toggle() }
                .help("Show the first line in the closed notch")
                .accessibilityLabel(store.pinned ? "Unpin from notch" : "Pin to notch")
                .accessibilityAddTraits(.isButton)
                IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.text, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                }
                IconButton(symbol: "trash", help: "Clear") { store.text = "" }
            }
            IslandCard(padding: EdgeInsets(top: 16, leading: 20, bottom: 14, trailing: 20)) {
                NoteBodyEditor(text: $store.text, placeholder: "Jot something down. It stays here until you clear it.", size: 14)
            }
            HStack {
                Text(store.pinned ? "Pinned: the first line shows in the closed notch" : "Not pinned. Open this tab to read it")
                Spacer()
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    Text("Saved " + Format.ago(store.savedAt, now: context.date))
                }
                Text("·")
                Text("\(store.wordCount)w · \(store.text.count)c")
            }
            .font(.brim(11, .bold))
            .foregroundStyle(theme.f(0.45))
            .padding(.horizontal, 4)
        }
    }
}
