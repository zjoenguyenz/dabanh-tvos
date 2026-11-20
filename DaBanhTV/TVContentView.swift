import SwiftUI

/// Đá Banh TV home — designed FOR the television, not ported from
/// the phone. The composition is the TV app's own, built and tuned
/// on the owner's TV since v1.2: a fixed cinematic hero whose
/// content follows the focused card, pill tabs, and horizontal
/// rails you drive with the remote from the sofa — 32pt screen
/// margins (60pt before the 2026-11-19 fit fix, which moved the
/// content to the edges so a 3-board row fits whole), nothing
/// important under 20pt, and a cyan focus ring
/// thick enough to read across the room. Football identity only —
/// the scoreboard's navy palette (one colour family app-wide
/// since 1.4.3 KH-7) and crest-first cards, deliberately unlike
/// the general TV app so the two are never confused.
///
/// v1.3.0 (redesign, 2026-11-14) takes from the iPhone v1.11
/// redesign only its language and data rules, re-expressed at TV
/// scale:
/// - ONE tile per fixture: every source carrying a match collapses
///   into a single card (TVFixtureEntry); the per-source card spray
///   is gone. Playing still uses the store's full source ladder.
/// - A featured rail of big face-off tiles leads the Trực tiếp tab
///   (the TV's expression of the phone's featured rail — twice the
///   phone card's size, inside this screen's hero + rails grammar,
///   not a copy of the phone's swipe cards).
/// - No raw playlist titles: tiles show "Team A vs Team B" or the
///   cleaned title; times are device-local (the old view pinned
///   Asia/Ho_Chi_Minh) and live minutes are true.
/// - The English-commentary block (group "EN · BLV Anh") gets its
///   own first-class section behind its own pill; its 24/7 channels
///   are filtered out of every fixture list and the featured rail.
struct TVContentView: View {
    @EnvironmentObject private var store: PlaylistStore
    /// The Nuvio addon's content (2026-11-19): a store of its
    /// own, read by the EN section and — each for its own
    /// league's slice only — by the folded league tabs (Tây
    /// Ban Nha, Ý, Pháp, Đức; owner, 2026-11-19 12:58 CST).
    /// The PlaylistStore fixture lists never see it, so addon
    /// content cannot leak into them.
    @StateObject private var nuvio = NuvioStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var playRequest: PlayRequest?
    /// The open fixture's link board (1.4.1, spec §2): a fixture
    /// tap opens its board first; a board row tap plays.
    @State private var boardRequest: BoardRequest?
    @State private var heroItem: HeroItem?
    /// Chrome focus ONLY (KH-2, ĐG-1): the tab pills, the header
    /// action buttons and the hero buttons keep their focus
    /// state here — those surfaces are cheap. Every CARD's focus
    /// state moved down into its rail view (TVMatchViews), so a
    /// focus step inside a rail no longer re-runs this body.
    @FocusState private var focusedKey: String?
    /// The diagnostic log screen (KH-1).
    @State private var logOpen = false
    /// All derived fixture data, computed ONCE per data revision
    /// (KH-2): body reads this snapshot and nothing else — the
    /// group + enrich + bucket work happens in rebuildSnapshot()
    /// when the DATA changes, never when focus moves.
    @State private var snap = HomeSnapshot()
    /// The root content width measured at runtime (KH-6): the
    /// 3-across tile width derives from it, never from an
    /// assumed 1920.
    @State private var contentWidth: CGFloat = 0

    /// selectedLeague value meaning "the EN section". The store's
    /// own sentinels are 0 (Hot) and -1 (Trực tiếp); -2 is free and
    /// only this view ever writes or reads it (each app owns its
    /// store instance, so the phone never sees it).
    private static let enTabValue = -2

    private struct PlayRequest: Identifiable {
        let id = UUID()
        let resolution: MatchResolution
    }

    private struct BoardRequest: Identifiable {
        let id = UUID()
        let entry: TVFixtureEntry
        let vnSources: [Channel]
        let enItems: [NuvioItem]
    }

    private enum HeroItem {
        case fixture(TVFixtureEntry)
        case english(Channel)
        case nuvio(NuvioItem)
    }

    // MARK: - Data (fixture lists never contain EN channels)

    private var isENTab: Bool { store.selectedLeague == Self.enTabValue }

    /// The selected tab's channels with the English block removed —
    /// EN channels are 24/7 streams, not fixtures, and must never
    /// pollute a fixture list or the featured rail.
    private var tabChannels: [Channel] {
        let raw: [Channel]
        if store.selectedLeague == PlaylistStore.liveTabValue {
            raw = store.liveChannels
        } else if store.selectedLeague == PlaylistStore.hotTabValue {
            raw = store.hotChannels
        } else {
            raw = store.channels(in: League(rawValue: store.selectedLeague) ?? .england)
        }
        return raw.filter { !TVEnglish.isEnglish($0) }
    }

    /// Attach each fixture's matched live state + competition
    /// identity (spec §1/§3): the store is the only reader of the
    /// state store; entries carry the result to the views.
    /// Builder-only since KH-2 — body never calls this.
    private func enriched(_ list: [TVFixtureEntry]) -> [TVFixtureEntry] {
        list.map { entry in
            var e = entry
            e.state = store.matchState(for: entry.channel)
            e.competition = store.competition(for: entry.channel)
            return e
        }
    }

    private var isCupTab: Bool { store.selectedLeague == LeagueClassifier.cupTabValue }

    // MARK: - Snapshot (KH-2, ĐG-1)

    /// Everything the body renders, precomputed: the tab's
    /// fixtures (grouped + enriched + MU-pinned), the featured
    /// rail, the whole-pool entries, the EN block, the hero
    /// lookup, the pin, and the current tab's Nuvio slices.
    /// Rebuilt by rebuildSnapshot() when — and only when — the
    /// underlying DATA changes (channels, hot channels, live
    /// revision, selected tab, Nuvio content). In 1.4.2 every
    /// one of these was a computed property re-evaluated on
    /// every body pass, and a focus step forced a body pass:
    /// ~21 group/enrich call sites per step, the measured
    /// ~1 s lag. Body now reads stored arrays for everything
    /// the snapshot owns (grouping, enrich, hero lookup — the
    /// expensive derived data is off the focus path entirely).
    /// The one classification body still evaluates live is the
    /// bucket split in scrollBody: effectiveBucket is a
    /// function of the CURRENT time (the −10/+125 min windows
    /// move with the clock, not with the data), so it is
    /// deliberately not snapshotted; its cost is calendar math
    /// plus a cached pair-key dictionary lookup per entry —
    /// not the regroup/re-enrich/re-canonicalise chain that
    /// caused the 1.4.2 lag.
    private struct HomeSnapshot {
        var entries: [TVFixtureEntry] = []
        var featuredEntries: [TVFixtureEntry] = []
        var allEntries: [TVFixtureEntry] = []
        var muPinEntry: TVFixtureEntry? = nil
        var enChannels: [Channel] = []
        var heroLookup: [String: HeroItem] = [:]
        var nuvioCupEvents: [NuvioItem] = []
        var leagueAddonChannels: [NuvioItem] = []
        var leagueLiveEvents: [NuvioItem] = []
        var leagueUpcomingEvents: [NuvioItem] = []
        var hasLeagueAddon = false
    }

    /// Build the snapshot from the stores' current state. The
    /// computations are the SAME ones the old computed
    /// properties ran (same grouping, same enrich, same pin,
    /// same slices — the KH-2 parity rule: the refactor changes
    /// WHEN they run, never WHAT they produce).
    private func rebuildSnapshot() {
        var s = HomeSnapshot()
        // Every fixture in the loaded data (both published
        // lists, EN block excluded, URL-deduped) — the pool the
        // cups tab and the Nuvio attach read from.
        var seen = Set<String>()
        var pool: [Channel] = []
        for ch in store.channels + store.hotChannels where !TVEnglish.isEnglish(ch) {
            if seen.insert(ch.url).inserted { pool.append(ch) }
        }
        s.allEntries = enriched(TVFixtureEntry.group(pool))
        // The tab's fixtures with the owner's Manchester United
        // pin applied (2026-11-19): a live or upcoming MU
        // fixture leads the list — and with it the hero default
        // and its bucket rail — while every other entry keeps
        // the store's order exactly. On the cups tab the list
        // is the positively identified cup fixtures only (spec
        // §4.2 S1; dual presence §4.1 — an additional home,
        // not a move).
        if isCupTab {
            s.entries = s.allEntries.filter { $0.isCupFixture }
        } else {
            s.entries = TVFixtureEntry.pinnedFirst(enriched(TVFixtureEntry.group(tabChannels)))
        }
        // Featured rail: the first fixtures of the Trực tiếp
        // tab only; empty on every other tab.
        if store.selectedLeague == PlaylistStore.liveTabValue {
            s.featuredEntries = Array(s.entries.prefix(10))
        }
        // The MU pin is drawn from the whole pool, not the
        // current tab's list (the pin is an app-level promise;
        // see the pre-resolve hook in body).
        s.muPinEntry = TVFixtureEntry.manchesterUnitedPin(in: s.allEntries)
        // The English block, merged from both published lists
        // and deduplicated by URL.
        var enSeen = Set<String>()
        for ch in store.channels + store.hotChannels where TVEnglish.isEnglish(ch) {
            if enSeen.insert(ch.url).inserted { s.enChannels.append(ch) }
        }
        // Nuvio cup events (spec §4.2 S2): addon event metas
        // whose competition string EXACTLY names a cup.
        s.nuvioCupEvents = (nuvio.liveEvents + nuvio.upcomingEvents).filter {
            DivisionClassifier.competition(forNuvioLeagueLine: $0.league)?.isCup == true
        }
        // The selected fold league's addon slices (empty for
        // Anh / Khác / EN / Trực tiếp / Hot).
        if let league = foldLeague {
            s.leagueAddonChannels = nuvio.leagueChannels[league.rawValue] ?? []
            s.leagueLiveEvents = nuvio.liveEvents.filter {
                LeagueClassifier.leagueRank(of: $0.headline) == league.rawValue
            }
            s.leagueUpcomingEvents = nuvio.upcomingEvents.filter {
                LeagueClassifier.leagueRank(of: $0.headline) == league.rawValue
            }
        }
        s.hasLeagueAddon = !s.leagueAddonChannels.isEmpty
            || !s.leagueLiveEvents.isEmpty || !s.leagueUpcomingEvents.isEmpty
        // Focus key → hero content, for every focusable card.
        var map: [String: HeroItem] = [:]
        for entry in s.featuredEntries { map["feat:" + entry.id] = .fixture(entry) }
        for entry in s.entries { map["rail:" + entry.id] = .fixture(entry) }
        for ch in s.enChannels { map["en:" + ch.url] = .english(ch) }
        for item in nuvio.liveEvents + nuvio.upcomingEvents + nuvio.channels {
            map["nv:" + item.id] = .nuvio(item)
        }
        for items in nuvio.leagueChannels.values {
            for item in items { map["nv:" + item.id] = .nuvio(item) }
        }
        s.heroLookup = map
        snap = s
    }

    /// Every data-input change funnels through here: rebuild
    /// the snapshot, then re-validate the hero against it.
    private func dataChanged() {
        rebuildSnapshot()
        syncHero()
    }

    /// A rail reported a focus change (KH-2): the hero follows
    /// the focused card, exactly as the old root
    /// .onChange(of: focusedKey) did — but the lookup reads the
    /// snapshot, and this body does no derived work for it.
    private func heroFocus(_ key: String) {
        if let item = snap.heroLookup[key] { heroItem = item }
    }

    // Snapshot reads — the ONLY form in which body and its
    // helpers touch fixture data now.
    private var entries: [TVFixtureEntry] { snap.entries }
    private var featuredEntries: [TVFixtureEntry] { snap.featuredEntries }
    private var allEntries: [TVFixtureEntry] { snap.allEntries }
    private var enChannels: [Channel] { snap.enChannels }
    private var nuvioCupEvents: [NuvioItem] { snap.nuvioCupEvents }
    private var leagueAddonChannels: [NuvioItem] { snap.leagueAddonChannels }
    private var leagueLiveEvents: [NuvioItem] { snap.leagueLiveEvents }
    private var leagueUpcomingEvents: [NuvioItem] { snap.leagueUpcomingEvents }
    private var hasLeagueAddon: Bool { snap.hasLeagueAddon }

    // MARK: - Nuvio attach (spec §2.5 + owner refinement 13:53 CST)

    /// The Nuvio English events that belong to THIS fixture —
    /// per-match merge only, fail closed. Belonging is the same
    /// matching as the livescore layer (Addendum 2 matcher):
    /// canonical pair-key equal AND the meta's kickoff naming the
    /// same ICT calendar date as the fixture's stamp AND the
    /// instants within 3 h AND the event matching no OTHER
    /// fixture under the same rule (an ambiguous event folds
    /// nowhere). Channels (24/7) are never events and never
    /// attach. An event that attaches nowhere stays in the BLV
    /// Anh tab exactly as today — the tab is never emptied.
    private func attachedNuvioEvents(for entry: TVFixtureEntry) -> [NuvioItem] {
        guard let teams = entry.teams, let kickoff = entry.channel.kickoff,
              let pair = MatchPairKey.key(home: teams.0, away: teams.1) else { return [] }
        let dateKey = FixtureGrouping.stampDateKey(of: kickoff)
        // Candidate fixture cards for this pair + ICT date,
        // including the tapped entry itself (its tab's grouping
        // can split clusters differently from the pool's).
        var byID: [String: TVFixtureEntry] = [:]
        for e in allEntries + [entry] { byID[e.id] = e }
        let candidates = byID.values.filter { e in
            guard let t = e.teams, let k = e.channel.kickoff,
                  MatchPairKey.key(home: t.0, away: t.1) == pair else { return false }
            return FixtureGrouping.stampDateKey(of: k) == dateKey
        }
        // Clusters: candidates whose kickoffs chain within
        // 45 min are ONE match whose listings were spelling-split
        // (A2.1) — an event attaches to every card of its cluster.
        let sorted = candidates.sorted {
            ($0.channel.kickoff ?? .distantPast) < ($1.channel.kickoff ?? .distantPast)
        }
        var clusters: [[TVFixtureEntry]] = []
        for e in sorted {
            let k = e.channel.kickoff ?? .distantPast
            if let last = clusters.last,
               let latest = last.map({ $0.channel.kickoff ?? .distantPast }).max(),
               k.timeIntervalSince(latest) <= 45 * 60 {
                clusters[clusters.count - 1].append(e)
            } else {
                clusters.append([e])
            }
        }
        guard let entryCluster = clusters.first(where: { c in c.contains { $0.id == entry.id } }),
              let clusterKickoff = entryCluster.map({ $0.channel.kickoff ?? .distantFuture }).min()
        else { return [] }
        let fixtureMarked = isWomenMarked(teams.0) || isWomenMarked(teams.1)
        return (nuvio.liveEvents + nuvio.upcomingEvents).filter { item in
            guard let t = item.teams, let ek = item.kickoff,
                  MatchPairKey.key(home: t.0, away: t.1) == pair,
                  FixtureGrouping.stampDateKey(of: ek) == dateKey,
                  abs(ek.timeIntervalSince(clusterKickoff)) <= 3 * 3600 else { return false }
            // Clusters > 45 min apart are two real matches: the
            // event folds only if exactly one cluster is inside
            // the 3 h instant guard — and it must be this one.
            let inGuard = clusters.filter { c in
                guard let ck = c.map({ $0.channel.kickoff ?? .distantFuture }).min()
                else { return false }
                return abs(ek.timeIntervalSince(ck)) <= 3 * 3600
            }
            guard inGuard.count == 1,
                  inGuard.first?.contains(where: { $0.id == entry.id }) == true
            else { return false }
            // Marker asymmetry (A2.1): an unmarked event folds
            // into a women-marked fixture (or the reverse) only
            // when it is the UNIQUE candidate for pair + date.
            let eventMarked = isWomenMarked(t.0) || isWomenMarked(t.1)
            if eventMarked != fixtureMarked && clusters.count != 1 { return false }
            return true
        }
    }

    /// A team name carries the women's marker when a marker token
    /// (Addendum 2's set) appears in its normalised form. Used
    /// ONLY for the belonging asymmetry guard — classification
    /// sees markers through its own rule (spec §3.2 S3).
    private func isWomenMarked(_ name: String) -> Bool {
        let markers: Set<String> = ["women", "w", "nu", "feminin", "femmes", "femenino", "femenina"]
        return Crests.norm(name).split(separator: " ").contains { markers.contains(String($0)) }
    }

    // MARK: - League tab addon content (owner, 2026-11-19 12:58 CST)

    /// The league whose tab is selected AND which carries an
    /// addon fold: Tây Ban Nha, Ý, Pháp and Đức — the four
    /// leagues with entries in NuvioClient.leagueSearches.
    /// Anh and Khác have no fold: for them foldLeague is nil,
    /// every accessor below is empty, and their tabs render
    /// exactly as they did before the folds existed.
    private var foldLeague: League? {
        guard let league = League(rawValue: store.selectedLeague) else { return nil }
        switch league {
        case .spain, .italy, .france, .germany: return league
        case .england, .other, .cups: return nil
        }
    }

    /// (The fold league's addon slices — its channels, its live
    /// and upcoming events by the shared classifier's filing,
    /// and the has-content flag — are snapshot fields since
    /// KH-2; see rebuildSnapshot. The filing rule is unchanged:
    /// the classifier files the addon's events under a league
    /// exactly as it files the mirror fixtures, and cross-border
    /// cup fixtures keep the first-checked-league convention.)

    /// The channel copy for a folded league, in the Đức
    /// round's wording pattern: the channel rail's title and
    /// subtitle, the card's play-line prefix and the hero's
    /// channel line. Only ever called with a fold league; the
    /// Anh / Khác arm exists so the switch is exhaustive, and
    /// its text is never rendered.
    private func leagueChannelCopy(_ league: League)
        -> (railTitle: String, railSubtitle: String, cardPrefix: String, heroLine: String) {
        switch league {
        case .spain:
            return ("📺  NUVIO · KÊNH GIẢI TÂY BAN NHA",
                    "Kênh La Liga từ addon Nuvio — phát liên tục.",
                    "Kênh giải Tây Ban Nha",
                    "Kênh giải Tây Ban Nha · phát liên tục")
        case .italy:
            return ("📺  NUVIO · KÊNH GIẢI Ý",
                    "Kênh Serie A từ addon Nuvio — phát liên tục.",
                    "Kênh giải Ý",
                    "Kênh giải Ý · phát liên tục")
        case .france:
            return ("📺  NUVIO · KÊNH GIẢI PHÁP",
                    "Kênh Ligue 1 từ addon Nuvio — phát liên tục.",
                    "Kênh giải Pháp",
                    "Kênh giải Pháp · phát liên tục")
        case .germany:
            return ("📺  NUVIO · KÊNH GIẢI ĐỨC",
                    "Kênh Bundesliga từ addon Nuvio — phát liên tục.",
                    "Kênh giải Đức",
                    "Kênh giải Đức · phát liên tục")
        case .england, .other, .cups:
            return ("📺  NUVIO · KÊNH 24/7",
                    "Kênh từ addon Nuvio — phát liên tục.",
                    "Kênh Nuvio",
                    "Kênh Nuvio · phát liên tục")
        }
    }

    /// The 3-across tile width from the measured content width
    /// (KH-6): min(592, (W − 2×8 rail insets − 2×28 spacing)/3).
    /// Before the first measurement lands, the approved 592.
    private var tileWidth: CGFloat {
        guard contentWidth > 0 else { return 592 }
        return min(592, max(300, (contentWidth - 72) / 3))
    }

    var body: some View {
        ZStack {
            background
            // KH-6: measure the REAL content width (the padded
            // region the rails live in) — the tile width derives
            // from this, never from an assumed screen size.
            GeometryReader { geo in
                Color.clear
                    .onAppear { contentWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in contentWidth = w }
            }
            .padding(.horizontal, 32)
            VStack(spacing: 20) {
                header
                tabBar
                if let message = store.statusMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                scrollBody
            }
            // Fit fix (2026-11-19, with Sony 2.20): side padding
            // 60 -> 32pt so a rail row of three live boards fits
            // entirely on the 1920pt screen — see TVLiveBoardView's
            // width note in TVMatchViews.swift.
            .padding(.horizontal, 32)
            .padding(.top, 40)
            .padding(.bottom, 28)
        }
        .environment(\.tvTileWidth, tileWidth)
        .task {
            DiagLog.logSessionStart()
            await store.start()
            dataChanged()
        }
        .task { await nuvio.load() }
        .task(id: snap.muPinEntry?.id) {
            // Pre-resolve the pinned Manchester United fixture
            // (2026-11-19): when a pin exists, its sources are
            // verified into the store's resolve cache at open, so
            // tapping the priority match starts from a verified
            // ladder with no resolve wait. The hook is keyed on
            // the pin's identity — a new pin supersedes the old
            // pre-resolve inside the store, and the pin vanishing
            // cancels it; nothing is pre-resolved when no MU
            // fixture is pinned. KH-2: the pin is read from the
            // snapshot — this hook no longer forces an
            // allEntries computation on every body pass.
            if let pin = snap.muPinEntry {
                store.preResolve(pin.channel)
            } else {
                store.cancelPreResolve()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await store.refreshIfStale() }
                Task { await nuvio.refreshIfStale() }
            }
        }
        .fullScreenCover(item: $playRequest) { request in
            TVPlayerView(resolution: request.resolution)
        }
        .fullScreenCover(item: $boardRequest) { request in
            TVMatchBoardView(entry: request.entry,
                             vnSources: request.vnSources,
                             enItems: request.enItems,
                             nuvio: nuvio)
        }
        .fullScreenCover(isPresented: $logOpen) {
            TVLogView()
        }
        // KH-2: every DATA input rebuilds the snapshot (and
        // re-validates the hero); focus changes never reach
        // this body as work — the rails own their focus state
        // and report hero keys through heroFocus(_:).
        .onChange(of: store.selectedLeague) { _, _ in dataChanged() }
        .onChange(of: store.channels) { _, _ in dataChanged() }
        .onChange(of: store.hotChannels) { _, _ in dataChanged() }
        .onChange(of: store.liveRevision) { _, _ in dataChanged() }
        .onChange(of: nuvio.liveEvents) { _, _ in dataChanged() }
        .onChange(of: nuvio.upcomingEvents) { _, _ in dataChanged() }
        .onChange(of: nuvio.channels) { _, _ in dataChanged() }
        .onChange(of: nuvio.leagueChannels) { _, _ in dataChanged() }
    }

    private func syncHero() {
        if isENTab {
            // The addon leads the tab, so the hero defaults to
            // its first item; the old EN block is the fallback
            // hero when the addon has nothing.
            if case .nuvio(let item) = heroItem,
               (nuvio.liveEvents + nuvio.upcomingEvents + nuvio.channels).contains(item) { return }
            if case .english(let ch) = heroItem, enChannels.contains(ch),
               !nuvio.hasContent { return }
            if let first = nuvio.liveEvents.first ?? nuvio.upcomingEvents.first ?? nuvio.channels.first {
                heroItem = .nuvio(first)
            } else {
                heroItem = enChannels.first.map { .english($0) }
            }
            return
        }
        if foldLeague != nil {
            // A folded league tab's hero follows its addon
            // content too: a focused addon item keeps its
            // hero, and the default is fixtures first, then
            // the addon's live / upcoming fixtures of the
            // league, then its channels — the tab's own rail
            // order.
            if case .nuvio(let item) = heroItem,
               (leagueLiveEvents + leagueUpcomingEvents + leagueAddonChannels).contains(item) { return }
            if case .fixture(let current) = heroItem,
               entries.contains(where: { $0.id == current.id }) { return }
            if let first = featuredEntries.first ?? entries.first {
                heroItem = .fixture(first)
            } else if let first = leagueLiveEvents.first ?? leagueUpcomingEvents.first ?? leagueAddonChannels.first {
                heroItem = .nuvio(first)
            } else {
                heroItem = nil
            }
            return
        }
        if case .fixture(let current) = heroItem,
           entries.contains(where: { $0.id == current.id }) { return }
        let first = featuredEntries.first ?? entries.first
        heroItem = first.map { .fixture($0) }
    }

    // MARK: - Chrome

    private var background: some View {
        // KH-7 (ĐG-4): navy, derived from the scoreboard's
        // boardBG — the screen background and the tiles are one
        // colour family now (was a teal-green gradient from the
        // app's first design, which read as a second, different
        // blue next to the navy boards in the owner's photos).
        LinearGradient(
            colors: [Color(red: 0.055, green: 0.09, blue: 0.17),
                     TVPalette.boardBG,
                     Color(red: 0.02, green: 0.035, blue: 0.07)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }

    /// Compact header (1.4.1, spec §0/§5.2-6): ONE row — small
    /// logo left; clock + dabanh.tv right, at the prototype's
    /// mini sizes. The Làm mới / Kiểm tra link mini-buttons keep
    /// their pill-row place directly beneath (their focus-travel
    /// position is load-bearing since v1.2.7 — see tabBar); the
    /// old 56-pt two-line brand block is gone.
    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            Text("⚽")
                .font(.system(size: 30))
            HStack(spacing: 8) {
                Text("ĐÁ BANH")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                Text("TV")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(TVPalette.boardSky)
            }
            Spacer()
            Text(TVKickoffFormat.time.string(from: Date()))
                .font(.system(size: 20))
                .foregroundStyle(Color(red: 0.388, green: 0.463, blue: 0.604))
            Text("dabanh.tv")
                .font(.system(size: 20))
                .foregroundStyle(TVPalette.leagueTx)
        }
        .padding(.bottom, 4)
    }

    private var countText: String {
        if isENTab {
            return "\(nuvio.totalCount + enChannels.count) kênh tiếng Anh"
        }
        if store.selectedLeague == PlaylistStore.liveTabValue {
            return "\(entries.count) trận đang đá"
        }
        if store.selectedLeague == PlaylistStore.hotTabValue {
            return "\(entries.count) trận hot"
        }
        if isCupTab {
            return "\(entries.count) trận cúp châu Âu"
        }
        if foldLeague != nil && hasLeagueAddon {
            let matches = entries.count + leagueLiveEvents.count + leagueUpcomingEvents.count
            return leagueAddonChannels.isEmpty
                ? "\(matches) trận"
                : "\(matches) trận · \(leagueAddonChannels.count) kênh"
        }
        return "\(entries.count) trận"
    }

    private var tabBar: some View {
        // Two rows since v1.2.7: the pills + count fill row one, and
        // the action buttons get a row of their own — cramming both
        // into one HStack (~2,290pt) exceeded the 1,800pt available
        // and crushed the buttons until focus could not land on them.
        // That two-row structure is load-bearing for focus travel
        // and is KEPT. Owner final form (2026-11-19 14:38 CST):
        // the ENG pill LEADS the bar — it is the first pill of
        // row one, ahead of Trực tiếp / Hot and the league pills
        // in League.tabOrder (NHA · TBN · Ý · Đức · Pháp ·
        // Khác · Cúp EU, cups last) — so the ENG + league
        // sequence renders ENG first and Cúp EU last. ENG fits
        // row one because every pill in the bar now shares the
        // same SMALL uniform metrics (see tabPill): the bar is
        // compact and does not grow — it shrinks.
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if !enChannels.isEmpty || nuvio.hasContent {
                    tabPill(title: "ENG", value: Self.enTabValue)
                }
                tabPill(title: "🔴 Trực tiếp", value: PlaylistStore.liveTabValue)
                tabPill(title: "🔥 Hot", value: PlaylistStore.hotTabValue)
                ForEach(League.tabOrder) { league in
                    tabPill(title: league.tabTitle, value: league.rawValue)
                }
                Spacer()
                Text(countText)
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            HStack(spacing: 12) {
                // The action buttons stay near the pills on purpose: as
                // a lone button in the header row above, tvOS spatial
                // focus could not reach it from the pills (owner, v1.1).
                Button {
                    Task {
                        await store.refresh()
                        await nuvio.refresh()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.clockwise")
                        Text("Làm mới")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.system(size: 20, weight: .medium))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(TVPillFace(focused: focusedKey == "hdr:refresh",
                                           selected: false))
                }
                .tvCardButton()
                .focused($focusedKey, equals: "hdr:refresh")
                .disabled(store.isLoading)
                // Manual link check (owner's request, 2026-11-13): fetch
                // the newest list, re-probe every link from this TV, and
                // republish the match rails without the dead ones.
                Button {
                    Task { await store.refreshAndValidate() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.shield")
                        Text(store.isValidating ? "Đang kiểm tra…" : "Kiểm tra link")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.system(size: 20, weight: .medium))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(TVPillFace(focused: focusedKey == "hdr:check",
                                           selected: false))
                }
                .tvCardButton()
                .focused($focusedKey, equals: "hdr:check")
                .disabled(store.isLoading || store.isValidating)
                // KH-1: the diagnostic log's door — the app had
                // NO way to get its log out before 1.4.3 (ĐG-3);
                // the log screen shows the big LAN URL + QR.
                Button {
                    logOpen = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text.magnifyingglass")
                        Text("Log")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.system(size: 20, weight: .medium))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(TVPillFace(focused: focusedKey == "hdr:log",
                                           selected: false))
                }
                .tvCardButton()
                .focused($focusedKey, equals: "hdr:log")
            }
        }
    }

    /// ONE pill construction for every tab in the bar (owner
    /// final form, 2026-11-19 14:38 CST): SMALL and UNIFORM —
    /// every tab pill, ENG included, is built here with the
    /// identical metrics: font size 20, weight .medium (the
    /// selected state no longer switches to .bold, which made
    /// the selected pill wider than its neighbours; selection
    /// is shown by the TVPillFace fill alone), horizontal
    /// padding 20, vertical padding 10. Width still follows
    /// each label's text (a fixed width would clip "Trực
    /// tiếp" or strand "Ý"); height, padding and text size —
    /// the pill metrics — are identical for every tab, and no
    /// focus geometry is hand-drawn here: the focus treatment
    /// stays the app's existing TVPillFace / OS path, shared
    /// by all pills alike. The two action buttons in the bar
    /// use these same font/padding metrics.
    private func tabPill(title: String, value: Int) -> some View {
        let selected = store.selectedLeague == value
        return Button {
            store.selectedLeague = value
        } label: {
            Text(title)
                .font(.system(size: 20, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(TVPillFace(focused: focusedKey == "pill:\(value)",
                                       selected: selected))
                .foregroundStyle(.white)
        }
        .tvCardButton()
        .focused($focusedKey, equals: "pill:\(value)")
    }

    private var emptyText: String {
        if store.selectedLeague == PlaylistStore.liveTabValue {
            return "Hiện không có trận nào đang đá. Các trận sắp đá nằm ở tab 🔥 Hot và các tab giải."
        }
        if store.selectedLeague == PlaylistStore.hotTabValue {
            return "Chưa có trận hot nào. Trang nguồn gắn cờ hot cho trận nào thì trận đó hiện ở đây."
        }
        if isCupTab {
            return "Chưa có trận cúp châu Âu nào được xác định. Các trận cúp hiện ở đây khi nguồn trực tiếp (ESPN/FotMob) xác nhận đúng giải — không đoán từ tên câu lạc bộ."
        }
        return "Chưa có trận nào trong mục này."
    }

    // MARK: - Content

    @ViewBuilder
    private var scrollBody: some View {
        if isENTab {
            enBody
        } else if entries.isEmpty && featuredEntries.isEmpty
                    && !hasLeagueAddon
                    && !(isCupTab && !nuvioCupEvents.isEmpty) {
            Spacer()
            if store.isLoading || (foldLeague != nil && nuvio.isLoading) {
                ProgressView("Đang tải danh sách…")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .tint(.white)
            } else {
                Text(emptyText)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
        } else if isCupTab {
            cupBody
        } else {
            let now = Date()
            let featuredIDs = Set(featuredEntries.map(\.id))
            // Division partition (spec §3.1): inside a country
            // tab the top block leads with the existing rail
            // order; positively-identified division-2 fixtures
            // form their own block below with a smaller header.
            // Unknown fixtures stay in the top block — the split
            // never removes a fixture from any global list.
            let isCountryTab = League(rawValue: store.selectedLeague).map {
                $0 != .other && $0 != .cups
            } ?? false
            let topEntries = isCountryTab ? entries.filter { !$0.isLowerDivision } : entries
            let lowerEntries = isCountryTab ? entries.filter { $0.isLowerDivision } : []
            let onLiveTab = store.selectedLeague == PlaylistStore.liveTabValue
            let live = topEntries.filter {
                store.effectiveBucket(of: $0.channel, now: now) == 0 && !featuredIDs.contains($0.id)
                    && !(onLiveTab && $0.isCupFixture)
            }
            let cupLive = onLiveTab ? topEntries.filter {
                store.effectiveBucket(of: $0.channel, now: now) == 0 && $0.isCupFixture
                    && !featuredIDs.contains($0.id)
            } : []
            let upcoming = topEntries.filter {
                let b = store.effectiveBucket(of: $0.channel, now: now)
                return b == 1 || b == 2
            }
            let rest = topEntries.filter { store.effectiveBucket(of: $0.channel, now: now) == 3 }
            let lowerLive = lowerEntries.filter {
                store.effectiveBucket(of: $0.channel, now: now) == 0
            }
            let lowerUpcoming = lowerEntries.filter {
                let b = store.effectiveBucket(of: $0.channel, now: now)
                return b == 1 || b == 2
            }
            let lowerRest = lowerEntries.filter {
                store.effectiveBucket(of: $0.channel, now: now) == 3
            }
            // Hero stays FIXED above the rails (owner ruling 2026-11-13):
            // inside the ScrollView it got half-clipped whenever focus
            // dived down into the rails.
            VStack(alignment: .leading, spacing: 22) {
                heroPanel
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 30) {
                        if !featuredEntries.isEmpty {
                            featuredRail(featuredEntries)
                        }
                        if !live.isEmpty {
                            railSection("🔴  ĐANG ĐÁ", live)
                        }
                        if !cupLive.isEmpty {
                            railSection("🏆  CÚP CHÂU ÂU · ĐANG ĐÁ", cupLive)
                        }
                        if !leagueLiveEvents.isEmpty {
                            nuvioEventRail("🔴  NUVIO · ĐANG ĐÁ", leagueLiveEvents)
                        }
                        if !upcoming.isEmpty {
                            railSection("⏰  SẮP ĐÁ", upcoming)
                        }
                        if !leagueUpcomingEvents.isEmpty {
                            nuvioEventRail("⏰  NUVIO · SẮP ĐÁ", leagueUpcomingEvents)
                        }
                        if !rest.isEmpty {
                            railSection("📺  KHÁC", rest)
                        }
                        if !lowerEntries.isEmpty, let league = League(rawValue: store.selectedLeague),
                           let lower = CompetitionID.lower(forCountryRank: league.rawValue) {
                            lowerDivisionSection(lower, live: lowerLive,
                                                 upcoming: lowerUpcoming, rest: lowerRest)
                        }
                        if let league = foldLeague, !leagueAddonChannels.isEmpty {
                            leagueChannelRail(leagueAddonChannels, league: league)
                        }
                        footerRow
                    }
                    .padding(.top, 2)
                    .padding(.bottom, 10)
                }
            }
        }
    }

    /// The division-2 block of a country tab (spec §3.1): a
    /// SMALLER sub-header (rail title −4 pt) and its own
    /// live → upcoming → rest order, tiles at the standard size.
    /// Rendered only when the block holds at least one fixture —
    /// an empty division shows no header at all.
    private func lowerDivisionSection(_ competition: CompetitionID,
                                      live: [TVFixtureEntry],
                                      upcoming: [TVFixtureEntry],
                                      rest: [TVFixtureEntry]) -> some View {
        VStack(alignment: .leading, spacing: 30) {
            Text(competition.label)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Color(red: 0.812, green: 0.878, blue: 0.961))
            if !live.isEmpty {
                railSection("🔴  ĐANG ĐÁ", live)
            }
            if !upcoming.isEmpty {
                railSection("⏰  SẮP ĐÁ", upcoming)
            }
            if !rest.isEmpty {
                railSection("📺  KHÁC", rest)
            }
        }
    }

    /// The cups tab (spec §4.1): three labelled sections — CÚP C1
    /// (gold), CÚP C2, CÚP C3 — each live → upcoming → rest, plus
    /// the addon's own cup events (S2) in their sections. A
    /// section with no fixtures is omitted entirely.
    @ViewBuilder
    private var cupBody: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: 22) {
            heroPanel
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 30) {
                    cupSection(.championsLeague,
                               fixtures: entries.filter {
                                   $0.competition == .championsLeague
                                       || $0.competition == .womensChampionsLeague
                               },
                               addon: nuvioCupEvents.filter {
                                   DivisionClassifier.competition(forNuvioLeagueLine: $0.league) == .championsLeague
                                       || DivisionClassifier.competition(forNuvioLeagueLine: $0.league) == .womensChampionsLeague
                               }, now: now)
                    cupSection(.europaLeague,
                               fixtures: entries.filter { $0.competition == .europaLeague },
                               addon: nuvioCupEvents.filter {
                                   DivisionClassifier.competition(forNuvioLeagueLine: $0.league) == .europaLeague
                               }, now: now)
                    cupSection(.conferenceLeague,
                               fixtures: entries.filter { $0.competition == .conferenceLeague },
                               addon: nuvioCupEvents.filter {
                                   DivisionClassifier.competition(forNuvioLeagueLine: $0.league) == .conferenceLeague
                               }, now: now)
                    footerRow
                }
                .padding(.top, 2)
                .padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder
    private func cupSection(_ competition: CompetitionID, fixtures: [TVFixtureEntry],
                            addon: [NuvioItem], now: Date) -> some View {
        if !fixtures.isEmpty || !addon.isEmpty {
            let live = fixtures.filter { store.effectiveBucket(of: $0.channel, now: now) == 0 }
            let upcoming = fixtures.filter {
                let b = store.effectiveBucket(of: $0.channel, now: now)
                return b == 1 || b == 2
            }
            let rest = fixtures.filter { store.effectiveBucket(of: $0.channel, now: now) == 3 }
            VStack(alignment: .leading, spacing: 30) {
                Text(competition.label)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(competition == .championsLeague
                        ? TVPalette.c1Head : .white)
                if !live.isEmpty {
                    railSection("🔴  ĐANG ĐÁ", live)
                }
                if !upcoming.isEmpty {
                    railSection("⏰  SẮP ĐÁ", upcoming)
                }
                if !rest.isEmpty {
                    railSection("📺  KHÁC", rest)
                }
                if !addon.isEmpty {
                    nuvioEventRail("📺  NUVIO · " + competition.label, addon)
                }
            }
        }
    }

    private var footerRow: some View {
        HStack {
            Spacer()
            Text("Đá Banh TV v1.4.3")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: - EN section

    /// The English-commentary section (owner, clarified
    /// 2026-11-19): the Nuvio addon's content LEADS — its live
    /// events, upcoming events and 24/7 channels in that order —
    /// and the old mirror EN block renders BELOW as its own
    /// section, the fallback that keeps the tab alive when the
    /// addon is down. The hero follows focus across every rail
    /// exactly like it does across the match rails; old-block
    /// channels are plain playable cards (no fixture grouping,
    /// no ladder), addon items resolve through the addon store.
    @ViewBuilder
    private var enBody: some View {
        if enChannels.isEmpty && !nuvio.hasContent {
            Spacer()
            if nuvio.isLoading || store.isLoading {
                ProgressView("Đang tải danh sách…")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .tint(.white)
            } else {
                Text("Chưa có kênh tiếng Anh nào trong danh sách hiện tại.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
        } else {
            VStack(alignment: .leading, spacing: 22) {
                heroPanel
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 30) {
                        if !nuvio.liveEvents.isEmpty {
                            nuvioEventRail("🔴  NUVIO · ĐANG ĐÁ", nuvio.liveEvents)
                        }
                        if !nuvio.upcomingEvents.isEmpty {
                            nuvioEventRail("⏰  NUVIO · SẮP ĐÁ", nuvio.upcomingEvents)
                        }
                        if !nuvio.channels.isEmpty {
                            nuvioChannelRail(nuvio.channels)
                        }
                        if !enChannels.isEmpty {
                            oldENBlock
                        }
                        footerRow
                    }
                    .padding(.top, 2)
                    .padding(.bottom, 10)
                }
            }
        }
    }

    // KH-2: the rails below are thin call sites over the leaf
    // rail structs in TVMatchViews.swift, which own their own
    // focus state. The play actions and the copy are unchanged;
    // hero following goes through heroFocus(_:).

    private func nuvioEventRail(_ title: String, _ items: [NuvioItem]) -> some View {
        TVNuvioEventRail(title: title, items: items,
                         onSelect: { item in
                             playRequest = PlayRequest(resolution: nuvio.resolution(for: item))
                         },
                         onFocusKey: heroFocus)
    }

    private func nuvioChannelRail(_ items: [NuvioItem]) -> some View {
        TVNuvioChannelRail(title: "📺  NUVIO · KÊNH 24/7",
                           subtitle: "Kênh tiếng Anh từ addon Nuvio — phát liên tục.",
                           items: items,
                           onSelect: { item in
                               playRequest = PlayRequest(resolution: nuvio.resolution(for: item))
                           },
                           onFocusKey: heroFocus)
    }

    /// A folded league tab's addon channel rail (owner,
    /// 2026-11-19 12:58 CST): the league fold's 24/7 channels
    /// below the tab's fixtures — the nuvioChannelRail shape,
    /// with the league's own copy and the card's own play line.
    private func leagueChannelRail(_ items: [NuvioItem], league: League) -> some View {
        let copy = leagueChannelCopy(league)
        return TVNuvioChannelRail(title: copy.railTitle,
                                  subtitle: copy.railSubtitle,
                                  items: items,
                                  detailPrefix: copy.cardPrefix,
                                  onSelect: { item in
                                      playRequest = PlayRequest(resolution: nuvio.resolution(for: item))
                                  },
                                  onFocusKey: heroFocus)
    }

    /// The old mirror EN block, unchanged but for its place:
    /// below the addon sections, as the fallback pool.
    private var oldENBlock: some View {
        TVENChannelRail(channels: enChannels,
                        onSelect: { ch in
                            playRequest = PlayRequest(resolution: store.resolution(for: ch))
                        },
                        onFocusKey: heroFocus)
    }

    // MARK: - Hero

    @ViewBuilder
    private var heroPanel: some View {
        switch heroItem {
        case .fixture(let entry):
            fixtureHero(entry)
        case .english(let ch):
            englishHero(ch)
        case .nuvio(let item):
            nuvioHero(item)
        case nil:
            EmptyView()
        }
    }

    /// The hero for an addon item, in the englishHero layout:
    /// a kind badge, the headline, the league/source meta,
    /// crest-vs-crest art for events with teams (the addon's
    /// own badges) or the channel art for 24/7 channels.
    private func nuvioHero(_ item: NuvioItem) -> some View {
        let heroFocused = focusedKey == "heroNV:" + item.id
        return Button {
            playRequest = PlayRequest(resolution: nuvio.resolution(for: item))
        } label: {
            HStack(alignment: .center, spacing: 36) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(nuvioHeroBadge(item))
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(nuvioHeroBadgeColor(item)))
                    Text(item.headline)
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(nuvioHeroMeta(item))
                        .font(.system(size: 24))
                        .foregroundStyle(TVPalette.heroMeta)
                        .lineLimit(1)
                    HStack(spacing: 10) {
                        Text("Xem ngay")
                            .font(.system(size: 24, weight: .semibold))
                        Image(systemName: "play.fill")
                            .font(.system(size: 19))
                    }
                    .foregroundStyle(TVPalette.cyan)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 10)
                    .overlay(Capsule().strokeBorder(TVPalette.cyan, lineWidth: 2.5))
                    .padding(.top, 4)
                }
                .frame(width: 1020, alignment: .leading)
                nuvioHeroArt(item)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
            .background(tvHeroBackground(focused: heroFocused))
        }
        .tvCardButton()
        .focused($focusedKey, equals: "heroNV:" + item.id)
    }

    private func nuvioHeroBadge(_ item: NuvioItem) -> String {
        switch item.kind {
        case .liveEvent: return "🔴 ĐANG ĐÁ · NUVIO"
        case .upcomingEvent:
            if let kickoff = item.kickoff {
                return "⏰ " + TVKickoffFormat.timeDay.string(from: kickoff)
            }
            return "⏰ SẮP ĐÁ · NUVIO"
        case .channel: return "📺 NUVIO · KÊNH 24/7"
        }
    }

    private func nuvioHeroBadgeColor(_ item: NuvioItem) -> Color {
        item.kind == .liveEvent ? TVPalette.liveRed : TVPalette.tealFill
    }

    private func nuvioHeroMeta(_ item: NuvioItem) -> String {
        var parts: [String] = []
        if let league = item.league { parts.append(league) }
        if item.kind == .channel {
            // A league-fold channel focused in its own league
            // tab is that league's channel, not an English one.
            if let league = foldLeague, leagueAddonChannels.contains(item) {
                parts.append(leagueChannelCopy(league).heroLine)
            } else {
                parts.append("Kênh tiếng Anh · phát liên tục")
            }
        } else {
            parts.append("Trận đấu qua addon Nuvio")
        }
        return parts.joined(separator: "  ·  ")
    }

    @ViewBuilder
    private func nuvioHeroArt(_ item: NuvioItem) -> some View {
        if item.teams != nil {
            HStack(spacing: 22) {
                TVCrestImage(url: item.team1Logo.flatMap(URL.init(string:)), size: 160)
                Text("VS")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.85))
                TVCrestImage(url: item.team2Logo.flatMap(URL.init(string:)), size: 160)
            }
            .frame(width: 440, alignment: .center)
        } else if !item.poster.isEmpty {
            TVChannelLogo(channel: item.displayChannel, height: 168)
                .frame(width: 440, height: 168)
        } else {
            TVSoccerPlaceholder(size: 110)
                .frame(width: 440, height: 168)
        }
    }

    private func fixtureHero(_ entry: TVFixtureEntry) -> some View {
        let heroFocused = focusedKey == "hero:" + entry.id
        return Button {
            play(entry)
        } label: {
            HStack(alignment: .center, spacing: 36) {
                VStack(alignment: .leading, spacing: 14) {
                    heroBadge(for: entry)
                    Text(entry.headline)
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(heroMeta(entry))
                        .font(.system(size: 24))
                        .foregroundStyle(TVPalette.heroMeta)
                        .lineLimit(1)
                    HStack(spacing: 10) {
                        Text("Xem ngay")
                            .font(.system(size: 24, weight: .semibold))
                        Image(systemName: "play.fill")
                            .font(.system(size: 19))
                    }
                    .foregroundStyle(TVPalette.cyan)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 10)
                    .overlay(Capsule().strokeBorder(TVPalette.cyan, lineWidth: 2.5))
                    .padding(.top, 4)
                }
                // Fixed widths on purpose: with a maxWidth-.infinity
                // text column the crest pair was pushed past the
                // panel's trailing edge and the second crest was cut
                // off on the owner's TV (v1.2.3 live test).
                .frame(width: 1020, alignment: .leading)
                fixtureHeroArt(entry.channel)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
            .background(tvHeroBackground(focused: heroFocused))
        }
        .tvCardButton()
        .focused($focusedKey, equals: "hero:" + entry.id)
    }

    private func englishHero(_ ch: Channel) -> some View {
        let heroFocused = focusedKey == "heroEN:" + ch.url
        return Button {
            playRequest = PlayRequest(resolution: store.resolution(for: ch))
        } label: {
            HStack(alignment: .center, spacing: 36) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("🌍 BLV TIẾNG ANH · KÊNH 24/7")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(TVPalette.tealFill))
                    Text(TVEnglish.displayName(ch))
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("Kênh tiếng Anh · phát liên tục · nguồn dự phòng khi nguồn Việt chậm hoặc chết")
                        .font(.system(size: 24))
                        .foregroundStyle(TVPalette.heroMeta)
                        .lineLimit(1)
                    HStack(spacing: 10) {
                        Text("Xem ngay")
                            .font(.system(size: 24, weight: .semibold))
                        Image(systemName: "play.fill")
                            .font(.system(size: 19))
                    }
                    .foregroundStyle(TVPalette.cyan)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 10)
                    .overlay(Capsule().strokeBorder(TVPalette.cyan, lineWidth: 2.5))
                    .padding(.top, 4)
                }
                .frame(width: 1020, alignment: .leading)
                Group {
                    if ch.logoURL != nil {
                        TVChannelLogo(channel: ch, height: 168)
                    } else {
                        Image(systemName: "tv")
                            .font(.system(size: 110))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                .frame(width: 440, height: 168)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
            .background(tvHeroBackground(focused: heroFocused))
        }
        .tvCardButton()
        .focused($focusedKey, equals: "heroEN:" + ch.url)
    }

    /// The fixture hero's badge with the matched state consulted
    /// (spec §1.4/§1.5): source minute verbatim, HT wording, or
    /// FT + final score — never PHÁT LẠI for a known FT.
    private func heroBadge(for entry: TVFixtureEntry) -> some View {
        heroBadgeText(bucket: store.effectiveBucket(of: entry.channel),
                      channel: entry.channel, state: entry.state)
    }

    private func heroBadgeText(bucket: Int, channel ch: Channel,
                               state: MatchState?) -> some View {
        let now = Date()
        let text: String
        let color: Color
        if let state, state.status == .ft {
            text = "FT" + (state.scoreText.map { " · " + $0 } ?? "")
            color = Color(red: 0.38, green: 0.38, blue: 0.42)
        } else if let state, state.status == .live || state.status == .ht {
            text = "🔴 ĐANG ĐÁ · " + (state.badgeText ?? "")
            color = TVPalette.liveRed
        } else if bucket == 0 {
            text = "🔴 ĐANG ĐÁ · " + (MatchStateStore.computedBadge(kickoff: ch.kickoff ?? now, now: now)
                ?? "\(TVKickoffFormat.liveMinute(of: ch.kickoff ?? now, now: now))'")
            color = TVPalette.liveRed
        } else if let kickoff = ch.kickoff, kickoff > now {
            text = "⏰ " + TVKickoffFormat.timeDay.string(from: kickoff)
            color = TVPalette.tealFill
        } else if ch.kickoff != nil {
            text = "↺ PHÁT LẠI"
            color = Color(red: 0.38, green: 0.38, blue: 0.42)
        } else {
            text = "📺 " + ch.group
            color = TVPalette.tealFill
        }
        return Text(text)
            .font(.system(size: 21, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 7)
            .background(Capsule().fill(color))
    }

    private func heroMeta(_ entry: TVFixtureEntry) -> String {
        var parts = [entry.leagueName]
        if !entry.channel.group.isEmpty { parts.append(entry.channel.group) }
        if entry.sourceCount > 1 { parts.append("\(entry.sourceCount) nguồn phát") }
        return parts.joined(separator: "  ·  ")
    }

    @ViewBuilder
    private func fixtureHeroArt(_ ch: Channel) -> some View {
        if let pair = Crests.crests(forTitle: ch.title), pair.0 != nil || pair.1 != nil {
            HStack(spacing: 22) {
                TVCrestImage(url: pair.0, size: 160)
                Text("VS")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.85))
                TVCrestImage(url: pair.1, size: 160)
            }
            .frame(width: 440, alignment: .center)
        } else if ch.logoURL != nil {
            TVChannelLogo(channel: ch, height: 168)
                .frame(width: 440, height: 168)
        } else {
            TVSoccerPlaceholder(size: 110)
                .frame(width: 440, height: 168)
        }
    }

    // MARK: - Rails and cards
    //
    // KH-2: thin call sites over TVFixtureRail (TVMatchViews),
    // which owns its own focus state; the titles, the card
    // choice (live → board, else featured/match card) and the
    // tap action are exactly as before.

    private func featuredRail(_ items: [TVFixtureEntry]) -> some View {
        TVFixtureRail(title: "⭐  TRẬN NỔI BẬT", entries: items, style: .featured,
                      onSelect: { play($0) }, onFocusKey: heroFocus)
    }

    private func railSection(_ title: String, _ items: [TVFixtureEntry]) -> some View {
        TVFixtureRail(title: title, entries: items, style: .standard,
                      onSelect: { play($0) }, onFocusKey: heroFocus)
    }

    // MARK: - Playing

    /// Playing a fixture hands the player the store's resolution
    /// for it: the store's own ladder (every displayable channel
    /// carrying the match, tapped one first — the same ladder the
    /// phone uses), verified at open and published progressively
    /// (PlaylistStore.resolution(for:)). A fixture the pin
    /// pre-resolved resolves from the cache instead, so the
    /// priority match is also the fastest to open.
    /// A fixture tap opens the fixture's link board (1.4.1,
    /// spec §2.1): VN rows are the store's ladder set for the
    /// fixture (sources(for:), representative first), EN rows
    /// are only this fixture's own attached Nuvio events
    /// (fail-closed attach above) — the board is the only place
    /// the VN/EN choice is made, and a board row tap plays.
    private func play(_ entry: TVFixtureEntry) {
        boardRequest = BoardRequest(entry: entry,
                                    vnSources: store.sources(for: entry.channel),
                                    enItems: attachedNuvioEvents(for: entry))
    }
}
