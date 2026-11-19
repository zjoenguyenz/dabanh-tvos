import Foundation

/// Live match states (Đá Banh TV 1.4.2, BOARD-REDESIGN-PLAN §1):
/// ESPN primary (full cluster per league-day) > FotMob fallback >
/// Flashscore (score + status only, no minute, no incidents) >
/// LiveScore (score + minute only) > bounded computed clock.
/// Matching is the apps' existing normalised pair-key + ICT date
/// agreement, fail closed: a state binds to a fixture only when the
/// pair matches AND the calendar dates agree (the ESPN US-Eastern
/// day seam tolerates ±1 day only when kickoff instants are within
/// 3 h). A higher layer's state replaces a lower one's wholesale —
/// fields are never merged across sources. FotMob matchDetails may
/// upgrade a FotMob day-feed state (same source family), capped at
/// 4 detail calls per poll cycle, live fixtures first.
///
/// Poll cadence (plan §1.7): 60 s while anything is in its live
/// window or matched-live, else 5 min. Last-good states are kept
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
struct MatchEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case goal, yellowCard, redCard }
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
    let htHome: Int?
    let htAway: Int?
    let events: [MatchEvent]
    let source: MatchSource
    let fetchedAt: Date
    /// The source event's kickoff instant (date-agreement checks).
    let kickoff: Date?
    /// FotMob match id, when the state came from FotMob (detail
    /// upgrades ride on it).
    let fotmobID: Int?

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
                   htHome: htHome, htAway: htAway, events: newEvents,
                   source: source, fetchedAt: fetchedAt, kickoff: kickoff,
                   fotmobID: fotmobID)
    }
}

/// Pair-key for two raw source team names — the CANONICAL key
/// of the measured matcher study (BOARD-REDESIGN-PLAN Addendum 2,
/// matcher v2, run over today's real mirror + Nuvio events; the
/// alias/filler tables below are its measured tables, adopted
/// verbatim — do not extend them without a measured case):
/// Crests.norm (Foundation diacritic folding, so Køge/Koge
/// canonicalise identically), filler tokens dropped (the fixture
/// identity's set PLUS de/do/da/del, dsc, sl, s, futbol, football
/// — each forced by a measured near-miss), numeric tokens
/// dropped, women's markers stripped as leading AND trailing
/// tokens, token aliases applied per token, whole-name aliases
/// applied last (whole name only, never substring). The tables
/// are Addendum 2's measured set exactly — no invented entries
/// (the survey's VN national-team aliases are NOT in the
/// measured table and are not carried; Addendum 2 is
/// authoritative for belonging, and this one function serves
/// every source, spec §2.5).
/// The same canonical function keys ESPN/FotMob/LiveScore states,
/// mirror fixtures and Nuvio events — one matcher everywhere
/// (spec §2.5). Fixture GROUPING keeps FixtureGrouping's own
/// key; only matching uses this canonical key.
enum MatchPairKey {
    private static let filler: Set<String> = [
        "fc", "cf", "sc", "afc", "ca", "cd", "fk", "sk",
        "club", "ac", "as", "sd", "us", "ec",
        "de", "do", "da", "del", "dsc", "sl", "s", "futbol", "football",
    ]
    private static let markers: Set<String> = [
        "women", "w", "nu", "feminin", "femmes", "femenino", "femenina",
    ]
    private static let tokenAliases: [String: String] = [
        "munchen": "munich", "wien": "vienna", "koln": "cologne",
        "mgladbach": "gladbach", "lyonnes": "lyon",
    ]
    private static let nameAliases: [String: String] = [
        "atletico penarol": "penarol",
        "montevideo city torque": "montevideo city",
        "servette chenois": "servette",
        "servette geneve": "servette",
        "vitoria ba": "vitoria",
        "koge": "hb koge",
        // Measured 2026-11-19 (Flashscore/ESPN Brazil feeds write
        // the club three ways; the mirror writes "Bragantino"):
        "rb bragantino": "bragantino",
        "red bull bragantino": "bragantino",
        "bragantino sp": "bragantino",
        "vitoria salvador ba": "vitoria",
    ]

    /// One team name canonicalised (matcher v2's canonical_team).
    static func canonicalTeam(_ name: String) -> String {
        var toks = Crests.norm(name).split(separator: " ").map(String.init)
            .filter { !filler.contains($0) && !$0.allSatisfy({ $0.isNumber }) }
            .map { tokenAliases[$0] ?? $0 }
        while let first = toks.first, markers.contains(first) { toks.removeFirst() }
        while let last = toks.last, markers.contains(last) { toks.removeLast() }
        let joined = toks.joined(separator: " ")
        return nameAliases[joined] ?? joined
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

@MainActor
final class MatchStateStore: ObservableObject {

    @Published private(set) var states: [String: MatchState] = [:]

    /// Set by PlaylistStore so list views re-render when states land.
    var onChange: (() -> Void)?

    private var fixturesProvider: (() -> [Channel])?
    private var pollTask: Task<Void, Never>?
    private var fetching = false
    private var fotmobDetailCache: [Int: [MatchEvent]] = [:]

    private static let livePoll: TimeInterval = 60
    private static let idlePoll: TimeInterval = 15 * 60
    private static let lastGoodWindow: TimeInterval = 30 * 60
    private static let fotmobDetailCap = 4

    // MARK: - Lifecycle

    func start(fixturesProvider: @escaping () -> [Channel]) {
        self.fixturesProvider = fixturesProvider
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

    /// A playlist refresh also triggers a state fetch (plan §1.7).
    func requestFetch() {
        Task { await cycle() }
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

    /// The matched state for a fixture channel, or nil. Tries the
    /// fixture's own ICT stamp date first, then the ±1-day ESPN
    /// seam — the seam binds only when the kickoff instants are
    /// within 3 h (plan §1.4). States older than the 30-minute
    /// last-good window no longer override anything.
    func state(for channel: Channel, now: Date = Date()) -> MatchState? {
        guard let kickoff = channel.kickoff,
              let pair = MatchPairKey.key(of: channel) else { return nil }
        let ownKey = FixtureGrouping.stampDateKey(of: kickoff)
        if let s = states[pair + "|" + ownKey], isFresh(s, now: now) {
            return s
        }
        for delta in [-86400.0, 86400.0] {
            let seamKey = FixtureGrouping.stampDateKey(of: kickoff.addingTimeInterval(delta))
            guard let s = states[pair + "|" + seamKey], isFresh(s, now: now),
                  let sk = s.kickoff,
                  abs(sk.timeIntervalSince(kickoff)) <= 3 * 3600 else { continue }
            return s
        }
        return nil
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
        // ESPN days intersecting the ICT window being served:
        // yesterday/today/tomorrow ICT at the seam (plan §1.1).
        let days = (0...1).map { Self.espnDayString(now.addingTimeInterval(TimeInterval($0 * 86400))) }
        let todayICT = Self.ictDateKey(now)
        async let espnStates = Self.fetchESPN(slugs: CompetitionID.espnSlugs, days: days)
        async let fotmobStates = Self.fetchFotMobMerged(now: now)
        async let flashscoreStates = Self.fetchFlashscore()
        async let livescoreStates = Self.fetchLiveScore(todayKey: todayICT)
        let layers = await [espnStates, fotmobStates, flashscoreStates, livescoreStates]

        // Precedence ESPN > FotMob > Flashscore > LiveScore, wholesale per
        // fixture key (plan §1.4): a lower layer never overwrites
        // a key a higher layer produced.
        var merged: [String: MatchState] = [:]
        for layer in layers {
            for (key, state) in layer where merged[key] == nil {
                merged[key] = state
            }
        }
        // FotMob detail upgrade: a live FotMob day-feed state with
        // no events yet earns a matchDetails call, capped at 4 per
        // cycle, live fixtures first (plan §1.2). Same source
        // family, so adding events to the day-feed state is the
        // one allowed upgrade.
        var detailBudget = Self.fotmobDetailCap
        let detailCandidates = merged
            .filter { $0.value.source == .fotmob
                && ($0.value.status == .live || $0.value.status == .ht)
                && $0.value.events.isEmpty && $0.value.fotmobID != nil }
            .map { $0.key }
            .sorted()
        for key in detailCandidates where detailBudget > 0 {
            guard let state = merged[key], let fid = state.fotmobID else { continue }
            detailBudget -= 1
            if let events = fotmobDetailCache[fid] {
                merged[key] = state.withEvents(events)
            } else if let events = await Self.fetchFotMobDetail(id: fid) {
                fotmobDetailCache[fid] = events
                merged[key] = state.withEvents(events)
            }
        }
        // Keep last-good for keys no layer answered this cycle (a
        // source error skips that cycle only, plan §1.7).
        var next = merged
        for (key, old) in states where next[key] == nil && isFresh(old, now: now) {
            next[key] = old
        }
        if next != states {
            states = next
            onChange?()
        }
    }

    // MARK: - Date helpers

    nonisolated private static func ictCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current
        return cal
    }

    /// "YYYYMMDD" for ESPN's dates= parameter, the date read in ICT.
    nonisolated private static func espnDayString(_ date: Date) -> String {
        let c = ictCalendar().dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
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

    /// "YYYY-MM-DD" for FotMob's date= parameter, the date read
    /// in the given calendar.
    nonisolated private static func fotmobDayString(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
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

    nonisolated private static func get(_ url: URL, headers: [String: String] = [:]) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (Linux; Android 14; TV)", forHTTPHeaderField: "User-Agent")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    // MARK: - ESPN (primary)

    private struct ESPNBoard: Decodable {
        struct Event: Decodable {
            struct Competition: Decodable {
                struct Competitor: Decodable {
                    struct Team: Decodable {
                        let id: String?
                        let displayName: String?
                    }
                    let homeAway: String?
                    let score: String?
                    let team: Team?
                }
                struct Detail: Decodable {
                    struct Kind: Decodable { let text: String? }
                    struct Athlete: Decodable { let displayName: String? }
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
            }
            let date: String?
            let competitions: [Competition]?
            let status: Status?
        }
        let events: [Event]?
    }

    nonisolated private static func fetchESPN(slugs: [String], days: [String]) async -> [String: MatchState] {
        var out: [String: MatchState] = [:]
        await withTaskGroup(of: [MatchState].self) { group in
            for slug in slugs {
                for day in days {
                    group.addTask { await fetchESPNBoard(slug: slug, day: day) }
                }
            }
            for await states in group {
                for s in states { out[s.storageKey] = s }
            }
        }
        return out
    }

    nonisolated private static func fetchESPNBoard(slug: String, day: String) async -> [MatchState] {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/soccer/\(slug)/scoreboard?dates=\(day)"),
              let data = await get(url),
              let board = try? JSONDecoder().decode(ESPNBoard.self, from: data) else { return [] }
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
                let name = d.athletesInvolved?.first?.displayName ?? ""
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
            out.append(MatchState(
                pairKey: pair, dateKey: dateKey, competition: competition,
                status: status,
                minuteText: status == .live ? event.status?.displayClock : nil,
                scoreHome: home.score.flatMap { Int($0) },
                scoreAway: away.score.flatMap { Int($0) },
                htHome: nil, htAway: nil,
                events: events, source: .espn, fetchedAt: Date(),
                kickoff: kickoff, fotmobID: nil))
        }
        return out
    }

    // MARK: - FotMob (fallback)

    private struct FotMobDay: Decodable {
        struct League: Decodable {
            struct Match: Decodable {
                struct Side: Decodable { let name: String? }
                struct Status: Decodable {
                    struct LiveTime: Decodable { let short: String?; let long: String? }
                    let scoreStr: String?
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
    nonisolated private static func fetchFotMobMerged(now: Date) async -> [String: MatchState] {
        let utcDay = fotmobDayString(now, calendar: utcCalendar())
        let localDay = fotmobDayString(now, calendar: appCalendar())
        let days = utcDay == localDay ? [utcDay] : [utcDay, localDay]
        var out: [String: MatchState] = [:]
        for day in days {
            for (key, state) in await fetchFotMob(day: day) where out[key] == nil {
                out[key] = state
            }
        }
        return out
    }

    nonisolated private static func fetchFotMob(day: String) async -> [String: MatchState] {
        guard let url = URL(string: "https://www.fotmob.com/api/data/matches?date=\(day)"),
              let data = await get(url),
              let decoded = try? JSONDecoder().decode(FotMobDay.self, from: data) else { return [:] }
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
                if let score = st.scoreStr {
                    let parts = score.split(separator: "-")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count == 2 { sh = Int(parts[0]); sa = Int(parts[1]) }
                }
                let kickoff = st.utcTime.flatMap { isoDate($0) }
                let dateKey = kickoff.map { FixtureGrouping.stampDateKey(of: $0) }
                    ?? FixtureGrouping.stampDateKey(of: Date())
                let state = MatchState(
                    pairKey: pair, dateKey: dateKey, competition: competition,
                    status: status,
                    minuteText: status == .live ? st.liveTime?.short : nil,
                    scoreHome: sh, scoreAway: sa,
                    htHome: nil, htAway: nil, events: [],
                    source: .fotmob, fetchedAt: Date(),
                    kickoff: kickoff, fotmobID: m.id)
                out[state.storageKey] = state
            }
        }
        return out
    }

    private struct FotMobDetail: Decodable {
        struct Content: Decodable {
            struct Facts: Decodable {
                struct Events: Decodable {
                    struct Event: Decodable {
                        let type: String?
                        let card: String?
                        let time: Int?
                        let isHome: Bool?
                        let nameStr: String?
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
            let name = e.nameStr ?? ""
            guard let isHome = e.isHome else { continue }
            if e.type == "Goal" {
                out.append(MatchEvent(kind: .goal, minuteText: minute, playerName: name,
                                      isHome: isHome, isPenalty: false, isOwnGoal: false))
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
    nonisolated private static func fetchFlashscore() async -> [String: MatchState] {
        guard let url = URL(string: "https://www.flashscore.com/x/feed/f_1_0_3_en_1"),
              let data = await get(url, headers: ["x-fsign": "SW9D1eZo"]),
              let text = String(data: data, encoding: .utf8) else { return [:] }
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
                htHome: nil, htAway: nil, events: [],
                source: .flashscore, fetchedAt: Date(),
                kickoff: kickoff, fotmobID: nil)
            out[state.storageKey] = state
        }
        return out
    }

    // MARK: - LiveScore (fourth layer, score + minute only)

    private struct LiveScoreFeed: Decodable {
        struct Stage: Decodable {
            struct Event: Decodable {
                struct Team: Decodable { let Nm: String? }
                let Eps: String?
                let Tr1: Int?
                let Tr2: Int?
                let T1: [Team]?
                let T2: [Team]?
            }
            let Events: [Event]?
        }
        let Stages: [Stage]?
    }

    nonisolated private static func fetchLiveScore(todayKey: String) async -> [String: MatchState] {
        guard let url = URL(string: "https://prod-public-api.livescore.com/v1/api/app/live/soccer/3?MD=1"),
              let data = await get(url),
              let decoded = try? JSONDecoder().decode(LiveScoreFeed.self, from: data) else { return [:] }
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
                    scoreHome: e.Tr1, scoreAway: e.Tr2,
                    htHome: nil, htAway: nil, events: [],
                    source: .livescore, fetchedAt: Date(), kickoff: nil, fotmobID: nil)
                out[state.storageKey] = state
            }
        }
        return out
    }
}
