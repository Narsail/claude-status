import Foundation

/// Resolves session state from JSONL files as a fallback for sessions without .cstatus files.
/// Also watches the projects directory of every configured profile for filesystem changes.
@MainActor
final class StateResolver {

    /// One watcher per profile `projects/` directory.
    private struct Watcher {
        let source: DispatchSourceFileSystemObject
        let fileDescriptor: Int32
        let path: String
    }

    private var watchers: [Watcher] = []

    /// Cache of away-summary lookups keyed by JSONL path. Re-parses only when
    /// the file mtime moves forward — saves a full-file scan per refresh for
    /// long-lived sessions.
    private struct RecapCache {
        let mtime: Date
        let summary: TimestampedSummary?
    }
    private var recapCache: [String: RecapCache] = [:]

    /// Callback invoked when any watched projects directory changes.
    var onProjectsChanged: (() -> Void)?

    init() {}

    deinit {
        for watcher in watchers {
            watcher.source.cancel()
        }
    }

    /// Replaces the active watcher set with one watcher per profile.
    func updateProfiles(_ profiles: [ClaudeProfile]) {
        let desired = profiles.map(\.projectsDirURL.path)
        let active = watchers.map(\.path)
        if desired == active { return }

        for watcher in watchers {
            watcher.source.cancel()
        }
        watchers.removeAll()

        for path in desired {
            if let watcher = makeWatcher(forProjectsDirPath: path) {
                watchers.append(watcher)
            }
        }
    }

    /// Returns a one-line summary of what's currently happening in the session,
    /// derived from the tail of `<sessionId>.jsonl` (e.g. "Bash: cargo build",
    /// "Read SessionRowView.swift", or a snippet of the assistant's reply).
    /// Returns nil if no useful summary can be extracted.
    /// Result of a JSONL summary lookup — text + the entry's transcript
    /// timestamp so callers can decide which signal is fresher.
    struct TimestampedSummary: Equatable {
        let text: String
        let timestamp: Date
    }

    func latestActionSummary(sessionId: String, in projectDir: URL) -> TimestampedSummary? {
        let jsonlURL = projectDir.appendingPathComponent("\(sessionId).jsonl")
        guard FileManager.default.fileExists(atPath: jsonlURL.path) else { return nil }
        return summaryFromLastMeaningfulLine(of: jsonlURL)
    }

    /// Returns the most recent `away_summary` system entry in the session's
    /// JSONL transcript — the short "Goal / Current task / Next" recap line
    /// Claude Code surfaces between turns. Returns nil when none exists yet.
    func latestRecapSummary(sessionId: String, in projectDir: URL) -> TimestampedSummary? {
        let jsonlURL = projectDir.appendingPathComponent("\(sessionId).jsonl")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: jsonlURL.path),
              let mtime = attrs[.modificationDate] as? Date else {
            return nil
        }

        // Hit cache: file hasn't grown since we last parsed it.
        if let cached = recapCache[jsonlURL.path], cached.mtime == mtime {
            return cached.summary
        }

        let summary = parseAwaySummary(at: jsonlURL)
        recapCache[jsonlURL.path] = RecapCache(mtime: mtime, summary: summary)
        return summary
    }

    /// Walks the file forward and remembers the last `away_summary` content.
    /// We scan from the beginning rather than tailing because the entry can
    /// sit deep in the transcript on long-lived sessions; the mtime cache
    /// above keeps the cost paid only when the file actually changes.
    private func parseAwaySummary(at jsonlURL: URL) -> TimestampedSummary? {
        guard let handle = try? FileHandle(forReadingFrom: jsonlURL) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd(),
              let contents = String(data: data, encoding: .utf8) else {
            return nil
        }

        var latest: TimestampedSummary?
        contents.enumerateLines { line, _ in
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (json["type"] as? String) == "system",
                  (json["subtype"] as? String) == "away_summary",
                  let content = json["content"] as? String else {
                return
            }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let ts = (json["timestamp"] as? String).flatMap(Self.transcriptDate(from:))
                ?? Date()
            latest = TimestampedSummary(text: trimmed, timestamp: ts)
        }
        return latest
    }

    /// Reused parser for ISO-8601 timestamps as written by Claude Code.
    private static let transcriptISOFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func transcriptDate(from raw: String) -> Date? {
        if let d = transcriptISOFormatter.date(from: raw) { return d }
        // Fallback for entries without fractional seconds.
        let plain = ISO8601DateFormatter()
        return plain.date(from: raw)
    }

    /// Resolves state from JSONL modification times for a given project directory.
    /// Only used as a fallback when no .cstatus file is available.
    func resolveFromJSONL(in projectDir: URL) -> (state: SessionState, lastActivity: Date) {
        guard let (newestFile, lastModified) = mostRecentJSONLFile(in: projectDir) else {
            return (.idle, .distantPast)
        }

        let interval = Date().timeIntervalSince(lastModified)

        if interval < 5 {
            return (.active, lastModified)
        }

        let lastLineState = stateFromLastMeaningfulLine(of: newestFile)

        switch lastLineState {
        case .assistantWorking:
            if interval < 30 {
                return (.active, lastModified)
            }
            return (.waiting, lastModified)

        case .assistantDone:
            if interval < 10 {
                return (.active, lastModified)
            }
            return (.waiting, lastModified)

        case .userMessage:
            if interval < 30 {
                return (.active, lastModified)
            }
            return (.waiting, lastModified)

        case .noMeaningfulMessage:
            return (.idle, lastModified)
        }
    }

    // MARK: - File Watching

    private func makeWatcher(forProjectsDirPath path: String) -> Watcher? {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: DispatchQueue.main
        )

        source.setEventHandler { [weak self] in
            self?.onProjectsChanged?()
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        return Watcher(source: source, fileDescriptor: fd, path: path)
    }

    // MARK: - JSONL Helpers

    private func mostRecentJSONLFile(in directory: URL) -> (URL, Date)? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return nil
        }

        var newestURL: URL?
        var newestDate = Date.distantPast
        for url in contents where url.pathExtension == "jsonl" {
            if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
               let modified = values.contentModificationDate,
               modified > newestDate {
                newestDate = modified
                newestURL = url
            }
        }

        guard let url = newestURL, newestDate != .distantPast else {
            return nil
        }
        return (url, newestDate)
    }

    // MARK: - Last Line Parsing

    private enum LastLineState {
        case assistantWorking
        case assistantDone
        case userMessage
        case noMeaningfulMessage
    }

    private static let meaningfulTypes: Set<String> = ["user", "assistant"]

    private func stateFromLastMeaningfulLine(of fileURL: URL) -> LastLineState {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return .noMeaningfulMessage
        }
        defer { try? handle.close() }

        let fileSize: UInt64
        do {
            fileSize = try handle.seekToEnd()
        } catch {
            return .noMeaningfulMessage
        }

        let tailSize: UInt64 = min(fileSize, 64 * 1024)
        let seekPos = fileSize - tailSize

        do {
            try handle.seek(toOffset: seekPos)
        } catch {
            return .noMeaningfulMessage
        }

        guard let data = try? handle.read(upToCount: Int(tailSize)),
              let tail = String(data: data, encoding: .utf8) else {
            return .noMeaningfulMessage
        }

        let lines = tail.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let jsonData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let entryType = json["type"] as? String else {
                continue
            }

            guard Self.meaningfulTypes.contains(entryType) else {
                continue
            }

            return parseMessageState(from: json, entryType: entryType)
        }

        return .noMeaningfulMessage
    }

    /// Walks the tail of the file backwards looking for the most recent
    /// assistant tool_use or text block, returning a short human-readable
    /// label paired with the assistant turn's transcript timestamp.
    private func summaryFromLastMeaningfulLine(of fileURL: URL) -> TimestampedSummary? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        let fileSize: UInt64
        do { fileSize = try handle.seekToEnd() } catch { return nil }

        let tailSize: UInt64 = min(fileSize, 128 * 1024)
        guard tailSize > 0 else { return nil }
        let seekPos = fileSize - tailSize
        do { try handle.seek(toOffset: seekPos) } catch { return nil }

        guard let data = try? handle.read(upToCount: Int(tailSize)),
              let tail = String(data: data, encoding: .utf8) else {
            return nil
        }

        let lines = tail.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let jsonData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  (json["type"] as? String) == "assistant",
                  let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else {
                continue
            }

            // Prefer the last non-empty content block from this assistant turn.
            for block in content.reversed() {
                if let summary = summarize(contentBlock: block) {
                    let ts = (json["timestamp"] as? String).flatMap(Self.transcriptDate(from:))
                        ?? Date()
                    return TimestampedSummary(text: summary, timestamp: ts)
                }
            }
        }
        return nil
    }

    private func summarize(contentBlock block: [String: Any]) -> String? {
        guard let blockType = block["type"] as? String else { return nil }

        switch blockType {
        case "tool_use":
            return summarizeToolUse(block)
        case "text":
            guard let text = block["text"] as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            // Collapse internal whitespace so a multi-paragraph reply renders
            // as a single flowable line — the row decides where to wrap.
            let collapsed = trimmed.replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            return truncate(collapsed, max: 240)
        case "thinking":
            return nil
        default:
            return nil
        }
    }

    private func summarizeToolUse(_ block: [String: Any]) -> String? {
        let name = block["name"] as? String ?? "Tool"
        let input = block["input"] as? [String: Any] ?? [:]

        switch name {
        case "Bash":
            if let cmd = input["command"] as? String {
                return "Bash: \(truncate(firstLine(of: cmd), max: 70))"
            }
            return "Bash"
        case "Read":
            if let path = input["file_path"] as? String {
                return "Read \(lastPathComponent(path))"
            }
            return "Read"
        case "Edit":
            if let path = input["file_path"] as? String {
                return "Edit \(lastPathComponent(path))"
            }
            return "Edit"
        case "Write":
            if let path = input["file_path"] as? String {
                return "Write \(lastPathComponent(path))"
            }
            return "Write"
        case "Grep":
            if let pattern = input["pattern"] as? String {
                return "Grep: \(truncate(pattern, max: 60))"
            }
            return "Grep"
        case "Glob":
            if let pattern = input["pattern"] as? String {
                return "Glob: \(truncate(pattern, max: 60))"
            }
            return "Glob"
        case "WebFetch":
            if let url = input["url"] as? String {
                return "WebFetch \(truncate(url, max: 60))"
            }
            return "WebFetch"
        case "WebSearch":
            if let query = input["query"] as? String {
                return "Search: \(truncate(query, max: 60))"
            }
            return "WebSearch"
        case "Task", "Agent":
            if let desc = input["description"] as? String {
                return "Agent: \(truncate(desc, max: 60))"
            }
            return name
        default:
            // For unknown tools, fall back to the first string-valued input we find.
            if let firstString = input.values.compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) {
                return "\(name): \(truncate(firstLine(of: firstString), max: 60))"
            }
            return name
        }
    }

    private func firstLine(of text: String) -> String {
        text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
    }

    private func lastPathComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func truncate(_ text: String, max: Int) -> String {
        if text.count <= max { return text }
        let endIndex = text.index(text.startIndex, offsetBy: max - 1)
        return text[..<endIndex] + "\u{2026}"
    }

    private func parseMessageState(from json: [String: Any], entryType: String) -> LastLineState {
        if entryType == "user" {
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]],
               content.contains(where: { ($0["type"] as? String) == "tool_result" }) {
                return .assistantWorking
            }
            return .userMessage
        }

        if entryType == "assistant" {
            if let message = json["message"] as? [String: Any] {
                let stopReason = message["stop_reason"] as? String
                if stopReason == "end_turn" { return .assistantDone }
                return .assistantWorking
            }
            return .assistantWorking
        }

        return .noMeaningfulMessage
    }
}
