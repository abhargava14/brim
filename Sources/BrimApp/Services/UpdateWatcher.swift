import Combine
import Foundation
import IslandCore
import IslandServices

/// Checks GitHub Releases once a day in the background. A new version shows as a notice in the
/// closed notch, a menu bar item and a row in Settings; nothing installs without a click.
@MainActor
final class UpdateWatcher: ObservableObject {
    @Published private(set) var available: AppUpdater.Update?
    @Published private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date
    private var timer: Timer?
    private weak var settings: AppSettings?
    private var cancellables = Set<AnyCancellable>()
    /// Called once per newly found version (the hub turns it into a notch notice).
    var onFound: ((AppUpdater.Update) -> Void)?

    static let interval: TimeInterval = 24 * 3600

    /// Only real installs check: not snapshot renders, QA runs or `swift run` builds.
    static var canCheck: Bool {
        !AppSettings.isSnapshot && !BrimQA.skipCredentials && Bundle.main.bundlePath.hasSuffix(".app")
    }

    func start(_ settings: AppSettings) {
        self.settings = settings
        guard Self.canCheck else { return }
        settings.$autoCheckUpdates
            .removeDuplicates()
            .sink { [weak self] on in Task { @MainActor in self?.schedule(on) } }
            .store(in: &cancellables)
    }

    private func schedule(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        // A little after launch, then every few hours; each run checks only if a day has passed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
    }

    func checkIfDue(now: Date = Date()) {
        guard settings?.autoCheckUpdates == true else { return }
        if let lastCheck, now.timeIntervalSince(lastCheck) < Self.interval { return }
        Task { await check() }
    }

    /// Asks GitHub for the latest release. Failures stay quiet; the next run tries again.
    func check() async {
        guard Self.canCheck, let outcome = try? await AppUpdater.check() else { return }
        lastCheck = Date()
        UserDefaults.standard.set(lastCheck, forKey: "lastUpdateCheck")
        if case .updateAvailable(let update) = outcome, update.version != settings?.skippedVersion {
            let isNew = available?.version != update.version
            available = update
            if isNew { onFound?(update) }
        } else {
            available = nil
        }
    }

    /// The user chose "Skip This Version".
    func skip(_ update: AppUpdater.Update) {
        settings?.skippedVersion = update.version
        available = nil
    }
}
