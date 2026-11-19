import SwiftUI

/// Đá Banh TV home — designed FOR the television, not ported from
/// the phone. The composition is the TV app's own, built and tuned
/// on the owner's TV since v1.2: a fixed cinematic hero whose
/// content follows the focused card, pill tabs, and horizontal
/// rails you drive with the remote from the sofa — 60pt overscan
/// margins, nothing important under 20pt, and a cyan focus ring
/// thick enough to read across the room. Football identity only —
/// deep-teal palette and crest-first cards, deliberately unlike
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
    @State private var heroItem: HeroItem?
    @FocusState private var focusedKey: String?

    /// selectedLeague value meaning "the EN section". The store's
    /// own sentinels are 0 (Hot) and -1 (Trực tiếp); -2 is free and
    /// only this view ever writes or reads it (each app owns its
    /// store instance, so the phone never sees it).
    private static let enTabValue = -2

    private struct PlayRequest: Identifiable {
        let id = UUID()
        let resolution: MatchResolution
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

    /// The tab's fixtures with the owner's Manchester United pin
    /// applied (2026-11-19): a live or upcoming MU fixture leads
    /// the list — and with it the hero default and its bucket
    /// rail — while every other entry keeps the store's order
    /// exactly. See TVFixtureEntry.pinnedFirst.
    private var entries: [TVFixtureEntry] {
        TVFixtureEntry.pinnedFirst(TVFixtureEntry.group(tabChannels))
    }

    /// Featured rail entries: the first live fixtures on the
    /// Trực tiếp tab (which the store fills with live matches only,
    /// and opens on whenever anything is live) — with one addition
    /// for the pin: when MU is only UPCOMING, this tab's own list
    /// (live matches only) does not carry the fixture at all, so
    /// the pinned MU entry is prepended from the wider loaded
    /// data and the hero + featured rail still lead with it, as
    /// the owner's "MU sắp đá hoặc đang đá thì luôn nằm đầu tiên"
    /// requires. The live fixture displaced from the rail's tenth
    /// slot is not lost: the ĐANG ĐÁ rail below excludes only
    /// featured ids, so it reappears there.
    private var featuredEntries: [TVFixtureEntry] {
        guard store.selectedLeague == PlaylistStore.liveTabValue else { return [] }
        if entries.contains(where: { $0.isManchesterUnited }) {
            return Array(entries.prefix(10))
        }
        if let pin = muPinEntry {
            return Array(([pin] + entries).prefix(10))
        }
        return Array(entries.prefix(10))
    }

    /// The best Manchester United fixture in everything the store
    /// has loaded — live first, then nearest kickoff — or nil
    /// when MU has no live or upcoming match in the data. Built
    /// from the lists already in memory (the same channels +
    /// hotChannels merge PlaylistStore.liveChannels uses, EN
    /// block excluded, deduplicated by URL): the pin never costs
    /// an extra fetch.
    private var muPinEntry: TVFixtureEntry? {
        var seen = Set<String>()
        var pool: [Channel] = []
        for ch in store.channels + store.hotChannels where !TVEnglish.isEnglish(ch) {
            if seen.insert(ch.url).inserted { pool.append(ch) }
        }
        return TVFixtureEntry.manchesterUnitedPin(in: TVFixtureEntry.group(pool))
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
        case .england, .other: return nil
        }
    }

    /// The selected fold league's addon channels: its league
    /// fold's 24/7 set from the Nuvio store.
    private var leagueAddonChannels: [NuvioItem] {
        guard let league = foldLeague else { return [] }
        return nuvio.leagueChannels[league.rawValue] ?? []
    }

    /// The selected fold league's addon fixtures: the store's
    /// live / upcoming events whose headline the shared
    /// classifier files under this league — the same rule the
    /// mirror fixtures follow, so a live or hot match of the
    /// league leads this tab whichever source carries it
    /// (owner's grouping rule, 2026-11-19 12:59 CST).
    /// Cross-border cup fixtures keep the first-checked-league
    /// convention: Bayern vs Arsenal classifies Anh and stays
    /// out of the Đức tab, exactly as it does in the mirror
    /// lists.
    private var leagueLiveEvents: [NuvioItem] {
        guard let league = foldLeague else { return [] }
        return nuvio.liveEvents.filter {
            LeagueClassifier.leagueRank(of: $0.headline) == league.rawValue
        }
    }

    private var leagueUpcomingEvents: [NuvioItem] {
        guard let league = foldLeague else { return [] }
        return nuvio.upcomingEvents.filter {
            LeagueClassifier.leagueRank(of: $0.headline) == league.rawValue
        }
    }

    /// True when the selected league tab has any addon
    /// content to show.
    private var hasLeagueAddon: Bool {
        !leagueAddonChannels.isEmpty || !leagueLiveEvents.isEmpty || !leagueUpcomingEvents.isEmpty
    }

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
        case .england, .other:
            return ("📺  NUVIO · KÊNH 24/7",
                    "Kênh từ addon Nuvio — phát liên tục.",
                    "Kênh Nuvio",
                    "Kênh Nuvio · phát liên tục")
        }
    }

    /// The English block, merged from both published lists and
    /// deduplicated by URL (in practice it lives in the main list).
    private var enChannels: [Channel] {
        var seen = Set<String>()
        var out: [Channel] = []
        for ch in store.channels + store.hotChannels where TVEnglish.isEnglish(ch) {
            if seen.insert(ch.url).inserted { out.append(ch) }
        }
        return out
    }

    var body: some View {
        ZStack {
            background
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
            .padding(.horizontal, 60)
            .padding(.top, 40)
            .padding(.bottom, 28)
        }
        .task { await store.start() }
        .task { await nuvio.load() }
        .task(id: muPinEntry?.id) {
            // Pre-resolve the pinned Manchester United fixture
            // (2026-11-19): when a pin exists, its sources are
            // verified into the store's resolve cache at open, so
            // tapping the priority match starts from a verified
            // ladder with no resolve wait. The hook is keyed on
            // the pin's identity — a new pin supersedes the old
            // pre-resolve inside the store, and the pin vanishing
            // cancels it; nothing is pre-resolved when no MU
            // fixture is pinned.
            if let pin = muPinEntry {
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
        .onChange(of: focusedKey) { _, key in
            guard let key else { return }
            if let item = heroLookup[key] { heroItem = item }
        }
        .onChange(of: store.selectedLeague) { _, _ in syncHero() }
        .onChange(of: store.channels) { _, _ in syncHero() }
        .onChange(of: store.hotChannels) { _, _ in syncHero() }
        .onChange(of: nuvio.liveEvents) { _, _ in syncHero() }
        .onChange(of: nuvio.upcomingEvents) { _, _ in syncHero() }
        .onChange(of: nuvio.channels) { _, _ in syncHero() }
        .onChange(of: nuvio.leagueChannels) { _, _ in syncHero() }
    }

    /// Focus key → hero content, for every focusable card on screen.
    private var heroLookup: [String: HeroItem] {
        var map: [String: HeroItem] = [:]
        for entry in featuredEntries { map["feat:" + entry.id] = .fixture(entry) }
        for entry in entries { map["rail:" + entry.id] = .fixture(entry) }
        for ch in enChannels { map["en:" + ch.url] = .english(ch) }
        for item in nuvio.liveEvents + nuvio.upcomingEvents + nuvio.channels {
            map["nv:" + item.id] = .nuvio(item)
        }
        for items in nuvio.leagueChannels.values {
            for item in items { map["nv:" + item.id] = .nuvio(item) }
        }
        return map
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
        LinearGradient(
            colors: [Color(red: 0.02, green: 0.22, blue: 0.19),
                     Color(red: 0.01, green: 0.11, blue: 0.11),
                     Color(red: 0.00, green: 0.05, blue: 0.06)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 7) {
                Text("TRỰC TIẾP BÓNG ĐÁ")
                    .font(.system(size: 23, weight: .semibold))
                    .tracking(6)
                    .foregroundStyle(Color(red: 0.45, green: 0.90, blue: 0.83))
                Text("Đá Banh TV")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(.white)
                RoundedRectangle(cornerRadius: 3)
                    .fill(TVPalette.cyan)
                    .frame(width: 120, height: 6)
            }
            Spacer()
        }
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
        // The EN pill joins row two for the same reason: row one is
        // already full, and row two sits directly under the pills,
        // one remote-press away.
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                tabPill(title: "🔴 Trực tiếp", value: PlaylistStore.liveTabValue)
                tabPill(title: "🔥 Hot", value: PlaylistStore.hotTabValue)
                ForEach(League.allCases) { league in
                    tabPill(title: league.name, value: league.rawValue)
                }
                Spacer()
                Text(countText)
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            HStack(spacing: 16) {
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
                    .font(.system(size: 24, weight: .medium))
                    .padding(.horizontal, 26)
                    .padding(.vertical, 12)
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
                    .font(.system(size: 24, weight: .medium))
                    .padding(.horizontal, 26)
                    .padding(.vertical, 12)
                    .background(TVPillFace(focused: focusedKey == "hdr:check",
                                           selected: false))
                }
                .tvCardButton()
                .focused($focusedKey, equals: "hdr:check")
                .disabled(store.isLoading || store.isValidating)
                if !enChannels.isEmpty || nuvio.hasContent {
                    tabPill(title: "🌍 EN · BLV Anh", value: Self.enTabValue)
                }
            }
        }
    }

    private func tabPill(title: String, value: Int) -> some View {
        let selected = store.selectedLeague == value
        return Button {
            store.selectedLeague = value
        } label: {
            Text(title)
                .font(.system(size: 26, weight: selected ? .bold : .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 30)
                .padding(.vertical, 14)
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
        return "Chưa có trận nào trong mục này."
    }

    // MARK: - Content

    @ViewBuilder
    private var scrollBody: some View {
        if isENTab {
            enBody
        } else if entries.isEmpty && featuredEntries.isEmpty
                    && !hasLeagueAddon {
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
        } else {
            let now = Date()
            let featuredIDs = Set(featuredEntries.map(\.id))
            let live = entries.filter {
                LeagueClassifier.bucket(of: $0.channel, now: now) == 0 && !featuredIDs.contains($0.id)
            }
            let upcoming = entries.filter {
                let b = LeagueClassifier.bucket(of: $0.channel, now: now)
                return b == 1 || b == 2
            }
            let rest = entries.filter { LeagueClassifier.bucket(of: $0.channel, now: now) == 3 }
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

    private var footerRow: some View {
        HStack {
            Spacer()
            Text("Đá Banh TV v1.4.0")
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

    private func nuvioEventRail(_ title: String, _ items: [NuvioItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 28) {
                    ForEach(items) { item in
                        Button {
                            playRequest = PlayRequest(resolution: nuvio.resolution(for: item))
                        } label: {
                            NuvioEventCard(item: item, focused: focusedKey == "nv:" + item.id)
                        }
                        .tvCardButton()
                        .focused($focusedKey, equals: "nv:" + item.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 16)
            }
        }
    }

    private func nuvioChannelRail(_ items: [NuvioItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("📺  NUVIO · KÊNH 24/7")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
            Text("Kênh tiếng Anh từ addon Nuvio — phát liên tục.")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.6))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 28) {
                    ForEach(items) { item in
                        Button {
                            playRequest = PlayRequest(resolution: nuvio.resolution(for: item))
                        } label: {
                            NuvioChannelCard(item: item, focused: focusedKey == "nv:" + item.id)
                        }
                        .tvCardButton()
                        .focused($focusedKey, equals: "nv:" + item.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 16)
            }
        }
    }

    /// A folded league tab's addon channel rail (owner,
    /// 2026-11-19 12:58 CST): the league fold's 24/7 channels
    /// below the tab's fixtures — the nuvioChannelRail shape,
    /// with the league's own copy and the card's own play line.
    private func leagueChannelRail(_ items: [NuvioItem], league: League) -> some View {
        let copy = leagueChannelCopy(league)
        return VStack(alignment: .leading, spacing: 4) {
            Text(copy.railTitle)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
            Text(copy.railSubtitle)
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.6))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 28) {
                    ForEach(items) { item in
                        Button {
                            playRequest = PlayRequest(resolution: nuvio.resolution(for: item))
                        } label: {
                            NuvioChannelCard(item: item, focused: focusedKey == "nv:" + item.id,
                                             detailPrefix: copy.cardPrefix)
                        }
                        .tvCardButton()
                        .focused($focusedKey, equals: "nv:" + item.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 16)
            }
        }
    }

    /// The old mirror EN block, unchanged but for its place:
    /// below the addon sections, as the fallback pool.
    private var oldENBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("🌍  EN · BLV Anh — KÊNH BLV TIẾNG ANH")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
            Text("Kênh 24/7 bình luận tiếng Anh — nguồn dự phòng khi nguồn Việt chậm hoặc chết.")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.6))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 28) {
                    ForEach(enChannels) { ch in
                        Button {
                            playRequest = PlayRequest(resolution: store.resolution(for: ch))
                        } label: {
                            TVENChannelCard(
                                channel: ch,
                                focused: focusedKey == "en:" + ch.url)
                        }
                        .tvCardButton()
                        .focused($focusedKey, equals: "en:" + ch.url)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 16)
            }
        }
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
            .background(
                RoundedRectangle(cornerRadius: 26)
                    .fill(LinearGradient(
                        colors: [Color.white.opacity(0.13), Color.white.opacity(0.05)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(
                        RoundedRectangle(cornerRadius: 26)
                            .strokeBorder(heroFocused ? TVPalette.cyan : Color.white.opacity(0.20),
                                          lineWidth: heroFocused ? 4 : 1.5)))
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
                    heroBadge(entry.channel)
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
            .background(
                RoundedRectangle(cornerRadius: 26)
                    .fill(LinearGradient(
                        colors: [Color.white.opacity(0.13), Color.white.opacity(0.05)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(
                        RoundedRectangle(cornerRadius: 26)
                            .strokeBorder(heroFocused ? TVPalette.cyan : Color.white.opacity(0.20),
                                          lineWidth: heroFocused ? 4 : 1.5)))
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
            .background(
                RoundedRectangle(cornerRadius: 26)
                    .fill(LinearGradient(
                        colors: [Color.white.opacity(0.13), Color.white.opacity(0.05)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(
                        RoundedRectangle(cornerRadius: 26)
                            .strokeBorder(heroFocused ? TVPalette.cyan : Color.white.opacity(0.20),
                                          lineWidth: heroFocused ? 4 : 1.5)))
        }
        .tvCardButton()
        .focused($focusedKey, equals: "heroEN:" + ch.url)
    }

    private func heroBadge(_ ch: Channel) -> some View {
        let now = Date()
        let bucket = LeagueClassifier.bucket(of: ch, now: now)
        let text: String
        let color: Color
        if bucket == 0 {
            text = "🔴 ĐANG ĐÁ · \(TVKickoffFormat.liveMinute(of: ch.kickoff ?? now, now: now))'"
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

    private func featuredRail(_ items: [TVFixtureEntry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("⭐  TRẬN NỔI BẬT")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 28) {
                    ForEach(items) { entry in
                        Button {
                            play(entry)
                        } label: {
                            TVFeaturedCard(entry: entry, focused: focusedKey == "feat:" + entry.id)
                        }
                        .tvCardButton()
                        .focused($focusedKey, equals: "feat:" + entry.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 16)
            }
        }
    }

    private func railSection(_ title: String, _ items: [TVFixtureEntry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 28) {
                    ForEach(items) { entry in
                        Button {
                            play(entry)
                        } label: {
                            TVMatchCard(entry: entry, focused: focusedKey == "rail:" + entry.id)
                        }
                        .tvCardButton()
                        .focused($focusedKey, equals: "rail:" + entry.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 16)
            }
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
    private func play(_ entry: TVFixtureEntry) {
        playRequest = PlayRequest(resolution: store.resolution(for: entry.channel))
    }
}
