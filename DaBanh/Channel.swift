import Foundation

/// One playlist entry — mirrors `Channel` in the Android Đá Banh TV app
/// (com.gathin.dabanh.MainActivity.Channel).
struct Channel: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let logo: String
    let group: String
    let url: String
    /// Kickoff parsed from the title (Vietnam time, ICT). nil mirrors
    /// Android's kickoffMs == 0 ("no kickoff in the title").
    let kickoff: Date?
    /// 1 = Ngoại Hạng Anh, 2 = Tây Ban Nha, 3 = Ý, 4 = Pháp, 5 = Đức,
    /// 9 = Khác.
    let leagueRank: Int
    /// Playback headers the entry itself declares via #EXTVLCOPT
    /// (http-referrer / http-user-agent). Some CDNs refuse the stream
    /// without them; empty means "send nothing extra" — a blanket
    /// Referer is never invented, because probing on Android showed an
    /// uninvited Referer turns other hosts' segment fetches into 403.
    let referrer: String
    let userAgent: String
    /// ADDITIVE (2026-11-19, Nuvio addon integration): the
    /// Origin header a stream's proxyHeaders declare, carried
    /// so pre-flight and the player can send it. Every
    /// pre-existing construction (M3U parser, playlist code)
    /// leaves it empty and behaves exactly as before; only
    /// addon-built ladder channels set it.
    let origin: String

    init(title: String, logo: String, group: String, url: String, kickoff: Date?, leagueRank: Int,
         referrer: String = "", userAgent: String = "", origin: String = "") {
        self.title = title
        self.logo = logo
        self.group = group
        self.url = url
        self.kickoff = kickoff
        self.leagueRank = leagueRank
        self.referrer = referrer
        self.userAgent = userAgent
        self.origin = origin
    }

    var streamURL: URL? { URL(string: url) }
    var logoURL: URL? { logo.isEmpty ? nil : URL(string: logo) }
}

/// The six league tabs, in the user's fixed order (Android LEAGUE_TABS /
/// LEAGUE_NAMES in MainActivity). Germany (5) joined in 1.4.0, after
/// France; the Android tab row itself carries no German entry — rank 5
/// exists in this port only.
enum League: Int, CaseIterable, Identifiable {
    case england = 1
    case spain = 2
    case italy = 3
    case france = 4
    case germany = 5
    /// European cups (1.4.1, spec §4.1): value 6, after Đức and
    /// before Khác. No mirror channel ever carries leagueRank 6
    /// (the classifier files by club/country only) — the cups
    /// tab's contents are the competition-identified fixtures
    /// the view assembles (spec §4.2 S1/S2), dual-present with
    /// their country tabs.
    case cups = 6
    case other = 9

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .england: return "Ngoại Hạng Anh"
        case .spain: return "Tây Ban Nha"
        case .italy: return "Ý"
        case .france: return "Pháp"
        case .germany: return "Đức"
        case .cups: return "Cúp châu Âu"
        case .other: return "Khác"
        }
    }

    /// Short tab-pill label ONLY (owner, 2026-11-19 14:35/14:36
    /// CST; final form 14:38 CST): small and short like "Đức" —
    /// NHA · TBN · Ý · Đức · Pháp. The cups tab label is now
    /// "Cúp EU" (owner final form, 14:38 CST), superseding the
    /// earlier keep-full-"Cúp châu Âu" instruction — TAB LABEL
    /// ONLY. Every other surface (competition label, hero/count
    /// copy, empty states, in-tab section headers) keeps using
    /// `name` or its own wording, byte-identical.
    var tabName: String {
        switch self {
        case .england: return "NHA"
        case .spain: return "TBN"
        case .italy: return "Ý"
        case .france: return "Pháp"
        case .germany: return "Đức"
        case .cups: return "Cúp EU"
        case .other: return "Khác"
        }
    }

    /// Small country flag shown beside `tabName` in the tab
    /// pill ONLY (owner final form, 2026-11-19 14:36 CST):
    /// system flag emoji, the same pill idiom as the existing
    /// "🔴 Trực tiếp" / "🔥 Hot" pills —
    /// no bundled flag image asset exists in the app (the
    /// asset catalog holds only the app icon; crests.json
    /// holds remote club/national-team badges, not flags).
    /// Cúp EU and Khác have no flag — text only. The
    /// England value is written as scalar escapes because
    /// its emoji is a tag sequence (waving black flag + tag
    /// letters "gbeng" + cancel tag), not a regional pair.
    var tabFlag: String? {
        switch self {
        case .england: return "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"
        case .spain: return "🇪🇸"
        case .italy: return "🇮🇹"
        case .france: return "🇫🇷"
        case .germany: return "🇩🇪"
        case .cups: return nil
        case .other: return nil
        }
    }

    /// The tab pill's full title: flag + short text for the
    /// five league tabs, plain text for Cúp EU / Khác.
    var tabTitle: String {
        guard let flag = tabFlag else { return tabName }
        return "\(flag) \(tabName)"
    }

    /// Visible tab-row order ONLY (owner final form,
    /// 2026-11-19 14:38 CST): the league pills render in the
    /// owner's row — NHA · TBN · Ý · Đức · Pháp · Khác ·
    /// Cúp EU — Đức before Pháp, Khác before the cups, and
    /// Cúp EU LAST. In the bar the ENG pill leads this row
    /// (see TVContentView.tabBar). The enum's cases,
    /// rawValues (cups stays 6) and `allCases` order are NOT
    /// changed: `PlaylistStore.pickInitialTabIfNeeded` iterates
    /// `allCases` for its priority pick and keeps its existing
    /// behaviour. Only the pill row renders in this order.
    static let tabOrder: [League] = [.england, .spain, .italy, .germany, .france, .other, .cups]
}
