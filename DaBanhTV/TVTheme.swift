import Foundation
import SwiftUI

/// Selectable app themes (1.7.0). The classic theme is the
/// app's established look; the Manchester United theme is an
/// added skin only — no behaviour changes with the theme.
/// See work-170/SCOPE-170.md and work-170/IMPL-SPEC.md.
enum TVThemeID: String, CaseIterable {
    case classic
    case manchesterUnited

    var isMU: Bool { self == .manchesterUnited }
}

/// A `#RRGGBB` colour, so the MU tokens below read exactly as
/// the approved design states them.
private func tvHex(_ hex: UInt32) -> Color {
    Color(
        red: Double((hex >> 16) & 0xFF) / 255.0,
        green: Double((hex >> 8) & 0xFF) / 255.0,
        blue: Double(hex & 0xFF) / 255.0)
}

/// The full token set one theme paints with. Every themed face
/// reads its colours from here instead of naming TVPalette
/// constants directly, so a theme is a pure token swap.
struct TVThemeTokens: Sendable {
    let id: TVThemeID
    let bgTop: Color, bgMid: Color, bgBottom: Color   // home gradient
    let boardBG: Color, tileBG: Color, tileBorder: Color
    let tileFocusedBG: Color        // classic #14263F / MU maroon #4A1A1A
    let focusRing: Color            // classic cyan / MU gold #C9A86A
    let accent: Color               // classic boardSky #38BDF8 / MU gold
    let leagueTx: Color             // classic #7E93B5 / MU #9AA0A8
    let minuteRed: Color            // classic #C22626 / MU #DA291C
    let htAmber: Color, liveDot: Color, teamTx: Color, dashTx: Color
    let eventsLine: Color, evTx: Color, evMin: Color
    let cardY: Color, cardR: Color
    let c1TileBG: Color, c1Border: Color, c1Gold: Color,
        c1Head: Color, c1Label: Color
    let selectedFill: Color         // classic tealFill / MU: see pill spec
    let liveRed: Color, amber: Color, heroMeta: Color
    let unitedRed: Color            // MU #DA291C / classic = liveRed
    let cream: Color                // MU #F2E6C8 / classic = c1Head

    /// The classic theme, built FROM the TVPalette constants so
    /// its values cannot drift from the pre-theme app: every
    /// token below IS the constant the classic faces used to
    /// name directly. bgTop / bgBottom have no TVPalette
    /// constant — they are the home gradient's end colours,
    /// copied verbatim from TVContentView.background (bgMid is
    /// TVPalette.boardBG, as in that gradient).
    static let classic = TVThemeTokens(
        id: .classic,
        bgTop: Color(red: 0.055, green: 0.09, blue: 0.17),
        bgMid: TVPalette.boardBG,
        bgBottom: Color(red: 0.02, green: 0.035, blue: 0.07),
        boardBG: TVPalette.boardBG,
        tileBG: TVPalette.tileBG,
        tileBorder: TVPalette.tileBorder,
        tileFocusedBG: TVPalette.tileFocusedBG,
        focusRing: TVPalette.cyan,
        accent: TVPalette.boardSky,
        leagueTx: TVPalette.leagueTx,
        minuteRed: TVPalette.minuteRed,
        htAmber: TVPalette.htAmber,
        liveDot: TVPalette.liveDot,
        teamTx: TVPalette.teamTx,
        dashTx: TVPalette.dashTx,
        eventsLine: TVPalette.eventsLine,
        evTx: TVPalette.evTx,
        evMin: TVPalette.evMin,
        cardY: TVPalette.cardY,
        cardR: TVPalette.cardR,
        c1TileBG: TVPalette.c1TileBG,
        c1Border: TVPalette.c1Border,
        c1Gold: TVPalette.c1Gold,
        c1Head: TVPalette.c1Head,
        c1Label: TVPalette.c1Label,
        selectedFill: TVPalette.tealFill,
        liveRed: TVPalette.liveRed,
        amber: TVPalette.amber,
        heroMeta: TVPalette.heroMeta,
        unitedRed: TVPalette.liveRed,
        cream: TVPalette.c1Head)

    /// The Manchester United theme (approved "united-tv"
    /// design): near-black boards, charcoal tiles, maroon
    /// focus fill, gold ring/accent, United red, cream text.
    static let manchesterUnited = TVThemeTokens(
        id: .manchesterUnited,
        bgTop: tvHex(0x0B0E13),
        bgMid: tvHex(0x0B0E13),
        bgBottom: .black,
        boardBG: tvHex(0x0B0E13),
        tileBG: tvHex(0x171B22),
        tileBorder: .white.opacity(0.14),
        tileFocusedBG: tvHex(0x4A1A1A),
        focusRing: tvHex(0xC9A86A),
        accent: tvHex(0xC9A86A),
        leagueTx: tvHex(0x9AA0A8),
        minuteRed: tvHex(0xDA291C),
        htAmber: TVPalette.htAmber,
        liveDot: tvHex(0xDA291C),
        teamTx: TVPalette.teamTx,
        dashTx: tvHex(0x9AA0A8),
        eventsLine: .white.opacity(0.12),
        evTx: .white.opacity(0.75),
        evMin: tvHex(0xF2E6C8),
        cardY: TVPalette.cardY,
        cardR: TVPalette.cardR,
        c1TileBG: tvHex(0x171B22),
        c1Border: .white.opacity(0.14),
        c1Gold: tvHex(0xC9A86A),
        c1Head: tvHex(0xF2E6C8),
        c1Label: tvHex(0xC9A86A),
        selectedFill: .white.opacity(0.10),
        liveRed: tvHex(0xDA291C),
        amber: tvHex(0xFFC759),
        heroMeta: tvHex(0xF2E6C8),
        unitedRed: tvHex(0xDA291C),
        cream: tvHex(0xF2E6C8))

    static func tokens(for id: TVThemeID) -> TVThemeTokens {
        switch id {
        case .classic: return .classic
        case .manchesterUnited: return .manchesterUnited
        }
    }
}

extension TVThemeTokens {
    var isMU: Bool { id.isMU }
}

// MARK: - Environment

private struct TVThemeKey: EnvironmentKey {
    static let defaultValue: TVThemeTokens = .classic
}

extension EnvironmentValues {
    var tvTheme: TVThemeTokens {
        get { self[TVThemeKey.self] }
        set { self[TVThemeKey.self] = newValue }
    }
}

// MARK: - Store

/// The theme selection + MU background position, persisted in
/// UserDefaults and nowhere else. Unknown stored values fall
/// back to the classic theme / the first background.
@MainActor
final class TVThemeStore: ObservableObject {
    @Published private(set) var themeID: TVThemeID
    @Published private(set) var bgIndex: Int

    var tokens: TVThemeTokens { .tokens(for: themeID) }

    init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "dabanh-theme"),
           let stored = TVThemeID(rawValue: raw) {
            themeID = stored
        } else {
            themeID = .classic
        }
        bgIndex = max(0, defaults.integer(forKey: "dabanh-mu-bg-index"))
    }

    func select(_ id: TVThemeID) {
        themeID = id
        UserDefaults.standard.set(id.rawValue, forKey: "dabanh-theme")
        DiagLog.write("theme", "selected \(id.rawValue)")
    }

    /// Advance to the next MU background, wrapping at `count`;
    /// a count of 0 still persists index 0 (never divides by 0).
    func cycleBackground(count: Int) {
        bgIndex = (bgIndex + 1) % max(count, 1)
        UserDefaults.standard.set(bgIndex, forKey: "dabanh-mu-bg-index")
        DiagLog.write("theme", "background cycled to \(bgIndex + 1)/\(max(count, 1))")
    }
}

// MARK: - Picker

/// The full-screen theme picker behind the header's "Giao
/// diện" pill. Chrome is painted in the CURRENT theme's
/// tokens; selecting a card applies it at once and dismisses.
struct TVThemePickerView: View {
    @EnvironmentObject private var themeStore: TVThemeStore
    @Environment(\.tvTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedTheme: TVThemeID?

    var body: some View {
        ZStack {
            theme.boardBG.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 36) {
                Text("Giao diện")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                optionCard(
                    id: .classic,
                    title: "Mặc định",
                    subtitle: "Giao diện gốc của Đá Banh TV")
                optionCard(
                    id: .manchesterUnited,
                    title: "Manchester United",
                    subtitle: "The Theatre of Dreams · đỏ / đen / vàng")
                Spacer()
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 44)
        }
        .defaultFocus($focusedTheme, themeStore.themeID)
        .onExitCommand { dismiss() }
    }

    private func optionCard(id: TVThemeID, title: String,
                            subtitle: String) -> some View {
        let selected = themeStore.themeID == id
        let focused = focusedTheme == id
        return Button {
            themeStore.select(id)
            dismiss()
        } label: {
            HStack(alignment: .center, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 22))
                        .foregroundStyle(theme.leagueTx)
                    if id.isMU {
                        swatchRow
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(theme.focusRing)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: 1100, alignment: .leading)
            .background(TVPillFace(focused: focused,
                                   selected: selected,
                                   theme: theme))
        }
        .tvCardButton()
        .focused($focusedTheme, equals: id)
    }

    /// The MU card's preview: maroon / gold / red / cream
    /// swatches in the MU theme's own tokens.
    private var swatchRow: some View {
        let mu = TVThemeTokens.manchesterUnited
        return HStack(spacing: 12) {
            ForEach(Array([mu.tileFocusedBG, mu.focusRing,
                           mu.unitedRed, mu.cream].enumerated()),
                    id: \.offset) { _, colour in
                RoundedRectangle(cornerRadius: 8)
                    .fill(colour)
                    .frame(width: 54, height: 30)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(mu.tileBorder, lineWidth: 1.5))
            }
        }
        .padding(.top, 4)
    }
}
