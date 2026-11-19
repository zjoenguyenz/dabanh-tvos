import Foundation

/// Competition identity + division overlay (Đá Banh TV 1.4.1,
/// BOARD-REDESIGN-PLAN §3). LeagueClassifier.leagueRank keeps
/// filing fixtures into country tabs exactly as before; this
/// overlay only SPLITS within a country (top vs lower division)
/// and MOVES positively-identified cup fixtures into the cup
/// area. Identification precedence (plan §3.5), first positive
/// identification wins, nothing is ever guessed:
///   1. Matched-state competition (ESPN slug / FotMob league) —
///      authoritative, applied by the caller from MatchState.
///   2. Both-clubs rule for unmatched mirror fixtures: lower
///      division ONLY when both normalised club names belong to
///      that division's 2025-26 set AND neither belongs to the
///      top-division set. A split pair (cup tie / friendly) files
///      neither division and stays top/unknown, exactly as today.
///   3. Nuvio league-line whitelist (addon fixtures only): an
///      exact-match league line files the meta; generic lines
///      ("Football", "Spain", …) file nothing.
///   4. Otherwise unknown → top section of its country tab.
/// The mirror itself carries NO competition text at all (plan
/// §3.1, measured 2026-11-19: zero league-name hits in 600
/// titles), so rules 2–3 are the only mirror-side signals and
/// they are deliberately conservative.

enum CompetitionID: String, Equatable, Sendable {
    case premierLeague = "eng.1"
    case championship = "eng.2"
    case laLiga = "esp.1"
    case segunda = "esp.2"
    case serieA = "ita.1"
    case serieB = "ita.2"
    case ligue1 = "fra.1"
    case ligue2 = "fra.2"
    case bundesliga = "ger.1"
    case bundesliga2 = "ger.2"
    case championsLeague = "uefa.champions"
    case europaLeague = "uefa.europa"
    case conferenceLeague = "uefa.europa.conf"
    case womensChampionsLeague = "uefa.womens.champions"

    init?(espnSlug: String) {
        // UWCL rides its own ESPN slug family; the store's slug
        // table normalises it to the case above before lookup.
        if espnSlug.hasPrefix("uefa.womens") { self = .womensChampionsLeague; return }
        guard let value = CompetitionID(rawValue: espnSlug) else { return nil }
        self = value
    }

    /// FotMob league identity (name + country code) — the ccode
    /// is what separates Championship ENG from Championship SCO
    /// and Serie A ITA from Serie A BRA (plan §1.2).
    init?(fotmobLeague name: String, ccode: String) {
        switch (name, ccode) {
        case ("Premier League", "ENG"): self = .premierLeague
        case ("Championship", "ENG"): self = .championship
        case ("LaLiga", "ESP"): self = .laLiga
        case ("LaLiga2", "ESP"): self = .segunda
        case ("Serie A", "ITA"): self = .serieA
        case ("Serie B", "ITA"): self = .serieB
        case ("Ligue 1", "FRA"): self = .ligue1
        case ("Ligue 2", "FRA"): self = .ligue2
        case ("Bundesliga", "GER"): self = .bundesliga
        case ("2. Bundesliga", "GER"): self = .bundesliga2
        case ("UEFA Champions League", _), ("Champions League", "INT"): self = .championsLeague
        case ("UEFA Europa League", _), ("Europa League", "INT"): self = .europaLeague
        case ("UEFA Conference League", _), ("Conference League", "INT"): self = .conferenceLeague
        case ("UEFA Women's Champions League", _),
             ("UEFA Women Champions League", _),
             ("Women's Champions League", _): self = .womensChampionsLeague
        default: return nil
        }
    }

    /// The ESPN slugs the live-state store polls (plan §3.4: all
    /// verified HTTP 200 with full details on 2026-11-19), plus
    /// the UWCL slug family the cup area needs (plan §2.4).
    static let espnSlugs: [String] = [
        "eng.1", "eng.2", "esp.1", "esp.2", "ita.1", "ita.2",
        "fra.1", "fra.2", "ger.1", "ger.2",
        "uefa.champions", "uefa.europa", "uefa.europa.conf",
        "uefa.womens.champions",
    ]

    /// Country league rank this competition belongs to (League
    /// rawValues 1–5), nil for the European cups.
    var countryRank: Int? {
        switch self {
        case .premierLeague, .championship: return 1
        case .laLiga, .segunda: return 2
        case .serieA, .serieB: return 3
        case .ligue1, .ligue2: return 4
        case .bundesliga, .bundesliga2: return 5
        case .championsLeague, .europaLeague, .conferenceLeague,
             .womensChampionsLeague: return nil
        }
    }

    var isLower: Bool {
        switch self {
        case .championship, .segunda, .serieB, .ligue2, .bundesliga2: return true
        default: return false
        }
    }

    var isCup: Bool { countryRank == nil }

    /// Display label for tiles, section heads and the link board.
    var label: String {
        switch self {
        case .premierLeague: return "NGOẠI HẠNG ANH"
        case .championship: return "GIẢI HẠNG NHẤT ANH (CHAMPIONSHIP)"
        case .laLiga: return "LA LIGA"
        case .segunda: return "SEGUNDA (LA LIGA 2)"
        case .serieA: return "SERIE A"
        case .serieB: return "SERIE B"
        case .ligue1: return "LIGUE 1"
        case .ligue2: return "LIGUE 2"
        case .bundesliga: return "BUNDESLIGA"
        case .bundesliga2: return "2. BUNDESLIGA"
        case .championsLeague: return "CÚP C1 · CHAMPIONS LEAGUE"
        case .europaLeague: return "CÚP C2 · EUROPA LEAGUE"
        case .conferenceLeague: return "CÚP C3 · CONFERENCE LEAGUE"
        case .womensChampionsLeague: return "CÚP C1 NỮ"
        }
    }

    /// The lower-division competition of a country rank, if any.
    static func lower(forCountryRank rank: Int) -> CompetitionID? {
        switch rank {
        case 1: return .championship
        case 2: return .segunda
        case 3: return .serieB
        case 4: return .ligue2
        case 5: return .bundesliga2
        default: return nil
        }
    }

    /// The top-division competition of a country rank, if any.
    static func top(forCountryRank rank: Int) -> CompetitionID? {
        switch rank {
        case 1: return .premierLeague
        case 2: return .laLiga
        case 3: return .serieA
        case 4: return .ligue1
        case 5: return .bundesliga
        default: return nil
        }
    }
}

enum DivisionClassifier {

    // MARK: - Club sets seeded from the SPEC's Appendix B
    // (ESPN /teams rosters pulled 2026-11-19; re-pull at each
    // season's start — promotion/relegation churn, spec §3.2 S3).
    // Appendix B's pull is a roster snapshot, not gospel: it
    // lists a few top-flight names inside division 2 (Burnley,
    // West Ham, Wolves, Girona, St. Pauli, Wolfsburg…), which
    // is exactly why the both-clubs rule ALSO requires neither
    // club in the division-1 set — those names can never file
    // a fixture as division 2 while they sit in the top set. Names are stored pre-normalised with the
    // fixture identity's normalisation (lowercase, diacritics
    // stripped, filler tokens dropped) so membership tests are
    // plain set lookups over MatchPairKey-normalised names.

    private static let championshipSet: Set<String> = [
        "birmingham city", "blackburn rovers", "bolton wanderers", "bristol city",
        "burnley", "cardiff city", "charlton athletic", "derby county",
        "lincoln city", "middlesbrough", "millwall", "norwich city",
        "portsmouth", "preston north end", "queens park rangers",
        "sheffield united", "southampton", "stoke city", "swansea city",
        "watford", "west bromwich albion", "west ham united", "wolves", "wrexham",
    ]
    private static let segundaSet: Set<String> = [
        "albacete", "almeria", "burgos", "sabadell", "castellon", "ceuta",
        "cadiz", "cordoba", "eibar", "eldense", "andorra", "girona", "granada",
        "las palmas", "leganes", "mallorca", "celta fortuna", "oviedo",
        "real sociedad ii", "real sociedad b", "real valladolid",
        "sporting gijon", "tenerife",
    ]
    private static let serieBSet: Set<String> = [
        "arezzo", "ascoli", "benevento", "carrarese", "catanzaro", "cesena",
        "cremonese", "empoli", "hellas verona", "verona", "juve stabia",
        "mantova", "modena", "padova", "palermo", "pisa", "sampdoria",
        "sudtirol", "avellino", "vicenza", "virtus entella",
    ]
    private static let ligue2Set: Set<String> = [
        "nancy lorraine", "nancy", "annecy", "boulogne", "clermont foot",
        "dijon", "dunkerque", "grenoble", "guingamp", "metz", "montpellier",
        "nantes", "pau", "red star", "rodez", "saint etienne", "sochaux",
        "stade laval", "laval", "stade de reims", "reims",
    ]
    private static let bundesliga2Set: Set<String> = [
        "heidenheim", "magdeburg", "nurnberg", "arminia bielefeld",
        "dynamo dresden", "energie cottbus", "hannover", "hertha berlin",
        "hertha bsc", "holstein kiel", "kaiserslautern", "karlsruher",
        "darmstadt", "greuther furth", "st pauli", "eintracht braunschweig",
        "bochum", "osnabruck", "wolfsburg",
    ]

    /// Top-division membership, same season, for the both-clubs
    /// rule's "neither belongs to the top set" half.
    private static let premierLeagueSet: Set<String> = [
        "arsenal", "aston villa", "bournemouth", "brentford", "brighton",
        "burnley", "chelsea", "crystal palace", "everton", "fulham",
        "leeds united", "liverpool", "manchester city", "manchester united",
        "newcastle united", "newcastle", "nottingham forest", "sunderland",
        "tottenham hotspur", "tottenham", "west ham united", "west ham", "wolves",
    ]
    private static let laLigaSet: Set<String> = [
        "alaves", "athletic bilbao", "atletico madrid", "barcelona", "celta vigo",
        "elche", "espanyol", "getafe", "girona", "levante", "mallorca",
        "osasuna", "oviedo", "rayo vallecano", "real betis", "real madrid",
        "real sociedad", "sevilla", "valencia", "villarreal",
    ]
    private static let serieASet: Set<String> = [
        "atalanta", "bologna", "cagliari", "como", "cremonese", "fiorentina",
        "genoa", "hellas verona", "inter", "juventus", "lazio", "lecce",
        "ac milan", "napoli", "parma", "pisa", "roma", "sassuolo", "torino",
        "udinese",
    ]
    private static let ligue1Set: Set<String> = [
        "angers", "auxerre", "brest", "le havre", "lens", "lille", "lorient",
        "lyon", "marseille", "metz", "monaco", "nantes", "nice", "paris",
        "paris saint germain", "rennes", "strasbourg", "toulouse",
    ]
    private static let bundesligaSet: Set<String> = [
        "augsburg", "bayer leverkusen", "bayern munich", "borussia dortmund",
        "borussia monchengladbach", "eintracht frankfurt", "freiburg",
        "hamburger sv", "hamburg", "heidenheim", "hoffenheim", "cologne", "mainz",
        "rb leipzig", "st pauli", "stuttgart", "union berlin",
        "werder bremen", "wolfsburg",
    ]

    private static func lowerSet(forCountryRank rank: Int) -> Set<String>? {
        switch rank {
        case 1: return championshipSet
        case 2: return segundaSet
        case 3: return serieBSet
        case 4: return ligue2Set
        case 5: return bundesliga2Set
        default: return nil
        }
    }

    private static func topSet(forCountryRank rank: Int) -> Set<String>? {
        switch rank {
        case 1: return premierLeagueSet
        case 2: return laLigaSet
        case 3: return serieASet
        case 4: return ligue1Set
        case 5: return bundesligaSet
        default: return nil
        }
    }

    private static func normalized(_ name: String) -> String {
        // The roster sets are written in canonical-key form
        // (Addendum 2 matcher), so membership tests canonicalise
        // with the same function the matcher uses.
        MatchPairKey.canonicalTeam(name)
    }

    /// Rule 2 (both-clubs): the fixture's lower-division
    /// competition when BOTH sides belong to that division's set
    /// and NEITHER belongs to the top set — otherwise nil. The
    /// country is the one LeagueClassifier already chose; a pair
    /// whose clubs sit in different countries' sets is never
    /// lower-filed (the sets consulted are only that country's).
    static func lowerCompetition(home: String, away: String, countryRank: Int) -> CompetitionID? {
        guard let lower = lowerSet(forCountryRank: countryRank),
              let top = topSet(forCountryRank: countryRank),
              let competition = CompetitionID.lower(forCountryRank: countryRank)
        else { return nil }
        let h = normalized(home)
        let a = normalized(away)
        guard lower.contains(h), lower.contains(a) else { return nil }
        guard !top.contains(h), !top.contains(a) else { return nil }
        return competition
    }

    /// Rule 2 for a fixture channel: reads its two team names from
    /// the cleaned title and applies the both-clubs test inside
    /// the country the classifier filed it under.
    static func lowerCompetition(for channel: Channel) -> CompetitionID? {
        guard let (a, b) = Crests.teams(ofCleanTitle: MatchTitle.clean(channel.title))
        else { return nil }
        // Women's exclusion (spec §3.2 S3): division classification
        // is disabled for a pair where either side carries the
        // women's marker — the men's rosters must not be applied
        // to women's fixtures; they keep today's filing.
        if isWomensSide(a) || isWomensSide(b) { return nil }
        return lowerCompetition(home: a, away: b, countryRank: channel.leagueRank)
    }

    /// A side carries the women's marker when its normalised name
    /// holds a "women" / "nu" (Nữ) / standalone "w" token.
    private static func isWomensSide(_ name: String) -> Bool {
        let tokens = FixtureGrouping.normalizedTeam(name).split(separator: " ").map(String.init)
        return tokens.contains("women") || tokens.contains("nu") || tokens.contains("w")
            || tokens.contains("womens")
    }

    // MARK: - Rule 3: Nuvio league-line whitelist (exact match)

    /// A Nuvio meta's "🏆 League:" line files it ONLY on an exact
    /// whitelist hit (plan §3.5 rule 3). Generic lines — "Football"
    /// (77/271 tonight), "Arabia", "Live TV", "Sports", a bare
    /// country name — file nothing, and a substring is never
    /// enough (the football catalog even carries handball's "EHF
    /// Champions League", which must not file as C1).
    static func competition(forNuvioLeagueLine line: String?) -> CompetitionID? {
        guard let line else { return nil }
        switch line.trimmingCharacters(in: .whitespaces) {
        case "Championship": return .championship
        case "LaLiga 2", "Segunda": return .segunda
        case "Serie B": return .serieB
        case "Ligue 2": return .ligue2
        case "2. Bundesliga": return .bundesliga2
        case "UEFA Champions League": return .championsLeague
        case "UEFA Europa League": return .europaLeague
        case "UEFA Conference League": return .conferenceLeague
        case "UEFA Women's Champions League", "UEFA Women Champions League":
            return .womensChampionsLeague
        default: return nil
        }
    }
}
