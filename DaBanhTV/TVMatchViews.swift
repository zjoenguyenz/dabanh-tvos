import SwiftUI
import ImageIO

/// TV-native building blocks for the Đá Banh TV redesign (v1.3.0,
/// 2026-11-14). What is carried over from the iPhone v1.11 redesign
/// is only the design LANGUAGE and the data behaviour: one card per
/// fixture with its sources grouped inside, cleaned titles (never a
/// raw playlist title), crest-vs-crest face-offs, true live minute /
/// device-local kickoff, and the store's source ladder at play time.
/// Nothing about the phone's layout comes with it — no vertical list
/// of rows, no 300pt swipe cards. Everything here is composed for a
/// 1080p/4K screen driven by a remote from the sofa: wide landscape
/// tiles in horizontal rails, 20pt+ type throughout, and a focus
/// ring you can see from across the room.
///
/// This file is tvOS-only. The iOS target has its own equivalents in
/// MatchViews.swift; the shared engine files (Channel, Crests,
/// LeagueClassifier, M3UParser, PlaylistStore) are untouched.

// MARK: - Kickoff formatting (device-local, like the phone)

/// Kickoff stamps in the playlist are absolute instants parsed from
/// ICT text, so they must render in the DEVICE's timezone — the
/// owner's rule from the iPhone redesign (21:00 in Vietnam reads
/// 08:00 in Oklahoma). The old TV view pinned its formatter to
/// Asia/Ho_Chi_Minh; v1.3.0 follows the device like the phone does.
/// Live minutes come from the absolute instant and never shift.
/// MainActor-isolated (Swift 6): DateFormatter is not Sendable, and
/// every caller is a SwiftUI view on the main actor anyway.
@MainActor
enum TVKickoffFormat {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "HH:mm"
        return f
    }()

    static let timeDay: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "HH:mm · dd/MM"
        return f
    }()

    /// Day-only stamp (1.7.1, MU cards): the day part of
    /// timeDay, for the MU card header's upcoming-day label.
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "dd/MM"
        return f
    }()

    /// Full date (1.7.4, design Match Centre / board
    /// metadata + design card footer): "dd/MM/yyyy" in the
    /// device timezone, like every other stamp here.
    static let fullDate: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "dd/MM/yyyy"
        return f
    }()

    /// 1.7.1 MU header date formatter (table H2): the design's
    /// right block is clock + date — "EEE, dd MMM" in the
    /// device locale and timezone, uppercased at the call site.
    static let muHeaderDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "EEE, dd MMM"
        return f
    }()

    /// 1.7.1 MU SẮP ĐÁ rail date note (table H4): "EEEE, dd/MM"
    /// in the device locale and timezone.
    static let muRailDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "EEEE, dd/MM"
        return f
    }()

    /// Minutes played for a live match, from the absolute kickoff.
    static func liveMinute(of kickoff: Date, now: Date = Date()) -> Int {
        max(1, Int(now.timeIntervalSince(kickoff) / 60))
    }
}

// MARK: - Fixture grouping (same rules as the phone, TV presentation)

/// One fixture as the TV UI presents it: every source carrying the
/// same match collapses into a single tile, so a match never fills
/// a rail with two or three near-identical cards again. Grouping
/// rules are the shared FixtureGrouping pair-key identity
/// (Crests.swift — order-independent, filler-tolerant, stamp-jitter
/// and live-merge aware), the same identity the phone's cards and
/// the store's source ladder use; the representative channel is
/// the first in the store's sorted order, and playing hands it to
/// PlaylistStore.sources(for:), which returns the fixture's full
/// member list as the fallback ladder. Display-only: stored
/// channels are never mutated.
struct TVFixtureEntry: Identifiable {
    let channel: Channel
    let sourceCount: Int
    let id: String
    /// Matched live state (1.4.1, spec §1) — attached by the view
    /// from PlaylistStore.matchState(for:) after grouping; nil
    /// for an unmatched fixture (board shows the bounded computed
    /// clock and NO score, never a fabricated one).
    var state: MatchState? = nil
    /// Competition identity (spec §3/§4): S1 matched-state slug,
    /// else S3 both-clubs lower division, else nil (unknown →
    /// top section of the country tab).
    var competition: CompetitionID? = nil

    /// Cleaned title — the only title form the UI ever shows.
    var cleanTitle: String { MatchTitle.clean(channel.title) }

    /// "Team A" / "Team B" when the cleaned title is a fixture.
    var teams: (String, String)? { Crests.teams(ofCleanTitle: cleanTitle) }

    /// Both crest URLs for the fixture (either side may be nil);
    /// nil when the title is not a fixture at all.
    var crests: (URL?, URL?)? { Crests.crests(forTitle: channel.title) }

    /// The crest pair the tiles actually draw (1.4.4, item 1):
    /// the crest map first; a side the map misses falls back to
    /// the logo ESPN published for THIS fixture's bound state
    /// (MatchState.espnLogo — ESPN states only, canonical-key
    /// side match, http(s) only, fail-closed). No bound ESPN
    /// state → exactly the map pair, shields as before.
    var displayCrests: (URL?, URL?)? {
        guard let base = crests else { return nil }
        guard let state, let teams else { return base }
        return (base.0 ?? state.espnLogo(forTeamName: teams.0),
                base.1 ?? state.espnLogo(forTeamName: teams.1))
    }

    /// Headline for hero and tiles: "Team A vs Team B" when both
    /// teams are known (no broadcaster clutter survives), else the
    /// cleaned title.
    var headline: String {
        if let teams { return "\(teams.0) vs \(teams.1)" }
        return cleanTitle
    }

    /// Live with the matched state consulted first (spec §1.4):
    /// a matched live/HT state is live even past +125 min; an FT
    /// or not-started state is not live even inside the window.
    var isLive: Bool {
        if let state {
            switch state.status {
            case .live, .ht: return true
            case .ft, .pre, .postponed, .cancelled: return false
            }
        }
        return LeagueClassifier.isLive(channel)
    }

    /// The board's badge text: the matched state's verbatim
    /// minute / HT wording / FT, else the bounded computed clock
    /// (spec §1.4), else nil.
    var badgeText: String? {
        if let state, let badge = state.badgeText { return badge }
        if state?.status == .ft { return "FT" }
        guard isLive, let kickoff = channel.kickoff else { return nil }
        return MatchStateStore.computedBadge(kickoff: kickoff)
    }

    /// Competition label for boards and heroes: the identified
    /// competition when there is one, else the league tab name.
    var competitionLabel: String {
        competition?.label ?? leagueName.uppercased()
    }

    var isLowerDivision: Bool { competition?.isLower == true }
    var isCupFixture: Bool { competition?.isCup == true }

    var leagueName: String {
        League(rawValue: channel.leagueRank)?.name ?? "Khác"
    }

    /// Group a sorted channel list into fixture entries, preserving
    /// the incoming order (first occurrence wins the slot). The
    /// identity itself lives in FixtureGrouping (Crests.swift),
    /// shared with the phone — this is a delegation, not a copy.
    static func group(_ channels: [Channel]) -> [TVFixtureEntry] {
        FixtureGrouping.group(channels).map { g in
            TVFixtureEntry(channel: g.members[0], sourceCount: g.members.count, id: g.id)
        }
    }

    // MARK: - Manchester United priority pin (owner, 2026-11-19)

    /// True when either side of this fixture is Manchester United.
    /// The test is the app's own club identity, not a name list of
    /// my own: a side counts as MU exactly when the crest chain
    /// (Crests.url(forTeam:), with its ĐTQG / Nữ / age-marker
    /// strippers) resolves its name to the same badge it resolves
    /// "Manchester United" to. In the crest map — the bundled
    /// 459-key baseline and the mirror's live 639-key map agree —
    /// that badge (xzqdr11517660252.png) is keyed by "manchester
    /// united", "manchester utd", "man united" and "man utd", so
    /// every spelling the data actually uses is covered, a future
    /// alias the mirror map adds is picked up with no code change,
    /// and Manchester City (a different badge) can never match.
    /// The club's other sides the listings carry — "Nữ Manchester
    /// Utd" (women), a "U21" youth side — resolve to the same
    /// badge through the crest chain's strippers, so they count as
    /// the club too, exactly as their tiles already show the MU
    /// crest.
    var isManchesterUnited: Bool {
        guard let teams,
              let badge = Crests.url(forTeam: "Manchester United")
        else { return false }
        return Crests.url(forTeam: teams.0) == badge
            || Crests.url(forTeam: teams.1) == badge
    }

    /// True when the fixture may be pinned: Manchester United AND
    /// live or upcoming (classifier buckets 0–2). A finished MU
    /// listing (bucket 3 — a stale replay) is never pinned: the
    /// pin exists so the match he is about to watch leads the
    /// screen, not so an old replay does.
    func isPinnableMU(now: Date) -> Bool {
        isManchesterUnited
            && LeagueClassifier.bucket(of: channel, now: now) < 3
    }

    /// Hoist the pinnable MU fixtures to the very front of a
    /// fixture list: live first, then nearest kickoff (the same
    /// order the store's sort already gives them, restated here so
    /// the rule holds for any input order; the sort is stable).
    /// Everything else — including a finished MU listing — keeps
    /// its incoming order exactly, so with no live or upcoming MU
    /// fixture in the list the result is the input untouched.
    static func pinnedFirst(_ entries: [TVFixtureEntry],
                            now: Date = Date()) -> [TVFixtureEntry] {
        let pinned = entries.filter { $0.isPinnableMU(now: now) }
        guard !pinned.isEmpty else { return entries }
        let ordered = pinned.sorted { a, b in
            let ba = LeagueClassifier.bucket(of: a.channel, now: now)
            let bb = LeagueClassifier.bucket(of: b.channel, now: now)
            if ba != bb { return ba < bb }
            let ka = a.channel.kickoff?.timeIntervalSince1970 ?? .greatestFiniteMagnitude
            let kb = b.channel.kickoff?.timeIntervalSince1970 ?? .greatestFiniteMagnitude
            return ka < kb
        }
        let pinnedIDs = Set(ordered.map(\.id))
        return ordered + entries.filter { !pinnedIDs.contains($0.id) }
    }

    /// The one fixture the pin puts first in a list, if any: the
    /// live MU match, else the nearest upcoming one.
    static func manchesterUnitedPin(in entries: [TVFixtureEntry],
                                    now: Date = Date()) -> TVFixtureEntry? {
        guard let first = pinnedFirst(entries, now: now).first,
              first.isPinnableMU(now: now)
        else { return nil }
        return first
    }
}

// MARK: - English-commentary channels

/// The English backup block the mirror added to the shared playlist
/// (2026-11-14): group-title "EN · BLV Anh", titles prefixed
/// "EN · ". These are 24/7 channels — no kickoff, no fixture — so
/// they get their own section and their own card, and are filtered
/// out of every fixture list and the featured rail.
enum TVEnglish {
    static let groupName = "EN · BLV Anh"

    static func isEnglish(_ ch: Channel) -> Bool { ch.group == groupName }

    /// Card name without the "EN · " prefix (the section header and
    /// the BLV ANH chip already carry that information).
    static func displayName(_ ch: Channel) -> String {
        let t = MatchTitle.clean(ch.title)
        if t.hasPrefix("EN · ") { return String(t.dropFirst("EN · ".count)) }
        if t.hasPrefix("EN ·") { return String(t.dropFirst("EN ·".count)) }
        return t
    }
}

// MARK: - Shared TV palette (the TV app's own teal/cyan identity)

/// Đá Banh TV's established palette — deep teal + cyan on near-black,
/// deliberately unlike both the phone app (near-black + green) and
/// the general TV app, so the three are never confused.
enum TVPalette {
    static let cyan = Color(red: 0.0, green: 0.898, blue: 1.0)
    // Scoreboard tokens (spec §0 — the approved prototype's exact
    // palette). Since 1.4.3 (KH-7) this navy family is the app's
    // ONE colour family — the screen background and the card/hero
    // faces derive from it too; the teal/cyan identity above
    // remains as accents (focus ring, badges, live dot).
    static let boardBG = Color(red: 0.039, green: 0.067, blue: 0.125)      // #0A1120
    static let boardSky = Color(red: 0.220, green: 0.741, blue: 0.973)     // #38BDF8
    static let tileBG = Color(red: 0.067, green: 0.114, blue: 0.200)       // #111D33
    static let tileBorder = Color(red: 0.133, green: 0.208, blue: 0.353)   // #22355A
    static let tileFocusedBG = Color(red: 0.078, green: 0.149, blue: 0.247) // #14263F
    static let leagueTx = Color(red: 0.494, green: 0.576, blue: 0.710)     // #7E93B5
    static let minuteRed = Color(red: 0.761, green: 0.149, blue: 0.149)    // #C22626
    static let htAmber = Color(red: 0.541, green: 0.427, blue: 0.122)      // #8A6D1F
    static let liveDot = Color(red: 0.937, green: 0.267, blue: 0.267)      // #EF4444
    static let teamTx = Color(red: 0.933, green: 0.957, blue: 0.988)       // #EEF4FC
    static let dashTx = Color(red: 0.329, green: 0.455, blue: 0.624)       // #54749F
    static let eventsLine = Color(red: 0.114, green: 0.173, blue: 0.286)   // #1D2C49
    static let evTx = Color(red: 0.663, green: 0.737, blue: 0.851)         // #A9BCD9
    static let evMin = Color(red: 0.910, green: 0.933, blue: 0.969)        // #E8EEF7
    static let cardY = Color(red: 0.961, green: 0.773, blue: 0.094)        // #F5C518
    static let cardR = Color(red: 0.878, green: 0.204, blue: 0.169)        // #E0342B
    static let c1TileBG = Color(red: 0.086, green: 0.102, blue: 0.180)     // #161A2E
    static let c1Border = Color(red: 0.290, green: 0.267, blue: 0.122)     // #4A441F
    static let c1Gold = Color(red: 1.0, green: 0.843, blue: 0.416)         // #FFD76A
    static let c1Head = Color(red: 1.0, green: 0.914, blue: 0.659)         // #FFE9A8
    static let c1Label = Color(red: 0.788, green: 0.698, blue: 0.412)      // #C9B269
    static let tealFill = Color(red: 0.05, green: 0.36, blue: 0.30)
    static let liveRed = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let amber = Color(red: 1.0, green: 0.78, blue: 0.35)
    static let heroMeta = Color(red: 0.75, green: 0.94, blue: 0.90)
}

/// The four-state status chip every fixture tile carries (owner,
/// 2026-11-13: live vs replay must never be a guess) — red
/// LIVE · minute / amber ⏰ kickoff (device-local) / grey ↺ PHÁT LẠI
/// / slate 📺 KÊNH. Same language as the phone, sized for TV.
struct TVStatusChip: View {
    @Environment(\.tvTheme) private var theme
    let channel: Channel
    /// Matched live state when the caller has one (1.4.1): the
    /// chip then shows the source's own minute / FT + score
    /// instead of the wall-clock minute (spec §1.4).
    var state: MatchState? = nil

    var body: some View {
        let now = Date()
        let bucket = LeagueClassifier.bucket(of: channel, now: now)
        if let state, state.status == .ft {
            Text("FT" + (state.scoreText.map { " · " + $0 } ?? ""))
                .font(.system(size: 19, weight: .heavy))
                .foregroundStyle(.white.opacity(0.75))
        } else if let state, state.status == .live || state.status == .ht {
            HStack(spacing: 7) {
                Circle()
                    .fill(theme.liveRed)
                    .frame(width: 13, height: 13)
                Text("LIVE · " + (state.badgeText ?? ""))
                    .font(.system(size: 19, weight: .heavy))
                    .foregroundStyle(theme.liveRed)
            }
        } else if bucket == 0 {
            HStack(spacing: 7) {
                Circle()
                    .fill(theme.liveRed)
                    .frame(width: 13, height: 13)
                Text("LIVE · \(TVKickoffFormat.liveMinute(of: channel.kickoff ?? now, now: now))'")
                    .font(.system(size: 19, weight: .heavy))
                    .foregroundStyle(theme.liveRed)
            }
        } else if let kickoff = channel.kickoff, kickoff > now {
            Text("⏰ " + TVKickoffFormat.time.string(from: kickoff))
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(theme.amber)
        } else if channel.kickoff != nil {
            Text("↺ PHÁT LẠI")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
        } else {
            Text("📺 KÊNH")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}

/// Tile background shared by every rail card, with the thick
/// cyan focus ring the owner approved — the focus state must
/// read from the sofa, not just glow faintly. KH-7 (ĐG-4): the
/// fill is the scoreboard's navy family (tileBG → boardBG),
/// not the old white glass — the whole app now reads as ONE
/// colour family, the board's. Colour tokens only; the shape,
/// the ring and the geometry are unchanged.
func tvCardBackground(focused: Bool, theme: TVThemeTokens = .classic) -> some View {
    RoundedRectangle(cornerRadius: 22)
        .fill(LinearGradient(
            colors: [focused ? theme.tileFocusedBG : theme.tileBG,
                     theme.boardBG],
            startPoint: .topLeading, endPoint: .bottomTrailing))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(focused ? theme.focusRing : theme.tileBorder,
                              lineWidth: focused ? 4 : 1.5))
}

/// The hero panel's background — the same navy family and the
/// same focus ring as tvCardBackground, at the hero's larger
/// corner radius (KH-7).
func tvHeroBackground(focused: Bool, theme: TVThemeTokens = .classic) -> some View {
    RoundedRectangle(cornerRadius: 26)
        .fill(LinearGradient(
            colors: [focused ? theme.tileFocusedBG : theme.tileBG,
                     theme.boardBG],
            startPoint: .topLeading, endPoint: .bottomTrailing))
        .overlay(
            RoundedRectangle(cornerRadius: 26)
                .strokeBorder(focused ? theme.focusRing : theme.tileBorder,
                              lineWidth: focused ? 4 : 1.5))
}

// MARK: - Rail tile width (KH-6, ĐG-5)

/// The 3-across tile width, measured — never assumed. The
/// tiles used to be a hard 592pt, a number that is exactly
/// right only when the running screen offers exactly the
/// width the arithmetic was done against (1920pt); on the
/// owner's set the row overflowed and the third tile was cut
/// (his 1.4.2 photos). The root now measures its real content
/// width at runtime and publishes
/// min(592, (W − 2×8 rail insets − 2×28 spacing) / 3) here;
/// heights and ALL type sizes stay exactly as approved (the
/// owner's not-shrunk ruling for his father's smaller TV).
private struct TVTileWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 592
}

extension EnvironmentValues {
    var tvTileWidth: CGFloat {
        get { self[TVTileWidthKey.self] }
        set { self[TVTileWidthKey.self] = newValue }
    }
}

// MARK: - Card button (the .card cure, 2026-11-17)
//
// Every button in this app used to wear .buttonStyle(.card).
// That style paints the SYSTEM's own platter under the label
// — a pale plate at the system's size and offset — so every
// pill and card showed a ghost copy of itself peeking out
// from underneath (the owner's close-ups of 2026-11-17; the
// same disease JoeTV cured in its v2.0.8). The labels here
// already own their focus rendering (tvCardBackground's cyan
// ring, TVPillFace below), so the style layer must add
// NOTHING: this style returns the label untouched, and
// .focusEffectDisabled() kills the separate focus-effect
// layer with it. The app's drawn faces are the only layer.
struct TVCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

struct TVCardButton: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(TVCardButtonStyle())
            .focusEffectDisabled()
    }
}

extension View {
    /// The app's only button construction — see TVCardButton.
    func tvCardButton() -> some View {
        modifier(TVCardButton())
    }
}

/// The pill face the league pills and the header buttons
/// share: capsule fill (selected teal / idle white 10%) plus
/// the app's own focus ring — an outset cyan stroke in the
/// same weight as the cards' ring — replacing the platter
/// the .card style used to lend them.
struct TVPillFace: View {
    let focused: Bool
    let selected: Bool
    var theme: TVThemeTokens = .classic
    /// Selection marks (MU red dot + underline) are drawn ONLY
    /// for tab pills; header action pills pass false (spec:
    /// showsSelectionMarks true only from tabPill).
    var showsSelectionMarks: Bool = false

    var body: some View {
        if theme.id.isMU {
            muBody
        } else {
            // Classic branch: today's body verbatim, with the
            // palette constants re-expressed as their classic
            // tokens (selectedFill == the classic tealFill,
            // focusRing == the classic cyan) — classic pixels
            // are identical.
            Capsule()
                .fill(selected ? theme.selectedFill : Color.white.opacity(0.10))
                .overlay(
                    Capsule()
                        .stroke(theme.focusRing, lineWidth: focused ? 4 : 0)
                        .padding(focused ? -4 : 0))
        }
    }

    /// MU pill (spec): white 10% fill idle; selected = white
    /// 6% fill + white 1.5pt stroke. The red dot lives in a
    /// FIXED 8pt slot at the leading edge — the slot is always
    /// reserved when showsSelectionMarks is set and only its
    /// opacity changes with selection, so the pill's geometry
    /// never jumps (FL-360). The red underline is an OVERLAY
    /// only, never in layout flow. Focus is the gold outset
    /// ring with exactly the classic cyan outset's geometry.
    private var muBody: some View {
        Capsule()
            .fill(selected ? Color.white.opacity(0.06) : Color.white.opacity(0.10))
            .overlay(
                Capsule()
                    .stroke(Color.white, lineWidth: selected ? 1.5 : 0))
            .overlay(
                Capsule()
                    .stroke(theme.focusRing, lineWidth: focused ? 4 : 0)
                    .padding(focused ? -4 : 0))
            .overlay(alignment: .leading) {
                if showsSelectionMarks {
                    Circle()
                        .fill(theme.unitedRed)
                        .frame(width: 8, height: 8)
                        .padding(.leading, 10)
                        .opacity(selected ? 1 : 0)
                }
            }
            .overlay(alignment: .bottom) {
                if showsSelectionMarks && selected {
                    Capsule()
                        .fill(theme.unitedRed)
                        .frame(width: 36, height: 3)
                        .padding(.bottom, 5)
                }
            }
    }
}

// MARK: - Crest / logo pieces

/// Session image cache for crests and channel logos (v1.3.5,
/// tvOS 27 optimisation pass). The two image views below used to
/// be bare AsyncImage: it keeps no decoded-image memory cache, so
/// every hero swap — and the hero follows EVERY focus move — plus
/// every rail re-render re-fetched and re-decoded the same
/// TheSportsDB crests all session long, visible as placeholder
/// flicker on the hero art. tvOS 26/27 changed nothing in
/// AsyncImage to fix that, so the app now holds decoded images in
/// an NSCache and fetches through a session with a real URLCache
/// (32 MB memory / 128 MB disk): a crest is downloaded at most
/// once per launch, and usually once ever. Rendering is
/// unchanged — same placeholder while loading, same scaledToFit
/// image when loaded.
enum TVImageCache {
    // Swift 6: nonisolated(unsafe) — NSCache is thread-safe by design
    // (Apple documents adding, removing and querying items from
    // different threads without locking the cache yourself), and
    // load() reads/writes it across await suspension points, off the
    // main actor. The cache instance itself is never mutated or
    // replaced after init — only its contents change, inside NSCache.
    nonisolated(unsafe) static let cache = NSCache<NSURL, UIImage>()
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                   diskCapacity: 128 * 1024 * 1024)
        return URLSession(configuration: config)
    }()

    static func load(_ url: URL) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let (data, _) = try? await session.data(from: url),
              let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    /// Downsampled load for wallpaper images (spec): some
    /// wallpapers are 8002px wide and must never be decoded at
    /// full size, so the decode goes through CGImageSource's
    /// thumbnail path capped at maxPixel on the longest side.
    /// The result is cached in the same NSCache as load().
    static func loadDownsampled(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard maxPixel > 0 else { return await load(url) }
        guard let (data, _) = try? await session.data(from: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel.rounded())
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cgImage)
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

/// One cached image with the house placeholder while it loads.
struct TVCachedImage: View {
    let url: URL
    let placeholderSize: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                TVSoccerPlaceholder(size: placeholderSize)
            }
        }
        .task(id: url) {
            image = await TVImageCache.load(url)
        }
    }
}

struct TVCrestImage: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let url {
                TVCachedImage(url: url, placeholderSize: size * 0.5)
            } else {
                TVSoccerPlaceholder(size: size * 0.5)
            }
        }
        .frame(width: size, height: size)
    }
}

struct TVSoccerPlaceholder: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "soccerball")
            .font(.system(size: size))
            .foregroundStyle(.white.opacity(0.35))
    }
}

/// Crest-vs-crest row for a fixture tile; falls back to the channel
/// logo when the title is not a known fixture.
struct TVCrestRow: View {
    let channel: Channel
    /// The fixture's bound state, when the caller has one
    /// (1.4.4: feeds the ESPN-logo fallback in filledPair).
    var state: MatchState? = nil
    var crestSize: CGFloat = 62
    var logoHeight: CGFloat = 54

    /// The map pair with the 1.4.4 ESPN fallback per missing
    /// side (same rule as TVFixtureEntry.displayCrests).
    private var filledPair: (URL?, URL?)? {
        guard let base = Crests.crests(forTitle: channel.title) else { return nil }
        guard let state,
              let teams = Crests.teams(ofCleanTitle: MatchTitle.clean(channel.title))
        else { return base }
        return (base.0 ?? state.espnLogo(forTeamName: teams.0),
                base.1 ?? state.espnLogo(forTeamName: teams.1))
    }

    var body: some View {
        let pair = filledPair
        Group {
            if let pair, pair.0 != nil || pair.1 != nil {
                HStack(spacing: 10) {
                    TVCrestImage(url: pair.0, size: crestSize)
                    if pair.0 != nil && pair.1 != nil {
                        Text("vs")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    TVCrestImage(url: pair.1, size: crestSize)
                    if (pair.0 == nil) != (pair.1 == nil) {
                        TVChannelLogo(channel: channel, height: 46)
                    }
                }
            } else {
                TVChannelLogo(channel: channel, height: logoHeight)
            }
        }
        // 1.4.9 (FL-360, audit S-7): the row's height is the
        // crest height in BOTH branches — the logo branch was
        // 54 against the pair branch's 62, so a tile whose
        // crest pair arrived late (the ESPN fallback filling
        // a missing side when its state landed) grew its
        // first row by 8 pt and pushed the headline inside
        // the tile. The row now holds 62 either way.
        .frame(height: max(crestSize, logoHeight))
    }
}

struct TVChannelLogo: View {
    let channel: Channel
    let height: CGFloat

    var body: some View {
        Group {
            if let url = channel.logoURL {
                TVCachedImage(url: url, placeholderSize: height * 0.6)
            } else {
                TVSoccerPlaceholder(size: height * 0.6)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Featured tile (the TV's featured rail)

/// Big face-off tile for the featured rail — the television
/// expression of the phone's featured card, NOT a scaled copy of
/// it: roughly twice the phone card in each dimension, crests at
/// 110pt with the team names under them, a LIVE · minute (or
/// device-local kickoff) badge, the league line, and the source
/// count. One tile per fixture, however many sources carry it.
struct TVFeaturedCard: View {
    @EnvironmentObject private var store: PlaylistStore
    @Environment(\.tvTheme) private var theme
    @Environment(\.tvTileWidth) private var tileWidth
    let entry: TVFixtureEntry
    let focused: Bool

    var body: some View {
        let _ = store.crestsRevision
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text(entry.leagueName.uppercased())
                    .font(.system(size: 21, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(theme.heroMeta)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if entry.sourceCount > 1 {
                    Text("\(entry.sourceCount) nguồn phát")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                }
            }

            if let teams = entry.teams {
                HStack(alignment: .top, spacing: 10) {
                    teamBlock(name: teams.0, crest: entry.displayCrests?.0 ?? nil)
                    Text("VS")
                        .font(.system(size: 24, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.top, 40)
                    teamBlock(name: teams.1, crest: entry.displayCrests?.1 ?? nil)
                }
            } else {
                HStack(spacing: 18) {
                    TVChannelLogo(channel: entry.channel, height: 84)
                    Text(entry.cleanTitle)
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 14) {
                if entry.isLive {
                    HStack(spacing: 8) {
                        Circle().fill(.white).frame(width: 11, height: 11)
                        if let kickoff = entry.channel.kickoff {
                            Text("ĐANG ĐÁ · \(TVKickoffFormat.liveMinute(of: kickoff))'")
                                .font(.system(size: 22, weight: .heavy))
                        } else {
                            Text("ĐANG ĐÁ")
                                .font(.system(size: 22, weight: .heavy))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(theme.liveRed))
                }
                if let kickoff = entry.channel.kickoff {
                    Text(TVKickoffFormat.timeDay.string(from: kickoff))
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.75))
                }
                Spacer(minLength: 0)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(theme.focusRing)
            }
        }
        .padding(28)
        // Featured fit fix (2026-11-19, with Sony 2.21): width
        // 640 -> 592pt. The featured rail is a 3-across row like
        // the board rails (root padding 32, rail insets 8+8,
        // spacing 28 -> usable 1840pt), and at 640 the third
        // featured tile overflowed: 3*640 + 2*28 = 1976 > 1840,
        // its last 96pt past the screen edge — the same defect
        // the owner photographed on Sony 2.20's featured rail.
        // At 592 the tile matches the live board's width:
        // 3*592 + 2*28 = 1832 <= 1840, third tile fully on
        // screen. Height unchanged; internals are flexible
        // (teamBlock is maxWidth .infinity), nothing inside
        // assumes 640.
        // KH-6: the width itself is no longer the constant —
        // it is the measured tvTileWidth (capped at this 592),
        // so the row fits the screen the app actually runs on.
        .frame(width: tileWidth, height: 330, alignment: .leading)
        .background(tvCardBackground(focused: focused, theme: theme))
    }

    private func teamBlock(name: String, crest: URL?) -> some View {
        VStack(spacing: 10) {
            TVCrestImage(url: crest, size: 110)
            Text(name)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}


// MARK: - Live scoreboard tile (1.4.1, spec §0/§1.5)

/// The big-score board: one live fixture as the approved
/// prototype draws it — competition label + minute/status badge
/// on top, crest+name | BIG CENTRED SCORE | name+crest, then the
/// event lines under a divider (scorers with minutes, card glyphs
/// with minutes). Geometry is the prototype's at TV scale (score
/// 69 pt, team names 24 pt, events 19 pt, tile 592 pt wide in
/// the 3-across row — 606 until the 2026-11-19 fit fix narrowed
/// it 14 pt so the third tile fits the screen whole; the type
/// sizes, which carry the owner's not-shrunk ruling for his
/// father's smaller TV, are unchanged). A fixture with no matched
/// state renders the same shape with the bounded computed clock
/// in the badge and NO score and NO event lines — nothing is
/// ever fabricated (spec §0/§1.4). C1 fixtures carry the gold
/// variant; C2/C3 use the standard board (spec §4.1 / plan
/// §0.4 reading). Focus follows the app's standing cure: the
/// custom button style adds nothing and the board's own focused
/// face (focused fill + SKY/gold border) is the only layer —
/// the OS platter never fights it (spec §5.2-10).
struct TVLiveBoardView: View {
    @EnvironmentObject private var store: PlaylistStore
    @Environment(\.tvTheme) private var theme
    @Environment(\.tvTileWidth) private var tileWidth
    let entry: TVFixtureEntry
    let focused: Bool

    private var isGold: Bool {
        entry.competition == .championsLeague || entry.competition == .womensChampionsLeague
    }

    var body: some View {
        let _ = store.crestsRevision
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Text(entry.competitionLabel)
                    .font(.system(size: 19, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(isGold ? theme.c1Label : theme.leagueTx)
                    .lineLimit(1)
                Spacer(minLength: 0)
                badge
            }
            // 1.4.9 (FL-360, audit S-7): the header row holds
            // the badge's height (25 pt line + its padding
            // ≈ 39) whether or not a badge is showing — a
            // badge landing with the tile's state no longer
            // grows the row and pushes the score row down
            // inside the fixed 342 frame.
            .frame(height: 39)
            scoreRow
            if let state = entry.state, !state.events.isEmpty {
                eventsBlock(state)
            }
        }
        .padding(20)
        // Fit fix (2026-11-19, with Sony 2.20): width 606 -> 592pt.
        // At the old 60pt root padding the usable row width was
        // 1920 - 2*60 - 2*8 = 1784 against 3*606 + 2*28 = 1874 —
        // the third board overflowed by 90pt and was cut at the
        // right edge (the same defect the owner photographed on
        // Sony 2.19). Padding 32 alone still left 34pt over, so
        // the board narrows too: usable = 1920 - 2*32 - 2*8 =
        // 1840; 3*592 + 2*28 = 1832 <= 1840, third board fully on
        // screen. Height unchanged; the focus ring is strokeBorder
        // (inside the frame), so a fully-visible frame means a
        // fully-visible ring.
        // KH-6: the width is the measured tvTileWidth (capped at
        // this 592) — see TVTileWidthKey.
        .frame(width: tileWidth, height: 342, alignment: .topLeading)
        .background(boardBackground(theme: theme))
    }

    private var badge: some View {
        let isHT = entry.state?.status == .ht
            || entry.badgeText == "NGHỈ GIỮA HIỆP"
        return Group {
            if let text = entry.badgeText {
                Text(text)
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(isHT ? theme.htAmber : theme.minuteRed))
            } else if entry.state?.status == .postponed || entry.state?.status == .cancelled {
                Text("HOÃN")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(Color(red: 0.38, green: 0.38, blue: 0.42)))
            }
        }
    }

    private var scoreRow: some View {
        HStack(alignment: .center, spacing: 10) {
            teamColumn(name: entry.teams?.0, crest: entry.displayCrests?.0 ?? nil)
            scoreCentre
            teamColumn(name: entry.teams?.1, crest: entry.displayCrests?.1 ?? nil)
        }
        .frame(maxWidth: .infinity)
    }

    private func teamColumn(name: String?, crest: URL?) -> some View {
        VStack(spacing: 8) {
            TVCrestImage(url: crest, size: 52)
            Text(name ?? entry.cleanTitle)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(theme.teamTx)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var scoreCentre: some View {
        if let state = entry.state, let h = state.scoreHome, let a = state.scoreAway {
            HStack(spacing: 10) {
                Text("\(h)")
                    .font(.system(size: 69, weight: .bold))
                    .foregroundStyle(.white)
                Text("-")
                    .font(.system(size: 69, weight: .bold))
                    .foregroundStyle(theme.dashTx)
                Text("\(a)")
                    .font(.system(size: 69, weight: .bold))
                    .foregroundStyle(.white)
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        } else {
            // Unmatched: the prototype's face-off shape — crests
            // and names only, no digits of any kind.
            Text("VS")
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    private func eventsBlock(_ state: MatchState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle()
                .fill(theme.eventsLine)
                .frame(height: 1)
            HStack(alignment: .top, spacing: 16) {
                eventColumn(events: state.events.filter { $0.isHome }, alignRight: false)
                eventColumn(events: state.events.filter { !$0.isHome }, alignRight: true)
            }
        }
    }

    private func eventColumn(events: [MatchEvent], alignRight: Bool) -> some View {
        VStack(alignment: alignRight ? .trailing : .leading, spacing: 4) {
            ForEach(Array(events.prefix(3).enumerated()), id: \.offset) { _, event in
                HStack(spacing: 7) {
                    if event.kind != .goal {
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(event.kind == .redCard ? theme.cardR : theme.cardY)
                            .frame(width: 12, height: 16)
                    }
                    Text(event.playerName)
                        .font(.system(size: 19))
                        .foregroundStyle(theme.evTx)
                        .lineLimit(1)
                    Text(event.minuteText)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(theme.evMin)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: alignRight ? .trailing : .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignRight ? .trailing : .leading)
    }

    private func boardBackground(theme: TVThemeTokens) -> some View {
        RoundedRectangle(cornerRadius: 17)
            .fill(isGold ? theme.c1TileBG : (focused ? theme.tileFocusedBG : theme.tileBG))
            .overlay(
                RoundedRectangle(cornerRadius: 17)
                    .strokeBorder(
                        focused ? (isGold ? theme.c1Gold : theme.accent)
                                : (isGold ? theme.c1Border : theme.tileBorder),
                        lineWidth: focused ? 4 : 2))
    }
}

// MARK: - Score digits + event columns (shared: hero + board)

/// The big score digits (69 pt, the board family's centre) —
/// ONE rendering for the two surfaces that show a bare score:
/// the slim hero's score slot (1.5.0) and the link board's
/// full-info header. Nothing else rides along: no events, no
/// meta — the digits are the score, whole.
struct TVScoreDigits: View {
    @Environment(\.tvTheme) private var theme
    let home: Int
    let away: Int
    /// Digit size (1.7.0): default 69 is the classic board
    /// size, so every existing call site renders unchanged;
    /// the MU board passes a larger size.
    var size: CGFloat = 69
    /// Separator glyph (1.7.0): default " - " draws "-" —
    /// the classic face exactly (the HStack's 12pt spacing
    /// already provides the separation the string's spaces
    /// describe, so only the glyph is drawn); the MU board
    /// passes " : " and draws ":".
    var separator: String = " - "
    /// 1.7.5: the design theme's digits are the programme's
    /// display face (Barlow Condensed 800 — TVDesignFont).
    /// Only the design centre (150) and the design board
    /// (64) pass true; the classic board, the MU Wally board
    /// and the classic detail keep the system face exactly.
    var design: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Text("\(home)")
                .font(digitFont)
                .foregroundStyle(.white)
            Text(separator.trimmingCharacters(in: .whitespaces))
                .font(digitFont)
                .foregroundStyle(theme.dashTx)
            Text("\(away)")
                .font(digitFont)
                .foregroundStyle(.white)
        }
        .lineLimit(1)
    }

    private var digitFont: Font {
        design ? TVDesignFont.display(size)
               : .system(size: size, weight: .bold)
    }
}

/// The per-side event columns under a divider: home events
/// left-aligned under the home side, away events right-aligned
/// under the away side — goals first, then cards, each kind in
/// the state's own order, at most 3 lines a side plus a "+N"
/// overflow line (the iOS board's rule), in the tvOS board's
/// line idiom (card glyph, name, minute). This is the 1.4.7
/// hero block's event rendering, moved here VERBATIM in 1.5.0
/// when the full info moved from the hero to the link board's
/// header (owner redesign ruling, 2026-11-21); the hero keeps
/// only TVScoreDigits. Fullest height: divider 1 + spacing 12
/// + four lines (4 × 24 + 3 × 4) = 121 — the number the board
/// header reserves while a live board's events are still
/// landing.
struct TVEventColumns: View {
    @Environment(\.tvTheme) private var theme
    let state: MatchState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle()
                .fill(theme.eventsLine)
                .frame(height: 1)
            HStack(alignment: .top, spacing: 16) {
                eventColumn(events: state.events.filter { $0.isHome },
                            alignRight: false)
                eventColumn(events: state.events.filter { !$0.isHome },
                            alignRight: true)
            }
        }
    }

    private func eventColumn(events: [MatchEvent], alignRight: Bool) -> some View {
        // Goals before cards; each kind keeps the state's own
        // order. Cap 3 lines, the rest collapse into "+N".
        let ordered = events.filter { $0.kind == .goal }
            + events.filter { $0.kind != .goal }
        return VStack(alignment: alignRight ? .trailing : .leading, spacing: 4) {
            ForEach(Array(ordered.prefix(3).enumerated()), id: \.offset) { _, event in
                eventLine(event, alignRight: alignRight)
            }
            if ordered.count > 3 {
                Text("+\(ordered.count - 3)")
                    .font(.system(size: 19))
                    .foregroundStyle(theme.evMin)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity,
                           alignment: alignRight ? .trailing : .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignRight ? .trailing : .leading)
    }

    private func eventLine(_ event: MatchEvent, alignRight: Bool) -> some View {
        HStack(spacing: 7) {
            if event.kind != .goal {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(event.kind == .redCard ? theme.cardR : theme.cardY)
                    .frame(width: 12, height: 16)
            }
            Text(event.playerName)
                .font(.system(size: 19))
                .foregroundStyle(theme.evTx)
                .lineLimit(1)
            Text(event.minuteText)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(theme.evMin)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: alignRight ? .trailing : .leading)
    }
}

// MARK: - Match tile (standard rail card)

/// One fixture in a bucket rail: crest-vs-crest (or the channel
/// logo), the headline, the four-state status chip, and a meta line
/// with the device-local kickoff and the grouped source count.
/// Same 470×252 footprint the owner already approved on his TV —
/// the redesign changes what the tile MEANS (one fixture, not one
/// source), not the rail geometry his remote flow is tuned to.
struct TVMatchCard: View {
    @EnvironmentObject private var store: PlaylistStore
    @Environment(\.tvTheme) private var theme
    let entry: TVFixtureEntry
    let focused: Bool

    private var channel: Channel { entry.channel }

    var body: some View {
        let _ = store.crestsRevision
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                TVCrestRow(channel: channel, state: entry.state)
                Spacer()
                TVStatusChip(channel: channel, state: entry.state)
            }
            Text(entry.headline)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(focused ? theme.focusRing : .white)
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

    private var meta: String {
        var parts: [String] = []
        if let kickoff = channel.kickoff {
            parts.append(TVKickoffFormat.timeDay.string(from: kickoff))
        }
        if !channel.group.isEmpty { parts.append(channel.group) }
        if entry.sourceCount > 1 { parts.append("\(entry.sourceCount) nguồn") }
        return parts.joined(separator: "  ·  ")
    }
}

// MARK: - English channel card

/// One English-commentary channel in the EN section. The mirror's
/// EN entries carry no tvg-logo, so the card is built around
/// typography, not artwork: the channel name large, a 24/7 · BLV ANH
/// chip (these channels are always on — there is no kickoff to
/// show), and the channel logo only when one exists. Playing one
/// hands the player just this channel; there is no fixture ladder
/// behind a 24/7 channel.
struct TVENChannelCard: View {
    @Environment(\.tvTheme) private var theme
    let channel: Channel
    let focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                if channel.logoURL != nil {
                    TVChannelLogo(channel: channel, height: 58)
                } else {
                    Image(systemName: "tv")
                        .font(.system(size: 44))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Text("24/7 · BLV ANH")
                    .font(.system(size: 19, weight: .heavy))
                    .foregroundStyle(theme.focusRing)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(theme.selectedFill))
            }
            Text(TVEnglish.displayName(channel))
                .font(.system(size: 31, weight: .bold))
                .foregroundStyle(focused ? theme.focusRing : .white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(theme.focusRing)
                Text("Kênh tiếng Anh · phát liên tục")
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

// MARK: - Rails (KH-2, ĐG-1 — focus lives at the leaf)
//
// The focus-lag cure's view half: every rail is its OWN view
// and owns its OWN @FocusState. In 1.4.2 the single @FocusState
// sat on the root view, so every focus step re-ran the root's
// whole body — which regrouped and re-enriched the entire pool
// at ~21 call sites. Now a focus step invalidates only the rail
// the remote is actually moving through; the root's body reads
// a precomputed snapshot (see TVContentView) for all grouped /
// enriched data — the only per-pass work left there is the
// time-based bucket split, which is live by design (see the
// HomeSnapshot note in TVContentView). Focus changes are
// reported upward as KEYS only (the root maps key → hero
// content through the snapshot's hero lookup), and each change
// is signposted into DiagLog (KH-1/KH-2's measuring rule).

/// One horizontal rail of fixture tiles — the featured rail
/// (big face-off cards) or a standard bucket rail (match
/// cards); live fixtures render as scoreboards in both.
struct TVFixtureRail: View {
    enum Style { case featured, standard }

    let title: String
    let entries: [TVFixtureEntry]
    let style: Style
    let onSelect: (TVFixtureEntry) -> Void
    let onFocusKey: (String) -> Void
    @FocusState private var focus: String?

    private var keyPrefix: String { style == .featured ? "feat:" : "rail:" }

    /// 1.4.9 (FL-360, audit S-3): the rail's slot height —
    /// every tile in the rail occupies the SAME height, so
    /// the rail's height is a property of the rail, not of
    /// which tile happens to be tallest today. Featured:
    /// always the board height 342 (the 330 featured card
    /// keeps its own face; the slot reserves the board's 12
    /// extra points, so the last board flipping to a card at
    /// FT no longer drops the rail and pulls every section
    /// below up). Standard: the board height when any entry
    /// renders as a board, else the card height — a standard
    /// rail's height can still change when its FIRST board
    /// arrives (a live state landing is a data-truth change;
    /// the alternative, a permanent 90 pt dead band under
    /// every card rail, is the worse always-visible defect),
    /// but tiles are top-aligned in the slot, so an existing
    /// tile never moves when a taller sibling lands.
    private var slotHeight: CGFloat {
        if style == .featured { return 342 }
        return entries.contains { $0.isLive } ? 342 : 252
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 28) {
                    ForEach(entries) { entry in
                        Button {
                            onSelect(entry)
                        } label: {
                            if entry.isLive {
                                TVLiveBoardView(entry: entry,
                                                focused: focus == keyPrefix + entry.id)
                            } else if style == .featured {
                                TVFeaturedCard(entry: entry,
                                               focused: focus == keyPrefix + entry.id)
                            } else {
                                TVMatchCard(entry: entry,
                                            focused: focus == keyPrefix + entry.id)
                            }
                        }
                        .tvCardButton()
                        .focused($focus, equals: keyPrefix + entry.id)
                        .frame(height: slotHeight, alignment: .top)
                    }
                }
                .padding(.horizontal, 4)
                // 1.5.1 (FL-360): vertical inset 14 → 4. The
                // focus ring is strokeBorder INSIDE the tile
                // frame and the card button style applies no
                // focus scaling (TVCardButtonStyle), so the
                // inset is pure breathing room — 4 pt clears
                // the ring whole and returns 20 pt to the
                // viewport (see BUILD-151-REPORT.md).
                .padding(.vertical, 4)
            }
        }
        .onChange(of: focus) { _, key in
            guard let key else { return }
            FocusSignpost.begin()
            onFocusKey(key)
            Task { @MainActor in FocusSignpost.end() }
        }
    }
}

/// One horizontal rail of Nuvio addon EVENT items (live or
/// upcoming fixtures from the addon).
struct TVNuvioEventRail: View {
    let title: String
    let items: [NuvioItem]
    let onSelect: (NuvioItem) -> Void
    let onFocusKey: (String) -> Void
    @FocusState private var focus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 28) {
                    ForEach(items) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            NuvioEventCard(item: item,
                                           focused: focus == "nv:" + item.id)
                        }
                        .tvCardButton()
                        .focused($focus, equals: "nv:" + item.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 16)
            }
        }
        .onChange(of: focus) { _, key in
            guard let key else { return }
            FocusSignpost.begin()
            onFocusKey(key)
            Task { @MainActor in FocusSignpost.end() }
        }
    }
}

/// One horizontal rail of Nuvio 24/7 CHANNEL items — the EN
/// tab's channel rail and the folded league tabs' channel
/// rails (league copy + card prefix passed in).
struct TVNuvioChannelRail: View {
    let title: String
    var subtitle: String? = nil
    let items: [NuvioItem]
    var detailPrefix: String? = nil
    let onSelect: (NuvioItem) -> Void
    let onFocusKey: (String) -> Void
    @FocusState private var focus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.6))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 28) {
                    ForEach(items) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            if let detailPrefix {
                                NuvioChannelCard(item: item,
                                                 focused: focus == "nv:" + item.id,
                                                 detailPrefix: detailPrefix)
                            } else {
                                NuvioChannelCard(item: item,
                                                 focused: focus == "nv:" + item.id)
                            }
                        }
                        .tvCardButton()
                        .focused($focus, equals: "nv:" + item.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 16)
            }
        }
        .onChange(of: focus) { _, key in
            guard let key else { return }
            FocusSignpost.begin()
            onFocusKey(key)
            Task { @MainActor in FocusSignpost.end() }
        }
    }
}

/// The old mirror EN block's rail: plain playable 24/7
/// channels, no fixture grouping, no ladder.
struct TVENChannelRail: View {
    let channels: [Channel]
    let onSelect: (Channel) -> Void
    let onFocusKey: (String) -> Void
    @FocusState private var focus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("🌍  EN · BLV Anh — KÊNH BLV TIẾNG ANH")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
            Text("Kênh 24/7 bình luận tiếng Anh — nguồn dự phòng khi nguồn Việt chậm hoặc chết.")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.6))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 28) {
                    ForEach(channels) { ch in
                        Button {
                            onSelect(ch)
                        } label: {
                            TVENChannelCard(channel: ch,
                                            focused: focus == "en:" + ch.url)
                        }
                        .tvCardButton()
                        .focused($focus, equals: "en:" + ch.url)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 16)
            }
        }
        .onChange(of: focus) { _, key in
            guard let key else { return }
            FocusSignpost.begin()
            onFocusKey(key)
            Task { @MainActor in FocusSignpost.end() }
        }
    }
}

// MARK: - MU theme views (1.7.1 — united-tv full layout)
//
// Everything below is NEW in 1.7.1 and renders ONLY under the
// Manchester United theme (the W-B branches in TVContentView
// select these views when theme.id.isMU). No existing
// declaration above is modified by this section, so the
// classic theme's render is untouched. The MU cards share ONE
// fixed geometry in every state (FL-360): width =
// tvMUCardWidth (published by the root, ≈421 at the design's
// 1760 content width), height 276, radius 12, and every
// interior slot is FIXED — header 40, centre 92, names 60,
// hairline 1, footer 24 (+8 top padding), vertical padding
// 16×2, and the flexible spacer taking exactly the remainder:
// 16 + 40 + 92 + 60 + 19 (spacer) + 1 + 8 + 24 + 16 = 276.
// Focus is the house cure only: tvCardButton() on the rail
// buttons and the drawn face (tvMUCardBackground) — no second
// focus layer, no scaling anywhere.

/// The MU rail card width (1.7.1): the root measures its real
/// content width and publishes (W − 74) / 4 capped to
/// 300...425 (≈421 at 1760 — the design's 4-across grid with
/// 22 pt gaps); the default is the design-width value.
private struct TVMUCardWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 421
}

extension EnvironmentValues {
    var tvMUCardWidth: CGFloat {
        get { self[TVMUCardWidthKey.self] }
        set { self[TVMUCardWidthKey.self] = newValue }
    }
}

/// The MU card face (1.7.1): radius 10 (1.7.2, audit H20),
/// the focused state is the maroon gradient (tileFocusedBG →
/// minuteRed — OPAQUE since 1.7.2, audit H23: at 0.35 alpha
/// the second stop let a bright wallpaper glow through the
/// focused card pink) with the gold focus ring drawn INSIDE
/// the bounds (strokeBorder 3); idle is the flat tileBG with
/// the 1.5 pt tile border. Beside tvCardBackground, same
/// construction — the drawn face is the only focus layer.
func tvMUCardBackground(focused: Bool, theme: TVThemeTokens) -> some View {
    RoundedRectangle(cornerRadius: 10)
        .fill(focused
              ? AnyShapeStyle(LinearGradient(
                    colors: [theme.tileFocusedBG,
                             theme.minuteRed],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
              : AnyShapeStyle(theme.tileBG))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(focused ? theme.focusRing : theme.tileBorder,
                              lineWidth: focused ? 3 : 1.5))
}

/// The upcoming-day label the MU card headers share (1.7.1):
/// today / tomorrow in words, any other day as dd/MM — all in
/// the device's timezone, like every kickoff stamp in the app.
@MainActor
private func tvMUDayLabel(for kickoff: Date, now: Date = Date()) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(kickoff) { return "HÔM NAY" }
    if calendar.isDateInTomorrow(kickoff) { return "NGÀY MAI" }
    return TVKickoffFormat.day.string(from: kickoff)
}

/// The LIVE line of an MU card header (dot + "LIVE"), shared
/// by the fixture card and the Nuvio event card so the two
/// headers can never drift apart.
private struct TVMULiveLine: View {
    @Environment(\.tvTheme) private var theme

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(theme.liveRed)
                .frame(width: 9, height: 9)
            Text("LIVE")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(theme.minuteRed)
                .lineLimit(1)
        }
    }
}

// MARK: MU fixture card

/// One fixture in the MU layout (1.7.1, table H5/H6): the
/// design's card — league caps + state stack on top, crest |
/// score-or-kickoff | crest in the fixed centre slot, names
/// under the crests, and the channel-group / kickoff footer
/// under a hairline. ONE shape for every fixture state (live,
/// upcoming, FT, postponed, replay, unmatched): the slots are
/// fixed and only their contents change (FL-360). No events
/// block — the design has none on the home card; the same tap
/// reaches the board, which carries the full info.
struct TVMUMatchCard: View {
    @EnvironmentObject private var store: PlaylistStore
    @Environment(\.tvTheme) private var theme
    @Environment(\.tvMUCardWidth) private var cardWidth
    let entry: TVFixtureEntry
    let focused: Bool

    /// C1 gold family, the TVLiveBoardView rule.
    private var isGold: Bool {
        entry.competition == .championsLeague || entry.competition == .womensChampionsLeague
    }

    var body: some View {
        let _ = store.crestsRevision
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            centreRow
            namesRow
            Spacer(minLength: 0)
            Rectangle()
                .fill(theme.tileBorder)
                .frame(height: 1)
            footerRow
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: cardWidth, height: 276, alignment: .topLeading)
        .background(tvMUCardBackground(focused: focused, theme: theme))
    }

    // Header, FIXED 40: league caps left (gold family for C1),
    // the state stack right — its slot is the full 40 whether
    // it carries the live card's two lines or a one-line state,
    // so FT / upcoming cards align with live ones.
    private var headerRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(entry.competitionLabel)
                .font(.system(size: 15, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(isGold ? theme.c1Label : theme.leagueTx)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                headerState
            }
        }
        .frame(height: 40, alignment: .top)
    }

    @ViewBuilder
    private var headerState: some View {
        let now = Date()
        if entry.isLive {
            TVMULiveLine()
            // 1.7.2 (audit H25): the minute number is RED
            // in the design, not the gold accent.
            Text(entry.state?.minuteText ?? entry.badgeText ?? "")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(theme.minuteRed)
                .lineLimit(1)
        } else if entry.state?.status == .ft {
            Text("FT")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
        } else if entry.state?.status == .postponed || entry.state?.status == .cancelled {
            Text("HOÃN")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(.gray)
                .lineLimit(1)
        } else if let kickoff = entry.channel.kickoff, kickoff > now {
            Text(tvMUDayLabel(for: kickoff, now: now))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.amber)
                .lineLimit(1)
        } else if let kickoff = entry.channel.kickoff,
                  LeagueClassifier.bucket(of: entry.channel, now: now) == 3 {
            // Bucket 3 and not FT: a finished listing with no
            // matched state — a replay, never a live guess.
            Text("PHÁT LẠI")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
    }

    // Centre, FIXED 92: crest 92 | centre slot FIXED 150 |
    // crest 92. A non-fixture entry centres its channel logo
    // in the same slot instead.
    private var centreRow: some View {
        Group {
            if entry.teams != nil {
                HStack(alignment: .center, spacing: 0) {
                    TVCrestImage(url: entry.displayCrests?.0 ?? nil, size: 92)
                        .frame(width: 92)
                    Spacer(minLength: 0)
                    centreSlot
                    Spacer(minLength: 0)
                    TVCrestImage(url: entry.displayCrests?.1 ?? nil, size: 92)
                        .frame(width: 92)
                }
            } else {
                TVChannelLogo(channel: entry.channel, height: 84)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 92)
    }

    @ViewBuilder
    private var centreSlot: some View {
        if let state = entry.state, let h = state.scoreHome, let a = state.scoreAway {
            // One string, digits + colon together (the design's
            // colon is white, not the dash colour), scaled
            // inside the fixed slot if a rare 2-digit score
            // overflows it — the slot itself never moves.
            Text("\(h) : \(a)")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 150)
        } else if let kickoff = entry.channel.kickoff, kickoff > Date() {
            Text(TVKickoffFormat.time.string(from: kickoff))
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: 150)
        } else {
            Text("VS")
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .frame(width: 150)
        }
    }

    // Names, FIXED 60: each name centred under its crest (the
    // 150 centre spacer keeps the two columns over the centre
    // row's), or the cleaned title centred for a non-fixture.
    private var namesRow: some View {
        Group {
            if let teams = entry.teams {
                HStack(alignment: .center, spacing: 0) {
                    // 1.7.2 (audit H29): team names 22 → 24 pt.
                    Text(teams.0)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    Color.clear.frame(width: 150, height: 1)
                    Text(teams.1)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            } else {
                Text(entry.cleanTitle)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 60)
    }

    // Footer, FIXED 24 (+8 top padding): the representative
    // channel's group (the classic meta line's datum; the
    // cleaned title when the group is empty) and the
    // device-local kickoff — shown for live entries too, as
    // the design draws it.
    private var footerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(entry.channel.group.isEmpty ? entry.cleanTitle : entry.channel.group)
                .font(.system(size: 19))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let kickoff = entry.channel.kickoff {
                Text("KO " + TVKickoffFormat.time.string(from: kickoff))
                    .font(.system(size: 19))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
        }
        .frame(height: 24)
        .padding(.top, 8)
    }
}

// MARK: MU rail header + fixture rail

/// The MU rail header (1.7.1, table H4): title 40 bold
/// (1.7.2, audit H15 — the design's rail titles measure
/// ≈40 pt; the fixed 50 slot still holds the line), the
/// rail's real count as a "%02d" chip in the accent family,
/// and an optional right-aligned note (the SẮP ĐÁ rail's
/// device date — W-B passes it). FIXED height 44.
struct TVMURailHeader: View {
    @Environment(\.tvTheme) private var theme
    let title: String
    let count: Int
    var note: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(title)
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(String(format: "%02d", count))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.accent)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(theme.accent.opacity(0.6), lineWidth: 1.5))
            Spacer(minLength: 0)
            if let note {
                Text(note)
                    .font(.system(size: 17))
                    .foregroundStyle(theme.leagueTx)
                    .lineLimit(1)
            }
        }
        .frame(height: 44)
    }
}

/// One horizontal rail of MU fixture cards (1.7.1): the MU
/// header over a LazyHStack of TVMUMatchCards at the design's
/// 22 pt gap. The card slot is 284 FIXED (276 + 2×4 insets)
/// for every state — one card shape, no live-dependent slot.
/// Focus lives here, at the leaf, exactly as TVFixtureRail's
/// (KH-2): own @FocusState, keys reported upward, signposted.
struct TVMUFixtureRail: View {
    let title: String
    let entries: [TVFixtureEntry]
    var note: String? = nil
    let keyFor: (TVFixtureEntry) -> String
    let onSelect: (TVFixtureEntry) -> Void
    let onFocusKey: (String) -> Void
    @FocusState private var focus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TVMURailHeader(title: title, count: entries.count, note: note)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 22) {
                    ForEach(entries) { entry in
                        Button {
                            onSelect(entry)
                        } label: {
                            TVMUMatchCard(entry: entry,
                                          focused: focus == keyFor(entry))
                        }
                        .tvCardButton()
                        .focused($focus, equals: keyFor(entry))
                        .frame(height: 284, alignment: .top)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 0)
            }
        }
        .onChange(of: focus) { _, key in
            guard let key else { return }
            FocusSignpost.begin()
            onFocusKey(key)
            Task { @MainActor in FocusSignpost.end() }
        }
    }
}

// MARK: MU Nuvio event card + rail

/// One addon event in the MU layout (1.7.1, table H8): the
/// design card's frame and slots, fed by the NuvioItem — the
/// classic NuvioEventCard's data fallbacks in the MU interior.
/// The addon carries NO score a card may show, so the centre
/// slot is the kickoff clock (or "VS"); a live event carries
/// the LIVE line + the meta's own releaseInfo in the header's
/// right stack. A team-less item draws its poster art in the
/// centre slot (the soccer placeholder while it loads, and
/// when the meta carries no poster at all).
struct TVMUNuvioEventCard: View {
    @Environment(\.tvTheme) private var theme
    @Environment(\.tvMUCardWidth) private var cardWidth
    let item: NuvioItem
    let focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            centreRow
            namesRow
            Spacer(minLength: 0)
            Rectangle()
                .fill(theme.tileBorder)
                .frame(height: 1)
            footerRow
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: cardWidth, height: 276, alignment: .topLeading)
        .background(tvMUCardBackground(focused: focused, theme: theme))
    }

    // Header, FIXED 40: the meta's league caps (the addon's
    // own fallback word when it carries none), the state
    // stack right — live line + releaseInfo for a live event,
    // the upcoming day label for one to come.
    private var headerRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Text((item.league ?? "NUVIO").uppercased())
                .font(.system(size: 15, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(theme.leagueTx)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                if item.kind == .liveEvent {
                    TVMULiveLine()
                    Text(item.releaseInfo)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(theme.accent)
                        .lineLimit(1)
                } else if item.kind == .upcomingEvent, let kickoff = item.kickoff {
                    Text(tvMUDayLabel(for: kickoff))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.amber)
                        .lineLimit(1)
                } else if item.kind == .upcomingEvent, !item.releaseInfo.isEmpty {
                    // No parsed kickoff: the meta's own clock
                    // text, the classic card's fallback datum.
                    Text(item.releaseInfo)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.amber)
                        .lineLimit(1)
                }
            }
        }
        .frame(height: 40, alignment: .top)
    }

    // Centre, FIXED 92: crest pair + kickoff slot for a
    // fixture meta; the poster's own art, centred, otherwise.
    private var centreRow: some View {
        Group {
            if item.teams != nil {
                HStack(alignment: .center, spacing: 0) {
                    TVCrestImage(url: item.team1Logo.flatMap(URL.init(string:)), size: 92)
                        .frame(width: 92)
                    Spacer(minLength: 0)
                    centreSlot
                    Spacer(minLength: 0)
                    TVCrestImage(url: item.team2Logo.flatMap(URL.init(string:)), size: 92)
                        .frame(width: 92)
                }
            } else if !item.poster.isEmpty, let url = URL(string: item.poster) {
                TVCachedImage(url: url, placeholderSize: 46)
                    .frame(maxWidth: .infinity)
                    .frame(height: 92)
            } else {
                TVSoccerPlaceholder(size: 46)
                    .frame(maxWidth: .infinity)
                    .frame(height: 92)
            }
        }
        .frame(height: 92)
    }

    @ViewBuilder
    private var centreSlot: some View {
        if let kickoff = item.kickoff {
            Text(TVKickoffFormat.time.string(from: kickoff))
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: 150)
        } else {
            Text("VS")
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .frame(width: 150)
        }
    }

    // Names, FIXED 60: the two sides under their crests, or
    // the item's display name centred for a team-less meta.
    private var namesRow: some View {
        Group {
            if let teams = item.teams {
                HStack(alignment: .center, spacing: 0) {
                    // 1.7.2 (audit H29 twin): this card renders
                    // the same design card as TVMUMatchCard —
                    // its team names take the same 24 pt.
                    Text(teams.0)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    Color.clear.frame(width: 150, height: 1)
                    Text(teams.1)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            } else {
                Text(item.displayName)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 60)
    }

    // Footer, FIXED 24 (+8 top padding): a fixture meta
    // repeats its display name on the left (the design's
    // channel-line slot; a team-less meta leaves it empty —
    // its name already fills the names row), the kickoff on
    // the right when the meta carries one.
    private var footerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(item.teams != nil ? item.displayName : "")
                .font(.system(size: 19))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let kickoff = item.kickoff {
                Text("KO " + TVKickoffFormat.time.string(from: kickoff))
                    .font(.system(size: 19))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
        }
        .frame(height: 24)
        .padding(.top, 8)
    }
}

/// One horizontal rail of MU Nuvio EVENT cards (1.7.1):
/// TVNuvioEventRail's signature and focus pattern, the MU
/// header and cards, the design's 22 pt gap, slot 284 FIXED.
struct TVMUNuvioEventRail: View {
    let title: String
    let items: [NuvioItem]
    let onSelect: (NuvioItem) -> Void
    let onFocusKey: (String) -> Void
    @FocusState private var focus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TVMURailHeader(title: title, count: items.count)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 22) {
                    ForEach(items) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            TVMUNuvioEventCard(item: item,
                                               focused: focus == "nv:" + item.id)
                        }
                        .tvCardButton()
                        .focused($focus, equals: "nv:" + item.id)
                        .frame(height: 284, alignment: .top)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 0)
            }
        }
        .onChange(of: focus) { _, key in
            guard let key else { return }
            FocusSignpost.begin()
            onFocusKey(key)
            Task { @MainActor in FocusSignpost.end() }
        }
    }
}

// MARK: MU channel cards + rails

/// The shared face of the two MU channel cards (1.7.1, table
/// H8): a 24/7 channel has no fixture geometry, so the design
/// card's centre slot carries the channel's logo art (the tv
/// glyph when it has none), the name sits in the names slot,
/// and the footer's left is the card's detail line. Same
/// fixed slots as the fixture card — the height arithmetic in
/// the section header above holds verbatim.
private struct TVMUChannelCardFace: View {
    @Environment(\.tvTheme) private var theme
    @Environment(\.tvMUCardWidth) private var cardWidth
    let headerLabel: String
    let name: String
    let detail: String
    /// The channel whose logo art fills the centre slot; nil
    /// draws the tv glyph (the classic cards' fallback).
    let logoChannel: Channel?
    let focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text(headerLabel)
                    .font(.system(size: 15, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(theme.leagueTx)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("24/7")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(theme.accent)
                    .lineLimit(1)
            }
            .frame(height: 40)
            Group {
                if let logoChannel {
                    TVChannelLogo(channel: logoChannel, height: 84)
                        .frame(maxWidth: .infinity)
                } else {
                    Image(systemName: "tv")
                        .font(.system(size: 64))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 92)
            Text(name)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .frame(height: 60)
            Spacer(minLength: 0)
            Rectangle()
                .fill(theme.tileBorder)
                .frame(height: 1)
            HStack(alignment: .center, spacing: 12) {
                Text(detail)
                    .font(.system(size: 19))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: 24)
            .padding(.top, 8)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: cardWidth, height: 276, alignment: .topLeading)
        .background(tvMUCardBackground(focused: focused, theme: theme))
    }
}

/// One addon 24/7 channel in the MU layout (1.7.1): the
/// classic NuvioChannelCard's data (poster-as-logo via the
/// display channel, the league-extended detail line) in the
/// shared MU channel face.
struct TVMUNuvioChannelCard: View {
    let item: NuvioItem
    let focused: Bool
    var detailPrefix: String = "Kênh tiếng Anh"

    var body: some View {
        TVMUChannelCardFace(
            headerLabel: "KÊNH 24/7",
            name: item.displayName,
            detail: item.league.map { "\(detailPrefix) · \($0)" }
                ?? "\(detailPrefix) · phát liên tục",
            logoChannel: item.poster.isEmpty ? nil : item.displayChannel,
            focused: focused)
    }
}

/// One old-block English channel in the MU layout (1.7.1):
/// the classic TVENChannelCard's label and detail line in
/// the shared MU channel face.
struct TVMUENChannelCard: View {
    let channel: Channel
    let focused: Bool

    var body: some View {
        TVMUChannelCardFace(
            headerLabel: "24/7 · BLV ANH",
            name: TVEnglish.displayName(channel),
            detail: "Kênh tiếng Anh · phát liên tục",
            logoChannel: channel.logoURL == nil ? nil : channel,
            focused: focused)
    }
}

/// One horizontal rail of MU Nuvio CHANNEL cards (1.7.1):
/// TVNuvioChannelRail's signature — optional subtitle and
/// detailPrefix included — with the MU header and cards.
struct TVMUNuvioChannelRail: View {
    let title: String
    var subtitle: String? = nil
    let items: [NuvioItem]
    var detailPrefix: String? = nil
    let onSelect: (NuvioItem) -> Void
    let onFocusKey: (String) -> Void
    @FocusState private var focus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TVMURailHeader(title: title, count: items.count)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.6))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 22) {
                    ForEach(items) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            if let detailPrefix {
                                TVMUNuvioChannelCard(item: item,
                                                     focused: focus == "nv:" + item.id,
                                                     detailPrefix: detailPrefix)
                            } else {
                                TVMUNuvioChannelCard(item: item,
                                                     focused: focus == "nv:" + item.id)
                            }
                        }
                        .tvCardButton()
                        .focused($focus, equals: "nv:" + item.id)
                        .frame(height: 284, alignment: .top)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 0)
            }
        }
        .onChange(of: focus) { _, key in
            guard let key else { return }
            FocusSignpost.begin()
            onFocusKey(key)
            Task { @MainActor in FocusSignpost.end() }
        }
    }
}

/// The old mirror EN block's rail in the MU layout (1.7.1):
/// TVENChannelRail's title and subtitle verbatim, the MU
/// header and cards, the same focus pattern.
struct TVMUENChannelRail: View {
    let channels: [Channel]
    let onSelect: (Channel) -> Void
    let onFocusKey: (String) -> Void
    @FocusState private var focus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TVMURailHeader(title: "🌍  EN · BLV Anh — KÊNH BLV TIẾNG ANH",
                           count: channels.count)
            Text("Kênh 24/7 bình luận tiếng Anh — nguồn dự phòng khi nguồn Việt chậm hoặc chết.")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.6))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 22) {
                    ForEach(channels) { ch in
                        Button {
                            onSelect(ch)
                        } label: {
                            TVMUENChannelCard(channel: ch,
                                              focused: focus == "en:" + ch.url)
                        }
                        .tvCardButton()
                        .focused($focus, equals: "en:" + ch.url)
                        .frame(height: 284, alignment: .top)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 0)
            }
        }
        .onChange(of: focus) { _, key in
            guard let key else { return }
            FocusSignpost.begin()
            onFocusKey(key)
            Task { @MainActor in FocusSignpost.end() }
        }
    }
}

// MARK: MU wallpaper layer

/// The MU wallpaper as a reusable layer (1.7.1): ONE photo,
/// decoded DOWNSAMPLED (the TVWallpaperView pattern — some
/// wallpapers are 8002 px wide and must never decode at full
/// size), scaled to fill, under a flat black scrim of the
/// caller's strength. The caller frames it — no
/// ignoresSafeArea in here. Loads in .task(id:) — no work on
/// any focus path (FL-128).
struct TVMUWallpaperLayer: View {
    let url: URL
    let dim: Double
    /// 1.7.6 (FL-438): settled + fading-in photos — a swap
    /// crossfades, exactly as TVWallpaperView's pair (the
    /// two views are the app's only wallpaper swap paths).
    @State private var image: UIImage?
    @State private var fadingImage: UIImage?
    @State private var fadeIn = false

    var body: some View {
        ZStack {
            Color.black.opacity(dim)
        }
        // 1.7.4 (S4): the layer is BOUNDED — the same frame
        // TVWallpaperView carries. Before, the ZStack sized
        // itself to the decoded photo, so any surface laying
        // out against it (the theme picker's foreground
        // column above all) negotiated a wallpaper-dependent
        // size and visibly shifted when the wallpaper changed
        // (picker-shift, convicted in the 1.7.2 full-set
        // audit). Callers that ignore the safe area still
        // get the full bleed; the layer itself now always
        // reports the same, parent-given size.
        // 1.7.6 (FL-439): the S4 frame alone did NOT close
        // the fault on the board — a max-frame yields to the
        // parent proposal, and inside a negotiating ZStack
        // the photo's ideal size still inflated the stack
        // (WALLPAPER-AUDIT-20261122 §4: steady per image,
        // severity ordered by aspect). The photo therefore
        // also moves OUT of this view's own stack: it is the
        // dim stack's BACKGROUND, sized BY this layer's
        // frame — a bitmap of any aspect fills the frame
        // and negotiates nothing, here or at any call site.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            // fade state from its first line — a superseded
            // task's in-flight fade is cleared HERE, so no
            // early exit (failed load, same-instance cache
            // hit, cancellation) can strand a stale photo
            // over the settled one. Same fix as
            // TVWallpaperView's task.
            fadingImage = nil
            fadeIn = false
            let loaded = await TVImageCache.loadDownsampled(url, maxPixel: 1920)
            guard !Task.isCancelled, let loaded else { return }
            guard let settled = image else {
                image = loaded
                return
            }
            if loaded === settled { return }
            fadingImage = loaded
            fadeIn = false
            withAnimation(.easeInOut(duration: 0.5)) { fadeIn = true }
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled, fadingImage === loaded else { return }
            image = loaded
            fadingImage = nil
            fadeIn = false
        }
    }
}

// MARK: - United design theme (1.7.4 — the designer's united set)
//
// Everything below renders ONLY under the "Manchester United"
// design theme (theme.id == .unitedDesign). The MU Wally family
// above is untouched. The design's rules that differ from the
// shipped MU look, per the designer's drawings + answers:
// - the app header is crest + the brand wordmark + the
//   letterspaced MANCHESTER UNITED tagline (the mock's centre
//   sample-data line and its "Cài đặt" link are mock furniture,
//   not app UI); the wordmark TEXT is the owner's brand
//   "Joe Soccer" since 1.7.6 (FL-441) — the drawing's lockup
//   geometry and dress stand, only its text was superseded;
// - tabs are plain text: selected = gold outline + red
//   underline, NO red dot;
// - rail counts are plain numbers in an outlined chip;
// - a missing crest falls back to the team's INITIALS on a
//   tile — never a sport glyph (answer Q1);
// - live cards carry ONE red line "TRỰC TIẾP · 67'"; upcoming
//   cards centre "VS" and put the kickoff clock in the footer.

/// The design header (Home, Match Centre, source board):
/// crest + wordmark left, the app's clock + date right (the
/// mock's right slot is its settings link — the app's real
/// settings door is the Giao diện pill, unchanged), hairline
/// under. One construction for every design surface.
struct TVDesignHeader: View {
    @Environment(\.tvTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                TVCrestImage(url: Crests.url(forTeam: "Manchester United"), size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    // 1.7.6 (FL-441, RECALC-DABANH RULING 1 —
                    // Form A): the wordmark text is the
                    // owner's brand "Joe Soccer"; the face is
                    // the theme's UI face at Bold 34 (Manrope
                    // — the recorded Outfit→Manrope
                    // substitution), "Joe" in the theme Text,
                    // " Soccer" in the design gold. Geometry
                    // and tagline are the drawing's, unchanged.
                    (Text("Joe").foregroundStyle(.white)
                        + Text(" Soccer").foregroundStyle(theme.accent))
                        .font(TVDesignFont.ui(34, .bold))
                    Text("MANCHESTER UNITED")
                        .font(TVDesignFont.ui(12, .semibold))
                        .tracking(3)
                        .foregroundStyle(theme.accent.opacity(0.8))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(TVKickoffFormat.time.string(from: Date()))
                        .font(TVDesignFont.ui(30))
                        .foregroundStyle(theme.dashTx)
                    Text(TVKickoffFormat.muHeaderDateFormatter.string(from: Date()).uppercased())
                        .font(TVDesignFont.ui(13))
                        .foregroundStyle(theme.leagueTx)
                }
            }
            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(height: 1)
                .padding(.top, 2)
        }
    }
}

/// A team's initials, the design's crest fallback (Q1): the
/// first letters of the first up-to-three words, uppercased,
/// diacritics kept ("Phù Đổng Ninh Bình" → "PĐN", "Saigon
/// Heat" → "SH", "Manchester United" → "MU" — the mock's own
/// renderings). A one-word name gives its first two letters.
func tvTeamInitials(_ name: String) -> String {
    let words = name.split(separator: " ").map(String.init)
    guard let first = words.first else { return "?" }
    if words.count == 1 {
        return String(first.prefix(2)).uppercased()
    }
    return words.prefix(3).map { String($0.prefix(1)) }.joined().uppercased()
}

/// The initials tile: dark tile, gold-tinted border, gold
/// initials. One construction at the design's three sizes
/// (card 80 / board 92 / Match Centre 168).
struct TVTeamInitialsTile: View {
    @Environment(\.tvTheme) private var theme
    let name: String
    let size: CGFloat
    let fontSize: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.17)
                .fill(theme.tileBG)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.17)
                        .strokeBorder(theme.accent.opacity(0.45),
                                      lineWidth: 1.5))
            Text(tvTeamInitials(name))
                .font(TVDesignFont.ui(fontSize, .bold))
                .foregroundStyle(theme.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 6)
        }
        .frame(width: size, height: size)
    }
}

/// A crest slot under the design theme: the real crest when
/// one resolved, the initials tile when it did not — the
/// slot's size never changes (FL-360). 1.7.5
/// (RECALC-DABANH H9): on the Home card the drawn crest ART
/// is ≈92 while the initials TILE stays ≈80 — `artSize`
/// separates the two; call sites where the drawing puts
/// both at one size (board 92, centre 168) leave it nil.
struct TVDesignCrestSlot: View {
    let url: URL?
    let teamName: String
    let size: CGFloat
    let fontSize: CGFloat
    var artSize: CGFloat? = nil

    var body: some View {
        if let url {
            TVCrestImage(url: url, size: artSize ?? size)
        } else {
            TVTeamInitialsTile(name: teamName, size: size, fontSize: fontSize)
        }
    }
}

/// The design text tab (fresh Home drawing): plain 25 pt
/// text, no capsule, NO red dot. Selected = white semibold +
/// gold outline + red underline inside the face's bounds;
/// focused = maroon fill + gold outline. Fixed height 50 and
/// a bold-width reservation, exactly the TVMUTabFace
/// discipline (FL-360 / FL-001).
struct TVDesignTabFace: View {
    let title: String
    let selected: Bool
    let focused: Bool
    let theme: TVThemeTokens

    var body: some View {
        ZStack {
            Text(title)
                .font(TVDesignFont.ui(25, .bold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .opacity(0)
            Text(title)
                .font(TVDesignFont.ui(25, selected ? .semibold : .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(selected ? .white : theme.leagueTx)
        }
        .padding(.horizontal, 16)
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

/// The design rail header (fresh Home drawing): title 40
/// bold + the count as a PLAIN number in a thin outlined
/// chip (no zero-padding, no gold). Fixed height 44, the
/// family slot.
struct TVDesignRailHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(title)
                .font(TVDesignFont.ui(40, .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text("\(count)")
                .font(TVDesignFont.ui(15, .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.white.opacity(0.25),
                                      lineWidth: 1.5))
            Spacer(minLength: 0)
        }
        .frame(height: 44)
    }
}

/// The design's FIXED footer bar (1.7.5, RECALC-DABANH
/// H13/C14): a hairline over a hints line at the left
/// ("Điều hướng · OK Chọn · ← Quay lại") and the
/// change-background control at the right as TEXT + icon
/// with the zero-padded counter ("Đổi hình nền · 01 / 43",
/// P6) — the drawing's form, not the in-flow pill the
/// 1.7.4 build ended its scroll with. One construction
/// shared by the design Home (root, outside the scroll) and
/// the Match Centre (the centre's last row): the bar never
/// scrolls. The parents own the wallpaper data and pass
/// position/count in; the button reports the cycle back.
/// Focus is the family's gold outline on the button only;
/// the hints are never focusable.
struct TVDesignFooterBar: View {
    @Environment(\.tvTheme) private var theme
    let position: Int
    let count: Int
    var focus: FocusState<String?>.Binding
    let focusValue: String
    let onChangeBackground: () -> Void

    private var focused: Bool { focus.wrappedValue == focusValue }

    var body: some View {
        VStack(spacing: 2) {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
            HStack(alignment: .center, spacing: 16) {
                Text("Điều hướng · OK Chọn · ← Quay lại")
                    .font(TVDesignFont.ui(17))
                    .foregroundStyle(theme.leagueTx)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if count > 0 {
                    Button(action: onChangeBackground) {
                        HStack(spacing: 10) {
                            Image(systemName: "photo")
                                .font(.system(size: 17))
                            Text("Đổi hình nền · \(Self.pad(position)) / \(Self.pad(count))")
                                .font(TVDesignFont.ui(17, .semibold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .foregroundStyle(focused ? .white : theme.teamTx)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(focused ? theme.focusRing : .clear,
                                              lineWidth: 2))
                    }
                    .tvCardButton()
                    .focused(focus, equals: focusValue)
                }
            }
        }
    }

    private static func pad(_ n: Int) -> String {
        String(format: "%02d", n)
    }
}

/// One fixture in the design layout: the MU card family's
/// fixed slots (header 40 / centre 92 / names 60 / footer
/// 24 + 8, height 276 — FL-360) with the design drawing's
/// contents: one-line red live mark, "VS" centred for every
/// scoreless state, initials tiles for missing crests, and
/// the footer carrying the channel group + the match DATE
/// (live/finished) or the kickoff CLOCK (upcoming).
struct TVDesignMatchCard: View {
    @EnvironmentObject private var store: PlaylistStore
    @Environment(\.tvTheme) private var theme
    @Environment(\.tvMUCardWidth) private var cardWidth
    let entry: TVFixtureEntry
    let focused: Bool

    /// C1 gold family, the TVLiveBoardView rule.
    private var isGold: Bool {
        entry.competition == .championsLeague || entry.competition == .womensChampionsLeague
    }

    var body: some View {
        let _ = store.crestsRevision
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            centreRow
            namesRow
            Spacer(minLength: 0)
            Rectangle()
                .fill(theme.tileBorder)
                .frame(height: 1)
            footerRow
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: cardWidth, height: 276, alignment: .topLeading)
        .background(tvMUCardBackground(focused: focused, theme: theme))
    }

    // Header, FIXED 40: league caps left (gold family for
    // C1), the state line right — ONE red line for live, the
    // design's form; upcoming and replay draw nothing here.
    private var headerRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(entry.competitionLabel)
                .font(TVDesignFont.ui(15, .bold))
                .tracking(1.5)
                .foregroundStyle(isGold ? theme.c1Label : theme.leagueTx)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            headerState
        }
        .frame(height: 40, alignment: .top)
    }

    @ViewBuilder
    private var headerState: some View {
        if entry.isLive {
            Text(liveLine)
                .font(TVDesignFont.ui(15, .heavy))
                .foregroundStyle(theme.minuteRed)
                .lineLimit(1)
        } else if entry.state?.status == .ft {
            Text("FT")
                .font(TVDesignFont.ui(15, .heavy))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
        } else if entry.state?.status == .postponed || entry.state?.status == .cancelled {
            Text("HOÃN")
                .font(TVDesignFont.ui(15, .heavy))
                .foregroundStyle(.gray)
                .lineLimit(1)
        }
    }

    /// "TRỰC TIẾP · 67'" — the minute is the matched state's
    /// own clock when one is bound; a live fixture without a
    /// state shows the word alone (no invented minute, Q1).
    private var liveLine: String {
        if let minute = entry.state?.minuteText {
            return "TRỰC TIẾP · " + minute
        }
        return "TRỰC TIẾP"
    }

    // Centre, FIXED 92: crest-or-initials 92 | centre slot
    // FIXED 150 | crest-or-initials 92. A non-fixture entry
    // centres its channel logo in the same slot instead.
    private var centreRow: some View {
        Group {
            if let teams = entry.teams {
                HStack(alignment: .center, spacing: 0) {
                    // 1.7.5 (H9): real crest ART at the drawn
                    // ≈92; the initials tile stays ≈80.
                    TVDesignCrestSlot(url: entry.displayCrests?.0 ?? nil,
                                      teamName: teams.0, size: 80, fontSize: 28,
                                      artSize: 92)
                        .frame(width: 92)
                    Spacer(minLength: 0)
                    centreSlot
                    Spacer(minLength: 0)
                    TVDesignCrestSlot(url: entry.displayCrests?.1 ?? nil,
                                      teamName: teams.1, size: 80, fontSize: 28,
                                      artSize: 92)
                        .frame(width: 92)
                }
            } else {
                TVChannelLogo(channel: entry.channel, height: 84)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 92)
    }

    @ViewBuilder
    private var centreSlot: some View {
        if let state = entry.state, let h = state.scoreHome, let a = state.scoreAway {
            Text("\(h) : \(a)")
                .font(TVDesignFont.display(44))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 150)
        } else {
            // The design's upcoming face: "VS" — the kickoff
            // clock lives in the footer, not the centre.
            Text("VS")
                .font(TVDesignFont.display(40))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: 150)
        }
    }

    // Names, FIXED 60: each name centred under its crest, or
    // the cleaned title centred for a non-fixture.
    private var namesRow: some View {
        Group {
            if let teams = entry.teams {
                HStack(alignment: .center, spacing: 0) {
                    Text(teams.0)
                        .font(TVDesignFont.ui(24, .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    Color.clear.frame(width: 150, height: 1)
                    Text(teams.1)
                        .font(TVDesignFont.ui(24, .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            } else {
                Text(entry.cleanTitle)
                    .font(TVDesignFont.ui(22, .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 60)
    }

    // Footer, FIXED 24 (+8 top padding): the representative
    // channel's group left; right = the kickoff CLOCK for a
    // fixture still to come, the match DATE otherwise (the
    // drawing's two rail forms).
    private var footerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(entry.channel.group.isEmpty ? entry.cleanTitle : entry.channel.group)
                .font(TVDesignFont.ui(19))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let kickoff = entry.channel.kickoff {
                Text(kickoff > Date()
                     ? TVKickoffFormat.time.string(from: kickoff)
                     : TVKickoffFormat.fullDate.string(from: kickoff))
                    .font(TVDesignFont.ui(19))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
        }
        .frame(height: 24)
        .padding(.top, 8)
    }
}

/// One horizontal rail of design fixture cards: the MU
/// fixture rail's shell (own @FocusState, keys reported
/// upward, slot 284 FIXED) with the design header + cards.
struct TVDesignFixtureRail: View {
    let title: String
    let entries: [TVFixtureEntry]
    let keyFor: (TVFixtureEntry) -> String
    let onSelect: (TVFixtureEntry) -> Void
    let onFocusKey: (String) -> Void
    @FocusState private var focus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TVDesignRailHeader(title: title, count: entries.count)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 22) {
                    ForEach(entries) { entry in
                        Button {
                            onSelect(entry)
                        } label: {
                            TVDesignMatchCard(entry: entry,
                                              focused: focus == keyFor(entry))
                        }
                        .tvCardButton()
                        .focused($focus, equals: keyFor(entry))
                        .frame(height: 284, alignment: .top)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 0)
            }
        }
        .onChange(of: focus) { _, key in
            guard let key else { return }
            FocusSignpost.begin()
            onFocusKey(key)
            Task { @MainActor in FocusSignpost.end() }
        }
    }
}

// MARK: - Design Nuvio / EN rails (1.7.4, Round 1 review B-1)

/// One horizontal rail of DESIGN Nuvio EVENT cards: the MU
/// rail's shell verbatim (own @FocusState, keys reported
/// upward, slot 284 FIXED) with the DESIGN header. No design
/// drawing exists for Nuvio cards, so the card stays the
/// family TVMUNuvioEventCard — it repaints from the design
/// tokens through the environment; only the header, the one
/// element every design rail shares, follows the design
/// theme. (Round 1 review B-1: these rails previously fell
/// through the family isMU branch and rendered the MU
/// Wally header under the design theme.)
struct TVDesignNuvioEventRail: View {
    let title: String
    let items: [NuvioItem]
    let onSelect: (NuvioItem) -> Void
    let onFocusKey: (String) -> Void
    @FocusState private var focus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TVDesignRailHeader(title: title, count: items.count)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 22) {
                    ForEach(items) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            TVMUNuvioEventCard(item: item,
                                               focused: focus == "nv:" + item.id)
                        }
                        .tvCardButton()
                        .focused($focus, equals: "nv:" + item.id)
                        .frame(height: 284, alignment: .top)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 0)
            }
        }
        .onChange(of: focus) { _, key in
            guard let key else { return }
            FocusSignpost.begin()
            onFocusKey(key)
            Task { @MainActor in FocusSignpost.end() }
        }
    }
}

/// One horizontal rail of DESIGN Nuvio CHANNEL cards:
/// TVMUNuvioChannelRail's signature and shell (subtitle and
/// detailPrefix included — data copy, not header styling)
/// with the design header; the cards stay the family
/// TVMUNuvioChannelCard (B-1, as above).
struct TVDesignNuvioChannelRail: View {
    let title: String
    var subtitle: String? = nil
    let items: [NuvioItem]
    var detailPrefix: String? = nil
    let onSelect: (NuvioItem) -> Void
    let onFocusKey: (String) -> Void
    @FocusState private var focus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TVDesignRailHeader(title: title, count: items.count)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.6))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 22) {
                    ForEach(items) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            if let detailPrefix {
                                TVMUNuvioChannelCard(item: item,
                                                     focused: focus == "nv:" + item.id,
                                                     detailPrefix: detailPrefix)
                            } else {
                                TVMUNuvioChannelCard(item: item,
                                                     focused: focus == "nv:" + item.id)
                            }
                        }
                        .tvCardButton()
                        .focused($focus, equals: "nv:" + item.id)
                        .frame(height: 284, alignment: .top)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 0)
            }
        }
        .onChange(of: focus) { _, key in
            guard let key else { return }
            FocusSignpost.begin()
            onFocusKey(key)
            Task { @MainActor in FocusSignpost.end() }
        }
    }
}

/// The old mirror EN block's rail in the DESIGN layout:
/// TVMUENChannelRail's title and subtitle verbatim (data
/// copy), the design header, the family TVMUENChannelCard,
/// the same focus pattern (B-1, as above).
struct TVDesignENChannelRail: View {
    let channels: [Channel]
    let onSelect: (Channel) -> Void
    let onFocusKey: (String) -> Void
    @FocusState private var focus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TVDesignRailHeader(title: "🌍  EN · BLV Anh — KÊNH BLV TIẾNG ANH",
                               count: channels.count)
            Text("Kênh 24/7 bình luận tiếng Anh — nguồn dự phòng khi nguồn Việt chậm hoặc chết.")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.6))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 22) {
                    ForEach(channels) { ch in
                        Button {
                            onSelect(ch)
                        } label: {
                            TVMUENChannelCard(channel: ch,
                                              focused: focus == "en:" + ch.url)
                        }
                        .tvCardButton()
                        .focused($focus, equals: "en:" + ch.url)
                        .frame(height: 284, alignment: .top)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 0)
            }
        }
        .onChange(of: focus) { _, key in
            guard let key else { return }
            FocusSignpost.begin()
            onFocusKey(key)
            Task { @MainActor in FocusSignpost.end() }
        }
    }
}
