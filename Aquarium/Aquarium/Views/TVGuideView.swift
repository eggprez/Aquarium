//  Live TV, laid out the way a paper TV guide always was: channels down the
//  side, time across the top, and each programme drawn as wide as the
//  minutes it runs. Drives both Jellyfin channels and a custom M3U/XMLTV
//  source (see LiveTVView) from the same grid: a channel from either carries
//  what it needs on the `BaseItem` itself, so nothing here has to know which
//  one it's drawing.

import SwiftUI

struct TVGuideView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(PlayerModel.self) private var player

    let channels: [BaseItem]
    /// How the guide gets programme data for a set of channel ids and a time
    /// window. Nil asks the signed-in Jellyfin server, which is right for
    /// its own channels; the custom playlist source passes its own, already
    /// -downloaded XMLTV programmes instead, filtered client-side rather
    /// than fetched — there is no server on the other end of that one to ask.
    ///
    /// `@Sendable` so that filtering happens wherever the task runs rather
    /// than on the main actor. A closure formed in a view body is isolated to
    /// the main actor unless it says otherwise, and this one walks every
    /// programme in the guide — which on a real XMLTV feed is a few thousand
    /// of them, each one asked for its start and end time. That ran between
    /// the tab being tapped and the screen appearing, and it is what made the
    /// transition stop dead.
    var programsProvider: (@Sendable ([String], Date, Date) async throws -> [BaseItem])?

    /// The term that matched nothing, when the filter has emptied the list.
    /// Only a Mac has a filter to empty it with — see `LiveTVView`.
    var noMatches: String?

    @State private var windowStart = TVGuideView.roundedNow()
    /// Bumped every time the guide is sent back to now. `windowStart` alone
    /// can't stand in for it: leaving the screen and coming back inside the
    /// same half hour leaves the window where it was, and the thing that needs
    /// undoing is how far sideways the guide was scrolled within it.
    @State private var resetCount = 0
    /// The app has been in the background since the guide last reset for it.
    @State private var wasBackgrounded = false
    /// The clock the red line is drawn against.
    ///
    /// It used to be `Date()`, read while the body was being built — so the
    /// line only moved when something else caused a redraw, and a screen left
    /// alone showed where "now" had been when it was last touched. The window
    /// itself had the same problem one size larger: `windowStart` is state
    /// initialised once, and a tab's view is not torn down when you switch away
    /// from it, so a guide come back to after a few hours was still drawing
    /// this morning's schedule until the app was force-quit.
    @State private var nowTick = Date()
    /// Whether the window is tracking the clock. It stops the moment a Mac's
    /// arrows move it, and starts again on "Now" or any of the ways back to
    /// now — without it the half-minute tick put the window back at the
    /// current half hour and a press of ▶ undid itself within thirty seconds.
    @State private var followsNow = true
    @State private var programsByChannel: [String: [BaseItem]] = [:]
    /// What `programsByChannel` covers, so that a window which has only grown
    /// later asks for the new hours and nothing else.
    @State private var loadedWindow: (start: Date, end: Date, channels: [String])?
    @State private var isLoadingPrograms = false
    @State private var guideError: String?
    /// Bumped by every programme fetch, so one that has been overtaken can't
    /// put its error — or its "done" — over the newer one's.
    @State private var programsGeneration = 0
    /// Which channel rows the programme column actually builds — see
    /// `noteRow`.
    @State private var rowWindow: Range<Int> = 0..<Self.rowWindowBlock
    /// The rows the channel column has on hand right now. A reference held in
    /// `@State` rather than a value: it is written on every row that scrolls
    /// past, and the answer that matters — `rowWindow` — changes far less
    /// often than that. Kept out of the view's own state, the bookkeeping
    /// costs no redraws.
    @State private var liveRows = LiveRows()

    /// Where in the guide the selector is, on a television.
    ///
    /// Watched rather than driven: what it is for is noticing the selector
    /// *arriving* on a programme from outside the guide — see `body` — and
    /// sending it to the channel that programme belongs to.
    ///
    /// Declared on every platform rather than behind an `#if`, so that
    /// `GuideRow` takes the same arguments everywhere and only the modifier
    /// reading it is conditional. Nowhere else does a guide cell take focus at
    /// all, so nowhere else does this ever hold anything.
    @FocusState private var focus: GuideFocus?

    @Environment(\.scenePhase) private var scenePhase

    /// How many hours of schedule the guide holds. How many of them are *on
    /// screen* is a different question, and is settled by
    /// `Metrics.guideMinuteWidth` — on a television that is now half as many,
    /// which is the point of the wider scale there.
    ///
    /// It grows rather than sliding. Scrolling to the end of what has been
    /// fetched asks for the next six hours and they are added on the right, so
    /// the schedule simply keeps going under your finger — see `extendWindow`.
    @State private var windowHours = TVGuideView.baseWindowHours

    /// What the guide opens with, and how much it adds each time it is asked
    /// for more.
    private static let baseWindowHours = 6

    /// Where it stops. A day is as much as any guide source reliably carries,
    /// and it is far past the point where scrolling stops being how anyone
    /// would look for a programme.
    private static let maxWindowHours = 24

    /// The end of the schedule is on screen, so fetch some more of it.
    ///
    /// This replaces the two window arrows on the platforms that no longer draw
    /// them. The arrows were the only way past the first six hours; without
    /// something in their place, a phone and a television could see this
    /// evening and nothing after it. Scrolling right is what someone does to
    /// look further ahead anyway, so it is what asks.
    ///
    /// Nothing measures a scroll offset to work this out — see the notes on
    /// `.coordinateSpace` in this file's history. The ruler's marks are a
    /// `LazyHStack` inside the scroll view that actually scrolls horizontally,
    /// so the last of them appearing *is* the end coming into view, the same
    /// way `MediaGrid` pages a library.
    private func extendWindow() {
        guard windowHours < Self.maxWindowHours else { return }
        windowHours += Self.baseWindowHours
    }

    private var rulerHeight: CGFloat {
        #if os(tvOS)
        44
        #else
        30
        #endif
    }

    private var windowEnd: Date { windowStart.addingTimeInterval(Double(windowHours) * 3600) }
    private var totalWidth: CGFloat { CGFloat(windowHours * 60) * Metrics.guideMinuteWidth }
    private var totalHeight: CGFloat { rulerHeight + CGFloat(channels.count) * Metrics.guideRowHeight }

    // `controls` is a pinned section header *inside* the scroll view rather
    // than a `.safeAreaInset` above it.
    //
    // An inset is fixed: it is subtracted from the scroll view's safe area and
    // then stays exactly where it was put. On iOS that same scroll view is
    // what this screen's large title and `.searchable`'s search bar watch to
    // decide how far to collapse, and those two do move — so pulling past the
    // top slid the title and the search bar down *underneath* a header that
    // hadn't budged, with the title disappearing behind the header's own
    // opaque background and reappearing in the wrong place on the way back.
    //
    // A pinned header is part of the content instead. It travels with the
    // bounce, so nothing can slide under it, and it still stops at the top
    // edge once the guide scrolls up past it — which is the reason the
    // controls were worth keeping in view in the first place.
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    grid
                } header: {
                    VStack(alignment: .leading, spacing: 0) {
                        controls

                        if let guideError {
                            GuideErrorBanner(message: guideError) { Task { await loadPrograms() } }
                        }

                        Rectangle().fill(Theme.border).frame(height: 0.5)
                    }
                    .background(Theme.background)
                }
            }
        }
        // Keyed on both ends of the window: the start moves when a Mac's
        // arrows shift it, the length grows when the guide is scrolled to its
        // end, and either one means a different set of programmes.
        //
        // And on the channels themselves: a source switch or a refresh hands
        // over a new list, whose programmes the old window's fetch never asked
        // for.
        .task(id: WindowKey(start: windowStart, hours: windowHours, channels: channels.map(\.id).hashValue)) {
            await loadPrograms()
        }
        .task(id: channels.count) { resetRowWindow() }
        // Keeps the red line moving, and catches a guide that has been sitting
        // on a television since this morning: a tick that crosses a half hour
        // moves the window with it.
        .task { await keepTime() }
        // Every way back onto this screen sends it to now. Appearing covers
        // the tab being selected again; the player closing covers coming back
        // out of a channel, which is the one the guide is most often left
        // through; the scene becoming active covers the whole app having been
        // away.
        .onAppear { resetToNow() }
        .reloadWhenPlaybackEnds { resetToNow() }
        .onChange(of: scenePhase) { _, phase in
            // Only a return from the background. Becoming active also follows
            // a dialog, Control Center or a notification closing, and each
            // reset rebuilds the whole grid — every visible row and cell —
            // to put back a guide that never went anywhere.
            if phase == .background { wasBackgrounded = true }
            if phase == .active, wasBackgrounded {
                wasBackgrounded = false
                resetToNow()
            }
        }
        // A window shifted wholesale is a fresh question; whatever had been
        // scrolled up to belonged to the old one.
        .onChange(of: windowStart) { _, _ in windowHours = Self.baseWindowHours }
        #if os(tvOS)
        // Coming down off the tab strip, the guide is one target and the engine
        // picks whatever of it happens to lie under the selector — a programme
        // cell somewhere in the middle of tonight's schedule, in a row whose
        // channel name is off to the left where it can't be read. A guide is
        // read channel-first: you pick the channel, and then, if you care,
        // scroll sideways through what is on it.
        //
        // A default focus preference cannot say that. `prefersDefaultFocus` is
        // consulted when focus is *placed* — on a reset, or when a scope is
        // first given focus — and coming down off the tab strip is neither: it
        // is a directional move, and a directional move is settled by geometry
        // and nothing else. That is why the scope this screen used to declare
        // never changed where the selector landed.
        //
        // So the arrival is caught instead of predicted. `focus` is nil for as
        // long as the selector is anywhere outside the guide — the tab strip,
        // the window arrows, the filter field — so a programme taking focus
        // straight out of nil *is* the guide being entered, and it is sent left
        // to that programme's own channel. Once inside, `focus` is no longer
        // nil, so moving between programmes is left alone.
        .onChange(of: focus) { previous, current in
            guard previous == nil, let current,
                  case .program(let channelId, _) = current else { return }
            focus = .channel(channelId)
        }
        #endif
        // Hours across and channels down is the one page in this app that is
        // wider than it is tall, so it is the one page a phone may be turned
        // sideways for. See `OrientationLock`.
        .allowsLandscape()
    }

    // MARK: - Controls

    /// While a window is loading, a spinner. On a Mac, two arrows beside it.
    /// Nothing else.
    ///
    /// There was a "Now" button here, and then a label naming the day. Both
    /// went for the same reason: the grid opens on the current half hour, the
    /// ruler writes the half hours along the top and the red line says where in
    /// them you are, so where you are and how to get back to now are already on
    /// the screen. A control that only repeated what the page already said was
    /// a third thing to read past.
    ///
    /// The arrows and the filter field followed on the two platforms with no
    /// room for them. On a television they were two more stops between the tab
    /// strip and the first channel; on a phone they cost a row of the one
    /// screen in this app that is short of height, above a guide already six
    /// hours wide that scrolls sideways by itself. A Mac window has the width
    /// to carry both without taking anything from the guide, so it keeps them.
    /// What is left everywhere is the loading spinner, which is a report rather
    /// than a control.
    private var controls: some View {
        HStack(spacing: 10) {
            #if os(macOS)
            GuideNavButton(symbol: "chevron.left") { shiftWindow(by: -shiftSeconds) }
                .help("Earlier")
            GuideNavButton(symbol: "chevron.right") { shiftWindow(by: shiftSeconds) }
                .help("Later")
            // Only once the arrows have taken the guide away from now; while
            // it opens on the current half hour it would only repeat what the
            // red line already says.
            if !followsNow {
                Button("Now") { resetToNow() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Back to what's on now")
                    .transition(.opacity)
            }
            #endif
            Spacer(minLength: 0)
            if isLoadingPrograms {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        // Nothing in the row, no row. Without arrows or a filter field this is
        // empty most of the time on a phone and a television, and sixteen
        // points of nothing above the guide is sixteen points the guide had
        // asked for.
        .padding(.vertical, hasControls ? 8 : 0)
    }

    /// Whether the controls row has anything in it right now.
    private var hasControls: Bool {
        #if os(macOS)
        return true
        #else
        return isLoadingPrograms
        #endif
    }

    #if os(macOS)
    /// How far one arrow moves the window: half of the window it opens with,
    /// so the hour you were looking at is still on screen after the jump.
    ///
    /// Measured against `baseWindowHours` rather than against `windowHours`,
    /// which grows as the guide is scrolled — a press that jumped twelve hours
    /// because you had scrolled a long way first is not what an arrow next to
    /// its opposite means. Shifting resets the length anyway; see `body`.
    private var shiftSeconds: TimeInterval { Double(Self.baseWindowHours) / 2 * 3600 }

    private func shiftWindow(by seconds: TimeInterval) {
        let shifted = windowStart.addingTimeInterval(seconds)
        windowStart = shifted
        withAnimation(.easeOut(duration: 0.15)) { followsNow = shifted == Self.roundedNow() }
    }
    #endif

    // MARK: - Grid
    //
    // The ruler is drawn as the first row inside the same horizontal
    // ScrollView as the programme rows, rather than as a separate view kept
    // in step with the body's scroll position by hand. An earlier version
    // tracked that offset itself, through a GeometryReader reporting into a
    // PreferenceKey — the standard trick for a header that has to float free
    // of the content it's labelling — but the two drifted out of sync in
    // practice (the ruler landing hours away from the programmes it was
    // meant to sit above) and a fresh reference into the same scroll view is
    // proof against that class of bug rather than another attempt to get the
    // tracking right: there is only one offset, because there is only one
    // ScrollView. The cost is that the ruler scrolls away with the channels
    // rather than staying pinned at the top — a real loss, not nothing, but
    // a guide with a wrong ruler is worse than one with no sticky ruler.

    @ViewBuilder
    private var grid: some View {
        if let noMatches, channels.isEmpty {
            Text("Nothing in the channel list matches \u{201C}\(noMatches)\u{201D}.")
                .font(.callout)
                .foregroundStyle(Theme.textDim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 28)
        } else {
            gridBody
        }
    }

    private var gridBody: some View {
        HStack(alignment: .top, spacing: 0) {
            LazyVStack(spacing: 0) {
                // Blank corner, matching the ruler row's height, so a
                // channel's own row lines up with its programmes rather
                // than sitting one row high of them. Given its width
                // explicitly rather than leaving it to `Color`'s own
                // ideal size — unconstrained, that's infinite, and an
                // infinitely wide child is what this column's LazyVStack
                // would report wanting to the HStack it sits in.
                Color.clear.frame(width: Metrics.guideChannelColumnWidth, height: rulerHeight)
                ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
                    ChannelGuideCell(channel: channel, onPlay: { play(channel) })
                        .frame(width: Metrics.guideChannelColumnWidth, height: Metrics.guideRowHeight)
                        #if os(tvOS)
                        .focused($focus, equals: .channel(channel.id))
                        #endif
                        .onAppear { noteRow(index, visible: true) }
                        .onDisappear { noteRow(index, visible: false) }
                }
            }
            // Sizing every child doesn't size the column: a LazyVStack takes
            // the whole width it is offered rather than the width its rows
            // want, so this one claimed half the screen and drew its 280-point
            // cells centred in the middle of it — a band of empty space down
            // each side of the channel names, and the programmes starting a
            // third of the way across a television. Pinned to the column
            // width, the guide starts at the leading edge and the hours get
            // the rest.
            .frame(width: Metrics.guideChannelColumnWidth)
            .focusRegion()

            ScrollView(.horizontal, showsIndicators: false) {
                // A plain `VStack`, and the word *plain* is the whole of it.
                //
                // A `LazyVStack` here was two separate faults wearing one coat.
                // The harmless-looking one first: a lazy stack decides what to
                // build from the visible rectangle of the scroll view it is
                // inside, and the one it is inside here scrolls *horizontally*.
                // Vertically that scroll view is as tall as its content, so
                // every row is inside its visible rectangle and every row gets
                // built anyway — a few thousand programme cells constructed in
                // one go between the tab being tapped and the screen appearing.
                // That is the whole reason for `rowWindow` below: the laziness
                // this stack advertised was never real, so the window is kept
                // by hand instead, from the channel column on the left — which
                // sits directly in the vertical scroll view and *is* genuinely
                // lazy, and was never the slow half.
                //
                // The other fault was that it hung the application. A lazy
                // stack asks its scroll view for a visible rectangle and its
                // own layout is part of the answer; nested one scroll view
                // inside another, the two never settle. The main thread spins
                // in `_UIHostingView.layoutSubviews`, recursing through
                // `HostingScrollView.PlatformContainer._updateSafeAreaInsets`,
                // and the tab transition freezes half-finished — no crash, no
                // log, just a screen that stops. It needs the content to be
                // taller than the viewport before it starts, which is why it
                // took a line-up of about ten channels to show: four were fine
                // and twelve were fatal. Nesting the scroll views is not the
                // problem and neither is the pinned header — both were tried
                // alone and neither reproduces it. This one word does.
                VStack(spacing: 0) {
                    TimeRuler(windowStart: windowStart, hours: windowHours) { extendWindow() }
                        .frame(width: totalWidth, height: rulerHeight, alignment: .leading)
                    // Only the rows anywhere near the screen are drawn; the
                    // rest are a spacer of exactly the right height. See above
                    // for why this is done by hand.
                    ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
                        if rowWindow.contains(index) {
                            GuideRow(
                                channelId: channel.id,
                                programs: programsByChannel[channel.id] ?? [],
                                windowStart: windowStart,
                                windowEnd: windowEnd,
                                totalWidth: totalWidth,
                                rowHeight: Metrics.guideRowHeight,
                                onPlay: { play(channel) },
                                focus: $focus
                            )
                        } else {
                            Color.clear
                                .frame(width: totalWidth, height: Metrics.guideRowHeight)
                        }
                    }
                }
                .overlay(alignment: .topLeading) { nowLine }
            }
            // Resets the scroll position to the leading edge whenever the
            // arrows swap the window's content out from under it — a
            // ScrollView doesn't do that on its own when its content
            // changes, and the old window's scroll position means
            // nothing against the new one's.
            .id(ResetKey(start: windowStart, resets: resetCount))
            .focusRegion()
        }
        // Two scroll views side by side, one of them nested inside the other's
        // row: without this the selector coming down off the controls had
        // nothing directly in line to move onto and stayed where it was, which
        // is why the guide could be looked at on a television but never
        // entered.
        .focusRegion()
    }

    @ViewBuilder
    private var nowLine: some View {
        let now = nowTick
        if now >= windowStart, now < windowEnd {
            let x = CGFloat(now.timeIntervalSince(windowStart) / 60) * Metrics.guideMinuteWidth
            Rectangle()
                .fill(Theme.danger)
                .frame(width: 1.5, height: totalHeight)
                .offset(x: x)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Data

    /// A channel from the custom playlist carries its own stream URL and
    /// plays straight through AVPlayer; a Jellyfin channel tunes the way it
    /// always has, through PlaybackInfo.
    private func play(_ channel: BaseItem) {
        if let raw = channel.ExternalStreamURL, let url = URL(string: raw) {
            player.playExternal(
                title: channel.title,
                subtitle: "",
                artworkURL: Artwork.channelLogo(channel, width: 600),
                streamURL: url,
                channel: channel
            )
        } else {
            Task {
                await player.play(item: channel, options: StreamOptions(resume: false, live: true))
            }
        }
    }

    private func loadPrograms() async {
        programsGeneration += 1
        let mine = programsGeneration
        isLoadingPrograms = true
        guideError = nil
        defer { if mine == programsGeneration { isLoadingPrograms = false } }
        let ids = channels.map(\.id)
        let start = windowStart, end = windowEnd
        // "Later" on the ruler adds hours to the end of the same window. The
        // hours already on screen used to be fetched again with them — a
        // five-thousand-programme request for the whole span — and every row
        // regrouped; now only the new stretch is asked for and appended.
        let extendingFrom: Date? = loadedWindow.flatMap {
            $0.start == start && $0.channels == ids && end > $0.end ? $0.end : nil
        }
        let existing = programsByChannel
        do {
            let items: [BaseItem]
            if let programsProvider {
                items = try await programsProvider(ids, extendingFrom ?? start, end)
            } else {
                items = try await client.programs(channelIds: ids, start: extendingFrom ?? start, end: end)
            }
            var grouped = await Self.grouped(items)
            if extendingFrom != nil { grouped = await Self.appending(grouped, to: existing) }
            guard mine == programsGeneration, !Task.isCancelled else { return }
            programsByChannel = grouped
            loadedWindow = (start, end, ids)
        } catch is CancellationError {
            // Overtaken by a newer window or channel list; not an outage.
        } catch {
            guard mine == programsGeneration, !Task.isCancelled else { return }
            guideError = error.localizedDescription
        }
    }

    /// Programmes filed under the channel they belong to, each channel's in
    /// the order they air.
    ///
    /// Off the main actor, and each programme's start time read once rather
    /// than once per comparison. Sorting a channel's evening by
    /// `programStart` looks free and is not: a comparison sort asks every
    /// element for its key some log-n times over, so a guide of a couple of
    /// thousand programmes was parsing tens of thousands of timestamps to put
    /// them in order — the larger half of the pause Live TV used to open
    /// with, with the filtering above it the smaller. Reading the key once and
    /// sorting the pairs is the ordinary fix for that, and it belongs off the
    /// main thread besides.
    private static func grouped(_ items: [BaseItem]) async -> [String: [BaseItem]] {
        await Task.detached(priority: .userInitiated) {
            var map: [String: [(start: Date, item: BaseItem)]] = [:]
            for item in items {
                guard let channelId = item.ChannelId else { continue }
                map[channelId, default: []].append((item.programStart ?? .distantPast, item))
            }
            return map.mapValues { $0.sorted { $0.start < $1.start }.map(\.item) }
        }.value
    }

    /// A later stretch of the schedule added to what is already filed. A
    /// programme that spans the old end of the window came back in both
    /// fetches and is kept once; everything else in the new stretch starts
    /// after what is there, so appending keeps each channel in order.
    private static func appending(
        _ fresh: [String: [BaseItem]], to existing: [String: [BaseItem]]
    ) async -> [String: [BaseItem]] {
        await Task.detached(priority: .userInitiated) {
            var out = existing
            for (channel, items) in fresh {
                let have = Set(out[channel]?.map(\.Id) ?? [])
                out[channel, default: []].append(contentsOf: items.filter { !have.contains($0.Id) })
            }
            return out
        }.value
    }

    // MARK: - Row window

    /// How many rows are added or dropped at a time.
    ///
    /// The window is quantised rather than tracked point for point: the scroll
    /// offset changes every frame, and a window recomputed from it exactly
    /// would set state — and so rebuild the column — every frame too. Rounded
    /// out to whole blocks it changes a few times per screenful, and the extra
    /// rows either side are the buffer that keeps a fast flick from outrunning
    /// it.
    private static let rowWindowBlock = 12

    /// A channel row has come into or gone out of the column on the left.
    ///
    /// That column is a `LazyVStack` sitting directly in the vertical scroll
    /// view, so the system already decides for it which rows are worth
    /// building — and it is beside the programme rows, one for one, at the
    /// same height. So it is asked rather than measured: whatever the channel
    /// names think is on screen is what the programmes beside them should be
    /// drawing too. Nothing to keep in step with a scroll offset, and nothing
    /// that can drift out of it.
    private func noteRow(_ index: Int, visible: Bool) {
        if visible {
            liveRows.indices.insert(index)
        } else {
            liveRows.indices.remove(index)
        }
        guard let low = liveRows.indices.min(), let high = liveRows.indices.max() else { return }

        let block = Self.rowWindowBlock
        let lower = max(0, (low / block) * block - block)
        let upper = min(channels.count, (high / block + 2) * block)
        let wanted = lower..<max(lower, upper)
        if wanted != rowWindow { rowWindow = wanted }
    }

    private func resetRowWindow() {
        liveRows.indices.removeAll()
        rowWindow = 0..<min(channels.count, Self.rowWindowBlock * 3)
    }

    /// Put the guide back where it opens: the current half hour at the leading
    /// edge, the base window length, and whatever was scrolled to forgotten.
    private func resetToNow() {
        withAnimation(.easeOut(duration: 0.15)) { followsNow = true }
        nowTick = Date()
        let start = Self.roundedNow()
        if start != windowStart {
            windowStart = start
        } else {
            // Same half hour, so nothing above notices — but the guide may
            // still be scrolled hours to the right, and that is the half of
            // "back to now" that is actually visible.
            windowHours = Self.baseWindowHours
        }
        resetCount &+= 1
    }

    /// One tick every half minute, aligned to the wall clock rather than to
    /// whenever the screen happened to appear.
    private func keepTime() async {
        while !Task.isCancelled {
            let now = Date()
            let step = Self.tickInterval
            let wait = step - now.timeIntervalSince1970.truncatingRemainder(dividingBy: step)
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            let tick = Date()
            nowTick = tick
            // The window is half-hourly, so this is true twice an hour at most
            // and is what stops a guide left open overnight from drawing
            // yesterday.
            let start = Self.roundedNow()
            if followsNow, start != windowStart { windowStart = start }
        }
    }

    private static let tickInterval: TimeInterval = 30

    /// Now, back to the last local half hour.
    ///
    /// Rounded as an instant rather than rebuilt from the clock's hour and
    /// minute: on the night the clocks go back, 1:40 happens twice, and asking
    /// the calendar for "1:30 today" answers with the first one — an hour
    /// behind during the second. Shifting by the zone's offset at this instant
    /// keeps the boundaries on the local half hour in zones that sit at :45.
    private static func roundedNow() -> Date {
        let now = Date()
        let offset = TimeInterval(TimeZone.current.secondsFromGMT(for: now))
        let local = now.timeIntervalSinceReferenceDate + offset
        let floored = (local / 1800).rounded(.down) * 1800
        return Date(timeIntervalSinceReferenceDate: floored - offset)
    }
}

/// What the horizontal scroll view is identified by, so it goes back to the
/// leading edge both when the window moves and when the guide is simply asked
/// to show now again.
private struct ResetKey: Hashable {
    var start: Date
    var resets: Int
}

/// Which stretch of schedule is being shown, as one value, so the fetch is
/// re-run when either end of it moves.
private struct WindowKey: Hashable {
    var start: Date
    var hours: Int
    /// Which channels, as a hash of their ids.
    var channels: Int
}

/// The channel rows the column on the left currently has built — see `noteRow`.
@MainActor
private final class LiveRows {
    var indices: Set<Int> = []
}

// MARK: - Time ruler

private struct TimeRuler: View {
    let windowStart: Date
    let hours: Int
    /// Called when the last mark comes into view — the guide has been scrolled
    /// to the end of what it holds. See `TVGuideView.extendWindow`.
    var onReachEnd: () -> Void = {}

    /// How far apart the marks are written.
    ///
    /// Half an hour rather than a whole one: a programme starts on the half
    /// as often as on the hour, and against an hourly ruler every one of
    /// those began at a mark that wasn't there — leaving the block's own
    /// start time as the only way to read it, which is the work the ruler
    /// exists to have already done.
    ///
    /// It costs nothing to draw. `windowStart` is rounded to the half hour
    /// (see `roundedNow`), so every mark lands on a real boundary rather than
    /// somewhere inside one, and even at a phone's 3.4 points a minute a half
    /// hour is a hundred points of tile — room enough for the label and its
    /// line without the two crowding each other.
    private static let step: TimeInterval = 30 * 60

    private var marks: Int { hours * Int(3600 / Self.step) }

    private var markWidth: CGFloat { CGFloat(Self.step / 60) * Metrics.guideMinuteWidth }

    /// Lazy, unlike everything else drawn inside this scroll view — and this
    /// is the one stack whose lazy axis and its scroll view's axis are the same
    /// one, which is what makes the laziness real rather than advertised. It is
    /// only here so that the last mark's `onAppear` can mean what it says: the
    /// end of the schedule has been scrolled to.
    var body: some View {
        LazyHStack(spacing: 0) {
            ForEach(0..<marks, id: \.self) { i in
                let mark = windowStart.addingTimeInterval(Double(i) * Self.step)
                Text(Self.formatter.string(from: mark))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.textDim)
                    .padding(.leading, 6)
                    .frame(width: markWidth, alignment: .leading)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.border).frame(width: 0.5)
                    }
                    .onAppear { if i == marks - 1 { onReachEnd() } }
            }
        }
    }

    private static let formatter: DateFormatter = {
        let df = DateFormatter()
        df.timeStyle = .short
        df.dateStyle = .none
        return df
    }()
}

// MARK: - Channel column

private struct ChannelGuideCell: View {
    let channel: BaseItem
    var onPlay: () -> Void

    /// Whether the logo slot ended up with a picture in it. A playlist that
    /// carries no `tvg-logo`, a guide with no `<icon>`, an address that 404s —
    /// all of them arrive here as the same empty tile, and a column of empty
    /// tiles reads as an app that is broken rather than as artwork nobody
    /// supplied. Until it is answered the tile shows the channel's own
    /// lettering, which is what the logo would have said anyway.
    @State private var hasLogo = false

    private var logoURL: URL? {
        Artwork.channelLogo(channel, width: Int(Metrics.guideLogoSize.width) * 3)
    }

    /// The first letters of the channel's name, minus the noise every line-up
    /// puts in front of it — "UK: BBC One HD" is a B and a B and a C.
    private var initials: String {
        let cleaned = channel.title
            .components(separatedBy: CharacterSet(charactersIn: ":|"))
            .last?
            .trimmingCharacters(in: .whitespaces) ?? channel.title
        let letters = cleaned.filter { $0.isLetter || $0.isNumber }
        return String(letters.prefix(3)).uppercased()
    }

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 8) {
                RemoteImage(url: logoURL, contentMode: .fit, onResolved: { hasLogo = $0 })
                .frame(width: Metrics.guideLogoSize.width, height: Metrics.guideLogoSize.height)
                .background {
                    ZStack {
                        Theme.raised
                        if !hasLogo {
                            Text(initials)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.textDim)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .padding(.horizontal, 2)
                        }
                    }
                }
                .cardChrome(radius: 4)

                VStack(alignment: .leading, spacing: 1) {
                    if let number = channel.ChannelNumber, !number.isEmpty {
                        Text(number)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.textDim)
                    }
                    // Two lines where there is a row tall enough to hold
                    // them. On one, every name on a phone was its first five
                    // letters — "Ameri…", "Rick a…", "Carto…" — in a column
                    // whose whole job is to say which channel this is.
                    Text(channel.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.text)
                        #if os(tvOS)
                        .lineLimit(1)
                        #else
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .multilineTextAlignment(.leading)
                        #endif
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(GuideCellButtonStyle())
        .itemContextMenu(channel)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 0.5) }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 0.5) }
    }
}

// MARK: - Focus

/// A place in the guide the selector can be: a channel in the column down the
/// left, or one programme in one channel's row. Only tvOS ever puts it
/// anywhere — see `TVGuideView.focus`.
private enum GuideFocus: Hashable {
    case channel(String)
    case program(channel: String, index: Int)
}

// MARK: - Programme row

private struct GuideRow: View {
    /// Which channel's row this is. Not drawn — it is what each cell's focus
    /// value is made of, so that the selector landing on a programme says
    /// which channel to send it to. See `TVGuideView.body`.
    let channelId: String
    let programs: [BaseItem]
    let windowStart: Date
    let windowEnd: Date
    let totalWidth: CGFloat
    let rowHeight: CGFloat
    var onPlay: () -> Void
    @FocusState.Binding var focus: GuideFocus?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if programs.isEmpty {
                GuideCell(
                    title: "No programme information",
                    timeLabel: nil,
                    isLive: false,
                    width: totalWidth,
                    height: rowHeight,
                    onPlay: onPlay
                )
                #if os(tvOS)
                .focused($focus, equals: .program(channel: channelId, index: 0))
                #endif
            } else {
                ForEach(Array(programs.enumerated()), id: \.offset) { index, program in
                    let start = max(program.programStart ?? windowStart, windowStart)
                    let end = min(program.programEnd ?? windowEnd, windowEnd)
                    if end > start {
                        let xOffset = CGFloat(start.timeIntervalSince(windowStart) / 60) * Metrics.guideMinuteWidth
                        let width = max(CGFloat(end.timeIntervalSince(start) / 60) * Metrics.guideMinuteWidth, 2)
                        GuideCell(
                            title: program.title,
                            timeLabel: Format.programWindow(start: program.programStart, end: program.programEnd),
                            isLive: program.isAiringNow,
                            width: width,
                            height: rowHeight,
                            onPlay: onPlay
                        )
                        #if os(tvOS)
                        .focused($focus, equals: .program(channel: channelId, index: index))
                        #endif
                        .offset(x: xOffset)
                    }
                }
            }
        }
        .frame(width: totalWidth, height: rowHeight, alignment: .topLeading)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 0.5) }
    }
}

private struct GuideCell: View {
    let title: String
    let timeLabel: String?
    let isLive: Bool
    let width: CGFloat
    let height: CGFloat
    var onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(width < 100 ? 1 : 2)
                if let timeLabel, width > 64 {
                    Text(timeLabel)
                        .font(.caption2)
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(width: width, height: height, alignment: .topLeading)
            .background(isLive ? Theme.accentSoft : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(GuideCellButtonStyle())
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 0.5) }
        #if os(macOS)
        // The whole title and its times on hover, for the cells the window
        // has cut short at either end.
        .help([title, timeLabel].compactMap { $0 }.joined(separator: "\n"))
        #endif
    }
}

// MARK: - Button styles

#if os(tvOS)
/// What a guide cell — a channel or a programme — does when the selector
/// reaches it. `.plain` draws nothing at all on this platform (the recurring
/// trap documented on `RowButtonStyle`), so this is the same ring-and-lift
/// treatment the rest of the app draws for focus, sized for a cell that sits
/// edge to edge with its neighbours rather than floating in open space —
/// the ring goes inside the cell's own border instead of overflowing onto it.
private struct GuideCellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FocusReader { isFocused in
            configuration.label
                .background(isFocused ? Theme.accentSoft : Color.clear)
                .overlay(
                    Rectangle().strokeBorder(isFocused ? Theme.accent : .clear, lineWidth: 3)
                )
                .scaleEffect(isFocused ? 1.02 : 1)
                .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: isFocused ? 10 : 0, y: isFocused ? 6 : 0)
                .zIndex(isFocused ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}
#else
/// What a guide cell does while it is being pressed: the same fill
/// `RowPressStyle` draws elsewhere, without the negative padding that trick
/// uses to bleed a list row's fill past its own text, which here would paint
/// over the neighbouring cell.
private struct GuideCellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Theme.hover.opacity(configuration.isPressed ? 1 : 0))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
#endif

#if os(macOS)
/// One of the two window arrows. Kept small and inline: it shares its row with
/// the loading spinner, and the guide is what the screen is for. See
/// `TVGuideView.controls` for why a Mac is the only platform still drawing
/// these.
private struct GuideNavButton: View {
    let symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 28, height: 28)
                .background(Theme.raised, in: Circle())
                .overlay(Circle().strokeBorder(Theme.border, lineWidth: 0.5))
        }
        .chipButtonStyle()
    }
}
#endif

private struct GuideErrorBanner: View {
    let message: String
    var retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Theme.warn)
            Text("Guide unavailable: \(message)")
                .font(.caption)
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Retry", action: retry)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .chipButtonStyle()
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 6)
    }
}
