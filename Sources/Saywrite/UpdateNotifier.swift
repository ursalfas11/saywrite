import AppKit
import SaywriteCore

/// The update hint: at most one request to GitHub per day while "Check for updates" is on, and a
/// menu line when a newer release exists. Nothing is downloaded or installed.
@MainActor
final class UpdateNotifier: ObservableObject {
    enum ManualResult: Equatable {
        case checking
        case upToDate(String)
        case available(ReleaseInfo)
        case failed(UpdateCheckError)
    }

    /// The newer release to point at, or nil.
    @Published private(set) var available: ReleaseInfo?
    /// What "Check now" found, shown next to the button.
    @Published private(set) var manualResult: ManualResult?

    private let settings: AppSettings
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var running: Task<Void, Never>?
    private lazy var session = UpdateCheck.makeSession()

    /// nil when not running from an app bundle (swift run): then there is nothing to compare with.
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    init(settings: AppSettings) {
        self.settings = settings
        // A release found by an earlier check stays visible after a restart, unless this version caught up.
        if settings.checkForUpdates, let tag = defaults.string(forKey: "updateTag"), let page = defaults.string(forKey: "updateURL"),
           let release = ReleaseInfo(tag: tag, pageURL: page), let currentVersion,
           case .updateAvailable = UpdateCheck.outcome(latest: release, currentVersion: currentVersion) {
            available = release
        }
    }

    /// Checks now if a day has passed, then looks again every few hours. The day is measured on the
    /// wall clock, so time asleep counts; the generous tolerance lets macOS bundle the wake-up.
    func start() {
        checkIfDue()
        timer?.invalidate()
        let timer = Timer(timeInterval: 3 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        timer.tolerance = 60 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The switch in the settings changed. Off: no request goes out, and the hint disappears.
    func enabledChanged() {
        if settings.checkForUpdates {
            checkIfDue()
        } else {
            running?.cancel()
            running = nil
            available = nil
            manualResult = nil
        }
    }

    private func checkIfDue() {
        let last = defaults.object(forKey: "lastUpdateCheck") as? Date
        guard running == nil, UpdateCheck.isDue(enabled: settings.checkForUpdates, lastCheck: last, now: Date()) else { return }
        run(manual: false)
    }

    /// The "Check now" button: ignores the daily limit and reports errors.
    func checkNow() {
        guard settings.checkForUpdates else { return }
        running?.cancel()
        run(manual: true)
    }

    private func run(manual: Bool) {
        guard let currentVersion else {
            Debug.log("update check skipped: no bundle version")
            if manual { manualResult = .failed(.invalidRelease) }
            return
        }
        if manual { manualResult = .checking }
        defaults.set(Date(), forKey: "lastUpdateCheck")
        running = Task { [weak self, session] in
            let result = await UpdateCheck.check(currentVersion: currentVersion, session: session)
            guard !Task.isCancelled else { return }
            self?.finish(result, manual: manual, currentVersion: currentVersion)
        }
    }

    private func finish(_ result: Result<UpdateCheckOutcome, UpdateCheckError>, manual: Bool, currentVersion: String) {
        running = nil
        // Switched off while the request was on its way.
        guard settings.checkForUpdates else { return }
        switch result {
        case .success(.updateAvailable(let release)):
            Debug.log("update check: \(release.tag) available (running \(currentVersion))")
            available = release
            defaults.set(release.tag, forKey: "updateTag")
            defaults.set(release.pageURL.absoluteString, forKey: "updateURL")
            if manual { manualResult = .available(release) }
        case .success(.upToDate):
            Debug.log("update check: up to date (\(currentVersion))")
            available = nil
            defaults.removeObject(forKey: "updateTag")
            defaults.removeObject(forKey: "updateURL")
            if manual { manualResult = .upToDate(currentVersion) }
        case .failure(let error):
            // Offline, rate limit, a captive portal: the automatic check stays silent and tries again tomorrow.
            Debug.log("update check failed: \(error)")
            if manual { manualResult = .failed(error) }
        }
    }

    func openReleasePage() {
        NSWorkspace.shared.open(available?.pageURL ?? UpdateCheck.releasesPageURL)
    }

    /// Menu and settings text for a release.
    static func availableText(_ release: ReleaseInfo) -> String {
        L("Version \(release.version) available…", "Version \(release.version) verfügbar …")
    }

    static func errorText(_ error: UpdateCheckError) -> String {
        switch error {
        case .offline: return L("No connection to GitHub.", "Keine Verbindung zu GitHub.")
        case .rateLimited: return L("GitHub refused for now (rate limit). Try again later.", "GitHub lehnt gerade ab (Abruflimit). Später erneut versuchen.")
        case .httpStatus(let code): return L("GitHub answered with error \(code).", "GitHub antwortete mit Fehler \(code).")
        case .notJSON: return L("Unexpected answer (a login page of the network?).", "Unerwartete Antwort (Anmeldeseite des Netzwerks?).")
        case .invalidRelease: return L("Could not read the version.", "Version nicht lesbar.")
        case .network(let message): return L("Check failed: \(message)", "Prüfung fehlgeschlagen: \(message)")
        }
    }
}
