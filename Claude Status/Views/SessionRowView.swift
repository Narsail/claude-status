import SwiftUI

/// Icon display style for session rows.
enum SessionIconStyle: String, CaseIterable {
    case emoji
    case dots

    var label: String {
        switch self {
        case .emoji: "Emoji"
        case .dots: "Dots"
        }
    }
}

/// A single row in the session list showing status, project name, and time.
struct SessionRowView: View {
    let session: ClaudeSession
    var iconStyle: SessionIconStyle = .emoji
    /// When non-nil, a small profile-name chip is shown next to the project name.
    /// SessionListView only passes this in when more than one profile is configured.
    var profileLabel: String?
    /// Layout mode. Window mode lets the action line wrap onto multiple lines
    /// to take advantage of the extra horizontal/vertical room.
    var presentation: SessionListPresentation = .popover

    @State private var isHovered = false

    /// Maximum number of lines for the recap/fallback summary. Popover stays
    /// strict at 1 to keep the menu compact; window mode shows the full text.
    private var actionLineLimit: Int {
        presentation == .window ? 6 : 1
    }

    /// While a session is actively working, prefer the live action snippet
    /// ("Bash: cargo build", "Read SettingsView.swift") so you can see what
    /// it's doing right now. Otherwise prefer the recap — but only when it's
    /// fresher than the latest action; a stale recap shouldn't shadow newer
    /// work the assistant has already done since the recap was written.
    /// Falls back to the hook's bare tool name when the JSONL has nothing yet.
    private var secondaryActionLine: String? {
        let action = session.lastAction
        let recap = session.recapIntent

        if session.state == .active {
            return action?.text ?? recap?.text ?? activityFallback
        }

        switch (recap, action) {
        case (nil, nil):
            return activityFallback
        case (let recap?, nil):
            return recap.text
        case (nil, let action?):
            return action.text
        case (let recap?, let action?):
            return recap.timestamp >= action.timestamp ? recap.text : action.text
        }
    }

    private var activityFallback: String? {
        session.activity.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    var body: some View {
        HStack(spacing: 6) {
            statusIndicator
                .frame(width: 16, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(session.sessionName ?? session.projectName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if let profileLabel {
                        profileChip(profileLabel)
                    }
                }

                HStack(spacing: 4) {
                    if session.sessionName != nil {
                        Text(session.projectName)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("\u{2022}")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                    Text(session.source.label)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if let actionLine = secondaryActionLine {
                    Text(actionLine)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(actionLineLimit)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text(session.state.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                Text(session.timeSinceActivity)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(session.workingDirectory)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch iconStyle {
        case .emoji:
            Text(session.state.emoji)
                .font(.system(size: 14))
        case .dots:
            ZStack {
                if session.state == .idle {
                    // Hollow ring so idle visually recedes vs filled dots.
                    Circle()
                        .strokeBorder(dotColor.opacity(0.6), lineWidth: 1.5)
                        .frame(width: 8, height: 8)
                } else {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 8, height: 8)
                    if session.state == .waiting {
                        // "?" marker reinforces "needs you" when scanning the list.
                        Text("?")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(y: -0.5)
                    }
                }
            }
        }
    }

    private var dotColor: Color {
        switch session.state {
        case .active: .green
        case .waiting: .red
        case .compacting: .blue
        case .idle: .gray
        }
    }

    private func profileChip(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(0.18))
            )
            .foregroundStyle(Color.accentColor)
    }
}

private extension String {
    /// `self` if non-empty, otherwise nil — lets us chain `?? fallback`.
    var nonEmpty: String? { isEmpty ? nil : self }
}
