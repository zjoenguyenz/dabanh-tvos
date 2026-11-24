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
    /// 1.7.0: the theme store — owned HERE, at the root, and
    /// nowhere else. Its tokens are injected into the
    /// environment for the whole tree (and re-injected into
    /// every fullScreenCover, which starts a fresh environment
    /// chain); the store object itself goes to the surfaces
    /// that ACT on it (the footer's background cycler, the
    /// theme picker). Classic is the default and the classic
    /// tokens ARE the 1.6.0 constants, so the classic render
    /// is unchanged by construction.
    @StateObject private var themeStore = TVThemeStore()
    /// The theme picker cover ("Giao diện" pill, tabBar row 2).
    @State private var themeOpen = false
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
    /// 1.7.6 (FL-438): the last moment the owner actually
    /// browsed the board — a rail focus report (heroFocus)
    /// or a chrome focus change. The wallpaper auto-rotate
    /// reads it: while the owner is browsing, the rotation
    /// PAUSES (no swap under his eyes); it resumes once the
    /// board has been idle a full cycle and no cover is up.
    @State private var lastBoardActivity = Date()
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

    /// The CURRENT theme's tokens, read straight from the
    /// owned store (this view injects the same value into the
    /// environment for its children; a view's own environment
    /// reads come from its parent, so the root reads the store
    /// directly).
    private var theme: TVThemeTokens { themeStore.tokens }

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
        // 1.4.9 (FL-361): a Nuvio event that belongs to a board
        // fixture is NOT a second board entry — it is that
        // fixture's English source, reachable from the
        // fixture's own link board (the play(_:) attach reads
        // the addon store directly and is unaffected by this
        // filter). In 1.4.8 the fold-league and cups slices
        // rendered such events in their own NUVIO rails beside
        // the playlist entry: the same fixture twice on one
        // board, the addon copy bare by construction (its hero
        // carries no score block). Belonging is the attach
        // rule's core: canonical pair equal + same ICT stamp
        // date + kickoffs within 3 h. An event matching no
        // board entry keeps its rail exactly as before, and
        // every event stays in the BLV Anh tab regardless —
        // the tab renders the store's lists, not these slices.
        let boardFixtures: [(pair: String, dateKey: String, kickoff: Date, marked: Bool)] =
            s.allEntries.compactMap { e in
                guard let t = e.teams, let k = e.channel.kickoff,
                      let p = MatchPairKey.key(home: t.0, away: t.1) else { return nil }
                return (pair: p, dateKey: FixtureGrouping.stampDateKey(of: k), kickoff: k,
                        marked: isWomenMarked(t.0) || isWomenMarked(t.1))
            }
        func nuvioDuplicatesBoard(_ item: NuvioItem) -> Bool {
            guard let t = item.teams, let ek = item.kickoff,
                  let p = MatchPairKey.key(home: t.0, away: t.1) else { return false }
            let dk = FixtureGrouping.stampDateKey(of: ek)
            // Marker rule (the attach guard's asymmetry,
            // applied strictly): MatchPairKey canonicalises
            // women's markers away, so pair equality alone
            // would let a women's event "duplicate" a men's
            // board entry of the same clubs. Suppression
            // requires the marker status to MATCH; a
            // cross-marker event keeps its rail, and the
            // play-time attach guard decides its folding.
            let itemMarked = isWomenMarked(t.0) || isWomenMarked(t.1)
            return boardFixtures.contains {
                $0.pair == p && $0.dateKey == dk && $0.marked == itemMarked
                    && abs(ek.timeIntervalSince($0.kickoff)) <= 3 * 3600
            }
        }
        s.nuvioCupEvents.removeAll(where: nuvioDuplicatesBoard)
        s.leagueLiveEvents.removeAll(where: nuvioDuplicatesBoard)
        s.leagueUpcomingEvents.removeAll(where: nuvioDuplicatesBoard)
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
        // 1.7.6 (FL-438): a rail focus step IS board
        // browsing — stamp it for the auto-rotate pause.
        lastBoardActivity = Date()
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
    /// subtitle and the card's play-line prefix. (A fourth
    /// element, the hero's channel line, left with the slim
    /// hero in 1.5.0 — the hero carries no meta line now.)
    /// Only ever called with a fold league; the
    /// Anh / Khác arm exists so the switch is exhaustive, and
    /// its text is never rendered.
    private func leagueChannelCopy(_ league: League)
        -> (railTitle: String, railSubtitle: String, cardPrefix: String) {
        switch league {
        case .spain:
            return ("📺  NUVIO · KÊNH GIẢI TÂY BAN NHA",
                    "Kênh La Liga từ addon Nuvio — phát liên tục.",
                    "Kênh giải Tây Ban Nha")
        case .italy:
            return ("📺  NUVIO · KÊNH GIẢI Ý",
                    "Kênh Serie A từ addon Nuvio — phát liên tục.",
                    "Kênh giải Ý")
        case .france:
            return ("📺  NUVIO · KÊNH GIẢI PHÁP",
                    "Kênh Ligue 1 từ addon Nuvio — phát liên tục.",
                    "Kênh giải Pháp")
        case .germany:
            return ("📺  NUVIO · KÊNH GIẢI ĐỨC",
                    "Kênh Bundesliga từ addon Nuvio — phát liên tục.",
                    "Kênh giải Đức")
        case .england, .other, .cups:
            return ("📺  NUVIO · KÊNH 24/7",
                    "Kênh từ addon Nuvio — phát liên tục.",
                    "Kênh Nuvio")
        }
    }

    /// The 3-across tile width from the measured content width
    /// (KH-6): min(592, (W − 2×4 rail insets − 2×28 spacing)/3).
    /// Before the first measurement lands, the approved 592.
    /// 1.5.1 (FL-360): the rail insets shrank 8 → 4 with the
    /// margin reclaim, so the constant is 64, and W itself is
    /// now the full safe-area width (the root's own 32 pt side
    /// padding is gone — see the body note below).
    private var tileWidth: CGFloat {
        guard contentWidth > 0 else { return 592 }
        return min(592, max(300, (contentWidth - 64) / 3))
    }

    /// 1.7.1: the MU card width (table H5) — 4 across from the
    /// measured content width: (W − 2×4 rail insets − 3×22
    /// gaps) / 4, i.e. (W − 74) / 4, clamped to [300, 425].
    /// Before the first measurement lands, 421 (the 1760-wide
    /// design value). Published as \.tvMUCardWidth below.
    private var muCardWidth: CGFloat {
        contentWidth > 0 ? min(425, max(300, (contentWidth - 74) / 4)) : 421
    }

    var body: some View {
        ZStack {
            // 1.7.6 (FL-439): the background is NO LONGER a
            // ZStack child. As a sibling it negotiated the
            // stack's size, and a wallpaper bitmap taller
            // than the stage (the set's 4:3 block, the square
            // crest, the one portrait) inflated the stack and
            // pushed the fixed chrome off the top edge —
            // steady per image, exactly as the owner reported
            // ("nền nào bị nuốt thì nó nuốt luôn"). As a
            // .background the layer is sized BY this stack and
            // can never inflate it; its own ignoresSafeArea
            // still gives the full bleed.
            // KH-6: measure the REAL content width (the padded
            // region the rails live in) — the tile width derives
            // from this, never from an assumed screen size.
            GeometryReader { geo in
                Color.clear
                    .onAppear { contentWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in contentWidth = w }
            }
            .padding(.horizontal, 0)
            VStack(spacing: theme.id.isMU ? 8 : 12) {
                header
                tabBar
                // 1.4.9 (FL-360, audit S-1): the status line's
                // slot is ALWAYS in the root VStack at a fixed
                // height — a message arriving (mirror slow,
                // fallback, link-check result) or clearing
                // changes only the text, never the layout. In
                // 1.4.8 the row inserted/removed ≈44 pt and the
                // hero plus every rail shifted with it, exactly
                // while the owner watched the screen settle.
                Text(store.statusMessage ?? "")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .frame(height: 24)
                scrollBody
                // 1.7.5 (RECALC-DABANH H13): under the design
                // theme the footer is the drawing's FIXED bar
                // (hairline + hints + the change-background
                // text control), a root row UNDER the scroll
                // body — it never scrolls. The in-flow
                // footerRow renders nothing under the design
                // theme; its Classic / MU Wally forms are
                // untouched.
                if theme.id.isDesign {
                    designFooterBar
                }
            }
            // 1.5.1 (FL-360, owner ruling 2026-11-21 15:36 CST:
            // "Hiện đóng khung nhỏ hơn nên thiếu diện tích các
            // khung" — the framing is inset too tightly and every
            // frame starves): the root's own padding is GONE on
            // all four sides. tvOS already insets primary content
            // by its safe area (60 top/bottom, 80 sides — Apple
            // HIG), and every point this stack added on top of it
            // was wasted area: the 1.5.0 count never included the
            // safe area at all, which is why its "fits" sheet
            // clipped on the real screen. The full count sheet
            // is in BUILD-151-REPORT.md.
            .padding(.horizontal, 0)
            // 1.7.2 (audit H9; owner ruling 2026-11-22 00:41
            // CST — keep the header HIGH, never lower it, but
            // not jammed against the edge): under MU the root
            // carries a guaranteed 27 pt top inset, the
            // design's header-band proportion (its band starts
            // 27 pt from the edge). Classic keeps 0 exactly.
            // 1.7.6 (owner ruling 2026-11-22 13:10 CST,
            // RECALC-DABANH RULING 2): the tab row still sits
            // too close to the top edge — nudge it down "một
            // chút xíu thôi": +16 pt for EVERY theme (MU
            // 27 → 43, Classic 0 → 16), taken from the scroll
            // viewport's flexible height only; the full-bleed
            // background layers and the 380 pt scrim band do
            // not move, and chrome position never differs by
            // theme.
            .padding(.top, theme.id.isMU ? 43 : 16)
            .padding(.bottom, 0)
        }
        .background { background }
        .environment(\.tvTileWidth, tileWidth)
        .environment(\.tvMUCardWidth, muCardWidth)
        .environment(\.tvTheme, themeStore.tokens)
        .environmentObject(themeStore)
        .task {
            DiagLog.logSessionStart()
            await store.start()
            dataChanged()
        }
        .task { await nuvio.load() }
        .task(id: theme.id.isMU && themeStore.bgAutoRotate) {
            // 1.7.1 (table S3): the MU wallpaper auto-rotate —
            // the round's ONLY functional addition, default OFF
            // (the theme store persists the toggle). The loop
            // cycles every 25 s ONLY while the MU theme is
            // active and the toggle is on; the task's id re-keys
            // (cancelling the loop) the moment either flips.
            // 1.7.6 (FL-438): the cycle is now IDLE-GATED. The
            // 1.7.5 loop swapped on the timer no matter what
            // the owner was doing, and the swap was a hard cut
            // (the crossfade half lives in the wallpaper
            // views) — the board "jumped" under his remote.
            // Now a swap lands only when the board has been
            // idle for a full 25 s cycle AND no cover (player,
            // board, log, picker) is up; while he browses, the
            // rotation is paused, not queued.
            guard theme.id.isMU && themeStore.bgAutoRotate else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                guard Date().timeIntervalSince(lastBoardActivity) >= 25,
                      playRequest == nil, boardRequest == nil,
                      !logOpen, !themeOpen else { continue }
                let count = Wallpapers.images().count
                if count > 1 {
                    themeStore.cycleBackground(count: count)
                    // The swap itself starts a fresh idle
                    // window, so the next one is a full cycle
                    // later — never a catch-up burst.
                    lastBoardActivity = Date()
                }
            }
        }
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
        .task(id: heroDetailKey) {
            // Hero detail priority + on-demand upgrade (1.4.8,
            // FL-331): the fixture in the hero is registered
            // for the cycle pass's first slot, and when its
            // bound state is a FotMob state still missing
            // events the upgrade fires right away — the named-
            // case treatment the link board has had since
            // 1.4.4 (spec §1.2), for the one surface that is
            // always on screen. A non-fixture hero clears the
            // registration.
            if case .fixture(let entry) = heroItem {
                store.setHeroDetailPriority(for: entry.channel)
                store.requestHeroDetail(for: entry.channel)
            } else {
                store.setHeroDetailPriority(for: nil)
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
                .environment(\.tvTheme, themeStore.tokens)
        }
        .fullScreenCover(item: $boardRequest) { request in
            TVMatchBoardView(entry: request.entry,
                             vnSources: request.vnSources,
                             enItems: request.enItems,
                             nuvio: nuvio)
                .environment(\.tvTheme, themeStore.tokens)
                .environmentObject(themeStore)
        }
        .fullScreenCover(isPresented: $logOpen) {
            TVLogView()
                .environment(\.tvTheme, themeStore.tokens)
        }
        .fullScreenCover(isPresented: $themeOpen) {
            TVThemePickerView()
                .environment(\.tvTheme, themeStore.tokens)
                .environmentObject(themeStore)
        }
        // KH-2: every DATA input rebuilds the snapshot (and
        // re-validates the hero); focus changes never reach
        // this body as work — the rails own their focus state
        // and report hero keys through heroFocus(_:).
        // 1.7.6 (FL-438): chrome focus steps are browsing too.
        .onChange(of: focusedKey) { _, _ in lastBoardActivity = Date() }
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
        // 1.4.8 (FL-331): re-validate AND refresh. The snapshot
        // was just rebuilt from the stores' newest data, so a
        // hero that still exists is re-pointed at the snapshot's
        // FRESH item for the same identity. The pre-1.4.8 early
        // return kept the captured item — the hero froze at the
        // state (and crest pair) it carried when focus last
        // moved, while the tiles, reading the snapshot, tracked
        // every poll. This is the hero's half of the chain the
        // tiles always had: state publish → liveRevision →
        // dataChanged → rebuildSnapshot → syncHero refresh →
        // hero re-render, with no focus move involved.
        if isENTab {
            // The addon leads the tab, so the hero defaults to
            // its first item; the old EN block is the fallback
            // hero when the addon has nothing.
            if case .nuvio(let item) = heroItem,
               let fresh = (nuvio.liveEvents + nuvio.upcomingEvents + nuvio.channels)
                   .first(where: { $0.id == item.id }) {
                heroItem = .nuvio(fresh)
                return
            }
            if case .english(let ch) = heroItem,
               let fresh = enChannels.first(where: { $0.url == ch.url }) {
                // Refresh by identity alone: the !nuvio.hasContent
                // condition the pre-1.4.8 keep-branch carried
                // belongs to DEFAULT selection (below), not to
                // keeping a hero the owner focused — with it, the
                // next poll yanked the hero off a focused old-EN
                // channel card back to the addon's first item.
                heroItem = .english(fresh)
                return
            }
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
               let fresh = (leagueLiveEvents + leagueUpcomingEvents + leagueAddonChannels)
                   .first(where: { $0.id == item.id }) {
                heroItem = .nuvio(fresh)
                return
            }
            if case .fixture(let current) = heroItem,
               let fresh = entries.first(where: { $0.id == current.id }) {
                heroItem = .fixture(fresh)
                return
            }
            if let first = featuredEntries.first ?? entries.first {
                heroItem = .fixture(first)
            } else if let first = leagueLiveEvents.first ?? leagueUpcomingEvents.first ?? leagueAddonChannels.first {
                heroItem = .nuvio(first)
            } else {
                heroItem = nil
            }
            return
        }
        // A Nuvio hero reaches this branch from the cups tab
        // (foldLeague is nil there): refresh it by identity
        // from the same pool heroLookup is built from — the
        // pre-1.4.8 branch knew only fixture heroes, so the
        // next poll overwrote a focused cup-event hero with
        // the fixture default, or nil when the tab had no
        // fixture entries at all.
        if case .nuvio(let item) = heroItem,
           let fresh = (nuvio.liveEvents + nuvio.upcomingEvents + nuvio.channels
               + nuvio.leagueChannels.values.flatMap { $0 })
               .first(where: { $0.id == item.id }) {
            heroItem = .nuvio(fresh)
            return
        }
        if case .fixture(let current) = heroItem,
           let fresh = entries.first(where: { $0.id == current.id }) {
            heroItem = .fixture(fresh)
            return
        }
        let first = featuredEntries.first ?? entries.first
        heroItem = first.map { .fixture($0) }
    }

    /// The hero-detail hook's identity (1.4.8): the hero
    /// fixture's id plus the shape of its bound state (source,
    /// FotMob id, events still missing) — the hook re-runs
    /// when either changes, and the store's guards make a
    /// re-run with nothing to do a no-op.
    private var heroDetailKey: String {
        guard case .fixture(let entry) = heroItem else { return "hero:none" }
        guard let state = entry.state else { return "hero:\(entry.id):nostate" }
        return "hero:\(entry.id):\(state.source):\(state.fotmobID ?? -1):\(state.events.isEmpty)"
    }

    // MARK: - Chrome

    @ViewBuilder
    private var background: some View {
        if theme.id.isMU {
            muBackground
        } else {
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
    }

    /// The current MU wallpaper, if any: the shared list in
    /// file order, indexed by the persisted choice. Empty list
    /// → nil (gradient only, fail-open like every other remote
    /// list in this app).
    private var currentWallpaperURL: URL? {
        let images = Wallpapers.images()
        guard !images.isEmpty else { return nil }
        let count = images.count
        return images[((themeStore.bgIndex % count) + count) % count]
    }

    /// 1.7.0 MU background: the theme's token gradient UNDER a
    /// full-bleed wallpaper photo with the design's heavy dark
    /// scrim over it. FL-128: this view reads NO focus state —
    /// it re-renders only when the theme, the chosen index or
    /// the remote list's revision changes, never on a focus
    /// step.
    private var muBackground: some View {
        // A remote wallpaper refresh bumps this revision; the
        // read is what re-runs this view (and only this view)
        // when the list lands.
        let _ = store.wallpaperRevision
        return ZStack {
            LinearGradient(
                colors: [theme.bgTop, theme.bgMid, theme.bgBottom],
                startPoint: .top, endPoint: .bottom)
            if let url = currentWallpaperURL {
                TVWallpaperView(url: url)
            }
            // 1.7.2 (audit H10): a dedicated top scrim band
            // behind the header + tab zone. The wallpaper's
            // own 3-stop scrim tops out at black .55 — over a
            // bright-sky wallpaper the header and tab rows
            // washed out (owner photo 2, 2026-11-22). This
            // band guarantees a dark ground over the top
            // ~380 pt (safe area + inset + header + tab bar
            // + status slot) and fades out before the rails.
            LinearGradient(
                colors: [Color.black.opacity(0.85),
                         Color.black.opacity(0.55),
                         Color.black.opacity(0)],
                startPoint: .top, endPoint: .bottom)
                .frame(height: 380)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .top)
        }
        .ignoresSafeArea()
    }

    /// Compact header (1.4.1, spec §0/§5.2-6): ONE row — small
    /// logo left; clock + dabanh.tv right, at the prototype's
    /// mini sizes. The Làm mới / Kiểm tra link mini-buttons keep
    /// their pill-row place directly beneath (their focus-travel
    /// position is load-bearing since v1.2.7 — see tabBar); the
    /// old 56-pt two-line brand block is gone.
    @ViewBuilder
    private var header: some View {
        if theme.id.isDesign {
            // 1.7.4: the design theme's own header (crest +
            // brand wordmark + MANCHESTER UNITED tagline;
            // the wordmark text is "Joe Soccer" since
            // 1.7.6, FL-441).
            TVDesignHeader()
        } else if theme.id.isMU {
            muHeader
        } else {
            HStack(alignment: .center, spacing: 18) {
                Text("⚽")
                    .font(.system(size: 30))
                // 1.7.6 (FL-441, RECALC-DABANH RULING 1 —
                // Form C): the wordmark is the owner's brand
                // "Joe Soccer" in the Classic dress — the
                // theme's own system Bold 30, "Joe" white,
                // " Soccer" in boardSky. (Was "ĐÁ BANH TV":
                // the brand name is the owner's ruling, the
                // face and colours are the header's own.)
                (Text("Joe").foregroundStyle(.white)
                    + Text(" Soccer").foregroundStyle(TVPalette.boardSky))
                    .font(.system(size: 30, weight: .bold))
                Spacer()
                Text(TVKickoffFormat.time.string(from: Date()))
                    .font(.system(size: 20))
                    .foregroundStyle(Color(red: 0.388, green: 0.463, blue: 0.604))
                Text("dabanh.tv")
                    .font(.system(size: 20))
                    .foregroundStyle(TVPalette.leagueTx)
            }
            // 1.5.1 (FL-360): the 4 pt bottom pad is reclaimed —
            // the root VStack spacing separates the rows now.
        }
    }

    /// 1.7.0 MU header, rescaled to the design in 1.7.1
    /// (table H2): crest 84, wordmark 40, tagline 13 tracked 2
    /// on two lines, the Theatre of Dreams line 15 tracked 3
    /// centred on the screen, and the right block = clock 30 +
    /// the device date — NO "dabanh.tv" under MU. A hairline
    /// divider sits under the row, inside this VStack, so the
    /// classic header is untouched.
    private var muHeader: some View {
        // 1.7.0 fix round 1: the Theatre of Dreams line is
        // centred on the SCREEN — the HStack (left block,
        // Spacer, clock block) sits underneath in a ZStack
        // and the centre Text is centred across the full
        // width on top. No focusables are in the header.
        VStack(spacing: 0) {
            ZStack {
                HStack(alignment: .center, spacing: 18) {
                    HStack(alignment: .center, spacing: 14) {
                        TVCrestImage(url: Crests.url(forTeam: "Manchester United"), size: 84)
                        VStack(alignment: .leading, spacing: 2) {
                            // 1.7.6 (FL-441, RECALC-DABANH
                            // RULING 1 — Form B): the wordmark
                            // TEXT is the owner's brand "Joe
                            // Soccer" — a text swap only. The
                            // face (system Bold 40), the crest
                            // 84 and the theme's slogan tagline
                            // below are MU Wally's preserved
                            // look and do not move; " Soccer"
                            // takes the Wally gold
                            // (theme.accent), the slot the old
                            // "TV" wore.
                            (Text("Joe").foregroundStyle(.white)
                                + Text(" Soccer").foregroundStyle(theme.accent))
                                .font(.system(size: 40, weight: .bold))
                            Text("THE MATCH. THE MOMENT. UNITED.")
                                .font(.system(size: 13))
                                .foregroundStyle(theme.leagueTx)
                                .tracking(2)
                                .lineLimit(2)
                                .frame(width: 210, alignment: .leading)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(TVKickoffFormat.time.string(from: Date()))
                            .font(.system(size: 30))
                            .foregroundStyle(theme.dashTx)
                        Text(TVKickoffFormat.muHeaderDateFormatter.string(from: Date()).uppercased())
                            .font(.system(size: 13))
                            .foregroundStyle(theme.leagueTx)
                    }
                }
                // 1.7.2 (audit H6): the design wraps this
                // line in TWO lines, its block centred at
                // ≈44% of the width (not 50%). The 230 pt
                // frame is what makes the string wrap (and
                // breaks it before "DREAMS", as drawn); the
                // −115 offset moves the block's centre from
                // 960 (50%) to 845 (44% of 1920).
                Text("◆ THE THEATRE OF DREAMS ◆")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .tracking(3)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: 230)
                    .offset(x: -115)
            }
            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(height: 1)
                .padding(.top, 2)
        }
    }

    // 1.7.2 (audit H13): the tab row's right-side count text
    // ("6 trận đang đá") is REMOVED — the design has nothing
    // at the tab row's right. Its countText property went
    // with it (the tab bar below was its only reader).

    private var tabBar: some View {
        // Two rows since v1.2.7: the pills alone fill row one, and
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
        VStack(alignment: .leading, spacing: theme.id.isMU ? 4 : 6) {
            HStack(spacing: 12) {
                if theme.id.isDesign {
                    // 1.7.5 (RECALC-DABANH H3): the design
                    // theme's tab row is the DRAWING's
                    // inventory — Trực tiếp · Sắp diễn ra ·
                    // the five leagues by their full names ·
                    // Khác. No ENG tab, no Hot tab, no emoji,
                    // no flag pills. The values are the app's
                    // own: "Sắp diễn ra" selects the Hot tab
                    // value — the app's upcoming-bearing list
                    // (its empty-state text has always sent
                    // sắp-đá viewers there). Recorded
                    // honestly: that list is the mirror's
                    // hot-flagged set, live-first — a live hot
                    // match can appear there, under its
                    // "Trực tiếp" rail; the label is the
                    // drawing's, the list is the closest the
                    // app has (gate record, 1.7.5). The cups
                    // value has no tab under this theme (cup
                    // fixtures still surface in the Trực tiếp
                    // rails and their league tabs).
                    tabPill(title: "Trực tiếp", value: PlaylistStore.liveTabValue)
                    tabPill(title: "Sắp diễn ra", value: PlaylistStore.hotTabValue)
                    tabPill(title: "Premier League", value: League.england.rawValue)
                    tabPill(title: "La Liga", value: League.spain.rawValue)
                    tabPill(title: "Serie A", value: League.italy.rawValue)
                    tabPill(title: "Bundesliga", value: League.germany.rawValue)
                    tabPill(title: "Ligue 1", value: League.france.rawValue)
                    tabPill(title: "Khác", value: League.other.rawValue)
                } else {
                    if !enChannels.isEmpty || nuvio.hasContent {
                        tabPill(title: "ENG", value: Self.enTabValue)
                    }
                    tabPill(title: "🔴 Trực tiếp", value: PlaylistStore.liveTabValue)
                    tabPill(title: "🔥 Hot", value: PlaylistStore.hotTabValue)
                    ForEach(League.tabOrder) { league in
                        tabPill(title: league.tabTitle, value: league.rawValue)
                    }
                }
                Spacer()
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
                    .padding(.vertical, theme.id.isMU ? 6 : 10)
                    .background(TVPillFace(focused: focusedKey == "hdr:refresh",
                                           selected: false, theme: theme))
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
                    .padding(.vertical, theme.id.isMU ? 6 : 10)
                    .background(TVPillFace(focused: focusedKey == "hdr:check",
                                           selected: false, theme: theme))
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
                    .padding(.vertical, theme.id.isMU ? 6 : 10)
                    .background(TVPillFace(focused: focusedKey == "hdr:log",
                                           selected: false, theme: theme))
                }
                .tvCardButton()
                .focused($focusedKey, equals: "hdr:log")
                // 1.7.0: the theme picker's door — the feature's
                // entry point, present under BOTH themes (it is
                // how the owner reaches MU, so the classic bar
                // gains this one pill and nothing else). Same
                // metrics as the other action pills.
                Button {
                    themeOpen = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "paintpalette")
                        Text("Giao diện")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.system(size: 20, weight: .medium))
                    .padding(.horizontal, 20)
                    .padding(.vertical, theme.id.isMU ? 6 : 10)
                    .background(TVPillFace(focused: focusedKey == "hdr:theme",
                                           selected: false, theme: theme))
                }
                .tvCardButton()
                .focused($focusedKey, equals: "hdr:theme")
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
            if theme.id.isDesign {
                // 1.7.4: the design theme's text tab — the
                // fresh drawing's face (gold outline + red
                // underline on selection, NO red dot).
                TVDesignTabFace(title: title, selected: selected,
                                focused: focusedKey == "pill:\(value)",
                                theme: theme)
            } else if theme.id.isMU {
                // 1.7.1 (table H3): under MU the tab is the
                // design's TEXT tab — TVMUTabFace carries the
                // whole face (hidden-bold width reservation
                // included, FL-360), replacing the 1.7.0 capsule
                // pill face on this arm only.
                TVMUTabFace(title: title, selected: selected,
                            focused: focusedKey == "pill:\(value)",
                            theme: theme)
            } else {
                Text(title)
                    .font(.system(size: 20, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(TVPillFace(focused: focusedKey == "pill:\(value)",
                                           selected: selected, theme: theme,
                                           showsSelectionMarks: true))
                    .foregroundStyle(.white)
            }
        }
        .tvCardButton()
        .focused($focusedKey, equals: "pill:\(value)")
    }

    private var emptyText: String {
        if store.selectedLeague == PlaylistStore.liveTabValue {
            // 1.7.5: under the design theme the inventory has
            // no 🔥 Hot tab — the same list is named
            // "Sắp diễn ra" there, and the copy follows.
            if theme.id.isDesign {
                return "Hiện không có trận nào đang đá. Các trận sắp đá nằm ở tab Sắp diễn ra và các tab giải."
            }
            return "Hiện không có trận nào đang đá. Các trận sắp đá nằm ở tab 🔥 Hot và các tab giải."
        }
        if store.selectedLeague == PlaylistStore.hotTabValue {
            if theme.id.isDesign {
                return "Chưa có trận nào trong mục Sắp diễn ra."
            }
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
            // 1.7.2 (audit H1): on the Trực tiếp tab the tab's
            // own entries come from the store's LIVE-ONLY list
            // (tabChannels = store.liveChannels), so `upcoming`
            // there is empty by construction and the design's
            // second rail could never render on Home. Under MU
            // the home's SẮP ĐÁ rail is fed from the WHOLE
            // pool instead (allEntries, buckets 1/2, MU pin
            // first — the pinned fixture is exactly the
            // content this rail exists for). Every other tab,
            // and the classic theme everywhere, keeps the
            // tab's own list verbatim.
            let muUpcoming = (theme.id.isMU && onLiveTab)
                ? TVFixtureEntry.pinnedFirst(allEntries.filter {
                    let b = store.effectiveBucket(of: $0.channel, now: now)
                    return b == 1 || b == 2
                  })
                : upcoming
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
            // 1.5.0 vertical budget (1080 canvas, line ≈ 1.24 ×
            // size): root pads 40 + 28 → 1012 for the root
            // VStack; header 41 + tabBar 100 + status slot 24 +
            // three 20-pt root spacings = 225 of chrome, leaving
            // 787 for this body. Slim hero panel 366 + this
            // VStack's 18 spacing → the rails' ScrollView
            // viewport is 403. A fixture rail needs 37 (title)
            // + 4 + 14 (top inset) + 342 (tile slot) = 397 for
            // its tiles to stand FULLY visible at rest — 403 ≥
            // 397, so the first rail's frames are whole again
            // (1.4.9: viewport 193, the tile cut at ≈136 of
            // 342 — the owner's "bị cắt" clip). The same 18
            // spacing applies to the cup and EN bodies below.
            // 1.5.1 (FL-360): that sheet was WRONG on the real
            // screen — it never counted the tvOS safe area
            // (120 pt) and dropped the rail's bottom inset; the
            // true 1.5.0 viewport was 283 against a 410 need.
            // The 1.5.1 reclaim (root padding gone, spacings
            // tightened, rail insets 14 → 4, hero padding
            // 18 → 10) gives viewport ≈419 against a 390 need.
            // Full count sheet: BUILD-151-REPORT.md.
            VStack(alignment: .leading, spacing: 12) {
                // 1.7.1 (table H1): under MU the hero panel is
                // NOT rendered — the rails lead the body. The
                // hero machinery (snapshot, heroFocus, the
                // heroDetailKey prefetch task) stays wired;
                // only the panel's rendering is skipped.
                if !theme.id.isMU { heroPanel }
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: theme.id.isMU ? 8 : 12) {
                        if theme.id.isMU {
                            // 1.7.1 (table H7): under MU there is
                            // no featured rail — the featured
                            // entries lead the ONE live rail
                            // (featured ⊂ entries and `live`
                            // already excludes featuredIDs, so no
                            // duplicates), each keeping its own
                            // focus key ("feat:" / "rail:") so
                            // heroLookup/prefetch behaviour is
                            // identical.
                            if !(featuredEntries + live).isEmpty {
                                if theme.id.isDesign {
                                    // 1.7.4: the design rail —
                                    // same entries, keys and
                                    // order; the design header
                                    // carries no date note.
                                    // 1.7.5: its title is the
                                    // drawing's "Trực tiếp" —
                                    // no emoji on design rails.
                                    TVDesignFixtureRail(title: "Trực tiếp",
                                                        entries: featuredEntries + live,
                                                        keyFor: { featuredIDs.contains($0.id) ? "feat:" + $0.id : "rail:" + $0.id },
                                                        onSelect: play,
                                                        onFocusKey: heroFocus)
                                } else {
                                    TVMUFixtureRail(title: "🔴  ĐANG ĐÁ",
                                                    entries: featuredEntries + live,
                                                    note: nil,
                                                    keyFor: { featuredIDs.contains($0.id) ? "feat:" + $0.id : "rail:" + $0.id },
                                                    onSelect: play,
                                                    onFocusKey: heroFocus)
                                }
                            }
                        } else {
                            if !featuredEntries.isEmpty {
                                featuredRail(featuredEntries)
                            }
                            if !live.isEmpty {
                                railSection("🔴  ĐANG ĐÁ", live)
                            }
                        }
                        if !cupLive.isEmpty {
                            railSection("🏆  CÚP CHÂU ÂU · ĐANG ĐÁ", cupLive)
                        }
                        if !leagueLiveEvents.isEmpty {
                            nuvioEventRail("🔴  NUVIO · ĐANG ĐÁ", leagueLiveEvents)
                        }
                        if !muUpcoming.isEmpty {
                            // 1.7.5: under the design theme the
                            // drawn rail title is "Sắp diễn ra";
                            // MU Wally keeps its shipped title.
                            railSection(theme.id.isDesign ? "Sắp diễn ra" : "⏰  SẮP ĐÁ",
                                        muUpcoming,
                                        muNote: TVKickoffFormat.muRailDateFormatter.string(from: now))
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
                    .padding(.top, theme.id.isMU ? 0 : 2)
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
        // 1.5.1 (FL-360): the division label folds into the
        // FIRST rail's title (see railSection(sectionLabel:)) —
        // the separate 26 pt header row is reclaimed.
        VStack(alignment: .leading, spacing: 12) {
            if !live.isEmpty {
                railSection("🔴  ĐANG ĐÁ", live, sectionLabel: competition.label)
            }
            if !upcoming.isEmpty {
                if live.isEmpty {
                    railSection("⏰  SẮP ĐÁ", upcoming, sectionLabel: competition.label)
                } else {
                    railSection("⏰  SẮP ĐÁ", upcoming)
                }
            }
            if !rest.isEmpty {
                if live.isEmpty && upcoming.isEmpty {
                    railSection("📺  KHÁC", rest, sectionLabel: competition.label)
                } else {
                    railSection("📺  KHÁC", rest)
                }
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
        VStack(alignment: .leading, spacing: 12) {
            // 1.7.1 (table H1): hero panel skipped under MU —
            // rendering only, machinery untouched (see scrollBody).
            if !theme.id.isMU { heroPanel }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
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
            // 1.5.1 (FL-360): the competition label folds into
            // the first rail's title (the Nuvio rail's title
            // already carries it); the stacked title row is
            // reclaimed so the first cup rail stands whole.
            VStack(alignment: .leading, spacing: 12) {
                if !live.isEmpty {
                    railSection("🔴  ĐANG ĐÁ", live, sectionLabel: competition.label)
                }
                if !upcoming.isEmpty {
                    if live.isEmpty {
                        railSection("⏰  SẮP ĐÁ", upcoming, sectionLabel: competition.label)
                    } else {
                        railSection("⏰  SẮP ĐÁ", upcoming)
                    }
                }
                if !rest.isEmpty {
                    if live.isEmpty && upcoming.isEmpty {
                        railSection("📺  KHÁC", rest, sectionLabel: competition.label)
                    } else {
                        railSection("📺  KHÁC", rest)
                    }
                }
                if !addon.isEmpty {
                    nuvioEventRail("📺  NUVIO · " + competition.label, addon)
                }
            }
        }
    }

    /// The design Home's fixed footer bar (1.7.5): the
    /// shared TVDesignFooterBar fed with this view's
    /// wallpaper data; its button keeps the in-flow footer's
    /// focus id ("ftr:bg" — the in-flow row is suppressed
    /// under the design theme, so the id has one owner).
    private var designFooterBar: some View {
        let images = Wallpapers.images()
        let count = images.count
        let position = count > 0
            ? ((themeStore.bgIndex % count) + count) % count + 1 : 0
        return TVDesignFooterBar(
            position: position, count: count,
            focus: $focusedKey, focusValue: "ftr:bg",
            onChangeBackground: {
                themeStore.cycleBackground(count: count)
                DiagLog.write("theme", "mu background cycled to \(themeStore.bgIndex + 1)/\(count)")
            })
    }

    @ViewBuilder
    private var footerRow: some View {
        if theme.id.isDesign {
            // 1.7.5: the design theme's footer is the fixed
            // bar at the root (designFooterBar above) — the
            // in-flow row stands down under this theme only.
            EmptyView()
        } else {
        HStack {
            // 1.7.2 (owner ruling 2026-11-22 00:40 CST —
            // "bỏ đi luôn": he watches at home, no credit
            // needed): the "Logos: football-logos.cc" line
            // that stood here is removed entirely.
            Spacer()
            // 1.7.0 MU only: the Change-background control —
            // cycles the shared wallpaper list (choice persists
            // in the theme store) with a counter instead of 35
            // position dots. Rendered only under MU with a
            // non-empty list; the classic footer is untouched.
            if theme.id.isMU {
                let images = Wallpapers.images()
                if !images.isEmpty {
                    Button {
                        themeStore.cycleBackground(count: images.count)
                        DiagLog.write("theme", "mu background cycled to \(themeStore.bgIndex + 1)/\(images.count)")
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "photo")
                            Text("Đổi hình nền · \((themeStore.bgIndex % images.count) + 1)/\(images.count)")
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .font(.system(size: 20, weight: .medium))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(TVPillFace(focused: focusedKey == "ftr:bg",
                                               selected: false, theme: theme))
                    }
                    .tvCardButton()
                    .focused($focusedKey, equals: "ftr:bg")
                }
            }
            // 1.4.8 (FL-331 round): version label read from the bundle, never
            // a hardcoded literal — a stale literal made screenshots
            // untraceable to a build (FL-015 lesson).
            Text("Đá Banh TV v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"))
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.4))
        }
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
            VStack(alignment: .leading, spacing: 12) {
                // 1.7.1 (table H1): hero panel skipped under MU —
                // rendering only, machinery untouched (see scrollBody).
                if !theme.id.isMU { heroPanel }
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
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

    @ViewBuilder
    private func nuvioEventRail(_ title: String, _ items: [NuvioItem]) -> some View {
        if theme.id.isDesign {
            // 1.7.4 (Round 1 review B-1): the design rail
            // shell — the design header over the family cards.
            TVDesignNuvioEventRail(title: title, items: items,
                                   onSelect: { item in
                                       playRequest = PlayRequest(resolution: nuvio.resolution(for: item))
                                   },
                                   onFocusKey: heroFocus)
        } else if theme.id.isMU {
            // 1.7.1 (table H8): the MU rail shell for addon events.
            TVMUNuvioEventRail(title: title, items: items,
                               onSelect: { item in
                                   playRequest = PlayRequest(resolution: nuvio.resolution(for: item))
                               },
                               onFocusKey: heroFocus)
        } else {
            TVNuvioEventRail(title: title, items: items,
                             onSelect: { item in
                                 playRequest = PlayRequest(resolution: nuvio.resolution(for: item))
                             },
                             onFocusKey: heroFocus)
        }
    }

    @ViewBuilder
    private func nuvioChannelRail(_ items: [NuvioItem]) -> some View {
        if theme.id.isDesign {
            // 1.7.4 (Round 1 review B-1): the design rail shell.
            TVDesignNuvioChannelRail(title: "📺  NUVIO · KÊNH 24/7",
                                     subtitle: "Kênh tiếng Anh từ addon Nuvio — phát liên tục.",
                                     items: items,
                                     onSelect: { item in
                                         playRequest = PlayRequest(resolution: nuvio.resolution(for: item))
                                     },
                                     onFocusKey: heroFocus)
        } else if theme.id.isMU {
            // 1.7.1 (table H8): the MU rail shell for addon channels.
            TVMUNuvioChannelRail(title: "📺  NUVIO · KÊNH 24/7",
                                 subtitle: "Kênh tiếng Anh từ addon Nuvio — phát liên tục.",
                                 items: items,
                                 onSelect: { item in
                                     playRequest = PlayRequest(resolution: nuvio.resolution(for: item))
                                 },
                                 onFocusKey: heroFocus)
        } else {
            TVNuvioChannelRail(title: "📺  NUVIO · KÊNH 24/7",
                               subtitle: "Kênh tiếng Anh từ addon Nuvio — phát liên tục.",
                               items: items,
                               onSelect: { item in
                                   playRequest = PlayRequest(resolution: nuvio.resolution(for: item))
                               },
                               onFocusKey: heroFocus)
        }
    }

    /// A folded league tab's addon channel rail (owner,
    /// 2026-11-19 12:58 CST): the league fold's 24/7 channels
    /// below the tab's fixtures — the nuvioChannelRail shape,
    /// with the league's own copy and the card's own play line.
    @ViewBuilder
    private func leagueChannelRail(_ items: [NuvioItem], league: League) -> some View {
        let copy = leagueChannelCopy(league)
        if theme.id.isDesign {
            // 1.7.4 (Round 1 review B-1): the design rail
            // shell, league copy kept.
            TVDesignNuvioChannelRail(title: copy.railTitle,
                                     subtitle: copy.railSubtitle,
                                     items: items,
                                     detailPrefix: copy.cardPrefix,
                                     onSelect: { item in
                                         playRequest = PlayRequest(resolution: nuvio.resolution(for: item))
                                     },
                                     onFocusKey: heroFocus)
        } else if theme.id.isMU {
            // 1.7.1 (table H8): the MU rail shell, league copy kept.
            TVMUNuvioChannelRail(title: copy.railTitle,
                                 subtitle: copy.railSubtitle,
                                 items: items,
                                 detailPrefix: copy.cardPrefix,
                                 onSelect: { item in
                                     playRequest = PlayRequest(resolution: nuvio.resolution(for: item))
                                 },
                                 onFocusKey: heroFocus)
        } else {
            TVNuvioChannelRail(title: copy.railTitle,
                               subtitle: copy.railSubtitle,
                               items: items,
                               detailPrefix: copy.cardPrefix,
                               onSelect: { item in
                                   playRequest = PlayRequest(resolution: nuvio.resolution(for: item))
                               },
                               onFocusKey: heroFocus)
        }
    }

    /// The old mirror EN block, unchanged but for its place:
    /// below the addon sections, as the fallback pool.
    @ViewBuilder
    private var oldENBlock: some View {
        if theme.id.isDesign {
            // 1.7.4 (Round 1 review B-1): the design rail shell.
            TVDesignENChannelRail(channels: enChannels,
                                  onSelect: { ch in
                                      playRequest = PlayRequest(resolution: store.resolution(for: ch))
                                  },
                                  onFocusKey: heroFocus)
        } else if theme.id.isMU {
            // 1.7.1 (table H8): the MU rail shell for the old block.
            TVMUENChannelRail(channels: enChannels,
                              onSelect: { ch in
                                  playRequest = PlayRequest(resolution: store.resolution(for: ch))
                              },
                              onFocusKey: heroFocus)
        } else {
            TVENChannelRail(channels: enChannels,
                            onSelect: { ch in
                                playRequest = PlayRequest(resolution: store.resolution(for: ch))
                            },
                            onFocusKey: heroFocus)
        }
    }

    // MARK: - Hero

    /// 1.5.0 (owner redesign ruling, 2026-11-21): the hero is
    /// SLIM and SCORE-ONLY. 1.4.9's full cluster hero failed
    /// his device test — the panel still ghosted on match
    /// swaps and its 572 pt ate the first rail's tiles — so
    /// the ruling shrinks the panel to the score essentials:
    /// the status badge, the fixture headline (team names),
    /// the big score digits, and the "Xem ngay" pill. Scorer
    /// lists and the league · group · source meta line are
    /// GONE from the hero; the full match info lives in the
    /// link board's header now (TVMatchBoardView, spec
    /// amendment 2026-11-21). The 1.4.9 frame discipline is
    /// unchanged: ONE fixed frame for every hero kind and
    /// state, every region a fixed-height slot, a kind change
    /// a value change in an unchanging structure, the nil
    /// hero the same frame unfocusable.
    ///
    /// Slots (line ≈ 1.24 × size, the house convention):
    /// badge 40 (21 pt + its vertical padding) + headline 114
    /// (46 pt × 2 lines) + score slot 86 (the 69-pt digits'
    /// line — digits or empty, never the event columns) +
    /// "Xem ngay" 54 (24 pt + padding) + the column's three
    /// 12-pt spacings 36 = 330. Panel = 330 + 2×18 vertical
    /// padding = 366 (was 572). The vertical budget this buys
    /// is stated at scrollBody: the first rail's tiles now
    /// stand FULLY inside the resting viewport.
    private static let heroColumnHeight: CGFloat = 330

    /// 1.4.9 (FL-360) slot discipline, kept at the slim
    /// hero's sizes: each region holds its height in EVERY
    /// state — content fills its slot or the slot stays
    /// empty, so nothing resizes and nothing rides, on focus
    /// moves, hero-kind changes, or the 60 s poll.
    private static let heroBadgeSlotHeight: CGFloat = 40
    private static let heroHeadlineSlotHeight: CGFloat = 114
    private static let heroScoreSlotHeight: CGFloat = 86

    /// 1.4.9 (FL-360): the hero's content as DATA. In 1.4.8
    /// three DIFFERENT view trees (fixtureHero / englishHero /
    /// nuvioHero) rendered the three hero kinds, so a focus
    /// move that changed the hero's KIND replaced the whole
    /// tree — the owner's 1.4.8 clip shows the two heroes
    /// drawn over each other mid-swap, text colliding, two
    /// "Xem ngay" buttons stacked. Now every kind is reduced
    /// to this one model and rendered by the ONE hero frame
    /// below: a kind change is a value change inside an
    /// unchanging structure, so SwiftUI updates the content
    /// in place — there is no second tree to ghost with.
    private struct HeroModel {
        var badgeText: String
        var badgeColor: Color
        var headline: String
        var scoreHome: Int? = nil
        var scoreAway: Int? = nil
        var art: HeroArt
        var focusKey: String

        /// The no-hero shell (heroItem == nil while the tab
        /// body renders): every slot empty, so the panel holds
        /// its full 366 pt instead of collapsing to the 0 pt
        /// EmptyView 1.4.8 rendered — the audit's S-5 case
        /// (a folded league tab whose fixtures are empty but
        /// whose addon rails exist).
        static let empty = HeroModel(badgeText: "", badgeColor: TVPalette.tealFill,
                                     headline: "",
                                     art: .soccer, focusKey: "")
    }

    /// The hero's art slot content: every variant renders
    /// inside the SAME 440×168 box, so a crest pair, a channel
    /// logo and a placeholder occupy identical geometry — in
    /// 1.4.8 the variants carried different boxes and the art
    /// drifted/clipped while a focused match's data loaded
    /// (the owner's clip: crests + "VS" floating mid-panel,
    /// the panel mostly empty).
    private enum HeroArt {
        case crests(URL?, URL?)
        case logo(Channel)
        case tvGlyph
        case soccer
    }

    @ViewBuilder
    private var heroPanel: some View {
        switch heroItem {
        case .fixture(let entry):
            heroPanelView(fixtureHeroModel(entry)) { play(entry) }
        case .english(let ch):
            heroPanelView(englishHeroModel(ch)) {
                playRequest = PlayRequest(resolution: store.resolution(for: ch))
            }
        case .nuvio(let item):
            heroPanelView(nuvioHeroModel(item)) {
                playRequest = PlayRequest(resolution: nuvio.resolution(for: item))
            }
        case nil:
            heroPanelView(.empty, action: nil)
        }
    }

    private func fixtureHeroModel(_ entry: TVFixtureEntry) -> HeroModel {
        let badge = heroBadgeInfo(bucket: store.effectiveBucket(of: entry.channel),
                                  channel: entry.channel, state: entry.state)
        // The 1.4.4 art rule, unchanged: the entry's
        // displayCrests pair when either side resolved, else
        // the channel logo, else the placeholder.
        let art: HeroArt
        let ch = entry.channel
        if let pair = entry.displayCrests, pair.0 != nil || pair.1 != nil {
            art = .crests(pair.0, pair.1)
        } else if ch.logoURL != nil {
            art = .logo(ch)
        } else {
            art = .soccer
        }
        var model = HeroModel(badgeText: badge.text, badgeColor: badge.color,
                              headline: entry.headline,
                              art: art, focusKey: "hero:" + entry.id)
        if let state = entry.state,
           let home = state.scoreHome, let away = state.scoreAway {
            model.scoreHome = home
            model.scoreAway = away
        }
        return model
    }

    private func englishHeroModel(_ ch: Channel) -> HeroModel {
        HeroModel(badgeText: "🌍 BLV TIẾNG ANH · KÊNH 24/7",
                  badgeColor: theme.selectedFill,
                  headline: TVEnglish.displayName(ch),
                  art: ch.logoURL != nil ? .logo(ch) : .tvGlyph,
                  focusKey: "heroEN:" + ch.url)
    }

    private func nuvioHeroModel(_ item: NuvioItem) -> HeroModel {
        // The addon's art rule, unchanged: crest-vs-crest for
        // events with teams (the addon's own badges), the
        // channel art for 24/7 channels, else the placeholder.
        let art: HeroArt
        if item.teams != nil {
            art = .crests(item.team1Logo.flatMap(URL.init(string:)),
                          item.team2Logo.flatMap(URL.init(string:)))
        } else if !item.poster.isEmpty {
            art = .logo(item.displayChannel)
        } else {
            art = .soccer
        }
        return HeroModel(badgeText: nuvioHeroBadge(item),
                         badgeColor: nuvioHeroBadgeColor(item),
                         headline: item.headline,
                         art: art, focusKey: "heroNV:" + item.id)
    }

    /// THE hero frame (1.4.9) — the only hero view tree in
    /// the app. With an action it is the focusable hero
    /// button; without one (the nil shell) it is the same
    /// frame, unfocusable, holding the panel's place — with
    /// `chrome: false`, so its slots render EMPTY (an empty
    /// badge Text would still paint its padded capsule, and
    /// a content-less panel must not show a call-to-action
    /// pill; the slot frames hold the geometry either way).
    @ViewBuilder
    private func heroPanelView(_ model: HeroModel, action: (() -> Void)?) -> some View {
        if let action {
            Button(action: action) {
                heroLabel(model, chrome: true)
            }
            .tvCardButton()
            .focused($focusedKey, equals: model.focusKey)
        } else {
            heroLabel(model, chrome: false)
        }
    }

    private func heroLabel(_ model: HeroModel, chrome: Bool) -> some View {
        HStack(alignment: .center, spacing: 36) {
            VStack(alignment: .leading, spacing: 12) {
                Group {
                    if chrome {
                        Text(model.badgeText)
                            .font(.system(size: 21, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(model.badgeColor))
                    } else {
                        Color.clear
                    }
                }
                .frame(height: Self.heroBadgeSlotHeight, alignment: .topLeading)
                Text(model.headline)
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(height: Self.heroHeadlineSlotHeight, alignment: .topLeading)
                // The score slot (1.5.0): the DIGITS ONLY, at
                // their one line height in every state — the
                // digits fill it or it stays empty. The event
                // columns the 1.4.7–1.4.9 hero carried under
                // the digits live in the link board's header
                // now (the owner's redesign ruling: the hero
                // records the score, the board carries the
                // info). "Xem ngay" below therefore sits at
                // ONE Y for every hero.
                Group {
                    if let home = model.scoreHome, let away = model.scoreAway {
                        TVScoreDigits(home: home, away: away)
                    } else {
                        Color.clear
                    }
                }
                .frame(height: Self.heroScoreSlotHeight, alignment: .topLeading)
                // The "Xem ngay" pill is the column's LAST
                // element: in the shell it is omitted entirely
                // (nothing below it can move — the column is
                // fixed-height and top-aligned).
                if chrome {
                    HStack(spacing: 10) {
                        Text("Xem ngay")
                            .font(.system(size: 24, weight: .semibold))
                        Image(systemName: "play.fill")
                            .font(.system(size: 19))
                    }
                    .foregroundStyle(theme.focusRing)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 10)
                    .overlay(Capsule().strokeBorder(theme.focusRing, lineWidth: 2.5))
                    .padding(.top, 4)
                }
            }
            // Fixed widths on purpose: with a maxWidth-.infinity
            // text column the crest pair was pushed past the
            // panel's trailing edge and the second crest was cut
            // off on the owner's TV (v1.2.3 live test). 1.4.8:
            // the height is fixed too (heroColumnHeight) — the
            // score/events block lives INSIDE this column, so
            // it can never widen the column or push the art.
            .frame(width: 1020, height: Self.heroColumnHeight,
                   alignment: .topLeading)
            heroArtView(model.art)
        }
        .padding(.horizontal, 24)
        // 1.5.1 (FL-360): vertical padding 18 → 10 and
        // horizontal 40 → 24 — the hero's own margins are
        // part of the reclaim; the content column (330) and
        // the art are untouched, so the panel is 350.
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(tvHeroBackground(focused: focusedKey == model.focusKey, theme: theme))
    }

    @ViewBuilder
    private func heroArtView(_ art: HeroArt) -> some View {
        Group {
            switch art {
            case .crests(let home, let away):
                HStack(spacing: 22) {
                    TVCrestImage(url: home, size: 160)
                    Text("VS")
                        .font(.system(size: 30, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.85))
                    TVCrestImage(url: away, size: 160)
                }
            case .logo(let ch):
                TVChannelLogo(channel: ch, height: 168)
            case .tvGlyph:
                Image(systemName: "tv")
                    .font(.system(size: 110))
                    .foregroundStyle(.white.opacity(0.35))
            case .soccer:
                TVSoccerPlaceholder(size: 110)
            }
        }
        .frame(width: 440, height: 168)
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
        item.kind == .liveEvent ? theme.liveRed : theme.selectedFill
    }

    /// The fixture hero's badge with the matched state consulted
    /// (spec §1.4/§1.5): source minute verbatim, HT wording, or
    /// FT + final score — never PHÁT LẠI for a known FT.
    /// 1.4.9: returns the badge as DATA (text + colour) for the
    /// one hero frame's badge slot; the computation is the
    /// 1.4.8 one, unchanged.
    private func heroBadgeInfo(bucket: Int, channel ch: Channel,
                               state: MatchState?) -> (text: String, color: Color) {
        let now = Date()
        let text: String
        let color: Color
        if let state, state.status == .ft {
            text = "FT" + (state.scoreText.map { " · " + $0 } ?? "")
            color = Color(red: 0.38, green: 0.38, blue: 0.42)
        } else if let state, state.status == .live || state.status == .ht {
            text = "🔴 ĐANG ĐÁ · " + (state.badgeText ?? "")
            color = theme.liveRed
        } else if bucket == 0 {
            text = "🔴 ĐANG ĐÁ · " + (MatchStateStore.computedBadge(kickoff: ch.kickoff ?? now, now: now)
                ?? "\(TVKickoffFormat.liveMinute(of: ch.kickoff ?? now, now: now))'")
            color = theme.liveRed
        } else if let kickoff = ch.kickoff, kickoff > now {
            text = "⏰ " + TVKickoffFormat.timeDay.string(from: kickoff)
            color = theme.selectedFill
        } else if ch.kickoff != nil {
            text = "↺ PHÁT LẠI"
            color = Color(red: 0.38, green: 0.38, blue: 0.42)
        } else {
            text = "📺 " + ch.group
            color = theme.selectedFill
        }
        return (text, color)
    }

    // MARK: - Rails and cards
    //
    // KH-2: thin call sites over TVFixtureRail (TVMatchViews),
    // which owns its own focus state; the titles, the card
    // choice (live → board, else featured/match card) and the
    // tap action are exactly as before.

    @ViewBuilder
    private func featuredRail(_ items: [TVFixtureEntry]) -> some View {
        if theme.id.isMU {
            // 1.7.1 (table H7): under MU there is no featured
            // rail — the featured entries render inside the MU
            // live rail (see scrollBody). Classic arm verbatim.
            EmptyView()
        } else {
            TVFixtureRail(title: "⭐  TRẬN NỔI BẬT", entries: items, style: .featured,
                          onSelect: { play($0) }, onFocusKey: heroFocus)
        }
    }

    /// 1.7.1: `muNote` is the MU rail header's right-aligned
    /// note (table H4) — only the SẮP ĐÁ call in scrollBody
    /// passes one (the device date). The classic arm ignores it.
    @ViewBuilder
    private func railSection(_ title: String, _ items: [TVFixtureEntry],
                             muNote: String? = nil) -> some View {
        if theme.id.isDesign {
            // 1.7.4: design rail (muNote is a Wally-header
            // datum; the design header carries no note).
            TVDesignFixtureRail(title: title, entries: items,
                                keyFor: { "rail:" + $0.id },
                                onSelect: play, onFocusKey: heroFocus)
        } else if theme.id.isMU {
            TVMUFixtureRail(title: title, entries: items, note: muNote,
                            keyFor: { "rail:" + $0.id },
                            onSelect: play, onFocusKey: heroFocus)
        } else {
            TVFixtureRail(title: title, entries: items, style: .standard,
                          onSelect: { play($0) }, onFocusKey: heroFocus)
        }
    }

    /// 1.5.1 (FL-360): a section label (cup competition,
    /// division) folded INTO the first rail's title — the
    /// stacked two-title arrangement (section title + rail
    /// title, ≈86 pt) starved the first rail of exactly the
    /// points the reclaim won back. Every word is preserved;
    /// the label simply rides the rail title row.
    @ViewBuilder
    private func railSection(_ title: String, _ items: [TVFixtureEntry],
                             sectionLabel: String) -> some View {
        if theme.id.isDesign {
            TVDesignFixtureRail(title: sectionLabel + " · " + title, entries: items,
                                keyFor: { "rail:" + $0.id },
                                onSelect: play, onFocusKey: heroFocus)
        } else if theme.id.isMU {
            TVMUFixtureRail(title: sectionLabel + " · " + title, entries: items,
                            note: nil,
                            keyFor: { "rail:" + $0.id },
                            onSelect: play, onFocusKey: heroFocus)
        } else {
            TVFixtureRail(title: sectionLabel + " · " + title, entries: items,
                          style: .standard,
                          onSelect: { play($0) }, onFocusKey: heroFocus)
        }
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

/// The MU design text tab (1.7.1, table H3): plain 25 pt text,
/// no capsule. Selected = white semibold label, a red dot in a
/// FIXED 8 pt slot before it, a gold outline, and a red
/// underline bar drawn INSIDE the face's bounds. The face has
/// a FIXED height of 50 in every state (selected or not,
/// focused or not); the underline (56×4) sits in an
/// overlay(alignment: .bottom) with 5 pt bottom padding, fully
/// inside the frame, so it never paints over the action-pill
/// row beneath (FL-001 outset fault, fixed in the 1.7.1 fix
/// round) and never moves the bar's other pills (FL-360).
/// Unselected = leagueTx medium, no outline. Focused = maroon
/// fill + gold outline 2.5 pt — this face is the tab's ONE
/// focus owner under MU. The pill's width is reserved at the
/// BOLD width in both states (a hidden bold copy sizes the
/// ZStack), so selection never changes the tab's width.
private struct TVMUTabFace: View {
    let title: String
    let selected: Bool
    let focused: Bool
    let theme: TVThemeTokens

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                Circle()
                    .frame(width: 8, height: 8)
                    .opacity(0)
                Text(title)
                    .font(.system(size: 25, weight: .bold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .opacity(0)
            HStack(spacing: 8) {
                Circle()
                    .fill(theme.unitedRed)
                    .frame(width: 8, height: 8)
                    .opacity(selected ? 1 : 0)
                Text(title)
                    .font(.system(size: 25, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(selected ? .white : theme.leagueTx)
            }
        }
        .padding(.horizontal, 16)
        // FIXED height 50 in BOTH states (selected or not,
        // focused or not): the label content is centred in
        // this frame and the underline overlays its bottom
        // edge from INSIDE — nothing paints outside the
        // face's bounds.
        .frame(height: 50)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(focused ? theme.tileFocusedBG : .clear)
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(focused ? theme.focusRing
                                          : (selected ? theme.focusRing : .clear),
                                  lineWidth: focused ? 2.5 : 1.5)
            }
        }
        .overlay(alignment: .bottom) {
            if selected {
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.unitedRed)
                    .frame(width: 56, height: 4)
                    .padding(.bottom, 5)
            }
        }
    }
}

/// The MU wallpaper layer (1.7.0): ONE photo, decoded
/// DOWNSAMPLED (some wallpapers are 8002 px wide — a full-size
/// decode would be a memory spike for a background), stretched
/// full-bleed, with the design's heavy dark scrim over it
/// (black .55 top → .25 mid → .75 bottom) so every rail and
/// pill above it stays readable. Loads in .task(id:) — no work
/// on any focus path (FL-128).
private struct TVWallpaperView: View {
    let url: URL
    /// 1.7.6 (FL-438): the settled image and the one fading
    /// in over it. Until now the decoded image was assigned
    /// the moment its fetch landed — a HARD CUT every swap,
    /// the board's visible "jump" in the owner's session
    /// log. A swap now crossfades: the new photo fades in
    /// over the settled one, then takes its place.
    @State private var image: UIImage?
    @State private var fadingImage: UIImage?
    @State private var fadeIn = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black.opacity(0.55),
                         Color.black.opacity(0.25),
                         Color.black.opacity(0.75)],
                startPoint: .top, endPoint: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 1.7.6 (FL-439): the photo is the scrim stack's
        // BACKGROUND — sized BY this view's frame, so its
        // bitmap (whatever its aspect) can never negotiate
        // this view's size. The crossfade pair lives here
        // too: settled photo under, incoming photo fading
        // over it, both filling the same fixed frame.
        .background {
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
                if let fadingImage {
                    Image(uiImage: fadingImage)
                        .resizable()
                        .scaledToFill()
                        .opacity(fadeIn ? 1 : 0)
                }
            }
        }
        .clipped()
        .task(id: url) {
            // Gate Round 1 (Lens A): this task owns the
            // fade state from its first line. A superseded
            // task's in-flight fade is cleared HERE, so no
            // exit below (failed load, a same-instance
            // cache hit on a reverted URL, cancellation)
            // can leave a stale photo hanging over the
            // settled one — the early returns used to
            // strand it at full opacity indefinitely.
            fadingImage = nil
            fadeIn = false
            let loaded = await TVImageCache.loadDownsampled(url, maxPixel: 1920)
            guard !Task.isCancelled, let loaded else { return }
            guard let settled = image else {
                // First photo on this surface: nothing
                // under it to fade from — it just lands.
                image = loaded
                return
            }
            if loaded === settled { return }
            fadingImage = loaded
            fadeIn = false
            withAnimation(.easeInOut(duration: 0.5)) { fadeIn = true }
            try? await Task.sleep(for: .milliseconds(550))
            // A newer swap may have superseded this one
            // while the fade ran; only settle when this
            // run's photo is still the incoming one.
            guard !Task.isCancelled, fadingImage === loaded else { return }
            image = loaded
            fadingImage = nil
            fadeIn = false
        }
    }
}
