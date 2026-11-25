import Foundation

/// Live match states (Đá Banh TV 1.4.2, BOARD-REDESIGN-PLAN §1):
/// ESPN primary (full cluster per league-day) > FotMob fallback >
/// Flashscore (score + status only, no minute, no incidents) >
/// LiveScore (score + minute only) > bounded computed clock.
/// Matching is the apps' existing normalised pair-key + ICT date
/// agreement, fail closed: a state binds to a fixture only when the
/// pair matches AND the calendar dates agree (the ESPN US-Eastern
/// day seam tolerates ±1 day only when kickoff instants are within
/// 3 h). Storage keeps one state per (pair, date) — the highest
/// layer that produced it — but the LOOKUP completes the winner
/// from the fixture's other date-compatible states, filling only
/// fields the winner lacks (1.4.5 partial-state merge, the RC2 /
/// FL-120 fix: a score-only Flashscore winner no longer starves
/// the events a FotMob state for the same fixture carries).
/// FotMob matchDetails may
/// upgrade a FotMob day-feed state (same source family), capped at
/// 4 detail calls per poll cycle, live fixtures first.
///
/// 1.4.6 (FL-331): the fetch layer was diffed field-by-field
/// against the iOS reference implementation (dabanh-ios — the
/// build whose four layers are all alive on the owner's iPhone)
/// and the convicted drifts were aligned: the FotMob day param
/// is yyyyMMdd (the old "YYYY-MM-DD" was answered with a literal
/// null body — the layer decoded 0 states), LiveScore scores
/// decode as the strings the wire actually sends (the Int? DTO
/// failed the whole feed decode), the shared GET carries the
/// iOS user-agent, ESPN failures are logged per board
/// (slug + day + outcome), the fifa.worldq.uefa board is
/// polled, FotMob kickoff falls back status.utcTime →
/// match.utcTime with the feed's own day as the dateKey
/// fallback (never the fetch instant), the detail parser reads
/// player.name + goalDescription (penalty / own-goal flags),
/// and the detail-upgrade pass covers finished FotMob states
/// too. Two iOS shapes were deliberately NOT adopted, each
/// against this tree's own measured evidence: the ESPN day
/// window stays US-Eastern (KH-4 — the ICT window silently
/// missed the Americas fixtures ESPN files under the Eastern
/// day) and LiveScore keeps its kickoff-free binding (KH-9 —
/// the Esd stamp's timezone measured UTC+3 against ESPN, so no
/// instant is derived from it). The merge, the staleness guard
/// and filledFromPool were re-verified iOS-shaped and untouched.
///
/// Poll cadence (plan §1.7): 60 s while anything is in its live
/// window or matched-live, else 15 min. Last-good states are kept
/// 30 min, then overrides drop (never worse than the computed
/// clock). All three sources are public-but-unlicensed site APIs;
/// the client fetches directly, one request per endpoint per
/// cycle, honest user-agent, no proxying (plan §6-Q5).

enum MatchStatus: Equatable, Sendable {
    case pre, live, ht, ft, postponed, cancelled
}

enum MatchSource: Equatable, Sendable {
    case espn, fotmob, flashscore, livescore
}

/// One goal or card event of a matched fixture.
/// 1.7.7 (item d): Codable so the settled-detail ledger can
/// persist finished matches' events across launches — every
/// stored property was already String/Int/Bool, so the
/// conformance is synthesised and changes no behaviour.
struct MatchEvent: Equatable, Sendable, Codable {
    enum Kind: Equatable, Sendable, Codable { case goal, yellowCard, redCard }
    let kind: Kind
    let minuteText: String
    let playerName: String
    let isHome: Bool
    let isPenalty: Bool
    let isOwnGoal: Bool
}

/// The state one source produced for one fixture (plan §1.0).
/// `pairKey` + `dateKey` are the storage identity: the normalised
/// pair key (FixtureGrouping rules) and the ICT calendar date the
/// source event belongs to, in FixtureGrouping.stampDateKey form.
struct MatchState: Equatable, Sendable {
    let pairKey: String
    let dateKey: String
    let competition: CompetitionID?
    let status: MatchStatus
    /// Verbatim display clock ("61'", "45'+3'") or nil.
    let minuteText: String?
    let scoreHome: Int?
    let scoreAway: Int?
    let events: [MatchEvent]
    let source: MatchSource
    let fetchedAt: Date
    /// The source event's kickoff instant (date-agreement checks).
    let kickoff: Date?
    /// FotMob match id, when the state came from FotMob (detail
    /// upgrades ride on it).
    let fotmobID: Int?
    /// ESPN's own display names + crest URLs for the two sides
    /// (1.4.4, item 1 — the Sony 2.24 mechanism): the ESPN
    /// payload carries a real logo per team, but until now the
    /// parser dropped both, so a club missing from every crest
    /// map (the Orlando City / FC Cincinnati class) showed no
    /// crest anywhere. Non-nil ONLY on ESPN states; the display
    /// layer may fall back to these per side, fail-closed, via
    /// espnLogo(forTeamName:). Names are display metadata only —
    /// binding never reads them.
    let homeName: String?
    let awayName: String?
    let logoHome: String?
    let logoAway: String?

    var storageKey: String { pairKey + "|" + dateKey }
    var goals: [MatchEvent] { events.filter { $0.kind == .goal } }
    var homeGoals: [MatchEvent] { goals.filter { $0.isHome } }
    var awayGoals: [MatchEvent] { goals.filter { !$0.isHome } }
    var homeYellow: Int { events.filter { $0.kind == .yellowCard && $0.isHome }.count }
    var awayYellow: Int { events.filter { $0.kind == .yellowCard && !$0.isHome }.count }
    var homeRed: Int { events.filter { $0.kind == .redCard && $0.isHome }.count }
    var awayRed: Int { events.filter { $0.kind == .redCard && !$0.isHome }.count }

    /// The badge text for this state (plan §1.5): HT normalises to
    /// the mock's Vietnamese wording; minutes are the source's own.
    var badgeText: String? {
        switch status {
        case .ht: return "NGHỈ GIỮA HIỆP"
        case .live: return minuteText
        case .ft: return "FT"
        case .pre, .postponed, .cancelled: return nil
        }
    }

    var scoreText: String? {
        guard let h = scoreHome, let a = scoreAway else { return nil }
        return "\(h) - \(a)"
    }

    func withEvents(_ newEvents: [MatchEvent]) -> MatchState {
        MatchState(pairKey: pairKey, dateKey: dateKey, competition: competition,
                   status: status, minuteText: minuteText,
                   scoreHome: scoreHome, scoreAway: scoreAway,
                   events: newEvents,
                   source: source, fetchedAt: fetchedAt, kickoff: kickoff,
                   fotmobID: fotmobID,
                   homeName: homeName, awayName: awayName,
                   logoHome: logoHome, logoAway: logoAway)
    }

    /// The ESPN crest URL for ONE side of this fixture (1.4.4):
    /// non-nil ONLY when this state came from ESPN, the given
    /// team name canonicalises (MatchPairKey.canonicalTeam — the
    /// same key the binder uses) to the same key as that side's
    /// ESPN display name, and the payload's logo for that side
    /// is a non-empty http(s) URL. Every other case returns nil
    /// and the caller keeps the shield — a logo is never guessed
    /// from an unbound or mismatched state.
    func espnLogo(forTeamName name: String) -> URL? {
        guard source == .espn else { return nil }
        let key = MatchPairKey.canonicalTeam(name)
        guard !key.isEmpty else { return nil }
        let raw: String?
        if let homeName, key == MatchPairKey.canonicalTeam(homeName) {
            raw = logoHome
        } else if let awayName, key == MatchPairKey.canonicalTeam(awayName) {
            raw = logoAway
        } else {
            raw = nil
        }
        guard let raw, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }
}

/// Pair-key for two raw source team names — the CANONICAL key
/// of the measured matcher study (BOARD-REDESIGN-PLAN Addendum 2,
/// matcher v2, run over the real mirror + Nuvio events).
///
/// 1.4.5 (FIX-127 port) supersedes the implementation, not the
/// design: the tables and the pipeline moved into TeamNameNorm,
/// the ONE normalization module every layer shares, and the
/// pipeline gained the steps the matcher-v2 shape could not
/// express — age markers are extracted BEFORE alias resolution
/// and re-attached as a canonical tag (the whole-name lookup on
/// the unstripped "y u17" is what split Ý U17 from Italy U17,
/// DB-04 variant 2 / FL-111), the leading "Câu lạc bộ (bóng
/// đá)" club phrase drops, measured city qualifiers
/// (jeddah/samara — with the stem guard) drop from the tail
/// (DB-08 / FL-115: "Al-Ahli Jeddah" never met the "Al Ahli"
/// state), letters the diacritic fold cannot decompose (ı, ø,
/// æ…) fold by hand ("Sumqayıt" reduced to "sumqay t"), and the
/// survey's VN national-team whole-name aliases are carried —
/// measured, like every other entry. This type keeps its
/// public API and delegates; its private tables are gone.
/// The same canonical function keys ESPN/FotMob/Flashscore/
/// LiveScore states, mirror fixtures and Nuvio events — one
/// matcher everywhere (spec §2.5). Fixture GROUPING runs the
/// same module's grouping key (FixtureGrouping delegates too).
enum MatchPairKey {

    /// One team name canonicalised — the shared module's
    /// canonical key (TeamNameNorm.canonicalKey).
    static func canonicalTeam(_ name: String) -> String {
        TeamNameNorm.canonicalKey(forTeam: name)
    }

    static func key(home: String, away: String) -> String? {
        let h = canonicalTeam(home)
        let a = canonicalTeam(away)
        guard !h.isEmpty, !a.isEmpty, h != a else { return nil }
        return [h, a].sorted().joined(separator: " vs ")
    }

    /// The canonical pair key of an existing fixture channel, so
    /// source states and fixtures meet on one key.
    static func key(of channel: Channel) -> String? {
        guard let (a, b) = Crests.teams(ofCleanTitle: MatchTitle.clean(channel.title))
        else { return nil }
        return key(home: a, away: b)
    }
}

/// One persisted settled FotMob detail answer (1.7.7, item
/// d): the events a finished match's matchDetails call
/// returned — an EMPTY list is a valid settled answer (a
/// goalless, card-less FT match) and persists like any other.
/// File-scope (not nested in the @MainActor store) so its
/// Codable conformance carries no actor isolation, mirroring
/// the SourceHealth entry shape in PlaylistStore.
private struct SettledDetail: Codable {
    let events: [MatchEvent]
    let fetchedAt: Date
}

@MainActor
final class MatchStateStore: ObservableObject {

    @Published private(set) var states: [String: MatchState] = [:]

    /// Donor index for filledFromPool (1.7.10, DIAG-140-SMOOTH
    /// tvOS audit item 3): pairKey → every state stored under
    /// it, rebuilt ONCE at each `states` assignment (the poll
    /// cycle's wholesale publish and applyBoardDetail's single
    /// write — the only two mutation sites). Before 1.7.10
    /// every state(for:) lookup re-filtered the WHOLE states
    /// dictionary (~600 entries) to find one fixture's handful
    /// of donors, and a snapshot rebuild paid that ~400 times.
    private var donorIndex: [String: [MatchState]] = [:]

    private func rebuildDonorIndex() {
        var index: [String: [MatchState]] = [:]
        for s in states.values {
            index[s.pairKey, default: []].append(s)
        }
        donorIndex = index
    }

    /// Set by PlaylistStore so list views re-render when states land.
    var onChange: (() -> Void)?

    private var fixturesProvider: (() -> [Channel])?
    private var pollTask: Task<Void, Never>?
    private var fetching = false
    /// 1.5.1 (FL-370): the cache entry carries its fetch time
    /// and whether the match was ALREADY FINISHED when the
    /// answer was fetched — before 1.5.1 a non-empty answer
    /// was applied forever, so a LIVE match's events froze at
    /// the minute of the first detail fetch and later
    /// goals/cards never landed. A live answer is now a
    /// snapshot with a 120 s life (two poll cycles); only an
    /// answer fetched while the match was finished is final.
    /// (The flag must be recorded at fetch time: judging
    /// finality from the state's CURRENT status would promote
    /// a live snapshot to "final" the moment the match ends,
    /// losing its last events — review round 1.)
    private var fotmobDetailCache: [Int: (events: [MatchEvent], fetchedAt: Date, final: Bool)] = [:]
    /// 1.7.7 (item d): the persisted SETTLED half of the
    /// detail ledger above, keyed by String(fotmobID) in
    /// UserDefaults (the SourceHealth storage pattern). Only
    /// final answers ever enter it — live snapshots stay
    /// RAM-only under the 120 s rule. Loaded into
    /// fotmobDetailCache (final: true) by start(); written
    /// through synchronously at the two cache-store sites the
    /// moment an entry becomes final. Before 1.7.7 the whole
    /// ledger was RAM-only, so every cold launch re-fetched
    /// detail for every FotMob-won finished match at the
    /// 4-per-cycle cap.
    private var settledDetails: [String: SettledDetail] = [:]
    private static let settledDetailKey = "dabanh-fotmob-detail-settled"
    private static let settledDetailCap = 1000
    private static let settledDetailMaxAge: TimeInterval = 7 * 24 * 3600
    /// The pair key of the fixture the hero panel is showing
    /// (1.4.8): the view layer registers it, the cycle's detail
    /// pass serves that pair first. The hero is the most
    /// prominent surface in the app — its events must not wait
    /// behind unrelated fixtures in the day feed.
    private var detailPriorityPairKey: String?
    /// FotMob ids with a board-open detail fetch in flight
    /// (1.4.4): repeated board opens must not spawn duplicate
    /// fetches for the same match.
    private var boardDetailInFlight: Set<Int> = []

    private static let livePoll: TimeInterval = 60
    private static let idlePoll: TimeInterval = 15 * 60
    private static let lastGoodWindow: TimeInterval = 30 * 60
    private static let fotmobDetailCap = 4

    // MARK: - Lifecycle

    func start(fixturesProvider: @escaping () -> [Channel]) {
        self.fixturesProvider = fixturesProvider
        // 1.7.7 (item d): restore the settled ledger BEFORE
        // the poll task begins, so the first cycle already
        // treats settled fixtures as final-fresh and spends
        // its detail budget only on genuinely new finishes.
        loadSettledDetails()
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.cycle()
                let live = self.hasLiveScope()
                try? await Task.sleep(for: .seconds(live ? Self.livePoll : Self.idlePoll))
            }
        }
    }

    /// 1.7.7 (item d): decode the persisted settled ledger
    /// into the RAM cache with final: true. Entries older
    /// than 7 days are dropped on load (a settled entry's
    /// only consumer is a same-week board). A persisted EMPTY
    /// events list loads too — it is the settled answer for a
    /// goalless/card-less FT match, and loading it is what
    /// stops that match's refetch. Synchronous UserDefaults
    /// work on the actor, mirroring SourceHealth.
    private func loadSettledDetails() {
        guard let data = UserDefaults.standard.data(forKey: Self.settledDetailKey),
              let decoded = try? JSONDecoder().decode([String: SettledDetail].self, from: data)
        else { return }
        let cutoff = Date().addingTimeInterval(-Self.settledDetailMaxAge)
        var table: [String: SettledDetail] = [:]
        for (key, entry) in decoded where entry.fetchedAt >= cutoff {
            guard let fid = Int(key) else { continue }
            table[key] = entry
            fotmobDetailCache[fid] = (events: entry.events,
                                      fetchedAt: entry.fetchedAt, final: true)
        }
        settledDetails = table
    }

    /// 1.7.7 (item d): write one newly-final answer through
    /// to the persisted ledger, synchronously. Bounded at
    /// 1,000 entries, oldest by fetchedAt evicted first (the
    /// SourceHealth cap discipline). Callers invoke this ONLY
    /// for final entries — live snapshots never persist.
    private func persistSettledDetail(fid: Int, events: [MatchEvent], fetchedAt: Date) {
        settledDetails[String(fid)] = SettledDetail(events: events, fetchedAt: fetchedAt)
        if settledDetails.count > Self.settledDetailCap {
            let oldest = settledDetails
                .sorted { $0.value.fetchedAt < $1.value.fetchedAt }
                .prefix(settledDetails.count - Self.settledDetailCap)
                .map { $0.key }
            for key in oldest { settledDetails.removeValue(forKey: key) }
        }
        if let data = try? JSONEncoder().encode(settledDetails) {
            UserDefaults.standard.set(data, forKey: Self.settledDetailKey)
        }
    }

    /// A playlist refresh also triggers a state fetch (plan §1.7).
    func requestFetch() {
        Task { await cycle() }
    }

    /// On-demand FotMob detail upgrade for the fixture whose
    /// link board is open (spec §1.2: matchDetails is fetched
    /// on demand only — the cycle's capped pass covers live
    /// fixtures generally; the board-open fixture is the spec's
    /// second named case, and 1.4.3 never wired it, so a board
    /// could sit on an event-less FotMob state until the cap
    /// race reached it). Same discipline as the cycle pass:
    /// FotMob states only, events still empty, the detail cache
    /// shared, and the write-back re-reads the CURRENT stored
    /// state and upgrades only that same FotMob state — a
    /// fresher cycle state (or an ESPN state that has since won
    /// the key) is never clobbered.
    func requestBoardDetail(for state: MatchState) {
        guard state.source == .fotmob,
              let fid = state.fotmobID,
              !boardDetailInFlight.contains(fid) else { return }
        // Cache discipline (1.4.8, extended 1.5.1/FL-370): a
        // cached answer is applied at once while it is FRESH —
        // a finished match's answer is final forever; a live
        // match's answer is a snapshot that expires after
        // 120 s, after which the board's fixture earns a
        // refetch (its event list can only have grown). With
        // no cache entry, only an event-less state fetches —
        // a non-empty FotMob state always has a cache entry
        // behind it (both write paths store non-empty answers).
        if let cached = fotmobDetailCache[fid] {
            let fresh = cached.final
                || Date().timeIntervalSince(cached.fetchedAt) < 120
            if fresh {
                if !cached.events.isEmpty {
                    applyBoardDetail(cached.events, fid: fid, key: state.storageKey)
                }
                return
            }
        } else if !state.events.isEmpty {
            return
        }
        boardDetailInFlight.insert(fid)
        let key = state.storageKey
        Task { [weak self] in
            guard let self else { return }
            defer { boardDetailInFlight.remove(fid) }
            if let events = await Self.fetchFotMobDetail(id: fid) {
                // Same 1.4.8 cache discipline as the cycle
                // pass: an empty answer is stored only when
                // the stored state says the match is finished
                // (a final answer); a live match's empty
                // answer is applied but never stored. And the
                // 1.5.1 richer-wins discipline (review round 1):
                // the fetched list is stored ONLY when it is
                // at least as rich as the cached prior — an
                // unguarded store let a shorter refetch poison
                // the cache, after which the cycle pass applied
                // the shorter list to the rebuilt day state and
                // the fixture's events SHRANK.
                let prior = fotmobDetailCache[fid]?.events ?? []
                if events.count >= prior.count,
                   !events.isEmpty || states[key]?.status == .ft {
                    let stamp = Date()
                    let isFinal = states[key]?.status == .ft
                    fotmobDetailCache[fid] = (events: events, fetchedAt: stamp,
                                               final: isFinal)
                    // 1.7.7 (item d): a final answer also
                    // writes through to the persisted ledger,
                    // so it survives the next cold launch.
                    if isFinal {
                        persistSettledDetail(fid: fid, events: events, fetchedAt: stamp)
                    }
                }
                applyBoardDetail(events, fid: fid, key: key)
            }
        }
    }

    /// Register the hero fixture for detail-upgrade priority
    /// (1.4.8): the cycle pass sorts this pair's FotMob states
    /// — winner or donor — ahead of every other candidate.
    /// Nil clears the priority (the hero shows no fixture).
    func setDetailPriority(for channel: Channel?) {
        detailPriorityPairKey = channel.flatMap { pairKey(for: $0) }
    }

    /// On-demand FotMob detail upgrade for the fixture the
    /// hero panel is showing (1.4.8, FL-331): the hero is the
    /// always-visible surface, so it is the board-open case's
    /// sibling — the fixture the owner is looking at NOW must
    /// not wait for the cycle's capped pass to reach it. Same
    /// guards, same cache, same write-back discipline as
    /// requestBoardDetail (the state passed is the fixture's
    /// bound state; a non-FotMob winner is refused by the
    /// shared guard, and the cycle's priority ordering covers
    /// a FotMob donor sitting under another date key).
    func requestHeroDetail(for state: MatchState) {
        requestBoardDetail(for: state)
    }

    private func applyBoardDetail(_ events: [MatchEvent], fid: Int, key: String) {
        // 1.5.1 (FL-370): the write-back used to require the
        // stored list to be EMPTY, so a detail fetched early in
        // a live match capped the fixture's events for good.
        // It now accepts any STRICTLY RICHER list for the same
        // FotMob state — never a shorter one (a refetch can
        // only complete the picture, never shrink it).
        guard let current = states[key], current.source == .fotmob,
              current.fotmobID == fid,
              events.count > current.events.count else { return }
        states[key] = current.withEvents(events)
        rebuildDonorIndex()
        onChange?()
        DiagLog.write("board", "fotmob detail id=\(fid) events=\(events.count)")
    }

    private func hasLiveScope() -> Bool {
        guard let fixtures = fixturesProvider?() else { return false }
        let now = Date()
        if fixtures.contains(where: { LeagueClassifier.bucket(of: $0, now: now) == 0 }) {
            return true
        }
        return states.values.contains { $0.status == .live || $0.status == .ht }
    }

    // MARK: - Lookup (pair-key + date agreement, fail closed)

    /// Pair-key cache (KH-2 item 3): canonicalising a channel's
    /// title (Crests.norm + the alias tables) used to run again
    /// on EVERY state(for:) / competition(for:) call — 4–6 times
    /// per fixture per body pass on the focus path. The key is a
    /// pure function of the channel's TITLE (MatchPairKey.key(of:)
    /// reads nothing else), so the title is the cache key; ""
    /// stores a known-nil (a real pair key is never empty —
    /// MatchPairKey.key guards both sides non-empty). The mapping
    /// can never go stale inside a process: the alias tables are
    /// static and Crests.norm is pure.
    private var pairKeyCache: [String: String] = [:]

    private func pairKey(for channel: Channel) -> String? {
        if let hit = pairKeyCache[channel.title] {
            return hit.isEmpty ? nil : hit
        }
        let key = MatchPairKey.key(of: channel)
        pairKeyCache[channel.title] = key ?? ""
        return key
    }

    /// The matched state for a fixture channel, or nil. Tries the
    /// fixture's own ICT stamp date first, then the ±1-day ESPN
    /// seam — the seam binds only when the kickoff instants are
    /// within 3 h (plan §1.4). States older than the 30-minute
    /// last-good window no longer override anything. The winner
    /// is then completed by the partial-state merge
    /// (filledFromPool): its missing fields are filled from the
    /// fixture's other date-compatible states, never overwritten.
    func state(for channel: Channel, now: Date = Date()) -> MatchState? {
        guard let kickoff = channel.kickoff,
              let pair = pairKey(for: channel) else { return nil }
        let ownKey = FixtureGrouping.stampDateKey(of: kickoff)
        if let s = states[pair + "|" + ownKey], isFresh(s, now: now) {
            return filledFromPool(s, fixtureKickoff: kickoff,
                                  fixtureDateKey: ownKey, now: now)
        }
        for delta in [-86400.0, 86400.0] {
            let seamKey = FixtureGrouping.stampDateKey(of: kickoff.addingTimeInterval(delta))
            guard let s = states[pair + "|" + seamKey], isFresh(s, now: now),
                  let sk = s.kickoff,
                  abs(sk.timeIntervalSince(kickoff)) <= 3 * 3600 else { continue }
            return filledFromPool(s, fixtureKickoff: kickoff,
                                  fixtureDateKey: ownKey, now: now)
        }
        // KH-9 (ĐG-9): a LiveScore state carries no kickoff (the
        // layer is score + minute only), so the seam above —
        // which requires the state's kickoff — could NEVER bind
        // it to a fixture stamped on the neighbouring ICT day:
        // a dead path for exactly the late Americas fixtures
        // that layer exists to cover. The feed DOES carry a
        // start stamp (Esd, yyyyMMddHHmmss — payload captured
        // 2026-11-19, 143-evidence/ls_live.json), but its
        // timezone is not the UTC it appears to be (the four
        // live events read exactly UTC+3 against their ESPN
        // kickoffs, an offset no documentation states and that
        // may follow the requester's locale), so no kickoff is
        // derived from it — a wrong instant would do more harm
        // than none. Fallback, fail closed: when exactly ONE
        // fresh LiveScore state exists for this pair across all
        // date keys it binds; two or more (today's beside a
        // last-good from the previous day) are ambiguous and
        // bind nothing.
        let lsCandidates = states.values.filter {
            $0.pairKey == pair && $0.source == .livescore && isFresh($0, now: now)
        }
        if lsCandidates.count == 1 {
            return filledFromPool(lsCandidates[0], fixtureKickoff: kickoff,
                                  fixtureDateKey: ownKey, now: now)
        }
        return nil
    }

    /// Partial-state merge (1.4.5, the FIX-127 port of the RC2 /
    /// FL-120 fix): precedence picks the winning STATE, but a
    /// source's state is often partial — Flashscore carries a
    /// score with no minute and no incidents, a FotMob state can
    /// carry the minute while another layer carries the events —
    /// and the pre-1.4.5 lookup returned the winner exactly as
    /// stored, so the fixture rendered the parts no single source
    /// had assembled (score shown, scorers/cards missing, even
    /// though a bound state for the same fixture held them). The
    /// winner now keeps every field it HAS; only its gaps are
    /// filled, from the fixture's own donor pool — fresh states
    /// for the same pair that are date-compatible with the
    /// FIXTURE (its own stamp date, or a kickoff within 3 h
    /// across the seam — the same agreement the winner itself
    /// had to pass; never from outside that pool), strongest
    /// layer first:
    /// - status: a `.pre` winner yields to a pool donor already
    ///   live / half-time / full-time (a reported later status
    ///   is never downgraded — RC5 discipline);
    /// - score: filled as a PAIR from the first donor carrying
    ///   both sides AND agreeing with every side the winner
    ///   already holds — home from one source and away from
    ///   another is never mixed, and a donor that contradicts
    ///   a set side is refused (fail closed);
    /// - minute, events, competition: filled when absent.
    /// A donor never overwrites a set field, so the merged
    /// state is still recognisably the winner's truth,
    /// completed. The stored states are not mutated — the fill
    /// is recomputed at every lookup, exactly like iOS.
    private func filledFromPool(_ winner: MatchState, fixtureKickoff: Date,
                                fixtureDateKey: String, now: Date) -> MatchState {
        // 1.7.10: the candidate set comes from the pairKey
        // donor index (rebuilt at each publish) instead of a
        // full-states filter — the remaining predicates and
        // the rank sort are exactly the pre-1.7.10 ones, so
        // the donor pool a lookup sees is unchanged; only its
        // cost is now O(this pair's states), not O(all states).
        let donors = (donorIndex[winner.pairKey] ?? [])
            .filter { s in
                s.storageKey != winner.storageKey
                    && isFresh(s, now: now)
                    && (s.dateKey == fixtureDateKey
                        || (s.kickoff.map {
                            abs($0.timeIntervalSince(fixtureKickoff)) <= 3 * 3600
                        } ?? false))
            }
            .sorted { Self.rank($0.source) < Self.rank($1.source) }
        guard !donors.isEmpty else { return winner }
        var status = winner.status
        var minuteText = winner.minuteText
        var scoreHome = winner.scoreHome
        var scoreAway = winner.scoreAway
        var events = winner.events
        var competition = winner.competition
        if status == .pre,
           let donor = donors.first(where: {
               $0.status == .live || $0.status == .ht || $0.status == .ft
           }) {
            status = donor.status
            if minuteText == nil { minuteText = donor.minuteText }
        }
        if scoreHome == nil || scoreAway == nil,
           let donor = donors.first(where: {
               $0.scoreHome != nil && $0.scoreAway != nil
                   && (scoreHome == nil || $0.scoreHome == scoreHome)
                   && (scoreAway == nil || $0.scoreAway == scoreAway)
           }) {
            scoreHome = donor.scoreHome
            scoreAway = donor.scoreAway
        }
        if minuteText == nil {
            minuteText = donors.first(where: { $0.minuteText != nil })?.minuteText
        }
        // 1.5.1 (FL-370): the events fill was all-or-nothing —
        // a winner holding a PARTIAL event list (one goal of
        // two, no cards) blocked every donor's fuller list for
        // the whole match, which is the owner's Monaco board
        // (score 1-1, only the 82' goal shown, the 29' goal
        // and the cards missing though both event sources
        // carried them). The fill is now richest-wins: a donor
        // whose list is LONGER than the current one replaces
        // it, but only when the donor's scoreline equals the
        // merged score exactly — events describing a different
        // score are never mixed in (fail closed, the same
        // discipline as the score fill above). The RICHEST
        // qualifying donor wins (review round 1: first-by-rank
        // let a stronger layer's shorter list shadow a fuller
        // one — goals shown, cards still missing); ties break
        // to the strongest layer, as donors are rank-sorted
        // and max(by:) keeps the first maximum.
        if let donor = donors
            .filter({
                $0.events.count > events.count
                    && $0.scoreHome != nil && $0.scoreHome == scoreHome
                    && $0.scoreAway != nil && $0.scoreAway == scoreAway
            })
            .max(by: { $0.events.count < $1.events.count }) {
            events = donor.events
        }
        if competition == nil {
            competition = donors.first(where: { $0.competition != nil })?.competition
        }
        if status == winner.status, minuteText == winner.minuteText,
           scoreHome == winner.scoreHome, scoreAway == winner.scoreAway,
           events == winner.events, competition == winner.competition {
            return winner
        }
        return MatchState(
            pairKey: winner.pairKey, dateKey: winner.dateKey,
            competition: competition, status: status,
            minuteText: minuteText, scoreHome: scoreHome, scoreAway: scoreAway,
            events: events, source: winner.source, fetchedAt: winner.fetchedAt,
            kickoff: winner.kickoff, fotmobID: winner.fotmobID,
            homeName: winner.homeName, awayName: winner.awayName,
            logoHome: winner.logoHome, logoAway: winner.logoAway)
    }

    private func isFresh(_ s: MatchState, now: Date) -> Bool {
        now.timeIntervalSince(s.fetchedAt) <= Self.lastGoodWindow
    }

    // MARK: - Bounded computed clock (plan §1.6, fallback only)

    /// Computed minute for an unmatched fixture: elapsed ≤ 45
    /// shows elapsed; 46–60 shows first-half added time
    /// ("45'+N", N = elapsed − 45) — half time is NEVER computed,
    /// it is shown only when a source reports the HT status
    /// (RC5, 2026-11-19: the old 45–60 → HT window declared the
    /// break up to 15 min early whenever the first half ran long);
    /// past 60 shows elapsed − 15; the estimate freezes at "90+'"
    /// once it passes 100. No score is ever computed.
    /// Pure date arithmetic — `nonisolated` because the view
    /// layer (TVFixtureEntry, a plain struct) reads it from
    /// non-isolated contexts; the class's @MainActor isolation
    /// would otherwise make every such call a Swift 6 error
    /// (the 1.3.8 main-actor-static failure family).
    nonisolated static func computedBadge(kickoff: Date, now: Date = Date()) -> String? {
        let elapsed = Int(now.timeIntervalSince(kickoff) / 60)
        if elapsed < 0 { return nil }
        if elapsed <= 45 { return "\(max(1, elapsed))'" }
        if elapsed <= 60 { return "45'+\(elapsed - 45)'" }
        let shown = elapsed - 15
        if shown > 100 { return "90+'" }
        return "\(shown)'"
    }

    // MARK: - Poll cycle

    private func cycle() async {
        if fetching { return }
        fetching = true
        defer { fetching = false }
        let now = Date()
        // ESPN days to fetch (KH-4, ĐG-8): ESPN files its events
        // under the US-EASTERN day, so the window is read in
        // America/New_York — {yesterday, today, tomorrow} Eastern.
        // The old window read two ICT days: during US-evening
        // hours ICT is already a day ahead, the Eastern day the
        // evening's Americas fixtures are filed under was never
        // requested, and ESPN silently never answered them.
        let days = Self.espnDays(now: now)
        let todayICT = Self.ictDateKey(now)
        async let espnResult = Self.fetchESPN(slugs: CompetitionID.espnSlugs, days: days)
        // 1.7.7 (item c): the fifth layer — ESPN basketball
        // (NBA), fetched in the same Eastern day window. Its
        // states join the precedence merge directly AFTER the
        // ESPN soccer layer (pair keys cannot collide with
        // soccer pairs in practice; the order is
        // belt-and-braces).
        async let basketballResult = Self.fetchESPNBasketball(days: days)
        async let fotmobResult = Self.fetchFotMobMerged(now: now)
        async let flashscoreResult = Self.fetchFlashscore()
        async let livescoreResult = Self.fetchLiveScore(todayKey: todayICT)
        let results = await [espnResult, fotmobResult, flashscoreResult, livescoreResult]
        let basketball = await basketballResult
        let layers = [results[0].states, basketball.states, results[1].states,
                      results[2].states, results[3].states]

        // Precedence ESPN > FotMob > Flashscore > LiveScore, wholesale per
        // fixture key (plan §1.4): a lower layer never overwrites
        // a key a higher layer produced.
        var merged: [String: MatchState] = [:]
        for layer in layers {
            for (key, state) in layer where merged[key] == nil {
                merged[key] = state
            }
        }
        // FotMob detail upgrade: a FotMob day-feed state with no
        // events yet earns a matchDetails call, capped at 4 per
        // cycle, live fixtures first (plan §1.2). Same source
        // family, so adding events to the day-feed state is the
        // one allowed upgrade. (1.4.6: finished states are
        // eligible too — the iOS cadence; a 90+' fixture whose
        // FotMob state never earned its scorers/cards was
        // exactly the owner's FL-331 photograph.)
        // 1.4.8 (FL-331, device video 2026-11-20): two ordering
        // defects starved the fixture the owner was looking at.
        // The candidate order fell back to the storage-key
        // string over the WHOLE merged day feed, so a featured
        // match waited behind dozens of unrelated fixtures; and
        // the budget burned on cache applications as well as
        // fetches, though the plan caps CALLS. Now: the hero
        // fixture's pair (registered by the view layer) sorts
        // first — winner or donor, same pair key — then live
        // before finished, then key; cached events apply FREE
        // (the iOS RC2 shape: the cap counts fetches only, and
        // a cached id is never refetched).
        var detailBudget = Self.fotmobDetailCap
        let detailCandidates = merged
            .filter { $0.value.source == .fotmob
                && ($0.value.status == .live || $0.value.status == .ht
                    || $0.value.status == .ft)
                && $0.value.events.isEmpty && $0.value.fotmobID != nil }
            .map { $0.key }
            .sorted { a, b in
                let heroA = merged[a]?.pairKey == detailPriorityPairKey ? 0 : 1
                let heroB = merged[b]?.pairKey == detailPriorityPairKey ? 0 : 1
                if heroA != heroB { return heroA < heroB }
                let liveRankA = (merged[a]?.status == .ft) ? 1 : 0
                let liveRankB = (merged[b]?.status == .ft) ? 1 : 0
                if liveRankA != liveRankB { return liveRankA < liveRankB }
                return a < b
            }
        for key in detailCandidates {
            guard let state = merged[key], let fid = state.fotmobID else { continue }
            // 1.5.1 (FL-370): a cached answer applies while it
            // is FRESH — final for a finished match, a 120 s
            // snapshot for a live one. The pre-1.5.1 code
            // applied a non-empty cache entry forever, freezing
            // a live match's scorers/cards at the first fetch's
            // minute. An expired snapshot still beats no events
            // when the fetch budget is spent or a fetch fails,
            // and a refetch can only grow the list (richer
            // wins), never shrink it.
            let cached = fotmobDetailCache[fid]
            let cacheFresh = cached != nil
                && (cached!.final
                    || now.timeIntervalSince(cached!.fetchedAt) < 120)
            if let cached, cacheFresh {
                merged[key] = state.withEvents(cached.events)
            } else if detailBudget > 0 {
                detailBudget -= 1
                if let events = await Self.fetchFotMobDetail(id: fid) {
                    // 1.4.8 (FL-331): an EMPTY answer is final
                    // only for a finished match. For a live one
                    // it means "no events yet" — caching it
                    // poisoned the fixture for the whole
                    // session: the first fetch's empty answer
                    // made every later cycle re-apply emptiness
                    // from the cache and never fetch again,
                    // however many goals followed (the owner's
                    // Bayern hero: score present, scorers
                    // missing all match). Empty live answers
                    // are applied for this cycle (a no-op) but
                    // never stored, so the fixture stays
                    // fetch-eligible under the same cap.
                    // The richer-wins comparison reads the
                    // cache AFTER the fetch suspends, never
                    // the pre-fetch snapshot (review round 1:
                    // a board/hero fetch for the same fixture
                    // can land while this fetch is in flight —
                    // the two paths share no in-flight guard —
                    // and guarding against the stale snapshot
                    // let the slower, shorter answer overwrite
                    // the richer cache and shrink the fixture).
                    let prior = fotmobDetailCache[fid]?.events ?? []
                    let applied = events.count >= prior.count ? events : prior
                    if applied.count == events.count,
                       !events.isEmpty || state.status == .ft {
                        fotmobDetailCache[fid] = (events: events, fetchedAt: now,
                                                   final: state.status == .ft)
                        // 1.7.7 (item d): a final answer also
                        // writes through to the persisted
                        // ledger, so it survives the next cold
                        // launch. Live answers never persist.
                        if state.status == .ft {
                            persistSettledDetail(fid: fid, events: events, fetchedAt: now)
                        }
                    }
                    merged[key] = state.withEvents(applied)
                } else if let cached {
                    merged[key] = state.withEvents(cached.events)
                }
            } else if let cached {
                merged[key] = state.withEvents(cached.events)
            }
        }
        // Staleness guard (KH-3, ĐG-7): a frozen winning layer
        // may yield to a fresher lower layer under the strict
        // fail-closed conditions in applyStalenessGuard.
        applyStalenessGuard(&merged, layers: layers)
        // Keep last-good for keys no layer answered this cycle (a
        // source error skips that cycle only, plan §1.7).
        var next = merged
        for (key, old) in states where next[key] == nil && isFresh(old, now: now) {
            next[key] = old
        }
        // 1.5.1 (FL-370, review round 1): never let this
        // assignment shrink a FotMob state's events below what
        // the store already holds. A board/hero detail fetch
        // writes into `states` directly (applyBoardDetail) and
        // can land WHILE this cycle is suspended on a later
        // candidate's fetch — after the fixture's own merged
        // snapshot was taken. Without this reconcile, the
        // wholesale assignment rolled the enriched state back
        // to the snapshot's shorter list. The guard is scoped
        // to the same fixture's FotMob state (same fotmobID):
        // layer precedence itself is untouched.
        for (key, old) in states {
            guard let incoming = next[key],
                  old.source == .fotmob, incoming.source == .fotmob,
                  old.fotmobID != nil, old.fotmobID == incoming.fotmobID,
                  old.events.count > incoming.events.count
            else { continue }
            next[key] = incoming.withEvents(old.events)
        }
        if next != states {
            states = next
            rebuildDonorIndex()
            onChange?()
        }
        // KH-1: the cycle's own account of itself — per-layer
        // counts, the merged total, the ESPN day window used —
        // plus the live-window fixtures no layer bound (the
        // bind-miss evidence ĐG-3 made impossible to collect).
        DiagLog.write("poll", "espn=\(layers[0].count) nba=\(layers[1].count) "
            + "fotmob=\(layers[2].count) "
            + "flash=\(layers[3].count) livescore=\(layers[4].count) "
            + "merged=\(next.count) espnDays=\(days.joined(separator: ","))")
        // 1.4.4, item 3: how each layer's FETCH ended this
        // cycle — "ok states=N" (answered; N may be 0) is now
        // distinguishable from "http-403"/"error"/"decode"
        // (never answered), which the counts line alone cannot
        // express.
        DiagLog.write("fetch", "espn: \(results[0].report) · nba: \(basketball.report) "
            + "· fotmob: \(results[1].report) "
            + "· flash: \(results[2].report) · livescore: \(results[3].report)")
        if let fixtures = fixturesProvider?() {
            var misses: [String] = []
            for ch in fixtures
            where LeagueClassifier.bucket(of: ch, now: now) == 0 {
                if state(for: ch, now: now) == nil {
                    misses.append(MatchPairKey.key(of: ch) ?? ch.title)
                }
            }
            if !misses.isEmpty {
                DiagLog.write("poll", "bind-miss \(misses.count): "
                    + misses.prefix(5).joined(separator: " | "))
            }
        }
    }

    // MARK: - Staleness guard (KH-3, ĐG-7)

    /// The winning layer's rank (lower = stronger) — the same
    /// order cycle() merges in.
    private static func rank(_ source: MatchSource) -> Int {
        switch source {
        case .espn: return 0
        case .fotmob: return 1
        case .flashscore: return 2
        case .livescore: return 3
        }
    }

    /// A comparable minute for a live state: "61'" → 61,
    /// "45'+3'" → 48. nil when the state is not live or carries
    /// no parseable minute (Flashscore states never carry one)
    /// — such states can neither be guarded nor challenge.
    nonisolated static func minuteValue(of state: MatchState) -> Double? {
        guard state.status == .live, let text = state.minuteText else { return nil }
        let parts = text.replacingOccurrences(of: "'", with: "")
            .split(separator: "+")
        guard !parts.isEmpty else { return nil }
        var total = 0
        for part in parts {
            guard let v = Int(part.trimmingCharacters(in: .whitespaces))
            else { return nil }
            total += v
        }
        return Double(total)
    }

    /// Per-key winner history for the guard: the winning source,
    /// its minute, and how many consecutive cycles that minute
    /// has now stood still.
    private var winnerTrack: [String: (source: MatchSource, minute: Double, stuck: Int)] = [:]

    /// The guard (plan KH-3): the winning (highest-layer) state
    /// yields for THIS cycle only when ALL of these hold —
    ///   · the winner is .live and its minute has not advanced
    ///     for 2 consecutive cycles (a server-frozen payload
    ///     re-fetched every 60 s otherwise looks forever fresh:
    ///     fetchedAt is our own fetch stamp, ĐG-7);
    ///   · a lower layer holds a state for the same key that is
    ///     also .live and whose minute is at least 3 ahead;
    ///   · the challenger's score is not behind the winner's on
    ///     either side (goals never go backwards).
    /// Anything else — HT/FT states, a minute-less layer, a
    /// genuinely standing minute both layers agree on — leaves
    /// the layer order exactly as it was. The override is
    /// recomputed from the live layers every cycle; nothing is
    /// latched.
    /// Internal (not private) so the desk harness can replay
    /// frozen-layer sequences against the real function (KH-3).
    func applyStalenessGuard(_ merged: inout [String: MatchState],
                                     layers: [[String: MatchState]]) {
        var overrides: [(String, MatchState, MatchState)] = []
        for (key, winner) in merged {
            guard let wMinute = Self.minuteValue(of: winner) else {
                winnerTrack.removeValue(forKey: key)
                continue
            }
            let stuck: Int
            if let t = winnerTrack[key],
               t.source == winner.source, t.minute == wMinute {
                stuck = t.stuck + 1
            } else {
                stuck = 0
            }
            winnerTrack[key] = (winner.source, wMinute, stuck)
            guard stuck >= 2 else { continue }
            let wRank = Self.rank(winner.source)
            var challenger: MatchState? = nil
            for layer in layers {
                guard let s = layer[key], Self.rank(s.source) > wRank,
                      let cMinute = Self.minuteValue(of: s),
                      cMinute >= wMinute + 3
                else { continue }
                challenger = s
                break
            }
            guard let challenger,
                  let cH = challenger.scoreHome, let cA = challenger.scoreAway,
                  let wH = winner.scoreHome, let wA = winner.scoreAway,
                  cH >= wH, cA >= wA
            else { continue }
            overrides.append((key, winner, challenger))
        }
        for (key, winner, challenger) in overrides {
            merged[key] = challenger
            DiagLog.write("guard", "override \(key): \(winner.source) "
                + "\(winner.minuteText ?? "?") stood still → "
                + "\(challenger.source) \(challenger.minuteText ?? "?")")
        }
    }

    // MARK: - Date helpers

    /// America/New_York calendar — ESPN files its events under
    /// the US-Eastern day (KH-4, ĐG-8).
    nonisolated private static func easternCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return cal
    }

    /// The ESPN fetch window: "YYYYMMDD" for the Eastern
    /// {yesterday, today, tomorrow} around `now`. The three days
    /// are built with calendar day arithmetic in the Eastern
    /// calendar itself (never ±86400 s), so a DST transition day
    /// (23/25 h) can neither skip nor duplicate a day.
    /// Internal (not private) so the desk harness can assert
    /// the KH-4 window against the real function.
    nonisolated static func espnDays(now: Date) -> [String] {
        let cal = easternCalendar()
        let start = cal.startOfDay(for: now)
        return (-1...1).compactMap { offset in
            cal.date(byAdding: .day, value: offset, to: start)
        }.map { day in
            let c = cal.dateComponents([.year, .month, .day], from: day)
            return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }
    }

    /// The app's own local calendar (owner timezone ruling
    /// 2026-11-19: every app runs on the Oklahoma timezone,
    /// America/Chicago; only iOS follows the device location).
    /// Used ONLY to choose which source day-files to fetch —
    /// never for binding keys, which stay on the playlist's ICT
    /// stamp convention (FixtureGrouping.stampDateKey).
    nonisolated private static func appCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        return cal
    }

    /// UTC calendar — FotMob files its day feeds under the UTC
    /// date, not the reader's local date.
    nonisolated private static func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }

    /// "yyyyMMdd" for FotMob's date= parameter, the date read
    /// in the given calendar. (1.4.6, FL-331: the old
    /// "YYYY-MM-DD" form is answered by FotMob with a literal
    /// null body — measured 4 bytes against 112,601 bytes of
    /// real JSON for the yyyyMMdd form — so the layer decoded
    /// zero states on every cycle.)
    nonisolated private static func fotmobDayString(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The UTC start of the day a yyyyMMdd FotMob day-param
    /// names — the fallback dateKey for a match whose kickoff
    /// stamp is missing (1.4.6: the iOS shape; the old code fell
    /// back to the fetch instant, stamping the state with
    /// whatever day the poll happened to run on).
    nonisolated private static func fotmobDayStart(_ dayParam: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd"
        return f.date(from: dayParam)
    }

    /// ICT date key in FixtureGrouping.stampDateKey form.
    nonisolated private static func ictDateKey(_ date: Date) -> String {
        FixtureGrouping.stampDateKey(of: date)
    }

    nonisolated private static func isoDate(_ stamp: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: stamp) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: stamp)
    }

    // MARK: - HTTP

    /// The three ways one HTTP fetch can end (1.4.4, item 3):
    /// the cycle's fetch-status line exists because the layers
    /// used to collapse all three into "empty", so the log could
    /// not tell "the source answered, there was nothing" from
    /// "the source never answered" (the owner's 1.4.3 log read
    /// espn=0 fotmob=0 flash=403 with no way to say which zeros
    /// were health and which were silence).
    private enum HTTPOutcome {
        case ok(Data)
        case http(Int)
        case failed
    }

    /// One ESPN board fetch's product: the states it produced
    /// plus how the fetch itself ended — "ok", "http-<code>",
    /// "error" (transport) or "decode" (200 but unparseable).
    /// slug + day ride along so fetchESPN can log EVERY failed
    /// board individually (1.4.6, FL-331: the 1.4.5 device log
    /// could only print the first failure's kind, so an
    /// all-boards failure was undiagnosable from one log).
    private struct BoardFetch: Sendable {
        let slug: String
        let day: String
        let states: [MatchState]
        let outcome: String
    }

    /// One FotMob day fetch's product — same contract, keyed.
    private struct LayerFetch: Sendable {
        let states: [String: MatchState]
        let outcome: String
    }

    /// One layer's whole cycle product: the merged states plus
    /// the one-line report the fetch log prints.
    private struct LayerResult: Sendable {
        let states: [String: MatchState]
        let report: String
    }

    nonisolated private static func getDetailed(_ url: URL, headers: [String: String] = [:]) async -> HTTPOutcome {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            return http.statusCode == 200 ? .ok(data) : .http(http.statusCode)
        } catch {
            return .failed
        }
    }

    /// The pre-1.4.4 seam, kept for the callers that only need
    /// the bytes (the FotMob detail fetch): exactly getDetailed
    /// collapsed to nil-on-anything-but-200, so its behaviour is
    /// unchanged.
    nonisolated private static func get(_ url: URL, headers: [String: String] = [:]) async -> Data? {
        if case .ok(let data) = await getDetailed(url, headers: headers) { return data }
        return nil
    }

    // MARK: - ESPN (primary)

    private struct ESPNBoard: Decodable {
        struct Event: Decodable {
            struct Competition: Decodable {
                struct Competitor: Decodable {
                    struct Team: Decodable {
                        let id: String?
                        let displayName: String?
                        /// The team's crest URL on ESPN's CDN
                        /// (1.4.4: captured for the display
                        /// layer's per-side fallback — every
                        /// team object in the captured payloads
                        /// carries one).
                        let logo: String?
                    }
                    let homeAway: String?
                    let score: String?
                    let team: Team?
                }
                struct Detail: Decodable {
                    struct Kind: Decodable { let text: String? }
                    struct Athlete: Decodable { let displayName: String?; let shortName: String? }
                    struct Clock: Decodable { let displayValue: String? }
                    struct TeamRef: Decodable { let id: String? }
                    let type: Kind?
                    let team: TeamRef?
                    let scoringPlay: Bool?
                    let yellowCard: Bool?
                    let redCard: Bool?
                    let athletesInvolved: [Athlete]?
                    let clock: Clock?
                }
                let competitors: [Competitor]?
                let details: [Detail]?
            }
            struct Status: Decodable {
                struct Kind: Decodable {
                    let name: String?
                    let state: String?
                    let completed: Bool?
                    let detail: String?
                }
                let type: Kind?
                let displayClock: String?
                /// The game period (1.7.7, item c): basketball
                /// only — 1–4 are quarters, 5+ are overtime
                /// periods. Soccer payloads omit it (verified
                /// against the captured NBA scoreboard payload,
                /// work-177/espn-nba-sample.json: status.period
                /// is an Int on every event). Optional, so the
                /// soccer decode is unchanged.
                let period: Int?
            }
            let date: String?
            let competitions: [Competition]?
            let status: Status?
        }
        let events: [Event]?
    }

    nonisolated private static func fetchESPN(slugs: [String], days: [String]) async -> LayerResult {
        var out: [String: MatchState] = [:]
        var okBoards = 0
        var totalBoards = 0
        var firstFailure: String? = nil
        await withTaskGroup(of: BoardFetch.self) { group in
            for slug in slugs {
                for day in days {
                    group.addTask { await fetchESPNBoard(slug: slug, day: day) }
                }
            }
            for await board in group {
                totalBoards += 1
                if board.outcome == "ok" { okBoards += 1 }
                else {
                    if firstFailure == nil { firstFailure = board.outcome }
                    DiagLog.write("fetch", "espn board fail slug=\(board.slug) "
                        + "day=\(board.day) outcome=\(board.outcome)")
                }
                for s in board.states { out[s.storageKey] = s }
            }
        }
        let report: String
        if okBoards == totalBoards {
            report = "ok states=\(out.count) boards=\(okBoards)/\(totalBoards)"
        } else if okBoards == 0 {
            report = "\(firstFailure ?? "error") states=0 boards=0/\(totalBoards)"
        } else {
            report = "partial states=\(out.count) boards=\(okBoards)/\(totalBoards) "
                + "fail=\(firstFailure ?? "error")"
        }
        return LayerResult(states: out, report: report)
    }

    nonisolated private static func fetchESPNBoard(slug: String, day: String) async -> BoardFetch {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/soccer/\(slug)/scoreboard?dates=\(day)") else {
            return BoardFetch(slug: slug, day: day, states: [], outcome: "error")
        }
        let data: Data
        switch await getDetailed(url) {
        case .ok(let payload): data = payload
        case .http(let code): return BoardFetch(slug: slug, day: day, states: [], outcome: "http-\(code)")
        case .failed: return BoardFetch(slug: slug, day: day, states: [], outcome: "error")
        }
        guard let board = try? JSONDecoder().decode(ESPNBoard.self, from: data) else {
            return BoardFetch(slug: slug, day: day, states: [], outcome: "decode")
        }
        let competition = CompetitionID(espnSlug: slug)
        var out: [MatchState] = []
        for event in board.events ?? [] {
            guard let comp = event.competitions?.first,
                  let competitors = comp.competitors,
                  let home = competitors.first(where: { $0.homeAway == "home" }),
                  let away = competitors.first(where: { $0.homeAway == "away" }),
                  let homeName = home.team?.displayName,
                  let awayName = away.team?.displayName,
                  let pair = MatchPairKey.key(home: homeName, away: awayName) else { continue }
            let type = event.status?.type
            let status: MatchStatus
            if type?.completed == true { status = .ft }
            else if type?.state == "in" {
                let marker = ((type?.detail ?? "") + " " + (type?.name ?? "")).uppercased()
                status = marker.contains("HALF") ? .ht : .live
            } else if (type?.name ?? "").uppercased().contains("POSTPON") { status = .postponed }
            else if (type?.name ?? "").uppercased().contains("CANCEL") { status = .cancelled }
            else { status = .pre }
            // Event sides resolve through the wire's team ids:
            // a detail belongs to the side whose competitor team
            // id it carries. A detail with no resolvable side is
            // dropped, never guessed onto a column.
            var events: [MatchEvent] = []
            for d in comp.details ?? [] {
                let isHome: Bool
                if let tid = d.team?.id, tid == home.team?.id { isHome = true }
                else if let tid = d.team?.id, tid == away.team?.id { isHome = false }
                else { continue }
                let name = d.athletesInvolved?.first.flatMap { $0.shortName ?? $0.displayName } ?? ""
                let minute = d.clock?.displayValue ?? ""
                let text = (d.type?.text ?? "").lowercased()
                if d.scoringPlay == true {
                    events.append(MatchEvent(
                        kind: .goal, minuteText: minute, playerName: name, isHome: isHome,
                        isPenalty: text.contains("penalty"),
                        isOwnGoal: text.contains("own goal")))
                } else if d.redCard == true || text.contains("red card") {
                    events.append(MatchEvent(
                        kind: .redCard, minuteText: minute, playerName: name, isHome: isHome,
                        isPenalty: false, isOwnGoal: false))
                } else if d.yellowCard == true || text.contains("yellow card") {
                    events.append(MatchEvent(
                        kind: .yellowCard, minuteText: minute, playerName: name, isHome: isHome,
                        isPenalty: false, isOwnGoal: false))
                }
            }
            let kickoff = event.date.flatMap { isoDate($0) }
            let dateKey = kickoff.map { FixtureGrouping.stampDateKey(of: $0) } ?? ""
            guard !dateKey.isEmpty else { continue }
            // The feed's own badges go into Crests' learned
            // registry (DB-02, 1.4.5), so the card — which looks
            // crests up by the playlist's spelling of the same
            // team — finds them even when the static map never
            // carried the team. They ALSO stay on the state
            // (logoHome/logoAway) for the 1.4.4 display fallback.
            if let s = home.team?.logo, let u = URL(string: s) {
                Crests.registerLearnedLogo(forTeam: homeName, logoURL: u)
            }
            if let s = away.team?.logo, let u = URL(string: s) {
                Crests.registerLearnedLogo(forTeam: awayName, logoURL: u)
            }
            out.append(MatchState(
                pairKey: pair, dateKey: dateKey, competition: competition,
                status: status,
                minuteText: status == .live ? event.status?.displayClock : nil,
                scoreHome: home.score.flatMap { Int($0) },
                scoreAway: away.score.flatMap { Int($0) },
                events: events, source: .espn, fetchedAt: Date(),
                kickoff: kickoff, fotmobID: nil,
                homeName: homeName, awayName: awayName,
                logoHome: home.team?.logo, logoAway: away.team?.logo))
        }
        return BoardFetch(slug: slug, day: day, states: out, outcome: "ok")
    }

    // MARK: - ESPN basketball (NBA, 1.7.7 item c)

    /// The basketball twin of fetchESPN: same BoardFetch /
    /// LayerResult reporting shape, same Eastern day window,
    /// but the slug table is CompetitionID.espnBasketballSlugs
    /// and the URL is the BASKETBALL sport path — the soccer
    /// slug list and URL are untouched. Field shapes verified
    /// against a captured live payload
    /// (work-177/espn-nba-sample.json, 2026-11-23): every
    /// event carries status.period (Int; 4 = Q4, 5 = first
    /// OT), status.displayClock ("9:32"), status.type
    /// (state "in"/"post", completed, detail "9:32 - 4th
    /// Quarter" / "Final" / "Final/OT", name
    /// STATUS_IN_PROGRESS / STATUS_FINAL), competitors[]
    /// .score as a String, team.displayName and team.logo.
    /// NBA competitions carry NO details array, so states are
    /// built with events: [] — basketball has no goal/card
    /// events and MatchEvent.Kind gains no basketball kinds.
    nonisolated private static func fetchESPNBasketball(days: [String]) async -> LayerResult {
        var out: [String: MatchState] = [:]
        var okBoards = 0
        var totalBoards = 0
        var firstFailure: String? = nil
        await withTaskGroup(of: BoardFetch.self) { group in
            for slug in CompetitionID.espnBasketballSlugs {
                for day in days {
                    group.addTask { await fetchESPNBasketballBoard(slug: slug, day: day) }
                }
            }
            for await board in group {
                totalBoards += 1
                if board.outcome == "ok" { okBoards += 1 }
                else {
                    if firstFailure == nil { firstFailure = board.outcome }
                    DiagLog.write("fetch", "espn basketball board fail slug=\(board.slug) "
                        + "day=\(board.day) outcome=\(board.outcome)")
                }
                for s in board.states { out[s.storageKey] = s }
            }
        }
        let report: String
        if okBoards == totalBoards {
            report = "ok states=\(out.count) boards=\(okBoards)/\(totalBoards)"
        } else if okBoards == 0 {
            report = "\(firstFailure ?? "error") states=0 boards=0/\(totalBoards)"
        } else {
            report = "partial states=\(out.count) boards=\(okBoards)/\(totalBoards) "
                + "fail=\(firstFailure ?? "error")"
        }
        return LayerResult(states: out, report: report)
    }

    nonisolated private static func fetchESPNBasketballBoard(slug: String, day: String) async -> BoardFetch {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/\(slug)/scoreboard?dates=\(day)") else {
            return BoardFetch(slug: slug, day: day, states: [], outcome: "error")
        }
        let data: Data
        switch await getDetailed(url) {
        case .ok(let payload): data = payload
        case .http(let code): return BoardFetch(slug: slug, day: day, states: [], outcome: "http-\(code)")
        case .failed: return BoardFetch(slug: slug, day: day, states: [], outcome: "error")
        }
        guard let board = try? JSONDecoder().decode(ESPNBoard.self, from: data) else {
            return BoardFetch(slug: slug, day: day, states: [], outcome: "decode")
        }
        let competition = CompetitionID(espnSlug: slug)
        var out: [MatchState] = []
        for event in board.events ?? [] {
            guard let comp = event.competitions?.first,
                  let competitors = comp.competitors,
                  let home = competitors.first(where: { $0.homeAway == "home" }),
                  let away = competitors.first(where: { $0.homeAway == "away" }),
                  let homeName = home.team?.displayName,
                  let awayName = away.team?.displayName,
                  let pair = MatchPairKey.key(home: homeName, away: awayName) else { continue }
            // Status mapping reuses the soccer rules verbatim
            // (the HALF test also catches basketball's
            // "Halftime" detail).
            let type = event.status?.type
            let status: MatchStatus
            if type?.completed == true { status = .ft }
            else if type?.state == "in" {
                let marker = ((type?.detail ?? "") + " " + (type?.name ?? "")).uppercased()
                status = marker.contains("HALF") ? .ht : .live
            } else if (type?.name ?? "").uppercased().contains("POSTPON") { status = .postponed }
            else if (type?.name ?? "").uppercased().contains("CANCEL") { status = .cancelled }
            else { status = .pre }
            let kickoff = event.date.flatMap { isoDate($0) }
            let dateKey = kickoff.map { FixtureGrouping.stampDateKey(of: $0) } ?? ""
            guard !dateKey.isEmpty else { continue }
            // The composed game clock for a live state:
            // "Q<period> <displayClock>", overtime periods
            // counting past 4 as "OT<n> …". Nil for every
            // non-live status. When the payload omits the
            // period, the raw displayClock stands alone —
            // never a fabricated quarter.
            let minuteText: String?
            if status == .live {
                if let period = event.status?.period,
                   let clock = event.status?.displayClock {
                    minuteText = period > 4 ? "OT\(period - 4) \(clock)" : "Q\(period) \(clock)"
                } else {
                    minuteText = event.status?.displayClock
                }
            } else {
                minuteText = nil
            }
            // Team logos ride the same learned-registry +
            // state-logo path as the soccer ESPN layer, so the
            // views' ESPN crest fallback works unchanged.
            if let s = home.team?.logo, let u = URL(string: s) {
                Crests.registerLearnedLogo(forTeam: homeName, logoURL: u)
            }
            if let s = away.team?.logo, let u = URL(string: s) {
                Crests.registerLearnedLogo(forTeam: awayName, logoURL: u)
            }
            out.append(MatchState(
                pairKey: pair, dateKey: dateKey, competition: competition,
                status: status,
                minuteText: minuteText,
                scoreHome: home.score.flatMap { Int($0) },
                scoreAway: away.score.flatMap { Int($0) },
                events: [], source: .espn, fetchedAt: Date(),
                kickoff: kickoff, fotmobID: nil,
                homeName: homeName, awayName: awayName,
                logoHome: home.team?.logo, logoAway: away.team?.logo))
        }
        return BoardFetch(slug: slug, day: day, states: out, outcome: "ok")
    }

    // MARK: - FotMob (fallback)

    private struct FotMobDay: Decodable {
        struct League: Decodable {
            struct Match: Decodable {
                struct Side: Decodable {
                    let name: String?
                    /// The feed's team id (1.4.5): FotMob serves
                    /// every badge from its teamlogo resource under
                    /// this id, so the day-feed parse now carries
                    /// it for the learned-logo registry (DB-02).
                    let id: Int?
                }
                struct Status: Decodable {
                    struct LiveTime: Decodable { let short: String?; let long: String? }
                    let scoreStr: String?
                    let ftScoreStr: String?
                    let finished: Bool?
                    let ongoing: Bool?
                    let started: Bool?
                    let liveTime: LiveTime?
                    let utcTime: String?
                }
                let id: Int?
                let home: Side?
                let away: Side?
                let status: Status?
                /// Match-level kickoff stamp — the fallback when
                /// status.utcTime is absent (1.4.6, the iOS read
                /// order; the day feed currently files the stamp
                /// inside status on every match, measured
                /// 172/172 against 0/172 at match level).
                let utcTime: String?
            }
            let name: String?
            let ccode: String?
            let matches: [Match]?
        }
        let leagues: [League]?
    }

    /// RC1 (2026-11-19): FotMob files matches under the UTC
    /// date, so a single local-date feed silently misses the
    /// matches filed under the neighbouring UTC day — the old
    /// code fetched only the ICT date, which sits a day ahead
    /// of Oklahoma during US-evening hours, and the whole layer
    /// came back empty. Fetch BOTH the UTC filing date and the
    /// app's local date (America/Chicago, owner timezone ruling
    /// 2026-11-19) and merge; when the two dates coincide the
    /// set holds one day and only one request is made. Dedupe
    /// is by storage key (pair key + dateKey), and each state's
    /// dateKey still derives from the match's own kickoff
    /// instant in the playlist's ICT stamp form — the date=
    /// parameter only chooses which of FotMob's files are read,
    /// never how a state binds.
    nonisolated private static func fetchFotMobMerged(now: Date) async -> LayerResult {
        let utcDay = fotmobDayString(now, calendar: utcCalendar())
        let localDay = fotmobDayString(now, calendar: appCalendar())
        let days = utcDay == localDay ? [utcDay] : [utcDay, localDay]
        var out: [String: MatchState] = [:]
        var okDays = 0
        var firstFailure: String? = nil
        for day in days {
            let fetch = await fetchFotMob(day: day)
            if fetch.outcome == "ok" { okDays += 1 }
            else if firstFailure == nil { firstFailure = fetch.outcome }
            for (key, state) in fetch.states where out[key] == nil {
                out[key] = state
            }
        }
        let report: String
        if okDays == days.count {
            report = "ok states=\(out.count) days=\(okDays)/\(days.count)"
        } else if okDays == 0 {
            report = "\(firstFailure ?? "error") states=0 days=0/\(days.count)"
        } else {
            report = "partial states=\(out.count) days=\(okDays)/\(days.count) "
                + "fail=\(firstFailure ?? "error")"
        }
        return LayerResult(states: out, report: report)
    }

    nonisolated private static func fetchFotMob(day: String) async -> LayerFetch {
        guard let url = URL(string: "https://www.fotmob.com/api/data/matches?date=\(day)") else {
            return LayerFetch(states: [:], outcome: "error")
        }
        let data: Data
        switch await getDetailed(url) {
        case .ok(let payload): data = payload
        case .http(let code): return LayerFetch(states: [:], outcome: "http-\(code)")
        case .failed: return LayerFetch(states: [:], outcome: "error")
        }
        guard let decoded = try? JSONDecoder().decode(FotMobDay.self, from: data) else {
            return LayerFetch(states: [:], outcome: "decode")
        }
        var out: [String: MatchState] = [:]
        for league in decoded.leagues ?? [] {
            let competition = CompetitionID(fotmobLeague: league.name ?? "", ccode: league.ccode ?? "")
            for m in league.matches ?? [] {
                guard let hn = m.home?.name, let an = m.away?.name,
                      let st = m.status,
                      let pair = MatchPairKey.key(home: hn, away: an) else { continue }
                let status: MatchStatus
                if st.finished == true { status = .ft }
                else if st.ongoing == true {
                    status = (st.liveTime?.short ?? "").uppercased().contains("HT") ? .ht : .live
                } else { status = .pre }
                var sh: Int? = nil, sa: Int? = nil
                if let score = st.scoreStr ?? st.ftScoreStr {
                    let parts = score.split(separator: "-")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count == 2 { sh = Int(parts[0]); sa = Int(parts[1]) }
                }
                let kickoff = (st.utcTime ?? m.utcTime).flatMap { isoDate($0) }
                let dateKey = kickoff.map { FixtureGrouping.stampDateKey(of: $0) }
                    ?? fotmobDayStart(day).map { FixtureGrouping.stampDateKey(of: $0) }
                    ?? FixtureGrouping.stampDateKey(of: Date())
                // FotMob's day feed carries no logo field — only
                // the team id — but FotMob serves every badge from
                // its own teamlogo resource under that id (DB-02;
                // the resource was verified live against this
                // feed's ids, Orlando City and FC Cincinnati among
                // them, before this derivation was trusted). The
                // logos register into Crests exactly like ESPN's.
                let homeLogo = m.home?.id.map {
                    URL(string: "https://images.fotmob.com/image_resources/logo/teamlogo/\($0).png")
                } ?? nil
                let awayLogo = m.away?.id.map {
                    URL(string: "https://images.fotmob.com/image_resources/logo/teamlogo/\($0).png")
                } ?? nil
                if let homeLogo { Crests.registerLearnedLogo(forTeam: hn, logoURL: homeLogo) }
                if let awayLogo { Crests.registerLearnedLogo(forTeam: an, logoURL: awayLogo) }
                let state = MatchState(
                    pairKey: pair, dateKey: dateKey, competition: competition,
                    status: status,
                    minuteText: status == .live ? st.liveTime?.short : nil,
                    scoreHome: sh, scoreAway: sa,
                    events: [],
                    source: .fotmob, fetchedAt: Date(),
                    kickoff: kickoff, fotmobID: m.id,
                    homeName: nil, awayName: nil,
                    logoHome: nil, logoAway: nil)
                out[state.storageKey] = state
            }
        }
        return LayerFetch(states: out, outcome: "ok")
    }

    private struct FotMobDetail: Decodable {
        struct Content: Decodable {
            struct Facts: Decodable {
                struct Events: Decodable {
                    struct Event: Decodable {
                        struct Player: Decodable { let name: String? }
                        let type: String?
                        let card: String?
                        let time: Int?
                        let isHome: Bool?
                        let nameStr: String?
                        /// The acting player (1.4.6, the iOS
                        /// DTO shape; nameStr stays decoded as
                        /// the fallback spelling).
                        let player: Player?
                        /// "Penalty" / "Own Goal" ride here on
                        /// goal events (1.4.6) — without it a
                        /// penalty or own goal rendered as an
                        /// ordinary goal, the iOS RC2 lesson.
                        let goalDescription: String?
                    }
                    let events: [Event]?
                }
                let events: Events?
            }
            let matchFacts: Facts?
        }
        let content: Content?
    }

    nonisolated private static func fetchFotMobDetail(id: Int) async -> [MatchEvent]? {
        guard let url = URL(string: "https://www.fotmob.com/api/data/matchDetails?matchId=\(id)"),
              let data = await get(url),
              let decoded = try? JSONDecoder().decode(FotMobDetail.self, from: data) else { return nil }
        var out: [MatchEvent] = []
        for e in decoded.content?.matchFacts?.events?.events ?? [] {
            let minute = e.time.map { "\($0)'" } ?? ""
            let name = e.player?.name ?? e.nameStr ?? ""
            guard let isHome = e.isHome else { continue }
            if e.type == "Goal" {
                let desc = e.goalDescription ?? ""
                out.append(MatchEvent(kind: .goal, minuteText: minute, playerName: name,
                                      isHome: isHome,
                                      isPenalty: desc.contains("Penalty"),
                                      isOwnGoal: desc.contains("Own Goal")))
            } else if e.type == "Card" {
                out.append(MatchEvent(kind: e.card == "Red" ? .redCard : .yellowCard,
                                      minuteText: minute, playerName: name,
                                      isHome: isHome, isPenalty: false, isOwnGoal: false))
            }
        }
        return out
    }

    // MARK: - Flashscore (third layer, score + status only)

    /// Flashscore root day feed (probe 2026-11-19,
    /// source-probe-20261119/EVALUATION.md): records separated
    /// by "~", fields "KEY÷value" separated by "¬". League
    /// headers carry "ZA÷<COUNTRY: League>"; match records
    /// start "AA÷<id>". Field semantics derived from
    /// fs_feed1.txt cross-checked against the second pull
    /// fsnap2/fs.txt and the known live results (Vasco 1–0
    /// Internacional, Vitória 2–0 Bragantino — both 22:30 UTC
    /// kickoffs, live at pull time):
    ///   AD = kickoff epoch seconds (1795127400 = 2026-11-19
    ///   22:30 UTC for both Brazil fixtures, matching ESPN);
    ///   AE/AF = home/away names; AG/AH = home/away score,
    ///   present only once a match has started (9 of 403
    ///   records: the 5 live + the 4 finished-with-result;
    ///   AT/AU duplicate AG/AH in every one and are ignored);
    ///   (AB, AC) stage pair: (1,1) not started — 389 records,
    ///   no score fields; (2,12) live — exactly the 5 in-play
    ///   records; (3,3) finished — 4 records, scores present;
    ///   (3,4)/(3,5) closed WITHOUT a result — no AG/AH, so
    ///   never .ft; the probe cannot separate postponed from
    ///   cancelled there, so both take .postponed (no badge, no
    ///   score — the fail-closed outcome). The sample holds NO
    ///   half-time code (every live record was first-half), so
    ///   this layer never emits .ht. AX is NOT a status field
    ///   (one live record carries AX=0) and is ignored; the
    ///   feed carries no minute at all (zero field changes
    ///   between pulls — the site computes its clock
    ///   client-side), so minuteText stays nil and the bounded
    ///   computed clock fills the badge. Unknown (AB, AC) pairs
    ///   and live/finished records without a parseable score
    ///   are skipped: one bad record never kills the feed and
    ///   nothing is ever guessed. Binding is the same pair-key
    ///   + ICT stamp dateKey discipline as ESPN/FotMob (the
    ///   dateKey derives from the record's own kickoff instant).
    nonisolated private static func fetchFlashscore() async -> LayerResult {
        guard let url = URL(string: "https://www.flashscore.com/x/feed/f_1_0_3_en_1") else {
            return LayerResult(states: [:], report: "error states=0")
        }
        let data: Data
        switch await getDetailed(url, headers: ["x-fsign": "SW9D1eZo"]) {
        case .ok(let payload): data = payload
        case .http(let code): return LayerResult(states: [:], report: "http-\(code) states=0")
        case .failed: return LayerResult(states: [:], report: "error states=0")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return LayerResult(states: [:], report: "decode states=0")
        }
        var out: [String: MatchState] = [:]
        var leagueHeader: String? = nil
        for record in text.split(separator: "~", omittingEmptySubsequences: true) {
            var fields: [String: String] = [:]
            for part in record.split(separator: "¬", omittingEmptySubsequences: true) {
                guard let cut = part.firstIndex(of: "÷") else { continue }
                let key = String(part[part.startIndex..<cut])
                let value = String(part[part.index(after: cut)...])
                fields[key] = value
            }
            if let header = fields["ZA"] { leagueHeader = header; continue }
            guard fields["AA"] != nil,
                  let homeName = fields["AE"], let awayName = fields["AF"],
                  let kickoffEpoch = fields["AD"].flatMap({ Int($0) }),
                  let pair = MatchPairKey.key(home: homeName, away: awayName)
            else { continue }
            let status: MatchStatus
            switch (fields["AB"], fields["AC"]) {
            case ("1", "1"): status = .pre
            case ("2", "12"): status = .live
            case ("3", "3"): status = .ft
            case ("3", "4"), ("3", "5"): status = .postponed
            default: continue
            }
            var sh: Int? = nil, sa: Int? = nil
            if status == .live || status == .ft {
                guard let h = fields["AG"].flatMap({ Int($0) }),
                      let a = fields["AH"].flatMap({ Int($0) }) else { continue }
                sh = h; sa = a
            }
            let kickoff = Date(timeIntervalSince1970: TimeInterval(kickoffEpoch))
            let state = MatchState(
                pairKey: pair, dateKey: FixtureGrouping.stampDateKey(of: kickoff),
                competition: leagueHeader.flatMap { CompetitionID(flashscoreLeague: $0) },
                status: status, minuteText: nil,
                scoreHome: sh, scoreAway: sa,
                events: [],
                source: .flashscore, fetchedAt: Date(),
                kickoff: kickoff, fotmobID: nil,
                homeName: nil, awayName: nil,
                logoHome: nil, logoAway: nil)
            out[state.storageKey] = state
        }
        return LayerResult(states: out, report: "ok states=\(out.count)")
    }

    // MARK: - LiveScore (fourth layer, score + minute only)

    private struct LiveScoreFeed: Decodable {
        struct Stage: Decodable {
            struct Event: Decodable {
                struct Team: Decodable { let Nm: String? }
                let Eps: String?
                /// Scores ride as STRINGS on this wire
                /// (measured on the saved live + date payloads:
                /// every Tr1/Tr2 is a JSON string). The pre-1.4.6
                /// Int? DTO threw on the first scored event and
                /// the whole feed decoded to zero states
                /// (FL-331).
                let Tr1: String?
                let Tr2: String?
                let T1: [Team]?
                let T2: [Team]?
            }
            let Events: [Event]?
        }
        let Stages: [Stage]?
    }

    nonisolated private static func fetchLiveScore(todayKey: String) async -> LayerResult {
        guard let url = URL(string: "https://prod-public-api.livescore.com/v1/api/app/live/soccer/3?MD=1") else {
            return LayerResult(states: [:], report: "error states=0")
        }
        let data: Data
        switch await getDetailed(url) {
        case .ok(let payload): data = payload
        case .http(let code): return LayerResult(states: [:], report: "http-\(code) states=0")
        case .failed: return LayerResult(states: [:], report: "error states=0")
        }
        guard let decoded = try? JSONDecoder().decode(LiveScoreFeed.self, from: data) else {
            return LayerResult(states: [:], report: "decode states=0")
        }
        var out: [String: MatchState] = [:]
        for stage in decoded.Stages ?? [] {
            for e in stage.Events ?? [] {
                guard let hn = e.T1?.first?.Nm, let an = e.T2?.first?.Nm,
                      let pair = MatchPairKey.key(home: hn, away: an) else { continue }
                let eps = e.Eps ?? ""
                let status: MatchStatus
                var minute: String? = nil
                switch eps {
                case "FT", "AP": status = .ft
                case "HT": status = .ht
                case "NS": status = .pre
                case "Canc.": status = .cancelled
                case "Postp.": status = .postponed
                default:
                    if eps.contains("'") { status = .live; minute = eps } else { status = .pre }
                }
                // The live feed carries no date of its own: it is
                // keyed to today's ICT date, and the lookup's date
                // agreement is what binds it — a fixture stamped
                // another day never sees it (plan §1.3/§1.4).
                let state = MatchState(
                    pairKey: pair, dateKey: todayKey, competition: nil,
                    status: status, minuteText: minute,
                    scoreHome: e.Tr1.flatMap { Int($0) }, scoreAway: e.Tr2.flatMap { Int($0) },
                    events: [],
                    source: .livescore, fetchedAt: Date(), kickoff: nil, fotmobID: nil,
                    homeName: nil, awayName: nil,
                    logoHome: nil, logoAway: nil)
                out[state.storageKey] = state
            }
        }
        return LayerResult(states: out, report: "ok states=\(out.count)")
    }
}
