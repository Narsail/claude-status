import Foundation
import WidgetKit

/// A session's state change between two refreshes.
/// `from` is nil when the session is newly observed.
struct SessionTransition {
    let session: ClaudeSession
    let from: SessionState?
    let to: SessionState
}

/// Monitors Claude Code sessions by scanning .cstatus files and filesystem state.
///
/// Uses three complementary mechanisms for timely updates:
/// 1. **Darwin notifications** — instant push from the hook script via `notifyutil -p`
/// 2. **File system watching** — `DispatchSource` on each profile's `projects/` dir
/// 3. **Polling timer** — 5s fallback for sessions without hooks (IDE agents, etc.)
@Observable
@MainActor
final class SessionMonitor {

    private(set) var sessions: [ClaudeSession] = []
    private(set) var productivityData: ProductivityData = ProductivityData(today: .empty(), allTime: .empty())

    /// Aggregate plugin install state across all configured profiles.
    /// `true` = installed for at least one profile, `false` = installed for none
    /// (we treat that as "broken" since we have no useful signal source), `nil` = unknown.
    private(set) var hookDetected: Bool?

    /// The most urgent state across all sessions, or nil if none.
    var aggregateState: SessionState? {
        sessions.map(\.state).max(by: { $0.priority < $1.priority })
    }

    /// Optional hook that fires when a session transitions between states.
    /// Used by the notification manager to alert on "needs your input".
    var onStateTransition: ((SessionTransition) -> Void)?

    private var discovery: SessionDiscovery
    private let stateResolver: StateResolver
    private let tracker: ProductivityTracker
    private let profileStore: ProfileStore
    nonisolated(unsafe) private var timer: Timer?
    private let scanInterval: TimeInterval

    /// Maps session ID → .cstatus file URL for fast notification-driven refresh.
    private var cstatusCache: [String: URL] = [:]

    /// Last seen state per session ID — used to detect transitions for notifications.
    private var lastStates: [String: SessionState] = [:]
    /// First-refresh guard: prevents notifications on the initial population.
    private var primed: Bool = false

    /// Cached plugin detection state and when it was last checked.
    private var lastPluginCheck: Date = .distantPast
    private var cachedPluginState: PluginInstallState = .unknown
    private static let pluginCheckInterval: TimeInterval = 30

    /// Throttle widget reloads to avoid excessive writes on every 5s poll.
    private var lastWidgetUpdate: Date = .distantPast
    private static let widgetUpdateInterval: TimeInterval = 30

    /// Darwin notification name posted by the hook script.
    private static let darwinNotificationName = "com.poisonpenllc.Claude-Status.session-changed" as CFString

    init(profileStore: ProfileStore, scanInterval: TimeInterval = 5.0) {
        self.scanInterval = scanInterval
        self.profileStore = profileStore
        self.discovery = SessionDiscovery(profiles: profileStore.profiles)
        self.stateResolver = StateResolver()
        self.tracker = ProductivityTracker()

        let resolver = self.stateResolver
        self.discovery.lastActionResolver = { sessionId, projectDir in
            resolver.latestActionSummary(sessionId: sessionId, in: projectDir)
                .map { TranscriptSummary(text: $0.text, timestamp: $0.timestamp) }
        }
        self.discovery.recapResolver = { sessionId, projectDir in
            resolver.latestRecapSummary(sessionId: sessionId, in: projectDir)
                .map { TranscriptSummary(text: $0.text, timestamp: $0.timestamp) }
        }
    }

    deinit {
        timer?.invalidate()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(self).toOpaque())
    }

    func start() {
        stateResolver.onProjectsChanged = { [weak self] in
            self?.refresh()
        }
        stateResolver.updateProfiles(profileStore.profiles)

        // React to profile list changes (add/remove/rename) by rebuilding watchers
        // and immediately rescanning.
        profileStore.onChange = { [weak self] in
            guard let self else { return }
            self.discovery.profiles = self.profileStore.profiles
            self.stateResolver.updateProfiles(self.profileStore.profiles)
            self.lastPluginCheck = .distantPast
            self.refresh()
        }

        registerDarwinNotification()
        refresh()

        timer = Timer.scheduledTimer(
            withTimeInterval: scanInterval,
            repeats: true
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        unregisterDarwinNotification()
    }

    // MARK: - Darwin Notifications

    private func registerDarwinNotification() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let monitor = Unmanaged<SessionMonitor>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    monitor.refreshFromNotification()
                }
            },
            Self.darwinNotificationName,
            nil,
            .deliverImmediately
        )
    }

    private func unregisterDarwinNotification() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(center, observer, nil, nil)
    }

    // MARK: - Refresh

    /// Full refresh: directory scan + PID validation.
    /// Called on timer ticks and file system changes.
    func refresh() {
        let result = discovery.discoverAll()
        applyResult(result)
    }

    /// Notification-driven refresh: always do a full scan since the notification
    /// may signal a new session that isn't in our cache yet.
    private func refreshFromNotification() {
        discovery.clearDeadSessions()
        refresh()
    }

    /// Applies a discovery result: updates sessions, cache, and hook detection.
    /// Only writes to the shared container and reloads the widget when data changes.
    private func applyResult(_ result: SessionDiscovery.DiscoveryResult) {
        let sessionsChanged = sessions != result.sessions

        // Detect state transitions before we overwrite `sessions`/`lastStates`.
        // First refresh after launch is "primed" — we record current states but
        // emit no notifications, to avoid spam on startup.
        if primed {
            for session in result.sessions {
                let previous = lastStates[session.id]
                if previous != session.state {
                    onStateTransition?(SessionTransition(
                        session: session,
                        from: previous,
                        to: session.state
                    ))
                }
            }
        }
        // Snapshot current states keyed by session id (drops gone sessions).
        var nextStates: [String: SessionState] = [:]
        for session in result.sessions { nextStates[session.id] = session.state }
        lastStates = nextStates
        primed = true

        sessions = result.sessions
        cstatusCache = result.cstatusFiles

        // Track time-in-state for productivity scoring
        tracker.recordSnapshot(sessions: result.sessions)
        let newProductivity = tracker.currentData
        let productivityChanged = productivityData != newProductivity
        productivityData = newProductivity

        updatePluginState()

        // Session changes write immediately; productivity changes are throttled
        if sessionsChanged {
            writeToSharedContainer()
        } else if productivityChanged {
            let now = Date()
            if now.timeIntervalSince(lastWidgetUpdate) >= Self.widgetUpdateInterval {
                writeToSharedContainer()
            }
        }
    }

    /// Aggregates plugin detection state across all configured profiles.
    /// "installed" means at least one profile has the plugin/hooks installed.
    private func updatePluginState() {
        let now = Date()
        if now.timeIntervalSince(lastPluginCheck) >= Self.pluginCheckInterval {
            cachedPluginState = aggregatePluginState()
            lastPluginCheck = now
        }
        switch cachedPluginState {
        case .installed: hookDetected = true
        case .notInstalled: hookDetected = false
        case .unknown: hookDetected = nil
        }
    }

    private func aggregatePluginState() -> PluginInstallState {
        var anyUnknown = false
        for profile in profileStore.profiles {
            switch PluginDetector(profile: profile).detect() {
            case .installed: return .installed
            case .unknown: anyUnknown = true
            case .notInstalled: break
            }
        }
        return anyUnknown ? .unknown : .notInstalled
    }

    /// Forces a fresh plugin detection check (e.g. after install/uninstall).
    func invalidatePluginCache() {
        lastPluginCheck = .distantPast
    }

    // MARK: - Shared Data

    private func writeToSharedContainer() {
        guard let sharedURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.poisonpenllc.Claude-Status"
        ) else {
            return
        }

        if let encoded = try? JSONEncoder().encode(sessions) {
            let dataURL = sharedURL.appendingPathComponent("sessions.json")
            try? encoded.write(to: dataURL, options: .atomic)
        }

        if let encoded = try? JSONEncoder().encode(productivityData) {
            let prodURL = sharedURL.appendingPathComponent("productivity.json")
            try? encoded.write(to: prodURL, options: .atomic)
        }

        lastWidgetUpdate = Date()

        WidgetCenter.shared.reloadTimelines(ofKind: "Claude_StatusWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "Claude_ProductivityWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "Claude_ScoreWidget")
    }
}
