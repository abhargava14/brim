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
                        Text("Saved")
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

/// Links: search the web or your saved sites, sorted into folders.
struct LinksTabView: View {
    @ObservedObject var store: LinksStore
    @State private var query = ""
    @State private var folder = "All"
    @State private var adding = false
    @State private var draftTitle = ""
    @State private var draftURL = ""
    @State private var draftFolder = "Work"
    @Environment(\.islandTheme) private var theme

    private var shown: [SavedLink] {
        store.links.filter { (folder == "All" || $0.folder == folder) && $0.matches(query) }
    }

    var body: some View {
        if store.links.isEmpty, !adding {
            ConnectCard(symbol: "bookmark", color: Palette.coral, title: "Save the sites you use",
                        message: "Search the web from the notch and keep the links you open every day, sorted into folders.",
                        actions: [.init(title: "Add a link") { adding = true }])
        } else {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .semibold)).opacity(0.6)
                    PlainTextField("Search the web or your links", text: $query, font: .brim(14, .bold), onSubmit: submit)
                    HStack(spacing: 6) {
                        Text(Links.looksLikeURL(query) ? "Open" : "Google")
                        Image(systemName: "return").opacity(0.6)
                    }
                    .font(.brim(11.5))
                    .foregroundStyle(theme.f(0.7))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 10).fill(theme.f(0.08)))
                }
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .frame(height: 42)
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(theme.f(0.07)))

                HStack(spacing: 8) {
                    SegmentedPills(options: (["All"] + store.folders).map { ($0, $0) }, selection: $folder)
                    Spacer()
                    IconButton(symbol: "plus", help: "Add a link", active: adding, rotation: adding ? 45 : 0) { adding.toggle() }
                }

                if adding {
                    addForm
                } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: Links.looksLikeURL(query) ? "arrow.up.right.square" : "magnifyingglass").font(.system(size: 12, weight: .bold))
                        Text(Links.looksLikeURL(query) ? "Open \(query)" : "Search Google for “\(query)”").font(.brim(12.5)).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .hoverFill(13, base: theme.f(0.1), hover: theme.f(0.15))
                    .onTapGesture(perform: submit)
                    .accessibilityAddTraits(.isButton)
                }

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

    private var addForm: some View {
        HStack(spacing: 8) {
            IslandField(placeholder: "linear.app", text: $draftURL, symbol: "link", onSubmit: saveDraft)
            IslandField(placeholder: "Title (optional)", text: $draftTitle, onSubmit: saveDraft)
                .frame(width: 180)
            SegmentedPills(options: store.folders.map { ($0, $0) }, selection: $draftFolder, height: 24)
            IslandButton(title: "Save", style: .primary, height: 30, action: saveDraft)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(theme.f(0.06)))
    }

    private func saveDraft() {
        guard !draftURL.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.add(title: draftTitle, url: draftURL, folder: draftFolder)
        draftURL = ""
        draftTitle = ""
        adding = false
    }

    private func submit() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if let match = shown.first, shown.count == 1 {
            store.open(match)
        } else if Links.looksLikeURL(text), let url = URL(string: Links.normalized(text)) {
            NSWorkspace.shared.open(url)
        } else if let url = Links.searchURL(text) {
            NSWorkspace.shared.open(url)
        }
        query = ""
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

/// One always-there text box. Typing saves as you go.
struct ScratchpadTabView: View {
    @ObservedObject var store: ScratchStore
    @State private var copied = false
    @Environment(\.islandTheme) private var theme

    var body: some View {
        IslandCard(padding: EdgeInsets(top: 14, leading: 18, bottom: 12, trailing: 18)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionTitle(title: "Scratchpad", aside: "\(store.text.count) characters")
                    IslandButton(title: copied ? "Copied" : "Copy", height: 24, fontSize: 11.5) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(store.text, forType: .string)
                        copied = true
                        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                    }
                    IslandButton(title: "Clear", height: 24, fontSize: 11.5) { store.text = "" }
                }
                NoteBodyEditor(text: $store.text, placeholder: "Jot something down. It stays here until you clear it.", size: 14)
            }
        }
    }
}
