import Foundation
import Observation

/// A configured Claude Code data root (e.g. ~/.claude, ~/.claude-personal).
/// Allows the app to monitor sessions across multiple `CLAUDE_CONFIG_DIR`
/// installations side-by-side.
struct ClaudeProfile: Codable, Identifiable, Equatable, Hashable {
    let id: String
    var name: String
    /// Filesystem path to the Claude config directory (the dir that contains `projects/`).
    var configDir: String

    var configDirURL: URL { URL(fileURLWithPath: configDir) }
    var projectsDirURL: URL { configDirURL.appendingPathComponent("projects") }

    /// True when this profile points at the default `~/.claude` location, so we don't
    /// have to set CLAUDE_CONFIG_DIR when invoking the Claude CLI for it.
    var isDefaultLocation: Bool {
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude").path
        return configDir == defaultPath
    }
}

/// Persisted profile list with auto-seeding on first launch.
@Observable
@MainActor
final class ProfileStore {

    private(set) var profiles: [ClaudeProfile]

    /// Called whenever the profile list changes so the monitor can rebuild watchers.
    var onChange: (() -> Void)?

    private let defaults: UserDefaults
    private static let storageKey = "claudeProfiles"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([ClaudeProfile].self, from: data),
           !decoded.isEmpty {
            self.profiles = decoded
        } else {
            self.profiles = Self.seedProfiles()
            self.persist()
        }
    }

    // MARK: - CRUD

    func add(name: String, configDir: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDir = (configDir as NSString).expandingTildeInPath
        guard !trimmedDir.isEmpty else { return }
        // Don't add duplicates of the same configDir
        if profiles.contains(where: { $0.configDir == trimmedDir }) { return }
        let profile = ClaudeProfile(
            id: UUID().uuidString,
            name: trimmedName.isEmpty ? Self.suggestedName(for: trimmedDir) : trimmedName,
            configDir: trimmedDir
        )
        profiles.append(profile)
        persist()
    }

    func remove(_ profileId: String) {
        guard profiles.count > 1 else { return }  // never remove the last one
        profiles.removeAll { $0.id == profileId }
        persist()
    }

    func rename(_ profileId: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = profiles.firstIndex(where: { $0.id == profileId }) else {
            return
        }
        profiles[idx].name = trimmed
        persist()
    }

    func profile(withId id: String) -> ClaudeProfile? {
        profiles.first { $0.id == id }
    }

    // MARK: - Persistence

    private func persist() {
        if let encoded = try? JSONEncoder().encode(profiles) {
            defaults.set(encoded, forKey: Self.storageKey)
        }
        onChange?()
    }

    // MARK: - Auto-detection

    /// Auto-detects Claude config dirs at first launch: `~/.claude` plus any
    /// sibling `.claude-*` directories that contain a `projects/` subfolder.
    private static func seedProfiles() -> [ClaudeProfile] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var found: [ClaudeProfile] = []

        // Always seed the default ~/.claude first if it has a projects dir or exists.
        let defaultDir = home.appendingPathComponent(".claude")
        if fm.fileExists(atPath: defaultDir.appendingPathComponent("projects").path)
            || fm.fileExists(atPath: defaultDir.path) {
            found.append(ClaudeProfile(
                id: UUID().uuidString,
                name: "Default",
                configDir: defaultDir.path
            ))
        }

        // Sibling `.claude-*` directories (e.g. .claude-personal, .claude-work).
        // Use the path-string API since FileManager.contentsOfDirectory(at:) with
        // .skipsHiddenFiles would filter out the dot-prefixed entries we want.
        let homeContents = (try? fm.contentsOfDirectory(atPath: home.path)) ?? []
        for entry in homeContents.sorted() {
            guard entry.hasPrefix(".claude-") else { continue }
            let url = home.appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard fm.fileExists(atPath: url.appendingPathComponent("projects").path) else { continue }
            // Skip if already added (defensive)
            if found.contains(where: { $0.configDir == url.path }) { continue }
            found.append(ClaudeProfile(
                id: UUID().uuidString,
                name: suggestedName(for: url.path),
                configDir: url.path
            ))
        }

        // If absolutely nothing was found (no Claude install yet), seed a single placeholder
        // so the app still has something to work with.
        if found.isEmpty {
            found.append(ClaudeProfile(
                id: UUID().uuidString,
                name: "Default",
                configDir: defaultDir.path
            ))
        }
        return found
    }

    /// Derives a friendly name from a config dir path (e.g. `~/.claude-personal` → "Personal").
    static func suggestedName(for path: String) -> String {
        let last = (path as NSString).lastPathComponent
        if last == ".claude" { return "Default" }
        if last.hasPrefix(".claude-") {
            let suffix = String(last.dropFirst(".claude-".count))
            return suffix.prefix(1).uppercased() + suffix.dropFirst()
        }
        return last.isEmpty ? path : last
    }
}
