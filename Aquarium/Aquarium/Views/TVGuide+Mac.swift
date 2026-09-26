//  The Mac half of the guide: what a pointer and a keyboard add to
//  `TVGuideView` that a finger and a remote never asked for. A selection that
//  is separate from playing, a popover that says what a programme is before
//  you commit to it, a ruler that stays put while the channels scroll under
//  it, and the pieces of a context menu.
//
//  Everything here is `#if os(macOS)`; the guide's own body decides when to
//  use it. Kept in its own file so that the layout in `TVGuideView.swift` —
//  which has a history of layout loops on iOS worth not disturbing — stays
//  readable as one thing.

#if os(macOS)
import SwiftUI
import AppKit
import Foundation

// MARK: - Selection

/// One cell of the guide, as the Mac's selection names it: which channel's
/// row, and which programme along it. `column` indexes the row's own
/// programme list; a row with no programme information has one cell at
/// column 0, the placeholder.
///
/// Also what the programme cells are `.id`'d with, so that a keyboard move
/// can ask the scroll view to bring the new selection into view.
struct GuideSelection: Hashable {
    var row: Int
    var column: Int
}

// MARK: - Clicks

enum GuideClicks {
    /// How long a click has to wait before it is known not to be a
    /// double-click — the system's own setting, which the user may have
    /// changed in System Settings ▸ Accessibility.
    static var doubleClickInterval: Duration {
        .seconds(NSEvent.doubleClickInterval)
    }
}

// MARK: - Sticky ruler

/// The horizontal scroll offset of the programme rows, reported up from a
/// `GeometryReader` behind them so that the pinned ruler above can be drawn
/// at the same offset. Positive as the guide is scrolled to the right.
struct GuideHorizontalOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// How wide the ruler — and so the programme viewport beside the channel
/// column — is. With the offset above it says whether the end of the
/// schedule has been scrolled into view.
struct GuideRulerWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The time marks along the top of the guide, pinned above the channels.
///
/// Not inside the horizontal scroll view with the rows — it is drawn in the
/// vertical scroll view's pinned header, translated by however far the rows
/// have been scrolled sideways, so it stays at the top of the window while
/// the channels scroll up past it. The translation comes from
/// `GuideHorizontalOffsetKey`, measured in the rows' own scroll view.
struct MacTimeRuler: View {
    let windowStart: Date
    let hours: Int
    let minuteWidth: CGFloat
    /// How far the rows have been scrolled to the right.
    let offset: CGFloat
    /// Where the red line is, if it falls inside the window.
    let now: Date

    /// Half-hour marks, for the reason `TimeRuler.step` gives.
    private static let step: TimeInterval = 30 * 60
    private var marks: Int { hours * Int(3600 / Self.step) }
    private var markWidth: CGFloat { CGFloat(Self.step / 60) * minuteWidth }
    private var totalWidth: CGFloat { CGFloat(hours * 60) * minuteWidth }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<marks, id: \.self) { i in
                let mark = windowStart.addingTimeInterval(Double(i) * Self.step)
                Text(Self.formatter.string(from: mark))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 6)
                    .frame(width: markWidth, alignment: .leading)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
            }
        }
        .frame(width: totalWidth, alignment: .leading)
        .overlay(alignment: .bottomLeading) { nowMark }
        .offset(x: -offset)
    }

    /// A short red tick where the red line through the rows meets the ruler.
    @ViewBuilder
    private var nowMark: some View {
        let end = windowStart.addingTimeInterval(Double(hours) * 3600)
        if now >= windowStart, now < end {
            let x = CGFloat(now.timeIntervalSince(windowStart) / 60) * minuteWidth
            Rectangle()
                .fill(.red)
                .frame(width: 1.5, height: 8)
                .offset(x: x)
                .allowsHitTesting(false)
        }
    }

    private static let formatter: DateFormatter = {
        let df = DateFormatter()
        df.timeStyle = .short
        df.dateStyle = .none
        return df
    }()
}

// MARK: - Programme popover

/// What a single click on a programme opens: enough to decide whether to
/// watch it, and the button that does. The default button, so Return in
/// the popover tunes the channel.
struct GuideProgrammePopover: View {
    let channel: BaseItem
    /// Nil for a row with no programme information.
    let program: BaseItem?
    var onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(program?.title ?? "No Programme Information")
                    .font(.headline)
                    .lineLimit(3)
                if let episode = program?.EpisodeTitle, !episode.isEmpty {
                    Text(episode)
                        .font(.subheadline)
                        .lineLimit(2)
                }
                if let program, let window = Format.programWindow(start: program.programStart, end: program.programEnd) {
                    Text(window)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(channelLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let overview = program?.Overview, !overview.isEmpty {
                Text(overview)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let genres = program?.Genres, !genres.isEmpty {
                Text(genres.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Spacer()
                Button("Play Channel", action: onPlay)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    private var channelLabel: String {
        if let number = channel.ChannelNumber, !number.isEmpty {
            return "\(number) · \(channel.title)"
        }
        return channel.title
    }
}

// MARK: - Context menu

/// The right-click menu on a channel or a programme cell. Three verbs, the
/// same three on both, so the menu reads the same wherever it is opened.
struct GuideCellMenu: View {
    /// What "Copy Title" puts on the pasteboard.
    let title: String
    var onPlay: () -> Void
    var onInfo: () -> Void

    var body: some View {
        Button("Play Channel", action: onPlay)
        Button("Show Info", action: onInfo)
        Divider()
        Button("Copy Title") { GuidePasteboard.copy(title) }
    }
}

enum GuidePasteboard {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

// MARK: - Type to select

/// The letters typed into the guide so far, the way a Finder window collects
/// them: keystrokes within a second of each other join into one prefix, a
/// pause starts over.
@MainActor
final class GuideTypeSelect {
    private var buffer = ""
    private var lastKey = Date.distantPast
    private static let gap: TimeInterval = 1.0

    var isEmpty: Bool { buffer.isEmpty || Date().timeIntervalSince(lastKey) > Self.gap }

    /// Adds what was typed and returns the prefix to look for.
    func append(_ characters: String) -> String {
        let now = Date()
        if now.timeIntervalSince(lastKey) > Self.gap { buffer = "" }
        lastKey = now
        buffer += characters.lowercased()
        return buffer
    }

    func reset() {
        buffer = ""
        lastKey = .distantPast
    }

    /// The first channel whose name starts with the prefix, else the first
    /// whose name contains it — "bbc" finds "UK: BBC One" even though the
    /// line-up's prefix is in the way. The noise every line-up puts in front
    /// of a name is skipped the same way `ChannelGuideCell.initials` skips it.
    static func match(_ prefix: String, in channels: [BaseItem]) -> Int? {
        guard !prefix.isEmpty else { return nil }
        let names = channels.map { channel -> String in
            let title = channel.title.lowercased()
            let cleaned = title
                .components(separatedBy: CharacterSet(charactersIn: ":|"))
                .last?
                .trimmingCharacters(in: .whitespaces) ?? title
            return cleaned
        }
        if let i = names.firstIndex(where: { $0.hasPrefix(prefix) }) { return i }
        if let i = channels.firstIndex(where: { ($0.ChannelNumber ?? "").hasPrefix(prefix) }) { return i }
        return names.firstIndex(where: { $0.contains(prefix) })
    }
}

// MARK: - Subtitle

enum GuideDayLabel {
    /// The day a window starts on, the way a calendar names it: "Today",
    /// "Tomorrow", "Yesterday", or the weekday and date.
    static func label(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let df = DateFormatter()
        df.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return df
    }()
}
#endif
