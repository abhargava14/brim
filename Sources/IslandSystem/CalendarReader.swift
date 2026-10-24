import AppKit
import Combine
import EventKit
import IslandCore

/// Whether macOS lets Brim use something, in the words Settings › Permissions uses.
public enum Access: Equatable, Sendable {
    case notAsked
    case allowed
    case denied
    /// This build can't ask (no usage text in Info.plist, e.g. `swift run`).
    case unavailable
}

/// True when the running bundle carries the usage text macOS needs before it shows a prompt.
/// Asking without it terminates the app, so every request checks this first.
public func canAsk(_ infoKey: String) -> Bool {
    Bundle.main.object(forInfoDictionaryKey: infoKey) != nil
}

public struct CalendarEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let allDay: Bool
    public let calendar: String
    public let account: String
    public let color: [Double]
    public let meeting: URL?
    public let location: String?
}

public struct ReminderItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let due: Date?
    public let done: Bool
    public let list: String
    public let color: [Double]
}

public struct CalendarAccount: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let calendars: Int
    public let color: [Double]
}

/// Reads this Mac's calendars and reminders (iCloud, Google, Exchange… whatever System Settings
/// › Internet Accounts has) through one EventKit permission. Brim never sees those passwords.
@MainActor
public final class CalendarReader: ObservableObject {
    @Published public private(set) var access: Access = .notAsked
    @Published public private(set) var reminderAccess: Access = .notAsked
    @Published public private(set) var events: [CalendarEvent] = []
    @Published public private(set) var reminders: [ReminderItem] = []
    @Published public private(set) var accounts: [CalendarAccount] = []
    @Published public private(set) var waiting = false

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?
    private var timer: Timer?

    public init() {
        refreshAccess()
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        // Up next moves on with the clock.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        reload()
    }

    public func refreshAccess() {
        access = Self.map(EKEventStore.authorizationStatus(for: .event), key: "NSCalendarsFullAccessUsageDescription")
        reminderAccess = Self.map(EKEventStore.authorizationStatus(for: .reminder), key: "NSRemindersFullAccessUsageDescription")
    }

    static func map(_ status: EKAuthorizationStatus, key: String) -> Access {
        switch status {
        case .notDetermined: return canAsk(key) || canAsk(key.replacingOccurrences(of: "FullAccess", with: "")) ? .notAsked : .unavailable
        case .denied, .restricted: return .denied
        default:
            // `.authorized` before macOS 14, `.fullAccess` after; write-only access can't read.
            if #available(macOS 14.0, *), status == .writeOnly { return .denied }
            return .allowed
        }
    }

    /// Asks for calendars and reminders together, as the design promises ("macOS asks once").
    public func request() {
        guard access == .notAsked || reminderAccess == .notAsked else { return openSettings() }
        waiting = true
        Task {
            if #available(macOS 14.0, *) {
                _ = try? await store.requestFullAccessToEvents()
                _ = try? await store.requestFullAccessToReminders()
            } else {
                _ = try? await store.requestAccess(to: .event)
                _ = try? await store.requestAccess(to: .reminder)
            }
            waiting = false
            refreshAccess()
            reload()
        }
    }

    public func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }

    public func reload() {
        refreshAccess()
        if access == .allowed { loadEvents() }
        if reminderAccess == .allowed { loadReminders() }
    }

    private func loadEvents() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                CalendarEvent(id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "Untitled",
                              start: event.startDate, end: event.endDate, allDay: event.isAllDay,
                              calendar: event.calendar.title, account: event.calendar.source.title,
                              color: Self.rgb(event.calendar.cgColor),
                              meeting: MeetingLink.find(in: [event.url?.absoluteString, event.location, event.notes]),
                              location: event.location)
            }
        var grouped: [String: [EKCalendar]] = [:]
        for calendar in store.calendars(for: .event) { grouped[calendar.source.title, default: []].append(calendar) }
        accounts = grouped.map { name, calendars in
            CalendarAccount(id: name, name: name, calendars: calendars.count, color: Self.rgb(calendars.first?.cgColor))
        }
        .sorted { $0.name < $1.name }
    }

    private func loadReminders() {
        let incomplete = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let doneToday = store.predicateForCompletedReminders(withCompletionDateStarting: startOfDay, ending: Date(), calendars: nil)
        store.fetchReminders(matching: incomplete) { [weak self] open in
            let openItems = (open ?? []).map(Self.item)
            self?.store.fetchReminders(matching: doneToday) { done in
                let doneItems = (done ?? []).map(Self.item)
                Task { @MainActor in
                    self?.reminders = (openItems.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) } + doneItems)
                }
            }
        }
    }

    nonisolated static func item(_ reminder: EKReminder) -> ReminderItem {
        ReminderItem(id: reminder.calendarItemIdentifier, title: reminder.title ?? "Untitled",
                     due: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                     done: reminder.isCompleted, list: reminder.calendar?.title ?? "Reminders",
                     color: rgb(reminder.calendar?.cgColor))
    }

    public func toggle(_ id: String) {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        reminder.isCompleted.toggle()
        try? store.save(reminder, commit: true)
        loadReminders()
    }

    public func addReminder(_ title: String) {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let list = store.defaultCalendarForNewReminders() else { return }
        let reminder = EKReminder(eventStore: store)
        reminder.title = text
        reminder.calendar = list
        try? store.save(reminder, commit: true)
        loadReminders()
    }

    /// The next event that hasn't ended, skipping all-day ones.
    public var nextEvent: CalendarEvent? {
        events.first { !$0.allDay && $0.end > Date() }
    }

    nonisolated static func rgb(_ color: CGColor?) -> [Double] {
        guard let color, let converted = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let parts = converted.components, parts.count >= 3 else { return [0.04, 0.52, 1] }
        return [Double(parts[0]), Double(parts[1]), Double(parts[2])]
    }

    /// Fixture data for snapshot renders.
    public func loadSamples() {
        access = .allowed
        reminderAccess = .allowed
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(byAdding: DateComponents(day: day, hour: hour, minute: minute), to: today)!
        }
        let work = [0.75, 0.35, 0.95], icloud = [0.04, 0.52, 1.0], google = [0.19, 0.82, 0.35]
        let sample: [(Int, Int, Int, String, [Double], String)] = [
            (0, 9, 30, "Standup", work, "Work"), (0, 14, 0, "Dentist", icloud, "iCloud"), (0, 23, 30, "Design review", google, "Google"),
            (1, 10, 0, "Brim sync", work, "Work"), (1, 13, 0, "Lunch with Sam", icloud, "iCloud"), (2, 9, 30, "Standup", work, "Work"),
            (2, 16, 0, "Launch prep", google, "Google"), (3, 11, 0, "User interview", google, "Google"), (4, 15, 0, "v0.4 release", google, "Google"),
            (5, 10, 0, "Farmers market", icloud, "iCloud"),
        ]
        events = sample.map { day, hour, minute, title, color, account in
            CalendarEvent(id: UUID().uuidString, title: title, start: at(day, hour, minute), end: at(day, hour, minute + 30), allDay: false,
                          calendar: account, account: account, color: color,
                          meeting: title == "Design review" ? URL(string: "https://meet.google.com/abc-defg-hij") : nil, location: nil)
        }
        accounts = [CalendarAccount(id: "iCloud", name: "iCloud", calendars: 4, color: icloud),
                    CalendarAccount(id: "Google", name: "Google", calendars: 2, color: google),
                    CalendarAccount(id: "Work", name: "Work", calendars: 2, color: work)]
        reminders = [
            ReminderItem(id: "1", title: "Renew Cursor Teams seat", due: today, done: false, list: "Work", color: work),
            ReminderItem(id: "2", title: "Reply to Priya about launch", due: at(0, 21), done: false, list: "Work", color: work),
            ReminderItem(id: "3", title: "Record demo video", due: at(1, 12), done: false, list: "Work", color: work),
            ReminderItem(id: "4", title: "Submit Brim to Homebrew", due: at(4, 12), done: false, list: "Work", color: work),
            ReminderItem(id: "5", title: "Water plants", due: today, done: true, list: "Personal", color: icloud),
        ]
    }
}
