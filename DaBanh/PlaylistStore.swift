import Foundation

/// Playlist loading, mirroring the Android app's behaviour:
/// - On launch: show the disk cache immediately (if present and > 100
///   bytes), then fetch the remote playlist.
/// - A successful fetch replaces the list AND rewrites the cache.
/// - A failed fetch keeps the current list; with nothing loaded yet it
///   surfaces a retry message instead.
/// - Auto-refresh: every 15 minutes — a foreground timer plus a
///   refresh-on-foreground when the data is older than 15 minutes
///   (the Android app does the staleness check in onResume).
/// - First load only: open on the Hot tab when it has a live match,
///   else the highest-priority league with a live match right now;
///   fall back to Ngoại Hạng Anh (Android setData).
///
/// Two sources are fetched on every refresh, GitHub first (owner's
/// rule, 2026-11-13 — all of his apps read from his own GitHub):
/// - Primary: the mirror in the owner's GitHub repo, whose workflow
///   auto-scans and republishes the whole list (origin leagues +
///   scraped extras + the 🔥 Hot group) every 30 minutes and keeps
///   the last good file if the origin dies.
/// - Fallback: the origin site (thtt.pages.dev), used only when
///   GitHub cannot be reached at all. It has no 🔥 Hot group, so the
///   Hot tab then keeps whatever it already had.
@MainActor
final class PlaylistStore: ObservableObject {

    /// Origin site — since 2026-11-13 only the fallback, used when
    /// the GitHub mirror cannot be reached at all.
    static let playlistURL = URL(string: "https://thtt.pages.dev/tttt.m3u")!
    /// The PRIMARY source (owner's own GitHub repo): a scheduled
    /// workflow auto-scans and republishes the full playlist there
    /// every 30 minutes, and a failed scan never overwrites the last
    /// good file — so this link is both fresher and harder to kill
    /// than the origin.
    static let backupPlaylistURL = URL(string: "https://raw.githubusercontent.com/zjoenguyenz/dabanh-playlist/main/tttt.m3u")!
    /// group-title the mirror's scraper gives its hot rail.
    static let hotGroupName = "🔥 Hot"
    /// selectedLeague value meaning "the Hot tab" (league rawValues
    /// are 1, 2, 3, 4, 5 and 9, so 0 is free).
    static let hotTabValue = 0
    /// selectedLeague value meaning "the Trực tiếp (live) tab" — every
    /// match in its live window right now, across all leagues and the
    /// Hot group. Added at the owner's request (2026-11-13): browsing
    /// league by league gave him no way to see at a glance what is
    /// live. The iOS UI does not render this tab yet; the tvOS UI does.
    static let liveTabValue = -1
    private static let autoRefreshInterval: TimeInterval = 15 * 60
    /// A mirror whose Updated stamp is older than this is treated as
    /// stale even when reachable (its workflow republishes every
    /// 30 minutes when healthy).
    private static let mirrorStaleThreshold: TimeInterval = 45 * 60

    @Published private(set) var channels: [Channel] = []
    @Published private(set) var hotChannels: [Channel] = []

    /// Unfiltered lists as parsed. The published lists above are these
    /// minus proven-dead links and minus .flv entries (AVPlayer cannot
    /// play FLV at all, so on Apple platforms they are dead weight;
    /// the Android app keeps them — ExoPlayer plays FLV fine).
    private var rawChannels: [Channel] = []
    private var rawHotChannels: [Channel] = []
    /// URLs proven unplayable FROM THIS DEVICE (see validateLinks).
    /// Persisted so a cold start opens already clean, and re-probed
    /// after every refresh so a revived link returns on its own.
    private var invalidURLs: Set<String> = []
    /// The mirror's EN block from the most recent successful mirror
    /// fetch (seeded from the mirror disk cache at launch). Kept
    /// separately so the EN merge below survives a mirror outage.
    private var lastMirrorEN: [Channel] = []
    private var validating = false
    /// Bumped when the crest map is swapped for a fresher remote copy,
    /// so crest-reading views re-render with the new badges.
    @Published private(set) var crestsRevision = 0
    /// Bumped when the wallpaper list is swapped for a fresher
    /// remote copy, so wallpaper-reading views re-render.
    @Published private(set) var wallpaperRevision = 0
    /// Live match states (1.4.1, plan §1): ESPN > FotMob >
    /// Flashscore > LiveScore > computed clock. Owned here; views read states
    /// through matchState(for:) / competition(for:), never the
    /// store directly. liveRevision bumps when states land so
    /// state-reading views re-render on the 60 s poll.
    let liveStore = MatchStateStore()
    @Published private(set) var liveRevision = 0
    @Published private(set) var isLoading = false
    /// True while a link-validation pass runs (automatic or manual);
    /// the "Kiểm tra link" button spins on it.
    @Published private(set) var isValidating = false
    @Published var statusMessage: String?
    @Published var selectedLeague: Int = League.england.rawValue

    private(set) var lastFetch: Date?
    private var loadedOnce = false
    private var didPickInitialTab = false
    private var fetching = false
    private var autoRefreshTask: Task<Void, Never>?

    private var cacheFileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("playlist.m3u")
    }

    private var mirrorCacheFileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mirror.m3u")
    }

    private var invalidFileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("invalid-urls.json")
    }

    private func loadInvalidSet() {
        guard let data = try? Data(contentsOf: invalidFileURL),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return }
        invalidURLs = Set(list)
    }

    private func saveInvalidSet() {
        let list = Array(invalidURLs)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: invalidFileURL, options: .atomic)
        }
    }

    var isStale: Bool {
        guard let lastFetch else { return true }
        return Date().timeIntervalSince(lastFetch) > Self.autoRefreshInterval
    }

    func channels(in league: League) -> [Channel] {
        channels.filter { $0.leagueRank == league.rawValue }
    }

    /// Every channel whose match is in its live window right now
    /// (classifier bucket 0), merged from the league lists and the Hot
    /// group, deduplicated by URL, in the standard live-first order.
    var liveChannels: [Channel] {
        let now = Date()
        var seen = Set<String>()
        var live: [Channel] = []
        for channel in channels + hotChannels {
            guard effectiveBucket(of: channel, now: now) == 0 else { continue }
            if seen.insert(channel.url).inserted {
                live.append(channel)
            }
        }
        return LeagueClassifier.sorted(live)
    }

    // MARK: - Lifecycle

    /// Called once from the root view's .task: cache first, remote second,
    /// then the 15-minute auto-refresh loop for as long as the app lives.
    func start() async {
        loadCache()
        scheduleValidation()
        // Live-state polling rides its own cadence (60 s live /
        // 15 min idle, plan §1.7) beside the 15-min playlist loop.
        liveStore.onChange = { [weak self] in self?.liveRevision += 1 }
        liveStore.start(fixturesProvider: { [weak self] in
            guard let self else { return [] }
            return self.channels + self.hotChannels
        })
        await refresh()
        // Crest coverage updates ride the same GitHub mirror as the
        // playlist: fetch once per launch, swap in if fresher.
        Task {
            if await Crests.refreshRemote() { crestsRevision += 1 }
        }
        Task {
            if await Wallpapers.refreshRemote() { wallpaperRevision += 1 }
        }
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.autoRefreshInterval))
                guard let self else { return }
                if self.isStale { await self.refresh() }
            }
        }
    }

    /// Android onResume rule: coming back to the app with a list older
    /// than 15 minutes triggers a refresh.
    func refreshIfStale() async {
        if loadedOnce && isStale { await refresh() }
    }

    // MARK: - Loading

    private func loadCache() {
        loadInvalidSet()
        // GitHub-first, same order as the live fetch: the mirror cache
        // is the main list (leagues + Hot + extras in one file).
        if let text = readCache(mirrorCacheFileURL) {
            let parsed = M3UParser.parse(text)
            if !parsed.isEmpty {
                noteMirrorEN(parsed)
                setData(parsed)
                setHot(parsed)
                DiagLog.write("playlist", "cache source=mirror channels=\(channels.count) hot=\(hotChannels.count)")
                return
            }
        }
        if let text = readCache(cacheFileURL) {
            let parsed = M3UParser.parse(text)
            if !parsed.isEmpty {
                setData(parsed)
                DiagLog.write("playlist", "cache source=origin channels=\(channels.count) hot=\(hotChannels.count)")
            }
        }
    }

    private func readCache(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count > 100 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func refresh() async {
        if fetching { return } // one fetch at a time, like Android
        fetching = true
        isLoading = true
        defer {
            fetching = false
            isLoading = false
        }
        do {
            // GitHub mirror first (the primary since 2026-11-13): one
            // file carries the leagues, the extras and the Hot group.
            let (data, parsed, text) = try await fetchPlaylist(from: Self.backupPlaylistURL)
            noteMirrorEN(parsed)
            // Freshness gate (root cause measured 2026-11-13): a
            // REACHABLE mirror can still be hours stale — its stamp
            // read 03:08 VN while the origin already carried 06:37 —
            // and stale means screens full of long-expired signed
            // links. When the stamp is older than the threshold,
            // prefer a fresher origin for the main list; Hot still
            // comes from the mirror (the origin has no Hot group).
            if let stamp = UpdatedStamp.parse(text),
               Date().timeIntervalSince(stamp) > Self.mirrorStaleThreshold,
               let (odata, oparsed, _) = try? await fetchPlaylist(from: Self.playlistURL) {
                try? odata.write(to: cacheFileURL, options: .atomic)
                setData(mergingEN(oparsed))
                setHot(parsed)
                statusMessage = "Gương đang chậm — đã dùng nguồn gốc mới hơn."
                DiagLog.write("playlist", "refresh source=origin-stale-mirror channels=\(channels.count) hot=\(hotChannels.count)")
            } else {
                try? data.write(to: mirrorCacheFileURL, options: .atomic)
                setData(parsed)
                setHot(parsed)
                DiagLog.write("playlist", "refresh source=mirror channels=\(channels.count) hot=\(hotChannels.count)")
            }
        } catch {
            // GitHub unreachable: fall back to the origin site before
            // giving up, and say so on screen when it saves us. The
            // origin has no Hot group, so the Hot tab keeps its list.
            do {
                let (data, parsed, _) = try await fetchPlaylist(from: Self.playlistURL)
                try? data.write(to: cacheFileURL, options: .atomic)
                setData(mergingEN(parsed))
                statusMessage = "Đang dùng nguồn dự phòng."
                DiagLog.write("playlist", "refresh source=origin-fallback channels=\(channels.count) hot=\(hotChannels.count)")
            } catch {
                if !loadedOnce {
                    statusMessage = "Không tải được danh sách kênh. Kiểm tra mạng rồi thử lại."
                } else {
                    statusMessage = "Chưa làm mới được — đang dùng danh sách cũ."
                }
                DiagLog.write("playlist", "refresh FAILED loadedOnce=\(loadedOnce) channels=\(channels.count)")
            }
        }
        // A playlist refresh also triggers a state fetch (§1.7).
        liveStore.requestFetch()
        pickInitialTabIfNeeded()
        scheduleValidation()
    }

    /// One playlist fetch + validation: the text must decode and parse
    /// to at least one channel, otherwise the source counts as failed
    /// (an error page or an empty file must never replace a good list).
    private func fetchPlaylist(from url: URL) async throws -> (Data, [Channel], String) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // Same user agent the Android app sends; some CDNs expect it.
        request.setValue("Mozilla/5.0 (Linux; Android 14; TV)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        let parsed = M3UParser.parse(text)
        if parsed.isEmpty { throw URLError(.zeroByteResource) }
        return (data, parsed, text)
    }

    private func setData(_ parsed: [Channel]) {
        rawChannels = parsed
        publishFiltered()
        lastFetch = Date()
        loadedOnce = true
        statusMessage = nil
    }

    /// Remember the newest EN block the mirror has served. An empty
    /// extraction never overwrites a good one (a bad mirror publish
    /// must not be able to erase the block everywhere at once).
    private func noteMirrorEN(_ parsed: [Channel]) {
        let en = parsed.filter { LeagueClassifier.isEN($0) }
        if !en.isEmpty { lastMirrorEN = en }
    }

    /// EN merge rule (owner's ecosystem ruling, 2026-11-15): the
    /// English-commentary block ALWAYS comes from the mirror,
    /// whichever source wins the main list. Before this rule, a stale
    /// mirror sent the main list to the origin — which carries no EN
    /// group — and the BLV Anh tab vanished until the mirror caught
    /// up. Measured flicker window: the origin's stamp ticks every
    /// 15–90 minutes while the mirror syncs every 15, so the tab
    /// blinked in and out. The web app carries the same rule (v6.2).
    private func mergingEN(_ main: [Channel]) -> [Channel] {
        if lastMirrorEN.isEmpty { return main }
        let have = Set(main.map { $0.url })
        let extra = lastMirrorEN.filter { !have.contains($0.url) }
        return extra.isEmpty ? main : main + extra
    }

    /// The Hot tab's list: the mirror's "🔥 Hot" group only, put
    /// through the same live-first sorting as every other list.
    private func setHot(_ parsed: [Channel]) {
        rawHotChannels = parsed.filter { $0.group == Self.hotGroupName }
        publishFiltered()
    }

    /// The single gate every display list flows through: raw entries
    /// minus proven-dead links minus .flv (unplayable on AVPlayer).
    private func publishFiltered() {
        channels = LeagueClassifier.sorted(rawChannels.filter(isDisplayable))
        hotChannels = LeagueClassifier.sorted(rawHotChannels.filter(isDisplayable))
    }

    private func isDisplayable(_ ch: Channel) -> Bool {
        if invalidURLs.contains(ch.url) { return false }
        return !Self.isFLV(ch.url)
    }

    /// Pure helper — also called from the non-isolated LinkProbe, so
    /// it must not inherit the store's MainActor isolation (build
    /// error in runs #45/#46, 2026-11-13).
    nonisolated static func isFLV(_ url: String) -> Bool {
        let path = url.split(separator: "?").first.map(String.init) ?? url
        return path.lowercased().hasSuffix(".flv")
    }

    /// The player's fallback ladder for a tapped channel: the
    /// members of the tapped channel's fixture, tapped one first,
    /// capped at 8. The fixture comes from FixtureGrouping — the
    /// same grouping the cards on both platforms render — so the
    /// ladder covers exactly the sources the card grouped, no more
    /// (the old fixtureKey ladder also swept in same-teams listings
    /// from other dates) and no less (reversed or filler-prefixed
    /// listings of the same match are members now, not strangers).
    func sources(for ch: Channel) -> [Channel] {
        // EN backup channels are standalone 24/7 channels, not fixtures:
        // their ladder is the tapped channel alone. (fixtureKey drops
        // trailing numerals, which would otherwise pair ESPN with
        // ESPN 2 and FOX Sports with Fox Sports 1 as "fallbacks".)
        if LeagueClassifier.isEN(ch) { return [ch] }
        let groups = FixtureGrouping.group(channels + hotChannels)
        guard let members = groups.first(where: { g in
            g.members.contains { $0.url == ch.url }
        })?.members else { return [ch] }
        var seen = Set<String>()
        var out: [Channel] = []
        for candidate in [ch] + members {
            if seen.insert(candidate.url).inserted {
                out.append(candidate)
                if out.count >= 8 { break }
            }
        }
        return out.isEmpty ? [ch] : out
    }

    // MARK: - Live state (1.4.1, plan §1/§2.2/§3)

    /// The matched live state for a fixture, if any source bound
    /// one (pair-key + date agreement, fail closed — see
    /// MatchStateStore.state(for:)).
    func matchState(for ch: Channel) -> MatchState? {
        liveStore.state(for: ch)
    }

    /// Board-open FotMob detail upgrade (spec §1.2; 1.4.4):
    /// forwarded to the live store, which owns the guards and
    /// the detail cache.
    func requestBoardDetail(for state: MatchState) {
        liveStore.requestBoardDetail(for: state)
    }

    /// Hero detail priority (1.4.8, FL-331): the view layer
    /// registers the fixture the hero panel is showing; the
    /// live store's cycle pass serves that pair's FotMob
    /// detail first, and the on-demand request below fires
    /// the upgrade for the hero's bound state immediately —
    /// the hero must not wait a full poll cycle (or the
    /// capped pass's queue) for its scorers and cards.
    func setHeroDetailPriority(for ch: Channel?) {
        liveStore.setDetailPriority(for: ch)
    }

    func requestHeroDetail(for ch: Channel) {
        guard let state = liveStore.state(for: ch) else { return }
        liveStore.requestHeroDetail(for: state)
    }

    /// The fixture's competition identity (plan §3.5): rule 1, a
    /// matched state's competition, wins; rule 2, the both-clubs
    /// lower-division test, files unmatched fixtures; otherwise
    /// nil (unknown → top section of its country tab, as today).
    func competition(for ch: Channel) -> CompetitionID? {
        if let competition = liveStore.state(for: ch)?.competition {
            return competition
        }
        return DivisionClassifier.lowerCompetition(for: ch)
    }

    /// Bucket with the matched state consulted first (plan §2.2):
    /// FT / postponed / cancelled leave bucket 0 at the poll that
    /// reports them; a not-started state suppresses bucket 0 even
    /// inside the −10 min window; a matched-live state stays in
    /// bucket 0 past +125 min while the source says live (extra
    /// time / penalties are real). Unmatched fixtures keep the
    /// classifier's bucket exactly.
    func effectiveBucket(of ch: Channel, now: Date = Date()) -> Int {
        let base = LeagueClassifier.bucket(of: ch, now: now)
        guard let state = liveStore.state(for: ch, now: now) else { return base }
        switch state.status {
        case .ft, .postponed, .cancelled:
            return base == 0 ? 3 : base
        case .pre:
            return base == 0 ? 1 : base
        case .live, .ht:
            return 0
        }
    }

    // MARK: - Match resolution (at-open verification, v1.3.7)

    /// The client-side port of the Nuvio live-sport addon's
    /// resolve machinery (research: LIVESPORT-PLUGIN-RESEARCH.md
    /// §3 items 1–5), adapted to this app's shape. What existed
    /// before: the background LinkProbe sweep (below), which hides
    /// persistently dead links from the lists on the store's own
    /// schedule, and the player's blind failover, which discovered
    /// a dead source only by sitting on it. What this adds is the
    /// at-open half: when a fixture is tapped (or pre-resolved),
    /// its candidate ladder is verified BEFORE the player sees it
    /// — dead links dropped, refused links repaired, verified
    /// links published progressively — and the result is cached
    /// with the addon's cache discipline (single-flight, adaptive
    /// TTL 60 s doubling to a 10 min cap, ~30 s negative entries,
    /// 200-entry LRU). The background sweep is untouched and
    /// complementary: it curates the lists; this curates the
    /// ladder of the one match being opened.
    ///
    /// 1.6.0 (web player standard): the gate's numbers are the
    /// web player's, not the addon's — the FIRST verified source
    /// releases the ladder at once (first-wins, the verified tier
    /// ordered by measured verify latency), the soft deadline is
    /// the web's ~3 s ceiling and publishes the blind head when
    /// nothing has verified by then, and the hard cap (15 s)
    /// only bounds how long stragglers keep verifying behind the
    /// playing source. The persisted SourceHealth memory is
    /// consulted before any probe is spent and fed by every
    /// verdict (see SourceHealth below).

    private static let resolveSoftDeadline: TimeInterval = 3
    private static let resolveHardCap: TimeInterval = 15
    private static let resolveBaseTTL: TimeInterval = 60
    private static let resolveMaxTTL: TimeInterval = 600
    private static let resolveNegativeTTL: TimeInterval = 30
    private static let resolutionCacheCap = 200

    private struct CachedResolution {
        let sources: [ResolvedSource]
        let expiresAt: Date
        let negative: Bool
    }

    private struct InFlightResolution {
        let resolution: MatchResolution
        var task: Task<Void, Never>?
        let startedByPreResolve: Bool
        var handedToPlayer: Bool
    }

    private var resolutionInFlight: [String: InFlightResolution] = [:]
    private var resolutionCache: [String: CachedResolution] = [:]
    private var resolutionCacheOrder: [String] = []
    /// Per-fixture learned TTL (the addon's adaptive TTL, keyed
    /// here by fixture rather than by provider source).
    private var resolutionTTLs: [String: TimeInterval] = [:]

    /// The cache key for a fixture: its FixtureGrouping id (the
    /// same identity sources(for:) ladders by), so the pin, the
    /// pre-resolve and a tap all land on the same entry. Falls
    /// back to the channel URL when no group claims the channel.
    private func fixtureKey(for ch: Channel) -> String {
        let groups = FixtureGrouping.group(channels + hotChannels)
        if let g = groups.first(where: { $0.members.contains { $0.url == ch.url } }) {
            return g.id
        }
        return "url:" + ch.url
    }

    /// The resolution a tap plays from. EN 24/7 channels keep
    /// today's direct path (they are standalone channels, not
    /// fixtures — sources(for:) already returns them alone);
    /// everything else resolves through verification, the cache,
    /// or the single in-flight resolve for that fixture.
    func resolution(for ch: Channel) -> MatchResolution {
        if LeagueClassifier.isEN(ch) {
            return MatchResolution.direct([ch])
        }
        let ladder = sources(for: ch)
        let key = fixtureKey(for: ch)
        if let entry = freshCacheEntry(forKey: key) {
            DiagLog.write("resolve", "cache hit (\(entry.negative ? "negative" : "verified")) — \(key)")
            // 1.6.0: a replayed ladder still answers to the
            // health memory — a rung proven dead since the entry
            // was cached (by a player session, most often) walks
            // at the tail instead of heading the replay.
            return MatchResolution.completed(SourceHealth.order(entry.sources))
        }
        if var flight = resolutionInFlight[key] {
            flight.handedToPlayer = true
            resolutionInFlight[key] = flight
            return flight.resolution
        }
        let res = MatchResolution()
        resolutionInFlight[key] = InFlightResolution(
            resolution: res, task: nil, startedByPreResolve: false, handedToPlayer: true)
        let task = Task { await self.runResolve(key: key, ladder: ladder, into: res) }
        resolutionInFlight[key]?.task = task
        return res
    }

    /// Pre-resolve one fixture into the cache (the pinned
    /// Manchester United match, at app open — TVContentView's
    /// pin hook). Bounded by the resolve's own deadlines and
    /// candidate cap, single-flight with any open of the same
    /// fixture, and superseded by the next pin: a pre-resolve
    /// that no player has taken over is cancelled, never left
    /// running for a match that is no longer pinned.
    func preResolve(_ ch: Channel) {
        if LeagueClassifier.isEN(ch) { return }
        let key = fixtureKey(for: ch)
        if freshCacheEntry(forKey: key) != nil { return }
        if resolutionInFlight[key] != nil { return }
        cancelPreResolve()
        let ladder = sources(for: ch)
        let res = MatchResolution()
        resolutionInFlight[key] = InFlightResolution(
            resolution: res, task: nil, startedByPreResolve: true, handedToPlayer: false)
        let task = Task { await self.runResolve(key: key, ladder: ladder, into: res) }
        resolutionInFlight[key]?.task = task
        DiagLog.write("resolve", "pre-resolving pinned fixture — \(key)")
    }

    /// Cancel the outstanding pre-resolve, if any — unless a
    /// player has already taken that resolution over, in which
    /// case it is a live open and runs to completion.
    func cancelPreResolve() {
        let keys = resolutionInFlight.compactMap { key, flight in
            (flight.startedByPreResolve && !flight.handedToPlayer) ? key : nil
        }
        for key in keys {
            resolutionInFlight[key]?.task?.cancel()
            resolutionInFlight.removeValue(forKey: key)
        }
    }

    private func freshCacheEntry(forKey key: String) -> CachedResolution? {
        guard let entry = resolutionCache[key] else { return nil }
        if entry.expiresAt <= Date() {
            resolutionCache.removeValue(forKey: key)
            resolutionCacheOrder.removeAll { $0 == key }
            return nil
        }
        resolutionCacheOrder.removeAll { $0 == key }
        resolutionCacheOrder.append(key)
        return entry
    }

    private func storeCacheEntry(key: String, sources: [ResolvedSource],
                                 negative: Bool, ttl: TimeInterval) {
        resolutionCache[key] = CachedResolution(
            sources: sources, expiresAt: Date().addingTimeInterval(ttl), negative: negative)
        resolutionCacheOrder.removeAll { $0 == key }
        resolutionCacheOrder.append(key)
        while resolutionCacheOrder.count > Self.resolutionCacheCap {
            let victim = resolutionCacheOrder.removeFirst()
            resolutionCache.removeValue(forKey: victim)
        }
    }

    /// Verify a fixture's ladder and publish it progressively
    /// into `res` (1.6.0 gate, the web player's shape): the
    /// FIRST verified source publishes at once — stragglers keep
    /// verifying behind the playing source until they settle or
    /// the hard cap cuts them off (an unsettled candidate counts
    /// as a transient failure). At the soft deadline (~3 s) with
    /// nothing verified yet, the blind head publishes instead,
    /// so the player starts TRYING rungs rather than sitting on
    /// its loading capsule. The final ladder is the verified
    /// sources fastest-first, then the blind tier (kept-blind
    /// and transient failures, candidate order), then the
    /// health-dead tail; definitively dead sources are excluded
    /// everywhere, so a fixture whose sources all prove dead
    /// resolves to an empty ladder and the player's no-signal
    /// slate — the addon's serve-nothing answer.
    private func runResolve(key: String, ladder: [Channel],
                            into res: MatchResolution) async {
        let started = Date()
        var verdicts: [Int: MatchVerdict] = [:]
        var latencies: [Int: Int] = [:]
        // The persisted health memory is consulted BEFORE any
        // probe is spent (1.6.0): a candidate inside its fresh
        // dead window is not probed again — it walks at the
        // final ladder's tail as a blind rung, never excluded.
        // Unless EVERY candidate is in that window: then the
        // memory may simply be stale, so all of them are probed
        // in listed order (the web's all-dead rule).
        var healthDead = Set(
            ladder.indices.filter { SourceHealth.isDead(ladder[$0].url) })
        if healthDead.count == ladder.count { healthDead = [] }
        let probeCount = ladder.count - healthDead.count
        // The deadline constants are captured as locals for the
        // sentinel tasks below: they are statics of this @MainActor
        // type, and a @Sendable task-group child must not reach
        // back through Self for them (the inherited-isolation
        // failure class the Swift 6 sweep exists to catch).
        let softDeadline = Self.resolveSoftDeadline
        let hardCap = Self.resolveHardCap
        var presented = false
        var gateReason = "hard"
        await withTaskGroup(of: (Int, MatchVerdict?, Int).self) { group in
            for (i, ch) in ladder.enumerated() where !healthDead.contains(i) {
                group.addTask {
                    let t0 = Date()
                    let verdict = await StreamVerifier.verify(ch)
                    return (i, verdict, Int(Date().timeIntervalSince(t0) * 1000))
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(softDeadline))
                return (-2, nil, 0)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(hardCap))
                return (-1, nil, 0)
            }
            for await (i, verdict, ms) in group {
                if i == -1 { break } // hard cap: stop collecting
                if i >= 0, let verdict {
                    verdicts[i] = verdict
                    latencies[i] = ms
                    SourceHealth.record(verdict: verdict, url: ladder[i].url,
                                        latencyMs: ms)
                }
                let wasPresented = presented
                if !presented {
                    let verified = Self.verifiedSources(ladder: ladder, verdicts: verdicts,
                                                        latencies: latencies)
                    let settled = verdicts.count == probeCount
                    let softPassed = Date().timeIntervalSince(started) >= softDeadline
                    if !verified.isEmpty {
                        gateReason = settled ? "settled" : "first-ok"
                        res.publish(verified)
                        presented = true
                        DiagLog.write("resolve", Self.gateLine(
                            reason: gateReason, ladder: ladder, published: verified,
                            verdicts: verdicts, latencies: latencies))
                    } else if softPassed || settled {
                        let head = Self.finalSources(ladder: ladder, verdicts: verdicts,
                                                     latencies: latencies,
                                                     healthDead: healthDead)
                        if !head.isEmpty {
                            gateReason = settled ? "settled" : "soft"
                            res.publish(head)
                            presented = true
                            DiagLog.write("resolve", Self.gateLine(
                                reason: gateReason, ladder: ladder, published: head,
                                verdicts: verdicts, latencies: latencies))
                        }
                    }
                }
                if wasPresented, i >= 0, let verdict, case .verified = verdict {
                    // Fix round (review A2): a verified rung
                    // landing after the first publish joins the
                    // ladder at once — the surface may already
                    // have burned through the published subset,
                    // and it must not idle beside a proven rung
                    // until every straggler settles.
                    res.publish(Self.finalSources(ladder: ladder, verdicts: verdicts,
                                                  latencies: latencies,
                                                  healthDead: healthDead))
                }
                if verdicts.count == probeCount { break }
            }
            group.cancelAll()
        }
        let final = Self.finalSources(ladder: ladder, verdicts: verdicts,
                                      latencies: latencies, healthDead: healthDead)
        if !presented {
            // Fix round (review A3): an all-probed-dead resolve
            // settles without ever presenting — its exit is
            // "settled", not the hard cap the initial value
            // would have claimed.
            DiagLog.write("resolve", Self.gateLine(
                reason: verdicts.count == probeCount ? "settled" : gateReason,
                ladder: ladder, published: final,
                verdicts: verdicts, latencies: latencies))
        }
        let verifiedCount = verdicts.values.filter {
            if case .verified = $0 { return true }
            return false
        }.count
        if !Task.isCancelled {
            res.publish(final)
            res.finish()
            if verifiedCount > 0 {
                let ttl = resolutionTTLs[key] ?? Self.resolveBaseTTL
                storeCacheEntry(key: key, sources: final, negative: false, ttl: ttl)
                resolutionTTLs[key] = min(ttl * 2, Self.resolveMaxTTL)
            } else {
                storeCacheEntry(key: key, sources: final, negative: true,
                                ttl: Self.resolveNegativeTTL)
                if let ttl = resolutionTTLs[key] {
                    resolutionTTLs[key] = max(ttl / 2, Self.resolveBaseTTL)
                }
            }
            DiagLog.write("resolve", "\(key): finished — \(verifiedCount)/\(ladder.count) verified, "
                + "ladder \(final.count)")
        } else {
            res.finish()
        }
        if let flight = resolutionInFlight[key], flight.resolution === res {
            resolutionInFlight.removeValue(forKey: key)
        }
    }

    /// The verified rungs so far, fastest first (1.6.0, web
    /// standard): the probe race's measured latency orders the
    /// tier — the web orders its whole ladder by probe latency
    /// and Sony's port does the same — with candidate order
    /// breaking ties. (Before 1.6.0 the tier published in
    /// candidate order, so a slow head source played ahead of a
    /// fast one that had already proven itself.)
    private static func verifiedSources(ladder: [Channel],
                                        verdicts: [Int: MatchVerdict],
                                        latencies: [Int: Int]) -> [ResolvedSource] {
        ladder.enumerated().compactMap { i, _ -> (Int, ResolvedSource)? in
            guard case .verified(let ch, let quality)? = verdicts[i] else { return nil }
            return (i, ResolvedSource(channel: ch, quality: quality, verified: true))
        }
        .sorted { a, b in
            let la = latencies[a.0] ?? Int.max
            let lb = latencies[b.0] ?? Int.max
            return la != lb ? la < lb : a.0 < b.0
        }
        .map { $0.1 }
    }

    /// The finished ladder: verified rungs fastest-first, then
    /// the blind tier — kept-blind and transiently failed
    /// candidates (an unsettled probed one counts as transient)
    /// in candidate order — then the health-dead tail, the
    /// candidates the health memory held back from probing,
    /// walking last as blind rungs. Definitively dead rungs
    /// never appear.
    private static func finalSources(ladder: [Channel],
                                     verdicts: [Int: MatchVerdict],
                                     latencies: [Int: Int],
                                     healthDead: Set<Int>) -> [ResolvedSource] {
        var out = verifiedSources(ladder: ladder, verdicts: verdicts,
                                  latencies: latencies)
        for (i, ch) in ladder.enumerated() where !healthDead.contains(i) {
            switch verdicts[i] {
            case .verified, .dead:
                break
            case .keptBlind, .failedTransient, nil:
                out.append(ResolvedSource(channel: ch, quality: nil, verified: false))
            }
        }
        for (i, ch) in ladder.enumerated() where healthDead.contains(i) {
            out.append(ResolvedSource(channel: ch, quality: nil, verified: false))
        }
        return out
    }

    /// The gate line (1.6.0, Sony 2.29's shape): how the gate
    /// released, the winning rung's host and its measured verify
    /// latency, and the ladder's shape — hosts only, and DiagLog
    /// scrubs regardless. `latency=-1` marks a blind winner that
    /// no verdict ever measured.
    private static func gateLine(reason: String, ladder: [Channel],
                                 published: [ResolvedSource],
                                 verdicts: [Int: MatchVerdict],
                                 latencies: [Int: Int]) -> String {
        let verifiedCount = verdicts.values.filter {
            if case .verified = $0 { return true }
            return false
        }.count
        guard let winner = published.first,
              let wi = ladder.firstIndex(where: { $0.url == winner.channel.url })
        else {
            return "gate reason=\(reason) winner=- latency=- "
                + "verified=\(verifiedCount) ladder=\(published.count)"
        }
        return "gate reason=\(reason) "
            + "winner=\(URL(string: winner.channel.url)?.host ?? "?") "
            + "latency=\(latencies[wi] ?? -1) "
            + "verified=\(verifiedCount) ladder=\(published.count)"
    }

    /// First load only: land on the Hot tab when it has a live match,
    /// else the highest-priority league with a live match right now;
    /// fall back to Ngoại Hạng Anh. Runs at the end of the first
    /// refresh so the Hot list is already known when deciding.
    private func pickInitialTabIfNeeded() {
        guard !didPickInitialTab, loadedOnce else { return }
        didPickInitialTab = true
        // Both platforms open on the Trực tiếp tab whenever anything
        // is live (owner's request, 2026-11-13) — that is what he
        // turns the TV on for, and iOS gained the same live chip in
        // 1.7 to stay in sync with the TV versions.
        if !liveChannels.isEmpty {
            selectedLeague = Self.liveTabValue
            return
        }
        let now = Date()
        if hotChannels.contains(where: { LeagueClassifier.bucket(of: $0, now: now) == 0 }) {
            selectedLeague = Self.hotTabValue
            return
        }
        var pick = League.england.rawValue
        for league in League.allCases {
            let hasLive = channels.contains {
                $0.leagueRank == league.rawValue && LeagueClassifier.bucket(of: $0, now: now) == 0
            }
            if hasLive { pick = league.rawValue; break }
        }
        selectedLeague = pick
    }

    // MARK: - Link validation (owner's request, 2026-11-13)

    /// The device's own vantage point is the only one that shares the
    /// owner's network and tunnel, so the app itself re-checks the
    /// list: after every load it probes each link in the background
    /// and hides the ones that are definitively unplayable HERE, so
    /// dead links never reach the match screens. The mirror repo runs
    /// the vantage-independent half of the same job (404s + filler).

    private func scheduleValidation() {
        Task { await validateLinks(reset: false) }
    }

    /// The "Kiểm tra link" button: force-fetch the newest playlist,
    /// then re-probe EVERYTHING from scratch (the hidden set is
    /// cleared first, so a link that died under a dead tunnel gets a
    /// fair second chance) and republish the match screens.
    func refreshAndValidate() async {
        await refresh()
        // refresh() schedules its own background pass; wait it out so
        // the from-scratch pass below is the one that runs.
        while validating {
            try? await Task.sleep(for: .milliseconds(200))
        }
        await validateLinks(reset: true)
        let hidden = invalidURLs.count
        statusMessage = hidden > 0
            ? "Đã kiểm tra xong: ẩn \(hidden) link chết."
            : "Đã kiểm tra xong: không có link chết."
    }

    private func validateLinks(reset: Bool) async {
        if validating { return }
        validating = true
        isValidating = true
        defer {
            validating = false
            isValidating = false
        }
        if reset {
            invalidURLs = []
            saveInvalidSet()
            publishFiltered()
        }
        let now = Date()
        var seen = Set<String>()
        var pool: [Channel] = []
        for ch in rawChannels + rawHotChannels where seen.insert(ch.url).inserted {
            if !Self.isFLV(ch.url) { pool.append(ch) }
        }
        // Live-window and always-on channels first — they are what
        // the home screen leads with; the rest follow in a second wave.
        let liveWave = pool.filter { isLiveScope($0, now: now) }
        let restWave = pool.filter { !isLiveScope($0, now: now) }
        await probeWave(liveWave, now: now)
        await probeWave(restWave, now: now)
    }

    /// "Should be serving right now": inside the live window, or a
    /// channel with no kickoff at all (24/7 streams).
    private func isLiveScope(_ ch: Channel, now: Date) -> Bool {
        ch.kickoff == nil || LeagueClassifier.bucket(of: ch, now: now) == 0
    }

    private func probeWave(_ wave: [Channel], now: Date) async {
        if wave.isEmpty { return }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: config)
        var validNow: Set<String> = []
        var invalidNow: Set<String> = []
        let chunkSize = 20
        var idx = 0
        while idx < wave.count {
            let chunk = Array(wave[idx..<min(idx + chunkSize, wave.count)])
            let results = await withTaskGroup(of: (String, Bool).self) { group in
                for ch in chunk {
                    let scope = isLiveScope(ch, now: now)
                    group.addTask {
                        (ch.url, await LinkProbe.isValid(ch, mustBeServing: scope, session: session))
                    }
                }
                var acc: [(String, Bool)] = []
                for await r in group { acc.append(r) }
                return acc
            }
            for (url, ok) in results {
                if ok { validNow.insert(url) } else { invalidNow.insert(url) }
            }
            idx += chunkSize
        }
        let before = invalidURLs
        invalidURLs.subtract(validNow)
        invalidURLs.formUnion(invalidNow)
        if invalidURLs != before {
            saveInvalidSet()
            publishFiltered()
        }
    }
}

/// One rung of a resolved fixture ladder: the channel the player
/// should use (a copy whose Referer was repaired during
/// verification, when the repair is what made it pass), the
/// quality parsed from its master playlist ("1080p", "720p50" —
/// nil when the playlist in hand declares none), and whether it
/// actually passed pre-flight (false = blind tier: kept or
/// transiently failed, presented only behind verified rungs).
struct ResolvedSource: Identifiable, Equatable {
    let channel: Channel
    let quality: String?
    let verified: Bool
    var id: String { channel.url }
}

/// A fixture's ladder being (or having been) resolved — the
/// progressive surface the player observes. The store owns the
/// resolve; the view only reads. `sources` is republished as
/// verification lands (first verified batch, then the finished
/// ladder); `finished` means nothing more will arrive.
@MainActor
final class MatchResolution: ObservableObject {
    @Published private(set) var sources: [ResolvedSource] = []
    @Published private(set) var finished = false

    func publish(_ sources: [ResolvedSource]) { self.sources = sources }
    func finish() { finished = true }

    /// A finished resolution that never went through
    /// verification — the direct path for standalone channels.
    static func direct(_ channels: [Channel]) -> MatchResolution {
        let r = MatchResolution()
        r.sources = channels.map { ResolvedSource(channel: $0, quality: nil, verified: false) }
        r.finished = true
        return r
    }

    /// A finished resolution replayed from the resolve cache.
    static func completed(_ sources: [ResolvedSource]) -> MatchResolution {
        let r = MatchResolution()
        r.sources = sources
        r.finished = true
        return r
    }
}

/// The verdict of one candidate's pre-flight (StreamVerifier).
enum MatchVerdict {
    /// Passed every check. Carries the channel to play (its
    /// Referer repaired, when the repair is what passed) and the
    /// quality parsed from the master playlist, when it has one.
    case verified(channel: Channel, quality: String?)
    /// Refused (401/403) but no Referer was ever attached to
    /// repair against — not proof of a dead stream (the addon's
    /// keep rule), so it is presented unverified, behind every
    /// verified rung.
    case keptBlind
    /// Network error or 5xx after the retry budget, or still
    /// unsettled at the resolve's hard cap: verification was
    /// inconclusive, so the rung joins the blind tier — never
    /// the verified ladder, never the dead list.
    case failedTransient
    /// Definitively dead: 404/410, a fake-200 body, a takedown
    /// slate, PNG-cloaked segments, or a refusal that stood
    /// after the Referer repair with a Referer attached.
    /// Excluded from the ladder and from the fallback alike.
    case dead
}

/// Pre-flight verification of ONE candidate stream, ported from
/// the addon's verifyStreams (src/streams.js) with its numbers:
/// transient answers (network errors, 5xx) are retried up to 3
/// attempts inside a 9 s total budget instead of believed; a
/// 401/403 earns ONE retry with a repaired Referer before it may
/// be called dead; a 200 must prove it is a playlist. Where the
/// addon consults a learned registry of embed hosts for the
/// repair, a client has no registry — the repair here is the
/// stream URL's own origin ("scheme://host/"), the one Referer
/// derivable from what the app already holds. Non-isolated like
/// LinkProbe, and for the same reason: it is called from task
/// groups off the main actor.
/// Internal rather than private since 2026-11-19: the tvOS
/// target's Nuvio addon store (DaBanhTV/NuvioAddon.swift)
/// verifies its addon ladders through this same verifier —
/// one judge for every ladder the player can receive.
enum StreamVerifier {

    private static let maxAttempts = 3
    private static let totalBudget: TimeInterval = 9
    private static let attemptTimeout: TimeInterval = 4
    private static let sampleCap = 32_768
    /// The user agent LinkProbe sends when an entry declares
    /// none — the verifier and the sweep speak with one voice.
    private static let defaultUA = "Mozilla/5.0 (Linux; Android 14; TV)"

    private enum FetchOutcome {
        case ok(sample: String)
        case http(status: Int)
        case transient
    }

    static func verify(_ channel: Channel) async -> MatchVerdict {
        // Direct media files are kept blind (the addon's
        // keep-list: it verifies playlists, not files).
        let path = channel.url.split(separator: "?").first.map(String.init) ?? channel.url
        if path.lowercased().hasSuffix(".mp4") { return .keptBlind }
        guard channel.streamURL != nil else { return .dead }
        let deadline = Date().addingTimeInterval(totalBudget)
        var attempt = 0
        while true {
            attempt += 1
            switch await fetch(channel: channel, referer: channel.referrer,
                               origin: channel.origin.isEmpty ? nil : channel.origin) {
            case .ok(let sample):
                return judge(sample: sample, channel: channel, referer: channel.referrer)
            case .http(let status) where status == 401 || status == 403:
                // Referer-repair: ONE retry with the host-derived
                // Referer; re-sending the refused one verbatim
                // would only double a dead stream's cost, so the
                // repair is skipped when it changes nothing.
                if let repaired = repairedReferer(for: channel.url),
                   repaired != channel.referrer {
                    switch await fetch(channel: channel, referer: repaired,
                                       origin: originString(for: repaired)) {
                    case .ok(let sample):
                        return judge(sample: sample, channel: channel, referer: repaired)
                    case .http:
                        // The refusal stood through the repair.
                        // It is genuine only when a Referer was
                        // attached from the start; with none, the
                        // addon's keep rule applies.
                        return channel.referrer.isEmpty ? .keptBlind : .dead
                    case .transient:
                        // The repair fetch itself was inconclusive
                        // (network error / 5xx), so the refusal was
                        // never actually re-tested: not proof of a
                        // dead stream — blind tier, not the grave.
                        return .failedTransient
                    }
                }
                return channel.referrer.isEmpty ? .keptBlind : .dead
            case .http:
                return .dead // 404/410, and any other terminal status
            case .transient:
                if attempt >= maxAttempts || Date() >= deadline {
                    return .failedTransient
                }
                try? await Task.sleep(for: .milliseconds(400 * attempt))
                if Task.isCancelled { return .failedTransient }
            }
        }
    }

    /// One bounded GET of the playlist with the stream's own
    /// headers, returning at most the first `sampleCap` bytes —
    /// everything the checks below need lives in the head of the
    /// playlist.
    private static func fetch(channel: Channel, referer: String,
                              origin: String?) async -> FetchOutcome {
        guard let url = URL(string: channel.url) else { return .http(status: 400) }
        var request = URLRequest(url: url)
        request.timeoutInterval = attemptTimeout
        request.setValue(channel.userAgent.isEmpty ? defaultUA : channel.userAgent,
                         forHTTPHeaderField: "User-Agent")
        if !referer.isEmpty { request.setValue(referer, forHTTPHeaderField: "Referer") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = attemptTimeout
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            if status == 401 || status == 403 || status == 404 || status == 410 {
                return .http(status: status)
            }
            if status >= 500 { return .transient }
            guard status == 200 else { return .http(status: status) }
            var buffer = Data()
            do {
                for try await byte in bytes {
                    buffer.append(byte)
                    if buffer.count >= sampleCap { break }
                }
            } catch {
                if buffer.isEmpty { return .transient }
            }
            return .ok(sample: String(decoding: buffer, as: UTF8.self))
        } catch {
            return .transient
        }
    }

    /// Judge a 200 body: it must be a real playlist (a 200 whose
    /// body is not one is the CDNs' fake-200 for an expired
    /// token), not a takedown slate, and not PNG-cloaked. A pass
    /// carries the winning Referer back into the channel — the
    /// repaired headers are what the player then uses, because
    /// PlayerController.asset already sends exactly the headers
    /// the channel declares — plus the quality parsed from the
    /// master playlist when this body is one.
    private static func judge(sample: String, channel: Channel,
                              referer: String) -> MatchVerdict {
        guard sample.contains("#EXTM3U") else { return .dead }
        let lower = sample.lowercased()
        if lower.contains("takedownslate") || lower.contains("ptv_takedownslates") {
            return .dead
        }
        if hasPNGSegmentLine(sample) { return .dead }
        var channel = channel
        if referer != channel.referrer {
            channel = Channel(title: channel.title, logo: channel.logo,
                              group: channel.group, url: channel.url,
                              kickoff: channel.kickoff, leagueRank: channel.leagueRank,
                              referrer: referer, userAgent: channel.userAgent,
                              origin: channel.origin)
        }
        return .verified(channel: channel, quality: parsedQuality(from: sample))
    }

    /// The addon's PNG-cloak test (a playlist line that is not a
    /// comment and points at a .png "segment"), line-based here
    /// instead of regex-based, same predicate.
    private static func hasPNGSegmentLine(_ sample: String) -> Bool {
        for raw in sample.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let path = line.split(separator: "?").first.map(String.init) ?? line
            if path.lowercased().hasSuffix(".png") { return true }
        }
        return false
    }

    /// Quality from the master playlist in hand, the addon's
    /// rule (M3U8ParserService): the highest-BANDWIDTH variant
    /// wins; its RESOLUTION height names the tag ("1080p", with
    /// the frame rate appended from 45 fps up — "1080p50"); a
    /// variant with no RESOLUTION is a generic "HD". A media
    /// playlist (no #EXT-X-STREAM-INF) declares nothing, so the
    /// quality stays nil rather than inventing a tier — the
    /// addon equally refuses to let a media playlist's generic
    /// tag stand as measured quality.
    private static func parsedQuality(from sample: String) -> String? {
        guard sample.contains("#EXT-X-STREAM-INF") else { return nil }
        var bestBandwidth = -1
        var bestTag: String? = nil
        for raw in sample.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("#EXT-X-STREAM-INF") else { continue }
            let bandwidth = attribute("BANDWIDTH", in: line).flatMap { Int($0) } ?? 0
            guard bandwidth > bestBandwidth else { continue }
            bestBandwidth = bandwidth
            var tag = "HD"
            if let resolution = attribute("RESOLUTION", in: line),
               let height = resolution.split(separator: "x").last.flatMap({ Int($0) }) {
                tag = "\(height)p"
                if let rate = attribute("FRAME-RATE", in: line).flatMap({ Double($0) }),
                   rate >= 45 {
                    tag += "\(Int(rate.rounded()))"
                }
            }
            bestTag = tag
        }
        return bestTag
    }

    /// One attribute of an #EXT-X-STREAM-INF line. The key must
    /// start an attribute (preceded by ':' or ',') so that e.g.
    /// "BANDWIDTH" never matches inside "AVERAGE-BANDWIDTH".
    private static func attribute(_ key: String, in line: String) -> String? {
        var searchFrom = line.startIndex
        while let hit = line.range(of: key + "=", range: searchFrom..<line.endIndex) {
            let before = line[..<hit.lowerBound].last
            if before == ":" || before == "," {
                let rest = line[hit.upperBound...]
                let value = rest.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
                return value.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            }
            searchFrom = hit.upperBound
        }
        return nil
    }

    /// The repaired Referer for a refused stream: its own
    /// origin, root path — the one Referer derivable from the
    /// URL itself (the addon's registry-and-regex chain, reduced
    /// to what a client can know).
    private static func repairedReferer(for urlString: String) -> String? {
        guard let c = URLComponents(string: urlString),
              let scheme = c.scheme, let host = c.host else { return nil }
        return "\(scheme)://\(host)/"
    }

    private static func originString(for referer: String) -> String? {
        guard let c = URLComponents(string: referer),
              let scheme = c.scheme, let host = c.host else { return nil }
        return "\(scheme)://\(host)"
    }
}

// MARK: - Source health memory (1.6.0, web player standard)

/// The persisted per-URL health memory — the web player's
/// localStorage table ("Sức khoẻ nguồn", dabanh-web/index.html)
/// and Sony 2.29's SourceHealth, ported with their numbers: a
/// URL that just proved dead is remembered 30 s (inside that
/// window a resolve does not spend a probe on it again — it
/// walks at the ladder's tail, never excluded); a URL that
/// verified or actually played is remembered 2 min; a probe
/// that merely answered is "seen". Capped at 200 entries,
/// oldest evicted first. This is the half FL-355 found missing
/// on the sibling app: a death record with nothing acting on
/// it. Here the verifier's verdicts AND the player's own
/// outcomes (ready = ok, advance = dead) feed one table, and
/// both resolvers consult it before probing — so a source the
/// player watched die is demoted for the next open, and a
/// source that played is not re-proven from zero on a reopen
/// inside the window.
///
/// Storage is UserDefaults (the web's localStorage analogue).
/// Every access is serialised under one lock and every mutation
/// persists synchronously — the DiagLog pattern, chosen for the
/// same reason: the table is touched from synchronous hot paths
/// (the player's advance/ready callbacks), so actor isolation
/// would change every call site's signature; the lock is the
/// safety argument.
enum SourceHealth {

    enum Status: String, Codable {
        case ok, seen, dead
    }

    private struct Entry: Codable {
        var status: Status
        var ts: TimeInterval
        var ms: Int
    }

    private static let defaultsKey = "dabanh-health"
    private static let deadTTL: TimeInterval = 30
    private static let okTTL: TimeInterval = 2 * 60
    private static let cap = 200

    private static let lock = NSLock()
    private nonisolated(unsafe) static var table: [String: Entry]?

    /// The fresh status of one URL, or nil when no record
    /// stands inside its TTL (an expired record is dropped).
    static func status(for url: String) -> Status? {
        lock.lock()
        defer { lock.unlock() }
        return freshEntryLocked(for: url)?.status
    }

    static func isDead(_ url: String) -> Bool {
        status(for: url) == .dead
    }

    /// Record one outcome. `.seen` never overwrites a fresh
    /// `.ok` or `.dead` (Sony's M1 discipline: a probe that
    /// merely answered must neither launder a proven death nor
    /// demote a proven player); `.ok` and `.dead` always write.
    static func record(_ url: String, _ status: Status, latencyMs: Int = 0) {
        lock.lock()
        defer { lock.unlock() }
        if status == .seen, let existing = freshEntryLocked(for: url),
           existing.status != .seen {
            return
        }
        var t = tableLocked()
        t[url] = Entry(status: status, ts: Date().timeIntervalSince1970,
                       ms: latencyMs)
        if t.count > cap {
            let oldest = t.sorted { $0.value.ts < $1.value.ts }
                .prefix(t.count - cap).map { $0.key }
            for k in oldest { t.removeValue(forKey: k) }
        }
        table = t
        persistLocked(t)
    }

    /// Record a verifier verdict, in the resolve path's own
    /// vocabulary: verified is a proven player, dead is a
    /// proven death, the inconclusive verdicts are "seen".
    static func record(verdict: MatchVerdict, url: String, latencyMs: Int) {
        switch verdict {
        case .verified:
            record(url, .ok, latencyMs: latencyMs)
        case .dead:
            record(url, .dead)
        case .keptBlind, .failedTransient:
            record(url, .seen, latencyMs: latencyMs)
        }
    }

    /// Demote fresh-dead rungs to the tail of a replayed ladder
    /// (the resolve cache's answer to the same memory): relative
    /// order is preserved inside both parts and no rung is ever
    /// dropped — a dead record is a demotion, not a ban. When
    /// every rung is dead-recorded the ladder stands as listed.
    /// The dead set is computed in ONE locked pass (fix round,
    /// review B-MINOR-2): two independently-locked filter passes
    /// could disagree if a record landed between them.
    static func order(_ sources: [ResolvedSource]) -> [ResolvedSource] {
        lock.lock()
        let deadURLs = Set(sources.compactMap { src -> String? in
            freshEntryLocked(for: src.channel.url)?.status == .dead
                ? src.channel.url : nil
        })
        lock.unlock()
        guard !deadURLs.isEmpty, deadURLs.count < sources.count else { return sources }
        return sources.filter { !deadURLs.contains($0.channel.url) }
            + sources.filter { deadURLs.contains($0.channel.url) }
    }

    // MARK: Locked internals (call ONLY with `lock` held)

    private static func tableLocked() -> [String: Entry] {
        if let table { return table }
        var loaded: [String: Entry] = [:]
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            loaded = decoded
        }
        table = loaded
        return loaded
    }

    private static func freshEntryLocked(for url: String) -> Entry? {
        var t = tableLocked()
        guard let entry = t[url] else { return nil }
        let ttl = entry.status == .dead ? deadTTL : okTTL
        if Date().timeIntervalSince1970 - entry.ts > ttl {
            t.removeValue(forKey: url)
            table = t
            persistLocked(t)
            return nil
        }
        return entry
    }

    private static func persistLocked(_ t: [String: Entry]) {
        if let data = try? JSONEncoder().encode(t) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

/// One-link probe. Definitive failure = HTTP 404/410, or HTTP 200 with
/// a body that is not a stream (empty, or an .m3u8 without #EXTM3U).
/// Other HTTP statuses keep the link (403 may be the tunnel being off
/// right now; 5xx is transient). A network-level failure (connect,
/// timeout) counts only when the channel should be serving right now —
/// a room for a future match may simply not exist yet.
private enum LinkProbe {

    static func isValid(_ ch: Channel, mustBeServing: Bool, session: URLSession) async -> Bool {
        guard let url = URL(string: ch.url) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue(
            ch.userAgent.isEmpty ? "Mozilla/5.0 (Linux; Android 14; TV)" : ch.userAgent,
            forHTTPHeaderField: "User-Agent")
        if !ch.referrer.isEmpty {
            request.setValue(ch.referrer, forHTTPHeaderField: "Referer")
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            if status == 404 || status == 410 { return false }
            guard status == 200 else { return true }
            var buffer = Data()
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count > 4096 { break }
            }
            if buffer.isEmpty { return false }
            if PlaylistStore.isFLV(ch.url) { return true }
            let path = ch.url.split(separator: "?").first.map(String.init) ?? ch.url
            if path.lowercased().hasSuffix(".m3u8") {
                return String(decoding: buffer.prefix(1024), as: UTF8.self).contains("#EXTM3U")
            }
            return true
        } catch {
            return !mustBeServing
        }
    }
}

/// The playlist files carry their generation time as a first
/// pseudo-entry ("Updated DD/MM HH:MM", Vietnam time). Parsed with
/// the same calendar rules as kickoffs; a stamp slightly in the
/// future (clock skew) reads as fresh, no stamp reads as unknown.
private enum UpdatedStamp {

    private static let regex = try! NSRegularExpression(
        pattern: #"Updated\s+(\d{1,2})/(\d{1,2})\s+(\d{1,2}):(\d{2})"#)

    static func parse(_ text: String) -> Date? {
        let head = String(text.prefix(512))
        let range = NSRange(head.startIndex..., in: head)
        guard let m = regex.firstMatch(in: head, range: range) else { return nil }
        func intAt(_ i: Int) -> Int? {
            guard let r = Range(m.range(at: i), in: head) else { return nil }
            return Int(head[r])
        }
        guard let day = intAt(1), let month = intAt(2),
              let hour = intAt(3), let minute = intAt(4) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current
        let now = Date()
        var comps = DateComponents()
        comps.year = calendar.component(.year, from: now)
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        guard var date = calendar.date(from: comps) else { return nil }
        if date.timeIntervalSince(now) < -30 * 24 * 3600 {
            date = date.addingTimeInterval(365 * 24 * 3600)
        }
        return date
    }
}
