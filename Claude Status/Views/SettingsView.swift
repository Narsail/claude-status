import AppKit
import ServiceManagement
import Sparkle
import SwiftUI

/// Settings window with icon style, launch at login, plugin management,
/// notifications, and multi-profile support.
struct SettingsView: View {
    @Bindable var profileStore: ProfileStore
    var updater: SPUUpdater?
    var pluginState: (ClaudeProfile) -> PluginInstallState
    var onInstallPlugin: (ClaudeProfile) -> Void
    var onUninstallPlugin: (ClaudeProfile) -> Void

    @AppStorage("iconStyle", store: UserDefaults(suiteName: "group.com.poisonpenllc.Claude-Status"))
    private var iconStyle: SessionIconStyle = .emoji
    @AppStorage(NotificationManager.enabledDefaultsKey)
    private var notificationsEnabled: Bool = NotificationManager.enabledDefault
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var renamingProfileId: String?
    @State private var renameText: String = ""

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Status Icon Style", selection: $iconStyle) {
                    ForEach(SessionIconStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("General") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        toggleLaunchAtLogin(newValue)
                    }
            }

            Section {
                Toggle(isOn: $notificationsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Alert when a session needs your input")
                            .font(.body)
                        Text("Posts a macOS notification when any session enters the Waiting state.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: notificationsEnabled) { _, newValue in
                    if newValue {
                        NotificationManager.shared.requestAuthorizationIfNeeded()
                    }
                }
                HStack {
                    Spacer()
                    Button("Send Test Notification") {
                        NotificationManager.shared.sendTestNotification()
                    }
                }
            } header: {
                Text("Notifications")
            }

            if let updater {
                Section("Updates") {
                    Toggle(isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.automaticallyChecksForUpdates = $0 }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Automatic Updates")
                                .font(.body)
                            Text("Check for updates daily and install automatically")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    HStack {
                        Spacer()
                        Button("Check for Updates\u{2026}") {
                            updater.checkForUpdates()
                        }
                        .disabled(!updater.canCheckForUpdates)
                    }
                }
            }

            Section {
                ForEach(profileStore.profiles) { profile in
                    profileRow(profile)
                }

                HStack {
                    Spacer()
                    Button {
                        addProfile()
                    } label: {
                        Label("Add Profile\u{2026}", systemImage: "plus")
                    }
                }
            } header: {
                Text("Claude Profiles")
            } footer: {
                Text("Monitor sessions across multiple Claude Code config directories (CLAUDE_CONFIG_DIR). The plugin needs to be installed in each profile to report session activity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Profile Row

    @ViewBuilder
    private func profileRow(_ profile: ClaudeProfile) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if renamingProfileId == profile.id {
                        TextField("", text: $renameText, onCommit: { commitRename(profile) })
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 160)
                        Button("Save") { commitRename(profile) }
                            .buttonStyle(.borderless)
                        Button("Cancel") { renamingProfileId = nil }
                            .buttonStyle(.borderless)
                    } else {
                        Text(profile.name)
                            .font(.body)
                        statusBadge(for: pluginState(profile))
                        Button {
                            renameText = profile.name
                            renamingProfileId = profile.id
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                        .help("Rename")
                    }
                }
                Text(displayPath(profile.configDir))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                pluginButtons(for: profile)
                if profileStore.profiles.count > 1 {
                    Button(role: .destructive) {
                        profileStore.remove(profile.id)
                    } label: {
                        Text("Remove")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusBadge(for state: PluginInstallState) -> some View {
        switch state {
        case .installed:
            badgeText("Installed", color: .green)
        case .notInstalled:
            badgeText("Not Installed", color: .orange)
        case .unknown:
            badgeText("Unknown", color: .secondary)
        }
    }

    private func badgeText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private func pluginButtons(for profile: ClaudeProfile) -> some View {
        switch pluginState(profile) {
        case .installed:
            HStack(spacing: 6) {
                Button("Reinstall") { onInstallPlugin(profile) }
                    .controlSize(.small)
                Button("Uninstall") { onUninstallPlugin(profile) }
                    .controlSize(.small)
            }
        case .notInstalled, .unknown:
            Button("Install Plugin") { onInstallPlugin(profile) }
                .controlSize(.small)
        }
    }

    // MARK: - Profile management

    private func commitRename(_ profile: ClaudeProfile) {
        profileStore.rename(profile.id, to: renameText)
        renamingProfileId = nil
    }

    private func addProfile() {
        let panel = NSOpenPanel()
        panel.title = "Choose Claude Config Directory"
        panel.message = "Select the Claude Code config dir (e.g. ~/.claude-work). It should contain a 'projects' folder."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let suggested = ProfileStore.suggestedName(for: url.path)
        profileStore.add(name: suggested, configDir: url.path)
    }

    /// Replaces the user's home dir with `~` for cleaner display.
    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = !enabled
        }
    }
}
