import Foundation
import SwiftUI

/// Nuvio Live Sports as a source INSIDE the BLV Anh tab
/// (owner, clarified 2026-11-19 10:11 CST).
///
/// What he asked for, exactly: the BLV Anh tab used to show only
/// the OLD source's fixed channels (the mirror's "EN · BLV Anh"
/// block). The channels and fixtures of the item-5 addon —
/// Nuvio Live Sports, public instance https://nuviosports.xyz —
/// now LEAD this tab: its live events, its upcoming events and
/// its 24/7 channels render first, in this screen's existing
/// rail/card idiom, and the old EN block stays BELOW them as the
/// fallback, so the tab never goes empty when the addon is down.
/// The store below is a separate object the fixture tabs never
/// read, and the ladder channels it builds carry the EN group
/// name, so the existing English exclusion (TVEnglish /
/// LeagueClassifier) treats them as English-block content
/// wherever they could ever surface.
///
/// One owner-ordered exception to "nothing addon-sourced
/// appears anywhere else" (2026-11-19 12:58 CST): a league tab
/// also carries ITS league's addon content. A folded league
/// tab shows the fixtures the store already holds (its live /
/// upcoming events whose headline classifies under that
/// league by the same LeagueClassifier the mirror fixtures
/// use) at the top of the tab, and the league's 24/7 channels
/// — folded from the Networks search index exactly like the
/// BLV Anh channel fold — in a channel rail below the
/// fixtures. The mechanism is general
/// (NuvioClient.leagueSearches, keyed by league rank);
/// 1.4.0 wires the four folded leagues: Tây Ban Nha, Ý, Pháp
/// and Đức. Anh and Khác carry no fold.
///
/// The addon speaks the Stremio shapes the hunt verified
/// (tv-build/sports-provider-hunt-20261117/HUNT-REPORT.md +
/// PL-CHECK.md, re-probed live 2026-11-19):
///   {base}/manifest.json
///   {base}/catalog/tv/{id}.json, paged as
///   {base}/catalog/tv/{id}/skip={n}.json   (page size 100;
///   the ?skip= query form does NOT page — verified live)
///   {base}/stream/tv/{id}.json
/// Stream entries carry behaviorHints.proxyHeaders.request
/// (Referer / User-Agent / Origin), applied to pre-flight AND
/// to the player via the Channel the ladder is built from.
/// Entries with no `url` (the addon's donation row is one) are
/// unplayable by construction and are dropped at parse time.
///
/// The 4-page window is not the whole addon, though: probed
/// live 2026-11-19, marquee channels sit beyond it in the
/// Networks order (Canal+ Foot first appears on page 5,
/// SuperSport Premier League on page 9; Astro SuperSport 1–4
/// sit on page 4, one reorder away from falling out). The
/// channel section is therefore extended with a fold from the
/// addon's own search index (the Networks catalog declares a
/// `search` extra): one unpaged search per football-
/// broadcaster family — the 22 families at
/// NuvioClient.networkFamilies, the set the iOS 1.19 review
/// proved against this same addon. Queries whose tokens
/// degenerate into generic matches ("V Sport", "Sport TV",
/// "USA Network") are deliberately NOT used; Setanta / Optus
/// / Peacock are not carried at all; Sport TV 1–7 (Portugal)
/// cannot be isolated by search and stays unfolded — the same
/// recorded residual as iOS. Fold results classify by the
/// same field-driven rule (releaseInfo "24/7" → channel) and
/// merge into the channel section deduped by meta id, the
/// catalogs' own entries winning collisions. The fold is
/// best-effort: it never gates the snapshot, and a fold that
/// answers empty keeps its last-good results, exactly like a
/// catalog.
///
/// Playback verification reuses the 1.3.7 machinery where it
/// fits: StreamVerifier (PlaylistStore.swift — its access was
/// widened from `private` for exactly this reuse) judges every
/// candidate with the addon's own numbers, and the ladder is
/// published through the same MatchResolution surface the
/// player already observes, with the same progressive rule
/// (quorum 3, soft 6 s, hard 15 s) and the same cache
/// discipline (single-flight, adaptive TTL 60 s → 600 s,
/// ~30 s negatives). The PlaylistStore resolve cache itself is
/// keyed by M3U fixture identity, so the addon keeps its own
/// cache here, keyed by addon meta id, with identical numbers.

// MARK: - Model

/// One addon meta as the BLV Anh tab presents it: a 24/7
/// channel, a live event, or an upcoming event.
struct NuvioItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case channel
        case liveEvent
        case upcomingEvent
    }

    /// The addon meta id ("nuvio_sport_…") — also the stream
    /// lookup key and the resolve-cache key.
    let id: String
    /// The addon meta type ("tv" for everything in scope).
    let type: String
    let kind: Kind
    /// The addon's raw name, emoji prefix and all.
    let name: String
    /// Poster/background art the addon provides (channel art
    /// for networks, generated match art for events).
    let poster: String
    let team1Name: String?
    let team1Logo: String?
    let team2Name: String?
    let team2Logo: String?
    /// Kickoff parsed from the meta's `released` stamp
    /// (events only; channels have none).
    let kickoff: Date?
    /// The "🏆 League:" line of the meta description, when it
    /// carries one.
    let league: String?
    /// The meta's releaseInfo verbatim ("24/7", "LIVE", or a
    /// kickoff clock text for upcoming entries).
    let releaseInfo: String

    /// The name with the addon's decoration removed: the
    /// leading emoji/symbol run and a "LIVE:" prefix. The
    /// addon's names are already clean titles underneath
    /// ("📺 ABC", "🔴 LIVE: Egypt U17 vs Greece U17",
    /// "⏱️ FK Austria Wien vs FC Bayern München").
    var displayName: String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = s.first, !first.isLetter && !first.isNumber {
            s.removeFirst()
        }
        if s.lowercased().hasPrefix("live:") {
            s = String(s.dropFirst("live:".count))
                .trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    /// "Team A vs Team B" sides when the meta carries teams
    /// (event metas do; channel metas do not).
    var teams: (String, String)? {
        guard let team1Name, let team2Name else { return nil }
        return (team1Name, team2Name)
    }

    var headline: String {
        if let teams { return "\(teams.0) vs \(teams.1)" }
        return displayName
    }

    /// A display-only Channel carrying this item's poster as
    /// its logo, for the existing logo/crest views. Its URL is
    /// a placeholder that is never played — playing goes
    /// through NuvioStore.resolution(for:) — and its group is
    /// the EN block's, so the English exclusion claims it
    /// wherever it could surface.
    var displayChannel: Channel {
        Channel(title: name, logo: poster, group: LeagueClassifier.enGroupName,
                url: "nuvio-meta://" + id, kickoff: kickoff, leagueRank: 9)
    }
}

// MARK: - Addon client (wire shapes)

/// The addon's JSON shapes, reduced to what the tab consumes.
/// Non-isolated and value-typed throughout: decoding happens
/// off the main actor, only models cross back.
private enum NuvioWire {

    struct Manifest: Decodable {
        struct Catalog: Decodable {
            let type: String
            let id: String
        }
        let catalogs: [Catalog]
    }

    struct CatalogPage: Decodable {
        let metas: [Meta]
    }

    struct Meta: Decodable {
        struct Team: Decodable {
            let name: String?
            let logo: String?
        }
        let id: String
        let type: String
        let name: String
        let poster: String?
        let background: String?
        let releaseInfo: String?
        let released: String?
        let description: String?
        let team1: Team?
        let team2: Team?
    }

    struct StreamPage: Decodable {
        let streams: [AddonStream]
    }

    struct AddonStream: Decodable {
        struct Hints: Decodable {
            struct ProxyHeaders: Decodable {
                let request: [String: String]?
            }
            let proxyHeaders: ProxyHeaders?
        }
        let name: String?
        let title: String?
        let url: String?
        let behaviorHints: Hints?

        /// One proxyHeaders.request value, looked up
        /// case-insensitively (the addon is not consistent
        /// about header casing across its scrapers).
        func header(_ key: String) -> String {
            guard let request = behaviorHints?.proxyHeaders?.request else { return "" }
            for (k, v) in request where k.lowercased() == key.lowercased() {
                return v
            }
            return ""
        }
    }
}

/// The HTTP half: manifest, catalogs (paged), streams.
/// Stateless statics on an ephemeral session, mirroring
/// StreamVerifier's session discipline.
private enum NuvioClient {

    static let base = URL(string: "https://nuviosports.xyz")!

    /// The catalog allowlist, in tab order. The manifest
    /// declares ~75 catalogs; the rest are replay shelves,
    /// which the hunt scoped OUT of integration by design.
    /// Live Now interleaves some 24/7 channel entries with
    /// its events — the store splits them by releaseInfo.
    static let catalogIDs = [
        "nuvio_sports_live",
        "nuvio_sports_upcoming",
        "nuvio_sports_networks",
    ]

    /// The catalog the search fold queries (its manifest
    /// entry declares the `search` extra).
    static let networksCatalogID = "nuvio_sports_networks"

    /// Football-broadcaster families folded in from the
    /// Networks catalog through its search index — the
    /// channels the 4-page catalog window cannot reach (see
    /// the file header). The same 22 families the iOS 1.19
    /// review probed live against this addon: every one
    /// returns a clean family set in a single unpaged
    /// response, all of it releaseInfo "24/7".
    private static let networkFamilies = [
        "Sky Sports", "TNT Sports", "beIN Sports", "SuperSport",
        "Premier Sports", "ESPN", "Astro SuperSport",
        "Canal+ Sport", "Canal+ Foot", "DAZN", "Nova Sport",
        "Arena Sport", "Digi Sport", "Orange Sport",
        "Prima Sport", "Eleven Sports", "Ziggo Sport",
        "RMC Sport", "Viaplay Sport", "CBS Sports", "FOX Sports",
        "Stan Sport",
    ]

    /// The fold's overall deadline: all 22 family searches
    /// together get the same 25 s a single catalog request
    /// gets, so the fold can never hold a refresh open longer
    /// than the fetches it rides with.
    private static let foldDeadline: TimeInterval = 25

    /// Per-league channel searches for the league tabs
    /// (owner, 2026-11-19 12:58 CST: a league's addon channels
    /// belong in that league's tab), keyed by League rawValue.
    /// Each query is one unpaged Networks search, folded with
    /// the same discipline as the family fold above. Every
    /// query below was probed live 2026-11-19 (this VM) and
    /// returns exactly its league's channel set — every meta
    /// releaseInfo "24/7", no duplicates, no other league's
    /// channels:
    /// - Tây Ban Nha: "La Liga" → 15 (DAZN LaLiga, Movistar
    ///   LaLiga, LaLiga TV, LaLiga SmartBank TV, SuperSport
    ///   LaLiga, beIN Sports La Liga, DAZN Laliga 1/2, La Liga
    ///   TV Bar, Laliga TV Hypermotion (base, 2, 3), M+
    ///   Laliga, Movistar La Liga 1/2). SmartBank TV and the
    ///   Hypermotion set are the Segunda tier's league-branded
    ///   channels — in scope under the same "the country's
    ///   football, top-flight-led" convention as Đức's
    ///   2. Bundesliga names.
    /// - Ý: "Sky Calcio" → 5 (Sky Sports Calcio, Sky Calcio
    ///   1–4) and "Sky Sports Serie A" → exactly 1 more (the
    ///   channel of that name), 6 in all. The bare "Serie A"
    ///   query is deliberately NOT used: it returns 34 metas,
    ///   33 of them TV-series channels (Sky Serie, beIN
    ///   Series, TNT Serie …) — all "24/7" too, so the fold's
    ///   field rule could not keep them out of the Ý tab.
    /// - Pháp: "Ligue 1" → 19 (DAZN Ligue 1, Canal+ Ligue 1,
    ///   DAZN Ligue 1 Live 1–9, Ligue 1+ ×7, Psg Ligue 1) and
    ///   "Leauge 1" → exactly 2: DAZN 2/3 Leauge 1, the
    ///   source's own misspelling on DAZN France's overflow
    ///   channels — unambiguously Ligue 1 channels, so they
    ///   fold, as they do on iOS.
    /// - Đức: "Sky Sport Bundesliga" → 11 (Sky Sports
    ///   Bundesliga + 1–10). (The broader "Sky Bundesliga" /
    ///   "Bundesliga" queries return the same 11 plus
    ///   Vavoo/Telekom duplicates of every number, so they
    ///   are deliberately NOT used.)
    static let leagueSearches: [Int: [String]] = [
        League.spain.rawValue: ["La Liga"],
        League.italy.rawValue: ["Sky Calcio", "Sky Sports Serie A"],
        League.france.rawValue: ["Ligue 1", "Leauge 1"],
        League.germany.rawValue: ["Sky Sport Bundesliga"],
    ]

    /// Catalog page size the addon serves (verified live).
    static let pageSize = 100
    /// The paging bound: at most 4 pages (400 metas) per
    /// catalog. Live Now and Networks both run past 1,200
    /// metas; 400 leading entries per catalog is what a TV
    /// tab can honestly present, and Upcoming (345 tonight)
    /// exhausts inside the bound.
    static let maxPages = 4

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        return URLSession(configuration: config)
    }()

    /// The allowlist intersected with what the manifest
    /// actually declares (a renamed catalog drops out instead
    /// of 404ing forever). A failed manifest fetch falls back
    /// to the allowlist itself — the catalogs are the contract
    /// the hunt verified, the manifest is the cross-check.
    static func scopedCatalogIDs() async -> [String] {
        guard let data = try? await fetch(Self.base.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(NuvioWire.Manifest.self, from: data)
        else { return catalogIDs }
        let declared = Set(manifest.catalogs
            .filter { $0.type == "tv" || $0.type == "events" }
            .map(\.id))
        let scoped = catalogIDs.filter { declared.contains($0) }
        return scoped.isEmpty ? catalogIDs : scoped
    }

    /// One catalog, paged until a short page (exhausted) or
    /// the page bound. A page that fails mid-catalog keeps
    /// the pages already in hand — a partial catalog beats
    /// none, and the store's last-good covers the rest.
    static func fetchCatalog(id: String) async -> [NuvioWire.Meta] {
        var out: [NuvioWire.Meta] = []
        for page in 0..<maxPages {
            // Built as strings, not appendingPathComponent: the
            // paged shape carries a literal "skip=" component.
            let url: URL
            if page == 0 {
                url = URL(string: "https://nuviosports.xyz/catalog/tv/\(id).json")!
            } else {
                url = URL(string: "https://nuviosports.xyz/catalog/tv/\(id)/skip=\(page * pageSize).json")!
            }
            guard let data = try? await fetch(url),
                  let decoded = try? JSONDecoder().decode(NuvioWire.CatalogPage.self, from: data)
            else { break }
            out.append(contentsOf: decoded.metas)
            if decoded.metas.count < pageSize { break }
        }
        return out
    }

    /// The Networks search fold: one search request per
    /// football-broadcaster family, all 22 in parallel under
    /// one deadline. Searches do not page on this instance —
    /// a combined search+skip path 404s (probed on iOS) — so
    /// one request per family is the whole walk. Best-effort
    /// per family: a request that fails, decodes badly or
    /// misses the deadline contributes nothing, and the fold
    /// as a whole never fails — the store decides what an
    /// empty fold means (it keeps its last-good fold).
    static func fetchNetworkFold() async -> [NuvioWire.Meta] {
        await fetchSearchFold(queries: networkFamilies)
    }

    /// One league's channel fold (see leagueSearches): the
    /// same search-fold shape as the family fold, scoped to
    /// the league's own queries. Best-effort per query and as
    /// a whole, under the same shared deadline.
    static func fetchLeagueFold(queries: [String]) async -> [NuvioWire.Meta] {
        await fetchSearchFold(queries: queries)
    }

    /// A set of Networks search-index queries in parallel
    /// under one shared deadline — the shape both folds use.
    /// Searches do not page on this instance, so one request
    /// per query is the whole walk.
    private static func fetchSearchFold(queries: [String]) async -> [NuvioWire.Meta] {
        let deadline = Date().addingTimeInterval(foldDeadline)
        return await withTaskGroup(of: [NuvioWire.Meta].self) { group in
            for query in queries {
                group.addTask { await searchMetas(query, deadline: deadline) }
            }
            var all: [NuvioWire.Meta] = []
            for await metas in group { all += metas }
            return all
        }
    }

    /// One Networks search-index query, unpaged. A request
    /// that fails, decodes badly or misses the deadline
    /// contributes nothing.
    private static func searchMetas(_ query: String, deadline: Date) async -> [NuvioWire.Meta] {
        // The probed encoding: alphanumerics plus
        // -._~ survive, so "Canal+ Sport" reaches
        // the index as Canal%2B%20Sport.
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://nuviosports.xyz/catalog/tv/\(networksCatalogID)/search=\(encoded).json"),
              let data = try? await fetch(url, deadline: deadline),
              let decoded = try? JSONDecoder().decode(NuvioWire.CatalogPage.self, from: data)
        else { return [] }
        return decoded.metas
    }

    /// The stream list for one meta, unfiltered — the store
    /// drops the url-less entries when it builds the ladder.
    static func fetchStreams(type: String, id: String) async throws -> [NuvioWire.AddonStream] {
        // Meta ids are addon-generated slugs; percent-encode
        // defensively so an id can never break the path shape.
        let safeID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let url = URL(string: "https://nuviosports.xyz/stream/\(type)/\(safeID).json")!
        let data = try await fetch(url)
        return try JSONDecoder().decode(NuvioWire.StreamPage.self, from: data).streams
    }

    /// One fetch. With a deadline (the fold passes one) the
    /// budget is a hard bound, not a hint: an expired budget
    /// fails at once, and the request's own timeout is capped
    /// at the time remaining. Without one, the standing 25 s
    /// request timeout applies, exactly as before.
    private static func fetch(_ url: URL, deadline: Date? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        if let deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw URLError(.timedOut) }
            request.timeoutInterval = min(25, remaining)
        }
        request.setValue("Mozilla/5.0 (Linux; Android 14; TV)",
                         forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard status == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}

// MARK: - Store

/// The BLV Anh tab's addon content + playback resolution.
/// A separate object from PlaylistStore by design: the
/// fixture tabs read only the store, so addon content cannot
/// leak into them; this object is read only by the EN tab.
@MainActor
final class NuvioStore: ObservableObject {

    @Published private(set) var liveEvents: [NuvioItem] = []
    @Published private(set) var upcomingEvents: [NuvioItem] = []
    @Published private(set) var channels: [NuvioItem] = []
    @Published private(set) var isLoading = false

    private var lastFetch: Date?
    private var loading = false

    /// Last-good metas per catalog, kept at the META level:
    /// the channel section is composed from TWO catalogs
    /// (Networks canonical, Live Now's 24/7 strays after) plus
    /// the search fold, so a section-level keep-last-good is
    /// not enough — if Networks fails while Live answers,
    /// composing from the fresh lists alone would shrink the
    /// channel rail to the strays. A catalog that answers
    /// empty or fails contributes its last-good metas to the
    /// composition instead, so its section can only be
    /// replaced by a catalog that actually answered.
    private var lastGoodLive: [NuvioWire.Meta] = []
    private var lastGoodUpcoming: [NuvioWire.Meta] = []
    private var lastGoodNetworks: [NuvioWire.Meta] = []

    /// Last-good search-fold metas, under the same rule as
    /// the catalogs: the fold is best-effort per family, so
    /// an EMPTY fold answer — every family failed or missed
    /// the deadline — keeps the previous fold instead of
    /// un-folding channels the tab already had. A non-empty
    /// fold replaces it wholesale; per-family flicker inside
    /// a non-empty fold is the accepted residual (the iOS
    /// 1.19 review records the same).
    private var lastGoodFold: [NuvioWire.Meta] = []

    /// Per-league channel sections for the league tabs,
    /// keyed by League rawValue (see NuvioClient.leagueSearches
    /// and the file header): the league fold's channels,
    /// published under the same last-good rule as every other
    /// section — an empty league fold keeps the league's
    /// last-good channels, and a league whose fold has never
    /// answered simply has no entry here, so its tab renders
    /// exactly as it did before 1.4.0.
    @Published private(set) var leagueChannels: [Int: [NuvioItem]] = [:]
    private var lastGoodLeagueFold: [Int: [NuvioWire.Meta]] = [:]

    /// The refresh task-group id the fold reports under —
    /// not a catalog id, so the catalog switch below never
    /// claims it. `nonisolated` because the fold's task-group
    /// child reads it off the main actor: a `static let`
    /// inside an @MainActor type is still actor-isolated
    /// without the marker, immutable String or not (CI run
    /// #5's single error). The value is a compile-time
    /// constant sentinel, so sharing it is safe.
    private nonisolated static let foldTaskID = "__nuvio_fold__"

    /// The league folds report under this prefix + the league
    /// rank ("__nuvio_league_fold__:5") — again not a catalog
    /// id, and `nonisolated` for the same reason as foldTaskID.
    private nonisolated static let leagueFoldTaskPrefix = "__nuvio_league_fold__:"

    /// Catalog TTL: inside it, a tab open costs no fetch.
    private static let catalogTTL: TimeInterval = 5 * 60

    var hasContent: Bool {
        !liveEvents.isEmpty || !upcomingEvents.isEmpty || !channels.isEmpty
    }

    var totalCount: Int {
        liveEvents.count + upcomingEvents.count + channels.count
    }

    /// First open: fetch once. Later opens ride the TTL and
    /// the scene-active hook (refreshIfStale), like the
    /// playlist store's own discipline.
    func load() async {
        if lastFetch == nil { await refresh() }
    }

    func refreshIfStale() async {
        guard let lastFetch else { await refresh(); return }
        if Date().timeIntervalSince(lastFetch) > Self.catalogTTL {
            await refresh()
        }
    }

    /// Fetch the scoped catalogs in parallel and publish each
    /// as it lands. Last-good rule, per catalog: a catalog
    /// that answers empty or fails keeps its previously
    /// published section — the addon flapping must never
    /// blank a section it filled a minute ago, and with every
    /// section empty the tab simply falls back to the old EN
    /// block below. The search fold rides the same group
    /// under the same rule (an empty fold keeps the last-good
    /// fold): it publishes through the same recompose and
    /// never gates, delays or blanks a catalog section.
    func refresh() async {
        if loading { return }
        loading = true
        isLoading = true
        defer {
            loading = false
            isLoading = false
        }
        let ids = await NuvioClient.scopedCatalogIDs()
        await withTaskGroup(of: (String, [NuvioWire.Meta]).self) { group in
            for id in ids {
                group.addTask { (id, await NuvioClient.fetchCatalog(id: id)) }
            }
            if ids.contains(NuvioClient.networksCatalogID) {
                group.addTask {
                    (Self.foldTaskID, await NuvioClient.fetchNetworkFold())
                }
                // The league folds ride the same group: the
                // search extra they query lives on the Networks
                // catalog, so they are scoped exactly like the
                // family fold.
                for (rank, queries) in NuvioClient.leagueSearches {
                    group.addTask {
                        (Self.leagueFoldTaskPrefix + "\(rank)",
                         await NuvioClient.fetchLeagueFold(queries: queries))
                    }
                }
            }
            var liveMetas = lastGoodLive
            var upcomingMetas = lastGoodUpcoming
            var networkMetas = lastGoodNetworks
            var foldMetas = lastGoodFold
            var leagueFoldMetas = lastGoodLeagueFold
            for await (id, metas) in group {
                if id.hasPrefix(Self.leagueFoldTaskPrefix) {
                    // A league fold arrival: an empty answer
                    // keeps the league's last-good fold, the
                    // same rule as the family fold below.
                    let rank = Int(String(id.dropFirst(Self.leagueFoldTaskPrefix.count))) ?? -1
                    if !metas.isEmpty {
                        leagueFoldMetas[rank] = metas
                        lastGoodLeagueFold[rank] = metas
                    }
                } else if id == Self.foldTaskID {
                    // An empty fold never replaces the
                    // last-good fold (see lastGoodFold above).
                    if !metas.isEmpty {
                        foldMetas = metas
                        lastGoodFold = metas
                    }
                } else if !metas.isEmpty {
                    // An empty answer never replaces a
                    // catalog's last-good metas (see
                    // lastGoodLive above).
                    switch id {
                    case "nuvio_sports_live":
                        liveMetas = metas
                        lastGoodLive = metas
                    case "nuvio_sports_upcoming":
                        upcomingMetas = metas
                        lastGoodUpcoming = metas
                    case "nuvio_sports_networks":
                        networkMetas = metas
                        lastGoodNetworks = metas
                    default: break
                    }
                }
                // Publish progressively as catalogs land: the
                // composition is a pure function of the four
                // lists, so recomposing on each arrival is safe.
                let composed = Self.compose(live: liveMetas,
                                            upcoming: upcomingMetas,
                                            networks: networkMetas,
                                            fold: foldMetas)
                if !composed.live.isEmpty { liveEvents = composed.live }
                if !composed.upcoming.isEmpty { upcomingEvents = composed.upcoming }
                if !composed.channels.isEmpty { channels = composed.channels }
                // League channel sections publish from their
                // own folds, independently of the EN sections
                // above: a league whose composed channels are
                // non-empty (re)publishes, and an empty
                // composition never clears a section already
                // on screen.
                for (rank, metas) in leagueFoldMetas {
                    let items = Self.leagueChannelItems(from: metas)
                    if !items.isEmpty { leagueChannels[rank] = items }
                }
            }
        }
        if hasContent { lastFetch = Date() }
    }

    /// Split the three catalogs into the tab's three sections.
    /// Live Now interleaves 24/7 channel entries (releaseInfo
    /// "24/7") with its events: channels go to the channel
    /// section, everything else is a live event. Upcoming
    /// entries whose id is already live are dropped (live
    /// wins). Channels dedupe by id, Networks first (it is
    /// the canonical channel list), Live Now's strays after,
    /// the search fold last: a catalog entry always wins a
    /// collision and keeps its catalog position, so the fold
    /// only ADDS the channels the 4-page window cannot reach.
    /// Fold metas classify by the same field rule — only a
    /// "24/7" fold meta is a channel; anything else the index
    /// returns is not this fold's to route and is dropped.
    private static func compose(live: [NuvioWire.Meta],
                                upcoming: [NuvioWire.Meta],
                                networks: [NuvioWire.Meta],
                                fold: [NuvioWire.Meta])
        -> (live: [NuvioItem], upcoming: [NuvioItem], channels: [NuvioItem]) {
        var liveOut: [NuvioItem] = []
        var channelOut: [NuvioItem] = []
        var seenChannels = Set<String>()
        for meta in networks {
            let item = item(from: meta, kind: .channel)
            if seenChannels.insert(item.id).inserted { channelOut.append(item) }
        }
        var liveIDs = Set<String>()
        for meta in live {
            if (meta.releaseInfo ?? "") == "24/7" {
                let item = item(from: meta, kind: .channel)
                if seenChannels.insert(item.id).inserted { channelOut.append(item) }
            } else {
                let item = item(from: meta, kind: .liveEvent)
                if liveIDs.insert(item.id).inserted { liveOut.append(item) }
            }
        }
        for meta in fold where (meta.releaseInfo ?? "") == "24/7" {
            let item = item(from: meta, kind: .channel)
            if seenChannels.insert(item.id).inserted { channelOut.append(item) }
        }
        var upcomingOut: [NuvioItem] = []
        var seenUpcoming = Set<String>()
        for meta in upcoming where !liveIDs.contains(meta.id) {
            let item = item(from: meta, kind: .upcomingEvent)
            if seenUpcoming.insert(item.id).inserted { upcomingOut.append(item) }
        }
        return (liveOut, upcomingOut, channelOut)
    }

    /// One league's channel section from its fold metas: the
    /// same field-driven rule as the EN fold (only a "24/7"
    /// meta is a channel), deduped by meta id. The search
    /// index returns a numbered family scrambled (Bundesliga
    /// 3, 4, 5 … 10, 1, 2 in tonight's probe), so the section
    /// is sorted by display name with numeric chunks compared
    /// numerically — the one place a fold's order is not kept
    /// verbatim, because a numbered channel rail in raw index
    /// order reads as broken on the TV.
    private static func leagueChannelItems(from metas: [NuvioWire.Meta]) -> [NuvioItem] {
        var seen = Set<String>()
        var out: [NuvioItem] = []
        for meta in metas where (meta.releaseInfo ?? "") == "24/7" {
            let item = item(from: meta, kind: .channel)
            if seen.insert(item.id).inserted { out.append(item) }
        }
        return out.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private static func item(from meta: NuvioWire.Meta, kind: NuvioItem.Kind) -> NuvioItem {
        NuvioItem(
            id: meta.id,
            type: meta.type,
            kind: kind,
            name: meta.name,
            poster: meta.poster ?? meta.background ?? "",
            team1Name: meta.team1?.name,
            team1Logo: meta.team1?.logo,
            team2Name: meta.team2?.name,
            team2Logo: meta.team2?.logo,
            kickoff: meta.released.flatMap(parseReleased),
            league: leagueLine(from: meta.description),
            releaseInfo: meta.releaseInfo ?? "")
    }

    /// The "🏆 League: X" line of the addon description.
    private static func leagueLine(from description: String?) -> String? {
        guard let description else { return nil }
        for line in description.components(separatedBy: "\n") {
            if let range = line.range(of: "League:") {
                let value = line[range.upperBound...]
                    .trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    private static let releasedFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let releasedFormatterPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseReleased(_ stamp: String) -> Date? {
        releasedFormatter.date(from: stamp) ?? releasedFormatterPlain.date(from: stamp)
    }

    // MARK: - Playback resolution

    /// The resolve numbers are the playlist store's own
    /// (PlaylistStore.runResolve): since 1.6.0 the web
    /// player's gate — first verified releases at once, soft
    /// deadline 3 s, hard cap 15 s, the SourceHealth memory
    /// consulted and fed identically; cache TTL 60 s doubling
    /// to a 600 s cap on healthy re-resolves, ~30 s negatives.
    private static let resolveSoftDeadline: TimeInterval = 3
    private static let resolveHardCap: TimeInterval = 15
    private static let resolveBaseTTL: TimeInterval = 60
    private static let resolveMaxTTL: TimeInterval = 600
    private static let resolveNegativeTTL: TimeInterval = 30
    private static let resolutionCacheCap = 100

    private struct CachedLadder {
        let sources: [ResolvedSource]
        let expiresAt: Date
    }

    private var resolutionInFlight: [String: MatchResolution] = [:]
    private var resolutionCache: [String: CachedLadder] = [:]
    private var resolutionCacheOrder: [String] = []
    private var resolutionTTLs: [String: TimeInterval] = [:]

    /// The resolution a tap on an addon item plays from:
    /// the addon's stream list for the meta, verified at
    /// open through StreamVerifier and published
    /// progressively — the same surface and rules as a
    /// fixture open, keyed by meta id instead of fixture.
    func resolution(for item: NuvioItem) -> MatchResolution {
        if let entry = freshCacheEntry(forKey: item.id) {
            // 1.6.0: as in the playlist store, a replayed ladder
            // answers to the health memory — fresh-dead rungs
            // walk at the tail (SourceHealth.order).
            return MatchResolution.completed(SourceHealth.order(entry.sources))
        }
        if let flight = resolutionInFlight[item.id] {
            return flight
        }
        let res = MatchResolution()
        resolutionInFlight[item.id] = res
        Task { await self.runResolve(item: item, into: res) }
        return res
    }

    private func freshCacheEntry(forKey key: String) -> CachedLadder? {
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

    private func storeCacheEntry(key: String, sources: [ResolvedSource], ttl: TimeInterval) {
        resolutionCache[key] = CachedLadder(
            sources: sources, expiresAt: Date().addingTimeInterval(ttl))
        resolutionCacheOrder.removeAll { $0 == key }
        resolutionCacheOrder.append(key)
        while resolutionCacheOrder.count > Self.resolutionCacheCap {
            let victim = resolutionCacheOrder.removeFirst()
            resolutionCache.removeValue(forKey: victim)
        }
    }

    /// Resolve one addon meta: fetch its streams, build the
    /// ladder (url-carrying entries only — the addon's
    /// donation row and any other externalUrl-only entry can
    /// never play in-app), verify progressively, publish.
    /// A meta with no playable streams, or a stream fetch
    /// that fails outright, finishes EMPTY: the player shows
    /// its no-signal slate — the designed fail-soft, never a
    /// hung screen.
    private func runResolve(item: NuvioItem, into res: MatchResolution) async {
        defer {
            if resolutionInFlight[item.id] === res {
                resolutionInFlight.removeValue(forKey: item.id)
            }
        }
        let streams: [NuvioWire.AddonStream]
        do {
            streams = try await NuvioClient.fetchStreams(type: item.type, id: item.id)
        } catch {
            res.publish([])
            res.finish()
            storeCacheEntry(key: item.id, sources: [], ttl: Self.resolveNegativeTTL)
            return
        }
        // The ladder follows the playlist store's own rule
        // (sources(for:)): deduplicated by URL — the player
        // tracks rungs by URL, so a second row for the same
        // URL under different headers could never be tried
        // as its own rung — and capped at 8 candidates.
        var seenURLs = Set<String>()
        let ladder: [Channel] = Array(streams.compactMap { stream in
            guard let url = stream.url, !url.isEmpty,
                  seenURLs.insert(url).inserted else { return nil }
            return Channel(
                title: item.displayName,
                logo: item.poster,
                group: LeagueClassifier.enGroupName,
                url: url,
                kickoff: item.kickoff,
                leagueRank: 9,
                referrer: stream.header("Referer"),
                userAgent: stream.header("User-Agent"),
                origin: stream.header("Origin"))
        }.prefix(8))
        if ladder.isEmpty {
            res.publish([])
            res.finish()
            storeCacheEntry(key: item.id, sources: [], ttl: Self.resolveNegativeTTL)
            return
        }
        let started = Date()
        var verdicts: [Int: MatchVerdict] = [:]
        var latencies: [Int: Int] = [:]
        // 1.6.0: the health memory is consulted before any
        // probe is spent, exactly as in PlaylistStore.runResolve
        // — fresh-dead streams are not probed again and walk at
        // the tail; an all-dead ladder probes everything.
        var healthDead = Set(
            ladder.indices.filter { SourceHealth.isDead(ladder[$0].url) })
        if healthDead.count == ladder.count { healthDead = [] }
        let probeCount = ladder.count - healthDead.count
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
        // The finished ladder mirrors PlaylistStore's: verified
        // rungs fastest-first, then the blind tier, then the
        // health-dead tail; definitively dead rungs never appear.
        let final: [ResolvedSource] = Self.finalSources(
            ladder: ladder, verdicts: verdicts, latencies: latencies,
            healthDead: healthDead)
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
                let ttl = resolutionTTLs[item.id] ?? Self.resolveBaseTTL
                storeCacheEntry(key: item.id, sources: final, ttl: ttl)
                resolutionTTLs[item.id] = min(ttl * 2, Self.resolveMaxTTL)
            } else {
                storeCacheEntry(key: item.id, sources: final, ttl: Self.resolveNegativeTTL)
                if let ttl = resolutionTTLs[item.id] {
                    resolutionTTLs[item.id] = max(ttl / 2, Self.resolveBaseTTL)
                }
            }
        } else {
            res.finish()
        }
    }

    /// The verified rungs so far, fastest first — the same
    /// latency ordering as PlaylistStore.verifiedSources (1.6.0).
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

    /// The finished ladder — PlaylistStore.finalSources' twin:
    /// verified fastest-first, the blind tier in candidate
    /// order, then the health-dead tail.
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

    /// The gate line — PlaylistStore.gateLine's twin (Sony
    /// 2.29's shape; hosts only).
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
}

// MARK: - Cards (the EN section's existing idiom)

/// One addon 24/7 channel: the same 470×252 card as
/// TVENChannelCard — logo, name, a chip, a play line — with
/// the chip naming the source so the owner can tell addon
/// channels from the old block at a glance. In the BLV Anh
/// tab the play line names the English block; a league tab
/// passes its own line via detailPrefix (the Đức rail's
/// channels are German, and the card must not call them
/// English).
struct NuvioChannelCard: View {
    @Environment(\.tvTheme) private var theme
    let item: NuvioItem
    let focused: Bool
    var detailPrefix: String = "Kênh tiếng Anh"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                if !item.poster.isEmpty {
                    TVChannelLogo(channel: item.displayChannel, height: 58)
                } else {
                    Image(systemName: "tv")
                        .font(.system(size: 44))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Text("NUVIO · 24/7")
                    .font(.system(size: 19, weight: .heavy))
                    .foregroundStyle(TVPalette.cyan)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(TVPalette.tealFill))
            }
            Text(item.displayName)
                .font(.system(size: 31, weight: .bold))
                .foregroundStyle(focused ? TVPalette.cyan : .white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(TVPalette.cyan)
                Text(item.league.map { "\(detailPrefix) · \($0)" } ?? "\(detailPrefix) · phát liên tục")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
        }
        .padding(22)
        .frame(width: 470, height: 252, alignment: .topLeading)
        .background(tvCardBackground(focused: focused, theme: theme))
    }
}

/// One addon event (live or upcoming) in the BLV Anh tab:
/// the match-tile idiom — crest-vs-crest when the meta
/// carries teams (the addon ships TheSportsDB badges for
/// both sides), the headline, and a status chip in the
/// section's language: red LIVE for a match on air, amber
/// device-local kickoff for one to come.
struct NuvioEventCard: View {
    @Environment(\.tvTheme) private var theme
    let item: NuvioItem
    let focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                // 1.4.9 (FL-360, audit S-7): the crest row
                // holds the crest height (62) in both
                // branches — the channel-logo branch was 54,
                // 8 pt shorter than the crest branch.
                crestRow
                    .frame(height: 62)
                Spacer()
                statusChip
            }
            Text(item.headline)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(focused ? TVPalette.cyan : .white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Text(meta)
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
        }
        .padding(22)
        .frame(width: 470, height: 252, alignment: .topLeading)
        .background(tvCardBackground(focused: focused, theme: theme))
    }

    @ViewBuilder
    private var crestRow: some View {
        if item.teams != nil {
            HStack(spacing: 10) {
                TVCrestImage(url: item.team1Logo.flatMap(URL.init(string:)), size: 62)
                Text("vs")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                TVCrestImage(url: item.team2Logo.flatMap(URL.init(string:)), size: 62)
            }
        } else {
            TVChannelLogo(channel: item.displayChannel, height: 54)
        }
    }

    @ViewBuilder
    private var statusChip: some View {
        if item.kind == .liveEvent {
            HStack(spacing: 7) {
                Circle()
                    .fill(TVPalette.liveRed)
                    .frame(width: 13, height: 13)
                Text("LIVE")
                    .font(.system(size: 19, weight: .heavy))
                    .foregroundStyle(TVPalette.liveRed)
            }
        } else if let kickoff = item.kickoff {
            Text("⏰ " + TVKickoffFormat.time.string(from: kickoff))
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(TVPalette.amber)
        } else if !item.releaseInfo.isEmpty {
            Text("⏰ " + item.releaseInfo)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(TVPalette.amber)
        }
    }

    private var meta: String {
        var parts: [String] = []
        if let kickoff = item.kickoff {
            parts.append(TVKickoffFormat.timeDay.string(from: kickoff))
        }
        if let league = item.league { parts.append(league) }
        parts.append("Nuvio")
        return parts.joined(separator: "  ·  ")
    }
}
