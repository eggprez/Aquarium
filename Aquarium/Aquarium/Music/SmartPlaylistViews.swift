//  The rule editor for a smart playlist, and the page that answers one.

import SwiftUI

#if os(iOS)

struct SmartPlaylistEditor: View {
    @State var playlist: SmartPlaylist
    var onSave: (SmartPlaylist) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(JellyfinClient.self) private var client

    @State private var genreOptions: [String] = []
    @State private var artistSearch = ""
    @State private var artistMatches: [BaseItem] = []
    @State private var artistTask: Task<Void, Never>?
    @State private var yearFromText = ""
    @State private var yearToText = ""
    @State private var addedDays = 0
    @State private var minPlays = 0
    /// The fields are filled from the rule once. The Form's `.task` runs again
    /// on the way back from the Genres page and would put back what was typed.
    @State private var didLoad = false

    private let dayChoices = [0, 7, 30, 90, 180, 365]
    private let limitChoices = [25, 50, 100, 200, 500]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $playlist.name)
                }

                Section {
                    NavigationLink {
                        GenrePicker(options: genreOptions, selected: $playlist.genres)
                    } label: {
                        HStack {
                            Text("Genres")
                            Spacer()
                            Text(playlist.genres.isEmpty ? "Any" : playlist.genres.joined(separator: ", "))
                                .foregroundStyle(Theme.textDim)
                                .lineLimit(1)
                        }
                    }
                } footer: {
                    Text(playlist.genres.isEmpty ? "Any genre." : "Songs in any of the chosen genres.")
                }

                Section {
                    ForEach(playlist.artists) { artist in
                        HStack {
                            Text(artist.Name ?? "")
                            Spacer()
                            Button(role: .destructive) {
                                playlist.artists.removeAll { $0.id == artist.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.danger)
                        }
                    }
                    TextField("Add an artist", text: $artistSearch)
                        .onChange(of: artistSearch) { _, term in searchArtists(term) }
                    ForEach(artistMatches) { match in
                        Button {
                            if !playlist.artists.contains(where: { $0.Id == match.Id }) {
                                playlist.artists.append(NameGuidPair(Id: match.Id, Name: match.title))
                            }
                            artistSearch = ""
                            artistMatches = []
                        } label: {
                            Label(match.title, systemImage: "plus")
                        }
                    }
                } header: {
                    Text("Artists")
                } footer: {
                    Text(playlist.artists.isEmpty ? "Any artist." : "Songs by any of these.")
                }

                Section("Years") {
                    HStack {
                        TextField("From", text: $yearFromText).keyboardType(.numberPad)
                        Text("–").foregroundStyle(Theme.textDim)
                        TextField("To", text: $yearToText).keyboardType(.numberPad)
                    }
                }

                Section("Listening") {
                    Picker("Added in the last", selection: $addedDays) {
                        ForEach(dayChoices, id: \.self) { d in
                            Text(d == 0 ? "Any time" : "\(d) days").tag(d)
                        }
                    }
                    Picker("Played", selection: $playlist.played) {
                        ForEach(SmartPlaylist.PlayedFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Stepper("Played at least \(minPlays) time\(minPlays == 1 ? "" : "s")", value: $minPlays, in: 0...50)
                    Toggle("Favourites only", isOn: $playlist.favoritesOnly)
                }

                Section {
                    Picker("Sort", selection: $playlist.sort) {
                        ForEach(MusicSort.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Limit", selection: $playlist.limit) {
                        ForEach(limitChoices, id: \.self) { Text("\($0) songs").tag($0) }
                    }
                } header: {
                    Text("Order")
                } footer: {
                    Text(preview.summary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Smart Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(preview)
                        dismiss()
                    }
                    .disabled(playlist.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task {
                guard !didLoad else { return }
                didLoad = true
                yearFromText = playlist.yearFrom.map(String.init) ?? ""
                yearToText = playlist.yearTo.map(String.init) ?? ""
                addedDays = playlist.addedWithinDays ?? 0
                minPlays = playlist.minPlayCount ?? 0
                genreOptions = ((try? await client.musicGenres(limit: 400).items) ?? []).map(\.title)
                // No server: the genres of what is downloaded are still there
                // to choose from, and they are the only ones that would match.
                if genreOptions.isEmpty { genreOptions = OfflineMusic.genres }
            }
        }
    }

    /// The playlist as the fields currently describe it.
    private var preview: SmartPlaylist {
        var out = playlist
        out.name = playlist.name.trimmingCharacters(in: .whitespaces)
        out.yearFrom = Int(yearFromText)
        out.yearTo = Int(yearToText)
        out.addedWithinDays = addedDays > 0 ? addedDays : nil
        out.minPlayCount = minPlays > 0 ? minPlays : nil
        if !limitChoices.contains(out.limit) { out.limit = 100 }
        return out
    }

    private func searchArtists(_ term: String) {
        artistTask?.cancel()
        let query = term.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else {
            artistMatches = []
            return
        }
        artistTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let found = (try? await client.allArtists(limit: 8, searchTerm: query).items) ?? []
            guard !Task.isCancelled else { return }
            artistMatches = found
        }
    }
}

/// A library's genres, searchable, with ticks. A hundred and sixty toggles
/// in a form is a scroll nobody finishes.
struct GenrePicker: View {
    let options: [String]
    @Binding var selected: [String]
    @State private var filter = ""

    private var shown: [String] {
        let term = filter.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return options }
        return options.filter { $0.localizedCaseInsensitiveContains(term) }
    }

    var body: some View {
        List {
            if !selected.isEmpty {
                Section("Chosen") {
                    ForEach(selected, id: \.self) { genre in
                        Button {
                            selected.removeAll { $0 == genre }
                        } label: {
                            Label(genre, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Theme.text)
                        }
                    }
                }
            }
            Section(options.isEmpty ? "Loading…" : "All genres") {
                ForEach(shown, id: \.self) { genre in
                    Button {
                        if selected.contains(genre) { selected.removeAll { $0 == genre } } else { selected.append(genre) }
                    } label: {
                        HStack {
                            Text(genre).foregroundStyle(Theme.text)
                            Spacer()
                            if selected.contains(genre) {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Genres")
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter genres")
    }
}

struct SmartPlaylistDetailView: View {
    let playlistId: UUID

    @Environment(AppModel.self) private var app
    @Environment(MusicPlayer.self) private var music

    @State private var store = SmartPlaylistStore.shared
    @State private var songs: [BaseItem] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var editing: SmartPlaylist?
    @State private var isFreezing = false
    /// The songs shown came from this device, not the server.
    @State private var isLocal = false

    @Environment(JellyfinClient.self) private var client

    private var playlist: SmartPlaylist? { store.playlist(playlistId) }

    var body: some View {
        ScrollView {
            if let playlist {
                LazyVStack(alignment: .leading, spacing: 0) {
                    CollectionHeader(kicker: "Smart Playlist", title: playlist.name) {
                        ZStack {
                            RoundedRectangle(cornerRadius: MusicMetrics.tileRadius, style: .continuous)
                                .fill(Theme.accentSoft)
                            Image(systemName: "sparkles")
                                .font(.system(size: 48, weight: .light))
                                .foregroundStyle(Theme.accent)
                        }
                    } detail: {
                        Text(playlist.summary)
                            .font(.caption)
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(Theme.textDim)
                        if isLocal {
                            Label("Offline — answered from your downloads", systemImage: "wifi.slash")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.warn)
                        }
                    }

                    PlayShuffleBar(onPlay: {
                        music.play(songs, title: playlist.name)
                    }, onShuffle: {
                        music.play(songs, shuffle: true, title: playlist.name)
                    }, isEnabled: !songs.isEmpty)
                    .padding(.vertical, 16)

                    if isLoading, songs.isEmpty {
                        SkeletonList(count: 8)
                    } else if let error, songs.isEmpty {
                        ErrorState(error: error) { Task { await load() } }
                    } else if songs.isEmpty {
                        EmptyState(symbol: "sparkles", title: "Nothing matches", message: "Loosen the rules and try again.")
                    } else {
                        ForEach(songs) { song in
                            SongRow(song: song, isCurrent: music.current?.Id == song.Id, isPlaying: music.isPlaying) {
                                music.play(songs, startingAt: songs.position(of: song) ?? 0, title: playlist.name)
                            }
                        }
                    }
                }
                .padding(.bottom, 32)
            } else {
                EmptyState(symbol: "sparkles", title: "Gone", message: "This smart playlist was deleted.")
            }
        }
        .navigationTitle(playlist?.name ?? "Smart Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .paletteBar()
        .toolbar {
            if let playlist {
                Menu {
                    Button { editing = playlist } label: { Label("Edit Rules", systemImage: "slider.horizontal.3") }
                    Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    Button { Task { await freeze(playlist) } } label: {
                        Label("Save as Playlist on Server", systemImage: "square.and.arrow.up")
                    }
                    .disabled(songs.isEmpty || isFreezing || isLocal)
                    Divider()
                    Button(role: .destructive) {
                        store.delete(playlist.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task(id: playlist) { await load() }
        .onChange(of: client.showsOffline) { Task { await load() } }
        .refreshable { await load() }
        .sheet(item: $editing) { list in
            SmartPlaylistEditor(playlist: list) { store.upsert($0) }
        }
    }

    private func load() async {
        guard let playlist else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        // A rule doesn't care who answers it. Offline — or with a server that
        // stops answering — it is put to the downloads instead.
        if client.showsOffline {
            songs = OfflineMusic.resolve(playlist)
            isLocal = true
            return
        }
        do {
            songs = try await playlist.resolve()
            isLocal = false
        } catch {
            let local = OfflineMusic.resolve(playlist)
            if local.isEmpty { self.error = error.localizedDescription } else {
                songs = local
                isLocal = true
            }
        }
    }

    /// Freeze what the rule says today into a playlist the server keeps.
    private func freeze(_ playlist: SmartPlaylist) async {
        isFreezing = true
        defer { isFreezing = false }
        do {
            let id = try await PlaylistStore.shared.create(name: playlist.name, itemIds: songs.map(\.Id))
            app.toast("Saved \(songs.count) songs as “\(playlist.name)” on the server", tone: .ok)
            app.push(.music(.playlist(id)))
        } catch {
            app.toast("Couldn't save it: \(error.localizedDescription)", tone: .error)
        }
    }
}

#endif
