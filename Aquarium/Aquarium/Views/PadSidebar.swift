//  The iPad's sidebar: who is signed in, the sections gathered under
//  headings, and at the foot what is playing and how the server is doing.
//
//  Drawn by the app rather than left to a `List`. A list with a title and
//  nine identical rows is what the column was, and it read as a settings
//  page beside a media app. The rows are the same sections `AppModel` hands
//  the phone's tab bar; only what is around them changes.

#if os(iOS)
import SwiftUI

struct PadSidebar: View {
    /// Puts the sidebar away. The system's own toggle lives in the column's
    /// navigation bar, which this column hides to draw its own header.
    var collapse: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(JellyfinClient.self) private var client
    @Environment(MusicPlayer.self) private var music

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 6)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(PadSidebarGroup.grouped(app.sections)) { group in
                        eyebrow(group.title)
                        ForEach(group.sections) { section in
                            row(section)
                        }
                        if group.holdsSearch {
                            searchRow
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }

            footer
        }
        .background(Theme.sidebar.ignoresSafeArea())
    }

    // MARK: Header

    /// The account: an initial in a disc, the name, the server. The sidebar
    /// toggle sits at the trailing end, where the system's would have been.
    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(
                    LinearGradient(
                        colors: [Theme.accentStrong, Theme.link],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                Text(initial)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(client.session?.userName ?? "Aquarium")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(serverLine)
                    .font(.caption)
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            Button(action: collapse) {
                Image(systemName: "sidebar.leading")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide sidebar")
        }
    }

    private var initial: String {
        let name = client.session?.userName ?? ""
        return name.first.map { String($0).uppercased() } ?? "A"
    }

    /// The server, by its host: the name it gave at sign-in is not kept.
    private var serverLine: String {
        guard let server = client.session?.server, let url = URL(string: server) else { return "" }
        return url.host ?? server
    }

    // MARK: Rows

    private func eyebrow(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.textDim)
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ section: AppSection) -> some View {
        let selected = app.shownSelection == section
        return Button {
            // The row already showing goes back to its top, as a tab does.
            if selected {
                app.path(for: section).wrappedValue = NavigationPath()
            } else {
                app.selection = section
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: section.symbol)
                    .font(.body.weight(.medium))
                    .frame(width: 24)
                    .foregroundStyle(selected ? Theme.accent : Theme.textBody)
                Text(section.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(selected ? Theme.text : Theme.textBody)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if section == .downloads, DownloadManager.shared.transfersToFinish > 0 {
                    Text("\(DownloadManager.shared.transfersToFinish)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.link)
                        .padding(.horizontal, 7)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Theme.accentSoft, in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.text.opacity(0.08))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Search is not a section on iOS — it opens over whatever is showing,
    /// as Home's search button does — so its row pushes rather than selects.
    private var searchRow: some View {
        Button {
            app.push(.search(""))
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.medium))
                    .frame(width: 24)
                    .foregroundStyle(Theme.textBody)
                Text("Search")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textBody)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            if music.isActive, let song = music.current {
                SidebarNowPlaying(song: song)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            SidebarFooter()
        }
        .animation(.easeOut(duration: 0.2), value: music.isActive)
    }
}

/// A heading and the rows under it.
struct PadSidebarGroup: Identifiable {
    let title: String
    let sections: [AppSection]
    /// The first group carries the Search row after Home.
    var holdsSearch = false
    var id: String { title }

    /// Home and Search; the libraries, Music and Audiobooks among them; Live
    /// TV; then what is kept — favourites and what is on this iPad. Settings
    /// is the gear in the footer, not a row.
    static func grouped(_ sections: [AppSection]) -> [PadSidebarGroup] {
        var browse: [AppSection] = []
        var libraries: [AppSection] = []
        var live: [AppSection] = []
        var you: [AppSection] = []
        for section in sections {
            switch section {
            case .home, .search: browse.append(section)
            case .liveTV: live.append(section)
            case .favorites, .downloads: you.append(section)
            case .settings, .more: break
            default: libraries.append(section)
            }
        }
        return [
            PadSidebarGroup(title: "Browse", sections: browse, holdsSearch: true),
            PadSidebarGroup(title: "Libraries", sections: libraries),
            PadSidebarGroup(title: "Live", sections: live),
            PadSidebarGroup(title: "You", sections: you),
        ].filter { !$0.sections.isEmpty }
    }
}

/// What is playing, as a card at the foot of the sidebar: the cover, the
/// song, play or pause, and a line of progress along the bottom. A tap opens
/// Now Playing. The phone's bar across the page is `MiniPlayerBar`; this is
/// the same thing in the column an iPad keeps for it.
private struct SidebarNowPlaying: View {
    let song: BaseItem

    @Environment(MusicPlayer.self) private var music
    @State private var presenter = NowPlayingPresentation.shared

    var body: some View {
        HStack(spacing: 10) {
            MusicArtwork(item: song, width: 200, radius: 9, placeholderSymbol: song.isAudiobook ? "book" : "music.note")
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(Theme.text)
                Text(secondLine)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(Theme.textDim)
            }
            Spacer(minLength: 6)
            Button { music.togglePlayPause() } label: {
                Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 30, height: 30)
                    .background(Theme.text.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(music.isPlaying ? "Pause" : "Play")
        }
        .padding(10)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .bottom) {
            if music.duration > 0 {
                Rectangle().fill(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 2)
                    .scaleEffect(x: min(1, max(0, music.position / music.duration)), y: 1, anchor: .leading)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border.opacity(0.6), lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture { presenter.isPresented = true }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens Now Playing")
    }

    private var secondLine: String {
        if song.isAudiobook, let chapter = music.currentChapter?.Name, !chapter.isEmpty { return chapter }
        let artist = song.artistLine
        return artist.isEmpty ? (song.Album ?? "") : artist
    }
}
#endif
