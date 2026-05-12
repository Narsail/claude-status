import AppKit
import SwiftUI

/// A standalone window mirroring the popover's session list. Designed to live
/// on a second monitor — frame and always-on-top state persist across launches,
/// and the window auto-reopens at next launch if it was open at quit time.
@MainActor
final class SessionsWindowController: NSObject, NSWindowDelegate {

    private static let frameAutosaveName = "SessionsWindow"
    private static let wasOpenDefaultsKey = "sessionsWindowWasOpen"
    private static let alwaysOnTopDefaultsKey = "sessionsWindowAlwaysOnTop"

    private weak var monitor: SessionMonitor?
    private weak var profileStore: ProfileStore?
    private let onSessionTap: (ClaudeSession) -> Void

    private var window: NSWindow?

    var alwaysOnTop: Bool {
        UserDefaults.standard.bool(forKey: Self.alwaysOnTopDefaultsKey)
    }

    init(
        monitor: SessionMonitor,
        profileStore: ProfileStore,
        onSessionTap: @escaping (ClaudeSession) -> Void
    ) {
        self.monitor = monitor
        self.profileStore = profileStore
        self.onSessionTap = onSessionTap
    }

    /// Called once at app launch — opens the window if the user had it open
    /// last time the app quit.
    func restoreIfPreviouslyOpen() {
        if UserDefaults.standard.bool(forKey: Self.wasOpenDefaultsKey) {
            show()
        }
    }

    /// Called from `applicationWillTerminate` so the next launch knows whether
    /// to auto-reopen.
    func persistOpenState() {
        UserDefaults.standard.set(window?.isVisible ?? false, forKey: Self.wasOpenDefaultsKey)
    }

    /// Opens the window (or brings it to the front if already open).
    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let monitor, let profileStore else { return }

        let hosting = NSHostingController(rootView: makeContentView(
            monitor: monitor,
            profileStore: profileStore
        ))
        hosting.sizingOptions = []

        let window = NSWindow(contentViewController: hosting)
        window.title = "Claude Sessions"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.collectionBehavior.insert(.fullScreenNone)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 380, height: 520))
        window.minSize = NSSize(width: 320, height: 240)
        window.setFrameAutosaveName(Self.frameAutosaveName)

        applyAlwaysOnTop(window: window, enabled: alwaysOnTop)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    /// Toggles the window's "stay on top" behavior. Persists across launches.
    func setAlwaysOnTop(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.alwaysOnTopDefaultsKey)
        if let window {
            applyAlwaysOnTop(window: window, enabled: enabled)
        }
    }

    private func applyAlwaysOnTop(window: NSWindow, enabled: Bool) {
        window.level = enabled ? .floating : .normal
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: Self.wasOpenDefaultsKey)
        window = nil
    }

    // MARK: - Content

    private func makeContentView(
        monitor: SessionMonitor,
        profileStore: ProfileStore
    ) -> some View {
        SessionsWindowContent(
            monitor: monitor,
            profileStore: profileStore,
            onSessionTap: onSessionTap,
            alwaysOnTopProvider: { [weak self] in self?.alwaysOnTop ?? false },
            setAlwaysOnTop: { [weak self] in self?.setAlwaysOnTop($0) }
        )
    }
}

/// SwiftUI wrapper that observes the monitor and includes an always-on-top toggle.
private struct SessionsWindowContent: View {
    @Bindable var monitor: SessionMonitor
    @Bindable var profileStore: ProfileStore
    var onSessionTap: (ClaudeSession) -> Void
    var alwaysOnTopProvider: () -> Bool
    var setAlwaysOnTop: (Bool) -> Void

    @State private var alwaysOnTop: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Toggle(isOn: $alwaysOnTop) {
                    Text("Always on Top")
                        .font(.system(size: 11))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .onChange(of: alwaysOnTop) { _, newValue in
                    setAlwaysOnTop(newValue)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            SessionListView(
                sessions: monitor.sessions,
                productivityData: monitor.productivityData,
                profileNames: Dictionary(uniqueKeysWithValues: profileStore.profiles.map { ($0.id, $0.name) }),
                presentation: .window,
                onSessionTap: onSessionTap,
                onRefresh: { monitor.refresh() }
            )
        }
        .onAppear { alwaysOnTop = alwaysOnTopProvider() }
    }
}
