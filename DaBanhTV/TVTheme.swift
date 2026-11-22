import Foundation
import SwiftUI

/// Selectable app themes (1.7.0). The classic theme is the
/// app's established look; the Manchester United theme is an
/// added skin only — no behaviour changes with the theme.
/// See work-170/SCOPE-170.md and work-170/IMPL-SPEC.md.
///
/// 1.7.4 (owner ruling 2026-11-22 02:01 CST): the MU side
/// splits in TWO. The shipped 1.7.2 MU look is preserved
/// verbatim as its own theme, "MU Wally" — and it keeps the
/// stored raw value "manchesterUnited", so the owner's
/// current selection migrates to the MU Wally arm by
/// construction (the stored string parses straight to it;
/// nothing is rewritten). The design-exact theme from the
/// designer's united set is the third theme, "Manchester
/// United", under its own stable id. `isMU` is the FAMILY
/// predicate (either MU theme): wallpaper plumbing, the
/// background rows, hero suppression and the family faces
/// key on it; a face that belongs to ONE arm compares the
/// id directly.
enum TVThemeID: String, CaseIterable {
    case classic
    case muWally = "manchesterUnited"
    case unitedDesign = "manchesterUnitedDesign"

    /// The MU family: MU Wally or the design theme.
    var isMU: Bool { self == .muWally || self == .unitedDesign }
    var isDesign: Bool { self == .unitedDesign }
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

    /// "MU Wally" (1.7.4): the shipped 1.7.2 MU token set,
    /// preserved VERBATIM — near-black boards, charcoal
    /// tiles, maroon focus fill, gold ring/accent, United
    /// red, cream text. The values below are the 1.7.0–1.7.3
    /// `manchesterUnited` set unchanged; only the name and
    /// the id moved.
    static let muWally = TVThemeTokens(
        id: .muWally,
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

    /// "Manchester United" (1.7.4): the design-exact theme —
    /// the designer's united spec sheet values (Ink #090B10 ·
    /// Navy #0A1120 · Red #DA291C · Gold #D7B777 · Text
    /// #F7F5EF · Muted #A5A8AF). The maroon focus fill is the
    /// drawn focused face's colour, shared with the family;
    /// the amber and the card colours have no design-sheet
    /// value and keep the family's.
    static let unitedDesign = TVThemeTokens(
        id: .unitedDesign,
        bgTop: tvHex(0x090B10),
        bgMid: tvHex(0x090B10),
        bgBottom: .black,
        boardBG: tvHex(0x090B10),
        tileBG: tvHex(0x0A1120),
        tileBorder: .white.opacity(0.10),
        tileFocusedBG: tvHex(0x4A1A1A),
        focusRing: tvHex(0xD7B777),
        accent: tvHex(0xD7B777),
        leagueTx: tvHex(0xA5A8AF),
        minuteRed: tvHex(0xDA291C),
        htAmber: TVPalette.htAmber,
        liveDot: tvHex(0xDA291C),
        teamTx: tvHex(0xF7F5EF),
        dashTx: tvHex(0xA5A8AF),
        eventsLine: .white.opacity(0.12),
        evTx: .white.opacity(0.75),
        evMin: tvHex(0xD7B777),
        cardY: TVPalette.cardY,
        cardR: TVPalette.cardR,
        c1TileBG: tvHex(0x0A1120),
        c1Border: .white.opacity(0.10),
        c1Gold: tvHex(0xD7B777),
        c1Head: tvHex(0xF7F5EF),
        c1Label: tvHex(0xD7B777),
        selectedFill: .white.opacity(0.10),
        liveRed: tvHex(0xDA291C),
        amber: tvHex(0xFFC759),
        heroMeta: tvHex(0xF7F5EF),
        unitedRed: tvHex(0xDA291C),
        cream: tvHex(0xF7F5EF))

    static func tokens(for id: TVThemeID) -> TVThemeTokens {
        switch id {
        case .classic: return .classic
        case .muWally: return .muWally
        case .unitedDesign: return .unitedDesign
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
    /// MU background auto-rotate (1.7.1, spec S3): persisted,
    /// default OFF — the root's rotation loop reads this and
    /// cycles only while it is on and the MU theme is current.
    @Published private(set) var bgAutoRotate: Bool

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
        // Absent key reads false — auto-rotate starts OFF.
        bgAutoRotate = defaults.bool(forKey: "dabanh-mu-bg-autorotate")
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

    /// Persist the MU background auto-rotate switch (1.7.1).
    func setAutoRotate(_ on: Bool) {
        bgAutoRotate = on
        UserDefaults.standard.set(on, forKey: "dabanh-mu-bg-autorotate")
        DiagLog.write("theme", "background auto-rotate \(on)")
    }
}

// MARK: - Picker

/// The full-screen theme picker behind the header's "Giao
/// diện" pill, rebuilt in 1.7.1 as the design's Giao diện
/// pane (table S1/S2/S3): header row, title, the theme
/// cards SIDE BY SIDE with preview blocks, then the MU
/// background rows. Chrome is painted in the CURRENT theme's
/// tokens (the 1.7.0 rule); selecting a card applies it at
/// once and dismisses. The background rows are always shown —
/// they steer the MU themes, and are labelled as such.
/// 1.7.4: THREE cards in one row (designer answer Q6) —
/// Classic / MU Wally / Manchester United. Focus and
/// selection are separate marks: the focused card carries
/// the SettingsSpec focus outline (gold, 3 pt, outset 6 pt —
/// pickerCardBackground below), the SELECTED card carries
/// only the checkmark on its preview.
/// 1.7.4 (S4): the foreground column is ANCHORED to the full
/// frame — before, it sized itself against the background
/// layers (whose wallpaper layer was itself unbounded), so
/// the whole pane negotiated a wallpaper-dependent position
/// and the cards visibly shifted when the wallpaper changed
/// (the owner's picker-shift report, convicted in the 1.7.2
/// full-set audit).
struct TVThemePickerView: View {
    @EnvironmentObject private var themeStore: TVThemeStore
    @Environment(\.tvTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    /// ONE focus owner for the whole surface: the two theme
    /// cards plus the two background rows.
    @FocusState private var focusedID: String?

    private static func cardID(_ id: TVThemeID) -> String {
        "card:" + id.rawValue
    }
    private static let bgRowID = "row:bgchange"
    private static let autoRowID = "row:autorotate"

    /// The current MU wallpaper, if any (same indexing as the
    /// home background: the shared list in file order, indexed
    /// by the persisted choice).
    private var currentWallpaperURL: URL? {
        let images = Wallpapers.images()
        guard !images.isEmpty else { return nil }
        let count = images.count
        return images[((themeStore.bgIndex % count) + count) % count]
    }

    var body: some View {
        ZStack {
            theme.boardBG.ignoresSafeArea()
            // The design's artwork-backed settings: under MU
            // with a wallpaper, the photo sits under a heavy
            // boardBG wash.
            if theme.id.isMU, let url = currentWallpaperURL {
                TVMUWallpaperLayer(url: url, dim: 0.7)
                    .ignoresSafeArea()
                theme.boardBG.opacity(0.4).ignoresSafeArea()
            }
            VStack(alignment: .leading, spacing: 30) {
                headerRow
                Text("Giao diện")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
                HStack(spacing: 28) {
                    optionCard(
                        id: .classic,
                        title: "Classic",
                        subtitle: "Giao diện gốc của Đá Banh TV")
                    optionCard(
                        id: .muWally,
                        title: "MU Wally",
                        subtitle: "Giao diện hiện có · Giữ nguyên")
                    optionCard(
                        id: .unitedDesign,
                        title: "Manchester United",
                        subtitle: "Đỏ United · Đen · Vàng kim")
                }
                backgroundSection
            }
            .padding(.horizontal, 100)
            .padding(.vertical, 44)
            // S4 anchor (1.7.4): the column fills the frame
            // and pins to its top-leading corner, so its
            // layout never negotiates against the background
            // layers' size (see the type note above).
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: .topLeading)
        }
        .defaultFocus($focusedID, Self.cardID(themeStore.themeID))
        .onExitCommand { dismiss() }
    }

    private var headerRow: some View {
        ZStack(alignment: .leading) {
            Text("GIAO DIỆN")
                .font(.system(size: 20, weight: .bold))
                .tracking(3)
                .foregroundStyle(theme.accent)
                .frame(maxWidth: .infinity, alignment: .center)
            Text("← Quay lại")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(theme.leagueTx)
        }
    }

    // MARK: Theme cards

    private func optionCard(id: TVThemeID, title: String,
                            subtitle: String) -> some View {
        let selected = themeStore.themeID == id
        let focused = focusedID == Self.cardID(id)
        return Button {
            themeStore.select(id)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                previewBlock(id: id, selected: selected)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 20))
                        .foregroundStyle(theme.leagueTx)
                }
                .padding(.horizontal, 8)
                Spacer(minLength: 0)
            }
            .padding(20)
            // 1.7.4 (Q6): three equal cards in one row —
            // (1920 − 2×100 pane padding − 2×28 gaps) / 3 =
            // 554. The face's outline is the ONLY focus mark;
            // selection is the preview checkmark alone — the
            // 1.7.1–1.7.3 build stroked the SELECTED card with
            // the same ring, so focus and selection were
            // indistinguishable.
            .frame(width: 554, height: 300, alignment: .leading)
            .background(pickerCardBackground(focused: focused))
        }
        .tvCardButton()
        .focused($focusedID, equals: Self.cardID(id))
    }

    /// The picker cards' focus face (1.7.4, gate F-2): the
    /// SettingsSpec sheet draws the theme cards' focus as a
    /// gold OUTLINE — 3 pt in the CURRENT theme's focus
    /// colour, OUTSET 6 pt from the card's edge (radius
    /// 22 + 6 = 28 keeps the corners concentric) — stated to
    /// be independent of the selected check/background. The
    /// shared tvCardBackground ring is an INSET stroke and
    /// remains the face of the in-app rail cards; the
    /// picker's drawn spec is its own. The fill inside is
    /// the family card fill (focused tile over board), so
    /// the card itself reads exactly like the family face in
    /// both states.
    private func pickerCardBackground(focused: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22)
                .fill(LinearGradient(
                    colors: [focused ? theme.tileFocusedBG : theme.tileBG,
                             theme.boardBG],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .strokeBorder(theme.tileBorder, lineWidth: 1.5))
            if focused {
                RoundedRectangle(cornerRadius: 28)
                    .stroke(theme.focusRing, lineWidth: 3)
                    .padding(-6)
            }
        }
    }

    /// The card's preview block (height 150): the selected
    /// check sits at its top-right, in the CURRENT theme's
    /// focus colour.
    private func previewBlock(id: TVThemeID, selected: Bool) -> some View {
        previewContent(id: id)
            .frame(maxWidth: .infinity)
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(theme.focusRing)
                        .padding(12)
                }
            }
    }

    @ViewBuilder
    private func previewContent(id: TVThemeID) -> some View {
        if id.isMU {
            if let url = Wallpapers.images().first {
                TVMUWallpaperLayer(url: url, dim: 0)
            } else {
                muSwatchComposition(for: id)
            }
        } else {
            classicSkeleton
        }
    }

    /// Classic preview: a navy skeleton composition built
    /// from the CLASSIC tokens — a boardBG panel carrying
    /// three tileBG bars (the design's skeleton idiom).
    private var classicSkeleton: some View {
        let classic = TVThemeTokens.classic
        return ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(classic.boardBG)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array([CGFloat(170), 250, 130].enumerated()),
                        id: \.offset) { _, width in
                    RoundedRectangle(cornerRadius: 6)
                        .fill(classic.tileBG)
                        .frame(width: width, height: 20)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(classic.tileBorder,
                                              lineWidth: 1))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: .leading)
            .padding(20)
        }
    }

    /// MU preview when the wallpaper list is empty: a maroon
    /// panel with the gold / red / cream swatches, in the
    /// card's OWN theme tokens (1.7.4: each MU card previews
    /// its own set).
    private func muSwatchComposition(for id: TVThemeID) -> some View {
        let mu = TVThemeTokens.tokens(for: id)
        return ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(mu.tileFocusedBG)
            HStack(spacing: 12) {
                ForEach(Array([mu.focusRing, mu.unitedRed,
                               mu.cream, mu.tileBG].enumerated()),
                        id: \.offset) { _, colour in
                    RoundedRectangle(cornerRadius: 8)
                        .fill(colour)
                        .frame(width: 72, height: 44)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(mu.tileBorder,
                                              lineWidth: 1.5))
                }
            }
        }
    }

    // MARK: Background rows (S3)

    private var backgroundSection: some View {
        let images = Wallpapers.images()
        let count = images.count
        let position = count > 0
            ? ((themeStore.bgIndex % count) + count) % count + 1 : 0
        return VStack(alignment: .leading, spacing: 16) {
            Text("Hình nền Manchester United")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            changeBackgroundRow(count: count, position: position)
            autoRotateRow
        }
    }

    private func changeBackgroundRow(count: Int,
                                     position: Int) -> some View {
        Button {
            themeStore.cycleBackground(count: count)
        } label: {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "photo")
                    .font(.system(size: 24))
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Đổi hình nền")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Chuyển sang hình nền tiếp theo · \(position)/\(count)")
                        .font(.system(size: 19))
                        .foregroundStyle(theme.leagueTx)
                }
                Spacer()
                Text("›")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(theme.leagueTx)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: 1718, alignment: .leading)
            .background(TVPillFace(focused: focusedID == Self.bgRowID,
                                   selected: false,
                                   theme: theme))
        }
        .tvCardButton()
        .focused($focusedID, equals: Self.bgRowID)
        .disabled(count == 0)
    }

    private var autoRotateRow: some View {
        let on = themeStore.bgAutoRotate
        return Button {
            themeStore.setAutoRotate(!on)
        } label: {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tự động đổi hình nền")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Luân phiên mỗi 25 giây · Luôn phủ tối để dễ đọc")
                        .font(.system(size: 19))
                        .foregroundStyle(theme.leagueTx)
                }
                Spacer()
                // The drawn switch: a fixed 64×36 capsule, the
                // knob sliding inside it — no geometry change
                // between states.
                ZStack {
                    Capsule()
                        .fill(on ? theme.unitedRed
                                 : Color.white.opacity(0.18))
                    Circle()
                        .fill(.white)
                        .frame(width: 28, height: 28)
                        .offset(x: on ? 16 : -16)
                }
                .frame(width: 64, height: 36)
                .animation(.easeInOut(duration: 0.2), value: on)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: 1718, alignment: .leading)
            .background(TVPillFace(focused: focusedID == Self.autoRowID,
                                   selected: false,
                                   theme: theme))
        }
        .tvCardButton()
        .focused($focusedID, equals: Self.autoRowID)
    }
}
