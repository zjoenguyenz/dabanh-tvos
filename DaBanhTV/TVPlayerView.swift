import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// The board context a player session was launched with (v1.4.1,
/// Sony 2.22 parity — owner ruling 2026-11-19): the fixture's
/// rows exactly as the board lists them, plus the two factories
/// that build a fresh ladder for a picked row. Only board
/// launches carry one; direct launches (addon items, EN 24/7
/// channels, heroes) pass nil and the player shows no switch
/// button, exactly as before.
struct TVSwitchContext {
    let title: String
    let vnSources: [Channel]
    let enItems: [NuvioItem]
    /// The EN item the session was opened on, nil for VN
    /// launches: an EN item's resolved streams carry no board
    /// channel URL to match, so the overlay marks it by this
    /// identity instead of by URL.
    let initialENItemID: String?
    /// The VN channel the session was opened on, nil for EN
    /// launches: the shell's playing identity from the first
    /// frame, instead of waiting for the surface's first URL
    /// report (review S3-D3).
    let initialVNURL: String?
    let makeVNResolution: @MainActor (Channel) -> MatchResolution
    let makeENResolution: @MainActor (NuvioItem) -> MatchResolution
}

/// The player session shell: it owns the ACTIVE resolution and
/// the source-switch overlay, while PlayerSurface below runs
/// one resolution at a time. A pick in the overlay swaps the
/// active resolution and rebuilds the surface (fresh ladder
/// state via the session id) — the switch happens inside the
/// player; nothing dismisses back to the board. Menu closes
/// the overlay first, and only exits the player when no
/// overlay is up.
struct TVPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tvTheme) private var theme
    @State private var activeResolution: MatchResolution
    @State private var session = 0
    @State private var playingURL: String?
    @State private var activeENItemID: String?
    /// The VN channel the owner picked in the overlay: the
    /// rebuilt surface must start on IT, not on the shared
    /// fixture ladder's head (review S3-D1 — PlaylistStore's
    /// resolution is fixture-keyed and keeps the original
    /// tap's order, so the pick is steered at the surface).
    @State private var startURL: String?
    @State private var switchOpen = false
    /// 1.7.6 (flow audit F-DT-1): the switch-hint capsule's
    /// visibility — raised at each session start (and after
    /// every pick / retry, which all bump `session`), lowered
    /// by the shell's timer task after ~5 s.
    @State private var switchHintVisible = false
    /// 1.6.0 (web standard, point 4): the session has already
    /// crossed VN↔EN once on ladder exhaustion — the slate is
    /// allowed only after that, never a ping-pong.
    @State private var autoCrossUsed = false
    @FocusState private var switchFocus: String?
    let switchContext: TVSwitchContext?

    init(resolution: MatchResolution, switchContext: TVSwitchContext? = nil) {
        _activeResolution = State(initialValue: resolution)
        _activeENItemID = State(initialValue: switchContext?.initialENItemID)
        _playingURL = State(initialValue: switchContext?.initialVNURL)
        self.switchContext = switchContext
    }

    var body: some View {
        ZStack {
            PlayerSurface(resolution: activeResolution,
                          showsSwitchButton: switchContext != nil,
                          onSwitchButton: { openSwitch() },
                          onPlayingURL: { playingURL = $0 },
                          onExhausted: { handleExhaustion() },
                          onRetry: { session += 1 },
                          onClose: { dismiss() },
                          startURL: startURL,
                          surfaceLocked: switchOpen,
                          launchedViaSwitch: session > 0)
                .id(session)
                // While the overlay is up the surface leaves
                // the focus environment entirely (review
                // S1/S2/S3-D2): no directional input can land
                // on the dimmed player or its switch button
                // behind the panel.
                .disabled(switchOpen)
            if switchOpen, let switchContext {
                if theme.id.isDesign {
                    designSwitchPanel(switchContext)
                } else {
                    switchOverlay(switchContext)
                }
            }
            // 1.7.6 (flow audit F-DT-1): the switch hint —
            // the in-player source switch otherwise lives
            // ONLY inside the native transport bar's custom
            // menu, which nothing on screen names. This
            // capsule (the surface's own status-capsule
            // idiom, bottom-leading) names the path for ~5 s
            // at each session start and after every pick;
            // it is non-interactive and never shows while
            // the switch panel itself is up.
            if switchContext != nil, !switchOpen, switchHintVisible {
                switchHintCapsule
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottomLeading)
                    .padding(.leading, 48)
                    .padding(.bottom, 36)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .task(id: session) {
            guard switchContext != nil else { return }
            withAnimation(.easeIn(duration: 0.3)) { switchHintVisible = true }
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled { return }
            withAnimation(.easeOut(duration: 0.4)) { switchHintVisible = false }
        }
        .onExitCommand {
            if switchOpen {
                switchOpen = false
            } else {
                dismiss()
            }
        }
        // 1.6.0: the launch instant, stamped so a session's
        // tap→first-frame time is the difference between this
        // line and the surface's first-frame line in DiagLog
        // (both carry timestamps) — the install session reads
        // the standard's headline number from the log alone.
        .onAppear { DiagLog.write("player", "session presented") }
    }

    /// The active ladder is exhausted (1.6.0, web standard —
    /// point 4): the no-signal slate is only for when the
    /// MATCH's pool is exhausted, and a board session's pool
    /// spans both sections of its board. A VN session whose
    /// ladder dies therefore crosses to the first EN item, and
    /// an EN session that resolves empty or dies crosses to
    /// the VN ladder's head — once per session (Sony 2.29's B1
    /// was this same hole in one direction, graded BLOCKER
    /// there). Direct launches carry no context and keep the
    /// slate exactly as before.
    private func handleExhaustion() {
        guard let ctx = switchContext, !autoCrossUsed else { return }
        if let activeENItemID {
            guard let first = ctx.vnSources.first else { return }
            autoCrossUsed = true
            DiagLog.write("player", "ladder exhausted — auto-cross EN→VN (was item=\(activeENItemID))")
            pickVN(first, in: ctx)
        } else {
            guard let first = ctx.enItems.first else { return }
            autoCrossUsed = true
            DiagLog.write("player", "ladder exhausted — auto-cross VN→EN item=\(first.id)")
            pickEN(first, in: ctx)
        }
    }

    // MARK: Switch overlay (the board's arrangement, spec §2)

    /// The switch hint capsule (1.7.6, flow audit F-DT-1):
    /// PlayerSurface's statusCapsule recipe carried to the
    /// shell — Capsule shape, h18/v8 padding, the fill rule
    /// verbatim (theme.tileBG at 0.9 under MU themes, black
    /// 0.55 otherwise), NO stroke — and it lands in the same
    /// bottom-leading corner as that capsule (the shell
    /// places it at leading 48 / bottom 36, the idiom's own
    /// offsets). (Gate Round 1, Lens B: the first pass
    /// invented h16/v10 + a hairline and called them the
    /// idiom's; the recipe above is the idiom's, read from
    /// statusCapsule itself.) Its eyebrow is the caps brand
    /// form (FL-441: 15 bold tracked 2, theme accent; the
    /// design face under design MU) — this capsule is the
    /// app-owned info surface over the player, so it carries
    /// the brand the drawn info slate would have; the line
    /// names the switch path through the native transport
    /// bar.
    private var switchHintCapsule: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("JOE SOCCER")
                .font(theme.id.isDesign
                    ? TVDesignFont.ui(15, .bold)
                    : .system(size: 15, weight: .bold))
                .tracking(2)
                .foregroundStyle(theme.accent)
                .lineLimit(1)
            Text("Đổi nguồn trong lúc xem: thanh điều khiển ▸ Đổi nguồn")
                .font(theme.id.isDesign
                    ? TVDesignFont.ui(19)
                    : .system(size: 19))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(theme.id.isMU
                ? theme.tileBG.opacity(0.9)
                : Color.black.opacity(0.55)))
    }

    private func openSwitch() {
        guard switchContext != nil else { return }
        DiagLog.write("player", "switch overlay opened")
        switchOpen = true
        switchFocus = playingRowID
    }

    /// The row playback is currently on: an EN session marks
    /// its item by identity; VN playback is found by URL
    /// against the surface's playing channel (the ladder may
    /// have walked since the pick). Falls back to the first
    /// row when neither matches yet.
    private var playingRowID: String? {
        guard let ctx = switchContext else { return nil }
        if let activeENItemID {
            return "nv:" + activeENItemID
        }
        if let playingURL,
           ctx.vnSources.contains(where: { $0.url == playingURL }) {
            return "vn:" + playingURL
        }
        return ctx.vnSources.first.map { "vn:" + $0.url }
            ?? ctx.enItems.first.map { "nv:" + $0.id }
    }

    private func switchOverlay(_ ctx: TVSwitchContext) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    // 1.7.6 (FL-441, RECALC-DABANH RULING 1):
                    // the caps brand eyebrow above the panel
                    // title — 15 bold tracked 2 in the theme
                    // accent. The panel is an outer surface;
                    // the live video itself never carries a
                    // persistent brand.
                    Text("JOE SOCCER")
                        .font(.system(size: 15, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(theme.accent)
                        .lineLimit(1)
                    Text(ctx.title)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text("Chọn nguồn khác để chuyển ngay trong lúc xem · Menu để đóng")
                        .font(.system(size: 21))
                        .foregroundStyle(.white.opacity(0.55))
                }
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 30) {
                        switchVNSection(ctx)
                        if !ctx.enItems.isEmpty {
                            switchENSection(ctx)
                        }
                    }
                    .padding(.bottom, 10)
                }
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 36)
            // The board's own focus pattern (its onAppear
            // below): the playing-row focus is asserted when
            // the panel actually appears, not only in the same
            // transaction that inserted it (review S3-D2).
            .onAppear { switchFocus = playingRowID }
            .frame(width: 1160)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .fill(theme.boardBG)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22)
                            .strokeBorder(theme.tileBorder, lineWidth: 2)))
        }
    }

    private func switchVNSection(_ ctx: TVSwitchContext) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("LINK TIẾNG VIỆT")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
            ForEach(ctx.vnSources, id: \.url) { ch in
                Button {
                    pickVN(ch, in: ctx)
                } label: {
                    switchRowFace(title: MatchTitle.clean(ch.title),
                                  detail: ch.group,
                                  playing: activeENItemID == nil
                                      && playingURL == ch.url,
                                  focused: switchFocus == "vn:" + ch.url,
                                  theme: theme)
                }
                .tvCardButton()
                .focused($switchFocus, equals: "vn:" + ch.url)
            }
        }
    }

    private func switchENSection(_ ctx: TVSwitchContext) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("LINK TIẾNG ANH · BLV ANH")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
            ForEach(ctx.enItems) { item in
                Button {
                    pickEN(item, in: ctx)
                } label: {
                    switchRowFace(title: item.league ?? item.displayName,
                                  detail: item.league != nil
                                      ? item.displayName : "Nuvio",
                                  playing: activeENItemID == item.id,
                                  focused: switchFocus == "nv:" + item.id,
                                  theme: theme)
                }
                .tvCardButton()
                .focused($switchFocus, equals: "nv:" + item.id)
            }
        }
    }

    // MARK: Design switch panel (1.7.4, Q7 — Player-sources)

    /// The design theme's source-switch panel: a right-side
    /// panel in the board's own arrangement (the drawing's
    /// Player-sources) — gold-edged, the board's rows, a
    /// check on the playing row, an ✕ that closes it (Menu
    /// closes it too, via the shell's exit command, exactly
    /// as the centred overlay). Same focus ids, same picks,
    /// same playing-row assertion as switchOverlay.
    private func designSwitchPanel(_ ctx: TVSwitchContext) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            // 1.7.6 (FL-441, RECALC-DABANH
                            // RULING 1): the caps brand eyebrow
                            // above the panel title — 15 bold
                            // tracked 2 in the design gold, the
                            // design face. Same ruling as the
                            // centred overlay's eyebrow.
                            Text("JOE SOCCER")
                                .font(TVDesignFont.ui(15, .bold))
                                .tracking(2)
                                .foregroundStyle(theme.accent)
                                .lineLimit(1)
                            Text("Chọn nguồn phát")
                                .font(TVDesignFont.ui(34, .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(ctx.title)
                                .font(TVDesignFont.ui(20))
                                .foregroundStyle(theme.leagueTx)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Button {
                            switchOpen = false
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 52, height: 52)
                                .background(
                                    Circle()
                                        .fill(theme.tileBG)
                                        .overlay(
                                            Circle()
                                                .strokeBorder(
                                                    switchFocus == "sw:close"
                                                        ? theme.focusRing
                                                        : theme.tileBorder,
                                                    lineWidth: switchFocus == "sw:close" ? 3 : 1.5)))
                        }
                        .tvCardButton()
                        .focused($switchFocus, equals: "sw:close")
                    }
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 26) {
                            designSwitchVNSection(ctx)
                            if !ctx.enItems.isEmpty {
                                designSwitchENSection(ctx)
                            }
                        }
                        .padding(.bottom, 10)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 32)
                .frame(width: 880)
                .frame(maxHeight: .infinity)
                .background(theme.boardBG)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(theme.focusRing)
                        .frame(width: 3)
                }
                .onAppear { switchFocus = playingRowID }
            }
        }
    }

    private func designSwitchVNSection(_ ctx: TVSwitchContext) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            designGroupHeader(title: "Tiếng Việt",
                              total: ctx.vnSources.count,
                              selectable: ctx.vnSources.filter {
                                  SourceHealth.status(for: $0.url) != .dead
                              }.count)
            ForEach(Array(ctx.vnSources.enumerated()), id: \.offset) { index, ch in
                Button {
                    pickVN(ch, in: ctx)
                } label: {
                    TVDesignSourceRow(
                        title: MatchTitle.clean(ch.title),
                        detail: ch.group,
                        isPrimary: index == 0,
                        isVN: true,
                        chipChannel: ch,
                        healthText: tvSourceHealthText(for: ch.url),
                        unavailable: SourceHealth.status(for: ch.url) == .dead,
                        playing: activeENItemID == nil && playingURL == ch.url,
                        focused: switchFocus == "vn:" + ch.url,
                        theme: theme)
                }
                .tvCardButton()
                .focused($switchFocus, equals: "vn:" + ch.url)
            }
        }
    }

    private func designSwitchENSection(_ ctx: TVSwitchContext) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            designGroupHeader(title: "English",
                              total: ctx.enItems.count,
                              selectable: ctx.enItems.count)
            ForEach(ctx.enItems) { item in
                Button {
                    pickEN(item, in: ctx)
                } label: {
                    TVDesignSourceRow(
                        title: item.league ?? item.displayName,
                        detail: item.league != nil ? item.displayName : "Nuvio",
                        isPrimary: false,
                        isVN: false,
                        chipChannel: item.poster.isEmpty ? nil : item.displayChannel,
                        healthText: "Chưa kiểm tra",
                        unavailable: false,
                        playing: activeENItemID == item.id,
                        focused: switchFocus == "nv:" + item.id,
                        theme: theme)
                }
                .tvCardButton()
                .focused($switchFocus, equals: "nv:" + item.id)
            }
        }
    }

    /// The switch panel's group header (name + real counts
    /// at the right) — the design board renders the same
    /// line from its own copy (designBoardGroupHeader).
    private func designGroupHeader(title: String, total: Int,
                                   selectable: Int) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(TVDesignFont.ui(24, .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(total) nguồn · \(selectable) có thể chọn")
                .font(TVDesignFont.ui(17))
                .foregroundStyle(theme.leagueTx)
                .lineLimit(1)
        }
    }

    /// The board's row face with one addition: the playing row
    /// carries a check and "(đang phát)" so the eye lands on it
    /// before focus even moves.
    private func switchRowFace(title: String, detail: String,
                               playing: Bool, focused: Bool,
                               theme: TVThemeTokens) -> some View {
        HStack(spacing: 16) {
            Image(systemName: playing ? "checkmark.circle.fill" : "play.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(playing || focused
                    ? theme.accent : .white.opacity(0.5))
            VStack(alignment: .leading, spacing: 3) {
                Text(playing ? title + "  (đang phát)" : title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(focused ? theme.accent : .white)
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(focused ? theme.tileFocusedBG : theme.tileBG)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(focused ? theme.accent : theme.tileBorder,
                                      lineWidth: focused ? 3 : 1.5)))
    }

    /// A pick swaps the session's resolution in place (picking
    /// the playing row builds a fresh ladder for it — an
    /// explicit reload, the Joe TV rule).
    private func pickVN(_ ch: Channel, in ctx: TVSwitchContext) {
        DiagLog.write("player", "switch → VN host=\(URL(string: ch.url)?.host ?? "?")")
        activeResolution = ctx.makeVNResolution(ch)
        activeENItemID = nil
        playingURL = nil
        startURL = ch.url
        session += 1
        switchOpen = false
    }

    private func pickEN(_ item: NuvioItem, in ctx: TVSwitchContext) {
        DiagLog.write("player", "switch → EN item=\(item.id)")
        activeResolution = ctx.makeENResolution(item)
        activeENItemID = item.id
        playingURL = nil
        startURL = nil
        session += 1
        switchOpen = false
    }
}

/// Full-screen native tvOS player with the Android app's same-fixture
/// fallback: the sources are every channel carrying the SAME match
/// (tapped one first); when a stream fails, the next source is tried
/// automatically, and only when all of them fail does the view settle
/// on a "no signal" slate. AVPlayerViewController brings the standard
/// remote transport controls (play/pause, scrub, Menu to exit).
///
/// v1.3.7: the sources arrive as a MatchResolution, not a fixed
/// list — the store verifies the fixture's ladder before (and
/// while) the player runs, so the ladder can GROW behind the
/// playing source and its membership can change when the finished
/// ladder lands. The playing source is therefore tracked by URL,
/// never by index: a republication can reorder or extend the list
/// without disturbing what is on screen, and "advance" means the
/// first rung this view has not tried yet, in the ladder's current
/// order. A failure with no untried rung left is only final once
/// the resolution is finished; until then the view waits on the
/// loading capsule for later-verified rungs, exactly as it waits
/// for the first batch.
private struct PlayerSurface: View {
    @Environment(\.tvTheme) private var theme
    @ObservedObject var resolution: MatchResolution
    /// The shell's switch hooks (v1.4.1, 2.22 parity): the
    /// switch button is installed only for board-launched
    /// sessions, and the playing URL is reported up so the
    /// shell's overlay can mark the playing row.
    var showsSwitchButton: Bool = false
    var onSwitchButton: (() -> Void)? = nil
    var onPlayingURL: ((String?) -> Void)? = nil
    /// Fired once, at the moment the ladder settles exhausted
    /// (1.6.0): the shell decides whether the match's pool is
    /// really spent (cross VN↔EN) or the slate stands.
    var onExhausted: (() -> Void)? = nil
    /// The no-signal slate buttons (1.7.4, Q7): retry
    /// rebuilds the surface on the same resolution (a fresh
    /// ladder walk), close dismisses the player. The design
    /// slate read them first; since 1.7.6 (flow audit
    /// F-DT-3) the classic / MU Wally slate carries the same
    /// three actions in its own dress — no slate is
    /// text-only any more.
    var onRetry: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil
    /// A VN pick from the switch overlay (v1.4.1): the rung
    /// this surface must start on. The store's resolution is
    /// fixture-keyed — its ladder keeps the ORIGINAL tap's
    /// order — so without this the rebuilt surface would
    /// replay the ladder's head and silently ignore the pick
    /// (review S3-D1).
    var startURL: String? = nil
    /// True while the switch overlay is up: the player
    /// controller's view stops taking interaction, so the
    /// focus engine cannot reach it behind the panel (review
    /// S1/S2/S3-D2; the shell's .disabled is the SwiftUI half
    /// of the same lock).
    var surfaceLocked: Bool = false
    /// True when the shell rebuilt this surface for an overlay
    /// pick (session > 0): the surface's first rung then reports
    /// kind=switch in the first-frame timing line (1.4.4).
    var launchedViaSwitch: Bool = false
    @State private var currentURL: String?
    @State private var tried: Set<String> = []
    @State private var exhausted = false
    @State private var switching = true
    /// Focus owner for the design slate's buttons (1.7.4):
    /// asserted when the slate appears, so the remote lands
    /// on "Thử lại" the moment the ladder settles exhausted.
    @FocusState private var slateFocus: String?
    /// When the current rung started loading (1.4.4, item 2):
    /// stamped by pump() at every rung assignment, consumed by
    /// handleReady() — nil whenever no rung is in flight.
    @State private var rungStartedAt: Date?

    private var current: ResolvedSource? {
        resolution.sources.first { $0.channel.url == currentURL }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if exhausted {
                noSignal
            } else if let current {
                if current.channel.streamURL != nil {
                    PlayerController(channel: current.channel, onFail: advance,
                                     onReady: { handleReady() },
                                     showsSwitchButton: showsSwitchButton,
                                     onSwitchButton: onSwitchButton ?? {},
                                     interactionLocked: surfaceLocked)
                        .id(current.channel.url)
                        .ignoresSafeArea()
                } else {
                    // An unparseable URL counts as a failed source.
                    Color.clear.onAppear { advance() }
                }
                if switching {
                    statusCapsule(current)
                }
            } else {
                // Nothing to play yet: the first verified batch is
                // still landing, or every tried rung failed and the
                // resolve is still verifying more.
                statusCapsule(nil)
            }
        }
        .onAppear { pump() }
        .onChange(of: resolution.sources) { _, _ in pump() }
        .onChange(of: resolution.finished) { _, _ in pump() }
        .onChange(of: currentURL) { _, url in onPlayingURL?(url) }
    }

    /// The existing loading capsule, unchanged but for one
    /// addition: when the rung being loaded carries a quality
    /// parsed from its own master playlist during pre-flight, the
    /// capsule names it ("Đang tải · 1080p…") — the only quality
    /// label the app shows for a stream, and it comes from the
    /// playlist itself, never from a title's "[FHD]" decoration.
    private func statusCapsule(_ current: ResolvedSource?) -> some View {
        var text = tried.isEmpty ? "Đang tải…" : "Đang chuyển nguồn khác…"
        if let quality = current?.quality { text += " · \(quality)" }
        return VStack {
            Spacer()
            HStack {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(theme.id.isMU
                        ? theme.tileBG.opacity(0.9)
                        : Color.black.opacity(0.55)))
                Spacer()
            }
            .padding(.leading, 48)
            .padding(.bottom, 36)
        }
        .ignoresSafeArea()
    }

    /// Start the first untried rung whenever there is a gap to
    /// fill: at presentation, when the ladder grows or finishes,
    /// and after a failure (via advance). With no untried rung,
    /// the ladder being finished is what makes the failure final.
    private func pump() {
        // 1.6.0 fix round (review A1): a republication can REMOVE
        // the rung this surface is trying — a blind-published
        // rung whose probe later proves it dead drops out of the
        // ladder, its controller is dismantled with it, and no
        // failure event ever fires; without this check every
        // pump() then returned at the guard below and the
        // session hung on the loading capsule until Menu. A
        // vanished rung IS a failed rung: advance. (Removal is
        // only ever a proven-dead verdict — verified rungs stay
        // verified, blind rungs stay until their verdict lands.)
        if let url = currentURL,
           !resolution.sources.contains(where: { $0.channel.url == url }) {
            advance()
            return
        }
        guard !exhausted, currentURL == nil else { return }
        // A switch pick outranks the ladder's own order: the
        // picked rung plays first; the rest of the ladder
        // stays behind it as the fallback, in ladder order.
        // Once the pick has been tried, this branch is inert.
        if let startURL, !tried.contains(startURL) {
            if let picked = resolution.sources.first(
                where: { $0.channel.url == startURL }) {
                currentURL = picked.channel.url
                rungStartedAt = Date()
                switching = true
                return
            }
            if !resolution.finished {
                // The picked source has not been published
                // yet — wait for the ladder to grow (pump
                // re-runs on every republication) rather than
                // replaying the head rung.
                switching = true
                return
            }
            // Finished and absent: the picked source was
            // proven dead — fall through to the ladder order.
        }
        if let next = resolution.sources.first(where: { !tried.contains($0.channel.url) }) {
            currentURL = next.channel.url
            rungStartedAt = Date()
            switching = true
        } else if resolution.finished {
            exhausted = true
            onExhausted?()
        } else {
            switching = true
        }
    }

    /// The rung reached readyToPlay (1.4.4, item 2): drop the
    /// loading capsule — as before — and stamp the rung's
    /// start→ready time into DiagLog, so a slow source (the
    /// owner's "English links load quite slowly") is a number
    /// in the log, not an impression. readyToPlay is the
    /// picture seam this player already trusts — it is what
    /// drops the capsule — so the line measures exactly the
    /// wait the viewer sees. The first rung of a surface
    /// reports kind=initial, or kind=switch when the shell
    /// rebuilt the surface for an overlay pick; a rung reached
    /// after a failure reports kind=advance. A repeat ready
    /// notification for the same rung logs nothing (the stamp
    /// is consumed by the first).
    private func handleReady() {
        switching = false
        guard let started = rungStartedAt, let url = currentURL else { return }
        rungStartedAt = nil
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let kind = tried.isEmpty
            ? (launchedViaSwitch ? "switch" : "initial")
            : "advance"
        // 1.6.0: a rung that actually played is a proven-good
        // URL — the health memory hears it from the player
        // itself, not only from the verifier.
        SourceHealth.record(url, .ok, latencyMs: ms)
        // 1.7.10 (change 5): the same real outcome teaches the
        // per-host reputation — a first frame reached, with the
        // player's own start→ready time as the latency sample.
        SourceReputation.recordSuccess(url: url, latencyMs: ms)
        DiagLog.write("player", "first-frame \(ms) ms kind=\(kind) "
            + "host=\(URL(string: url)?.host ?? "?")")
    }

    private func advance() {
        if let currentURL {
            tried.insert(currentURL)
            // 1.6.0 (FL-355): the failure is recorded in the
            // health memory, not only in the log — the next
            // resolve of this fixture demotes the URL instead
            // of re-proving it from zero.
            SourceHealth.record(currentURL, .dead)
            // 1.7.10 (change 5): the same advance teaches the
            // per-host reputation a failure for this rung's host.
            SourceReputation.recordFailure(url: currentURL)
            // KH-1: player failures are a required log event —
            // host only, never the full URL (DiagLog scrubs
            // regardless; callers still log hosts, not links).
            DiagLog.write("player", "source failed, advancing — host=\(URL(string: currentURL)?.host ?? "?") tried=\(tried.count)")
        }
        currentURL = nil
        switching = true
        pump()
    }

    private var noSignal: some View {
        ZStack {
            (theme.id.isMU ? theme.boardBG
                : Color(red: 0.05, green: 0.07, blue: 0.08)).ignoresSafeArea()
            if theme.id.isDesign {
                designNoSignal
            } else {
                // 1.7.6 (flow audit F-DT-3 + FL-441): this
                // slate was TEXT-ONLY — when every source
                // died, the owner's only move was Menu out,
                // with no retry and no source switch, while
                // the design slate carried all three actions.
                // It now carries the same three actions in the
                // Classic/Wally dress (classicSlateButton:
                // system face, the slate family's tokens),
                // focus asserted to Thử lại, and the brand
                // wordmark above the title (22 bold, centred,
                // " Soccer" in the theme accent). The copy
                // drops the Menu instruction — the actions are
                // the way out now (Menu still exits, as it
                // does everywhere).
                VStack(spacing: 18) {
                    (Text("Joe").foregroundStyle(.white)
                        + Text(" Soccer").foregroundStyle(theme.accent))
                        .font(.system(size: 22, weight: .bold))
                        .lineLimit(1)
                    Text("MẤT TÍN HIỆU")
                        .font(.system(size: 54, weight: .bold))
                        .tracking(4)
                        .foregroundStyle(.white)
                    Text("Tất cả các nguồn của trận này đều không phát được.")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.65))
                    HStack(spacing: 18) {
                        classicSlateButton(title: "Thử lại", id: "slate:retry",
                                           primary: true) { onRetry?() }
                        if showsSwitchButton, let onSwitchButton {
                            classicSlateButton(title: "Đổi nguồn", id: "slate:switch",
                                               primary: false) { onSwitchButton() }
                        }
                        classicSlateButton(title: "Đóng", id: "slate:close",
                                           primary: false) { onClose?() }
                    }
                    .padding(.top, 8)
                }
                .defaultFocus($slateFocus, "slate:retry")
                .onAppear { slateFocus = "slate:retry" }
            }
        }
    }

    /// The design theme's no-signal slate (1.7.4, Q7 — the
    /// drawing's Player-no-signal): a centred panel with a
    /// red top border, the gold broadcast (radiowaves) glyph
    /// at the panel's TOP-LEFT — the drawing's mark and
    /// placement (Round 1 review A-3) — and the three
    /// actions wired to the shell — Thử lại rebuilds the
    /// surface on the same resolution, Đổi nguồn opens the
    /// switch panel (board sessions only, exactly when the
    /// transport menu offers it), Đóng exits. These are
    /// app-owned slate buttons, not transport chrome (the
    /// native controls own the chrome, FL-129 untouched).
    private var designNoSignal: some View {
        VStack(spacing: 26) {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 54))
                    .foregroundStyle(theme.accent)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 1.7.6 (FL-441, RECALC-DABANH RULING 1): the
            // brand wordmark centred above the slate title —
            // title-case, 22 bold in the design face, "Joe"
            // white, " Soccer" in the design gold. The glyph
            // row and the panel geometry are untouched.
            (Text("Joe").foregroundStyle(.white)
                + Text(" Soccer").foregroundStyle(theme.accent))
                .font(TVDesignFont.ui(22, .bold))
                .lineLimit(1)
            Text("Không có tín hiệu")
                .font(TVDesignFont.ui(48, .bold))
                .foregroundStyle(.white)
            Text("Tất cả các nguồn của trận này đều không phát được.")
                .font(TVDesignFont.ui(22))
                .foregroundStyle(.white.opacity(0.65))
            HStack(spacing: 18) {
                slateButton(title: "Thử lại", id: "slate:retry",
                            primary: true) { onRetry?() }
                if showsSwitchButton, let onSwitchButton {
                    slateButton(title: "Đổi nguồn", id: "slate:switch",
                                primary: false) { onSwitchButton() }
                }
                slateButton(title: "Đóng", id: "slate:close",
                            primary: false) { onClose?() }
            }
            .padding(.top, 6)
        }
        .padding(48)
        .frame(width: 1160)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.boardBG)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(theme.tileBorder, lineWidth: 1.5)))
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 3)
                .fill(theme.unitedRed)
                .frame(height: 5)
                .padding(.horizontal, 16)
                .padding(.top, 0)
        }
        .defaultFocus($slateFocus, "slate:retry")
        .onAppear { slateFocus = "slate:retry" }
    }

    private func slateButton(title: String, id: String, primary: Bool,
                             action: @escaping () -> Void) -> some View {
        let focused = slateFocus == id
        return Button(action: action) {
            Text(title)
                .font(TVDesignFont.ui(24, .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 34)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(primary ? theme.unitedRed : theme.tileBG)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(focused ? theme.focusRing
                                                      : theme.tileBorder,
                                              lineWidth: focused ? 3 : 1.5)))
        }
        .tvCardButton()
        .focused($slateFocus, equals: id)
    }

    /// The Classic / MU Wally slate button (1.7.6, flow
    /// audit F-DT-3): slateButton's exact face — same
    /// tokens, same focus ring, same primary fill — in the
    /// system face these themes speak. It exists so the
    /// Classic/Wally no-signal slate carries the same three
    /// actions as the design slate instead of text alone.
    private func classicSlateButton(title: String, id: String, primary: Bool,
                                    action: @escaping () -> Void) -> some View {
        let focused = slateFocus == id
        return Button(action: action) {
            Text(title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 34)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(primary ? theme.unitedRed : theme.tileBG)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(focused ? theme.focusRing
                                                      : theme.tileBorder,
                                              lineWidth: focused ? 3 : 1.5)))
        }
        .tvCardButton()
        .focused($slateFocus, equals: id)
    }
}


// MARK: - Design source row (1.7.4)

/// The Q5 health line for one VN source URL, from the health
/// memory's fresh record: a proven player reads "Đã kiểm
/// tra · Hoạt động", a proven death "Không khả dụng", and
/// everything else — no record, an expired record, or a
/// merely-seen probe — "Chưa kiểm tra" (never dressed up as
/// a confirmation). NO quality / signal fields exist anywhere
/// in the design (answer Q5).
func tvSourceHealthText(for url: String) -> String {
    switch SourceHealth.status(for: url) {
    case .ok: return "Đã kiểm tra · Hoạt động"
    case .dead: return "Không khả dụng"
    case .seen, nil: return "Chưa kiểm tra"
    }
}

/// One source row under the design theme — the Detail
/// drawing's row, shared by the source board and the
/// in-player switch panel: cream logo chip (FIXED 68×52,
/// FL-360), name + KHUYÊN DÙNG on the first VN row, the
/// drawn sub-line (the commentary line; the playing row
/// carries "Đang phát" in it — 1.7.5, RECALC-DABANH
/// B9/B14), and the trailing slot: the health line + arrow,
/// or — in the switch panel — the playing row's check.
/// Focused = the family's maroon gradient + gold border
/// (2 pt, the StateLibrary §01 value — 1.7.5, B12). A PROVEN-DEAD
/// source (the same SourceHealth value that produces its
/// "Không khả dụng" health text) renders the drawn
/// unavailable state (DetailSourceUnavailable, StateLibrary
/// §02): the whole row dimmed — dark grey chip with the logo
/// greyed on it, muted title, muted sub-line and health
/// line (gate F-1).
struct TVDesignSourceRow: View {
    let title: String
    let detail: String
    let isPrimary: Bool
    let isVN: Bool
    let chipChannel: Channel?
    let healthText: String
    let unavailable: Bool
    let playing: Bool
    let focused: Bool
    let theme: TVThemeTokens

    /// The drawn sub-line (1.7.5, RECALC-DABANH B9): every
    /// board drawing carries the commentary line — the
    /// 1.7.4 build's channel-group + primary/backup suffix
    /// was the component library's variant, not the
    /// screen's. The playing row's marker rides in the
    /// sub-line too (B14 / StateLibrary §01: "Đang phát"),
    /// not after the title. `detail`/`isPrimary` no longer
    /// feed the sub-line; isPrimary still drives the
    /// KHUYÊN DÙNG marker (the owner's standing rule).
    private var sub: String {
        let commentary = isVN ? "Bình luận tiếng Việt" : "English commentary"
        return playing ? commentary + " · Đang phát" : commentary
    }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(unavailable
                        ? Color(white: 0.25)
                        : Color(red: 0.96, green: 0.94, blue: 0.88))
                Group {
                    if let chipChannel, chipChannel.logoURL != nil {
                        TVChannelLogo(channel: chipChannel, height: 44)
                    } else {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(Color.black.opacity(0.55))
                    }
                }
                // The unavailable row's logo greys and dims
                // with the row (gate F-1): on the dark grey
                // chip it reads as the drawing's greyed
                // lettering, not the cream chip's full art.
                .grayscale(unavailable ? 1 : 0)
                .opacity(unavailable ? 0.45 : 1)
            }
            .frame(width: 68, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    Text(title)
                        .font(TVDesignFont.ui(26, .semibold))
                        .foregroundStyle(unavailable
                            ? Color.white.opacity(0.45) : .white)
                        .lineLimit(1)
                    if isVN && isPrimary {
                        Text("KHUYÊN DÙNG")
                            .font(TVDesignFont.ui(15, .bold))
                            .tracking(1)
                            .foregroundStyle(unavailable
                                ? theme.accent.opacity(0.45) : theme.accent)
                            .lineLimit(1)
                    }
                }
                Text(sub)
                    .font(TVDesignFont.ui(17))
                    .foregroundStyle(unavailable
                        ? theme.leagueTx.opacity(0.5) : theme.leagueTx)
                    .lineLimit(1)
                    .frame(height: 24, alignment: .leading)
            }
            Spacer(minLength: 0)
            // The health text shows on EVERY row — the
            // playing row included (the Player-sources
            // drawing carries "Chưa kiểm tra" AND the ✓ on
            // its playing row; Round 1 review A-2). Playing
            // swaps the arrow for the check, nothing else.
            HStack(spacing: 12) {
                Text(healthText)
                    .font(TVDesignFont.ui(19))
                    .foregroundStyle(unavailable
                        ? theme.leagueTx.opacity(0.5) : theme.leagueTx)
                    .lineLimit(1)
                if playing {
                    Image(systemName: "checkmark")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(unavailable
                            ? theme.accent.opacity(0.45) : theme.accent)
                        .frame(width: 30)
                } else {
                    // 1.7.5 (RECALC-DABANH B11): every focus
                    // drawing keeps the "→" — the 1.7.4 build
                    // swapped it for a play glyph on focus.
                    Image(systemName: "arrow.right")
                        .font(.system(size: 20))
                        .foregroundStyle(focused ? theme.accent
                                                 : (unavailable
                                                    ? .white.opacity(0.18)
                                                    : .white.opacity(0.35)))
                        .frame(width: 30)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(focused
                    ? AnyShapeStyle(LinearGradient(
                        colors: [theme.tileFocusedBG, theme.minuteRed],
                        startPoint: .leading, endPoint: .trailing))
                    : AnyShapeStyle(theme.tileBG))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(focused ? theme.focusRing : theme.tileBorder,
                                      lineWidth: focused ? 2 : 1)))
    }
}

// MARK: - Link board (1.4.1, spec §2)

/// The fixture's link board — the only place the VN/EN choice is
/// made (spec §2.1). Header = the fixture's FULL match info
/// (1.5.0, owner redesign ruling 2026-11-21 + spec §2.4 as
/// amended): minute/status badge, headline, kickoff, the big
/// score digits and the per-side event columns (every scorer,
/// cards as glyph lines) — the whole cluster the slim hero no
/// longer carries. With no matched state it shows the kickoff
/// and the board is still usable — it never waits for state.
/// Below: LINK TIẾNG VIỆT —
/// the fixture's grouped mirror channels in ladder order,
/// representative first, labelled by their cleaned titles
/// verbatim (the trailing "(Name)" IS the commentator choice,
/// §2.3a) — then LINK TIẾNG ANH · BLV ANH with one row per
/// attached Nuvio event meta (§2.3b), the whole section omitted
/// when nothing attached (fail closed — never faked). Focus
/// starts on the detail's one small button (1.7.4; the
/// header/detail is a static strip, never focusable) and
/// moves to the first VN row when the list opens. A row tap plays that row: VN
/// rows enter the player with the store's ladder rotated to the
/// row (PlaylistStore.resolution(for:) is tapped-first by
/// construction), EN rows resolve through the addon store.
struct TVMatchBoardView: View {
    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var themeStore: TVThemeStore
    @Environment(\.tvTheme) private var theme
    let entry: TVFixtureEntry
    let vnSources: [Channel]
    let enItems: [NuvioItem]
    @ObservedObject var nuvio: NuvioStore
    @Environment(\.dismiss) private var dismiss
    @State private var playRequest: BoardPlayRequest?
    /// 1.7.4 (owner ruling 2026-11-22 01:56 CST, all three
    /// themes): the board OPENS on the fixture's detail —
    /// the Match Centre under the design theme, the info
    /// column under MU Wally, the classic header under
    /// Classic — and the source list stands behind ONE small
    /// button. `showSources` is that button's state; Menu
    /// closes the list back to the detail before it exits.
    @State private var showSources = false
    @FocusState private var focusedRow: String?

    private struct BoardPlayRequest: Identifiable {
        let id = UUID()
        let resolution: MatchResolution
        /// The EN item this launch came from, nil for VN rows —
        /// the player session's switch context marks it as the
        /// playing row (v1.4.1, 2.22 parity).
        let enItemID: String?
        /// The VN channel this launch came from, nil for EN
        /// rows — the session's initial playing identity.
        let vnURL: String?
    }

    /// The focus id of the detail's one small button, per
    /// theme — where focus lands when the board opens and
    /// where it returns when the source list closes. Nil
    /// when the button does not exist on the detail: under
    /// MU Wally the watch button is omitted when both source
    /// lists are empty (the shipped caller guard), so there
    /// is nothing for opening focus to target (Round 1
    /// review B-2). The design CTA always exists and is
    /// always focusable (see centreCTA — the A-1 ruling),
    /// and the classic button is unconditional.
    private var detailFocusID: String? {
        if theme.id.isDesign { return "design:cta" }
        if theme.id.isMU { return totalSources > 0 ? "mu:watch" : nil }
        return "classic:open"
    }

    /// The first source row's focus id (VN first, else EN) —
    /// where focus lands when the source list opens.
    private var firstRowID: String? {
        vnSources.first.map { "vn:" + $0.url }
            ?? enItems.first.map { "nv:" + $0.id }
    }

    private var totalSources: Int { vnSources.count + enItems.count }

    /// "Có thể chọn" (the design's count): every source the
    /// health memory has NOT proven dead — unchecked sources
    /// included, exactly as the board's own note states. EN
    /// items carry no pre-resolution health record, so they
    /// all count.
    private var selectableSources: Int {
        vnSources.filter { SourceHealth.status(for: $0.url) != .dead }.count
            + enItems.count
    }

    private func openSources() {
        showSources = true
        focusedRow = firstRowID
    }

    /// Menu on the board: with the source list open it closes
    /// the list back to the detail; on the detail it exits.
    private func handleBoardExit() {
        if showSources {
            showSources = false
            focusedRow = detailFocusID
        } else {
            dismiss()
        }
    }

    var body: some View {
        Group {
            if theme.id.isDesign {
                if showSources {
                    designBoard
                } else {
                    designCentre
                }
            } else if theme.id.isMU {
                if showSources {
                    muBoard
                } else {
                    muLanding
                }
            } else {
                classicBoard
            }
        }
        // 1.7.6 (flow audit F-DT-2): the staged Menu exit
        // (list first, then the board) is a house rule the
        // owner relies on, but NOTHING on screen said the
        // first Menu press only closes the list — the board
        // read as ignoring his exit. While the source list
        // is open, a small cue at the bottom-trailing corner
        // names the stage. One overlay for all three themes,
        // in each theme's own face at the muted tier;
        // non-interactive.
        .overlay(alignment: .bottomTrailing) {
            if showSources {
                Text("Menu — đóng danh sách nguồn")
                    .font(theme.id.isDesign
                        ? TVDesignFont.ui(17)
                        : .system(size: 17))
                    .foregroundStyle(theme.leagueTx)
                    .lineLimit(1)
                    .padding(.trailing, 60)
                    .padding(.bottom, 30)
                    .allowsHitTesting(false)
            }
        }
        .onExitCommand { handleBoardExit() }
        .onAppear {
            focusedRow = showSources ? firstRowID : detailFocusID
            // 1.4.4 (spec §1.2): the board-open fixture earns
            // its on-demand FotMob detail fetch — the store
            // guards (FotMob state, events still empty) and
            // no-ops for every other state.
            // 1.5.1 (FL-370): the LIVE state is passed, not the
            // tap-time snapshot — and the store's guard now
            // also refetches a live match whose cached detail
            // snapshot has expired, so an open board's event
            // list can keep growing past its first fetch.
            if let state = liveEntry.state {
                store.requestBoardDetail(for: state)
            }
        }
        .fullScreenCover(item: $playRequest) { request in
            TVPlayerView(
                resolution: request.resolution,
                switchContext: TVSwitchContext(
                    title: entry.headline,
                    vnSources: vnSources,
                    enItems: enItems,
                    initialENItemID: request.enItemID,
                    initialVNURL: request.vnURL,
                    makeVNResolution: { store.resolution(for: $0) },
                    makeENResolution: { nuvio.resolution(for: $0) }))
                .environment(\.tvTheme, theme)
        }
    }

    /// Classic board — the 1.6.0 code path (only the palette
    /// constants are read through the theme tokens, whose
    /// classic values ARE those constants), with the ONE
    /// sanctioned 1.7.4 change (owner ruling 2026-11-22
    /// 01:56 CST): the header stands on the detail first and
    /// the source sections open from one small button, the
    /// same flow as the other two themes. The sections
    /// themselves are untouched.
    private var classicBoard: some View {
        ZStack {
            theme.boardBG.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 26) {
                header
                if showSources {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 30) {
                            vnSection
                            if !enItems.isEmpty {
                                enSection
                            }
                        }
                        .padding(.bottom, 10)
                    }
                } else {
                    classicSourceButton
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 60)
            .padding(.top, 40)
            .padding(.bottom, 28)
        }
    }

    /// The classic detail's one small button: the source
    /// rows' own face (the classic arm of rowFaceBackground),
    /// the rows' own leading glyph, and the real source
    /// count at the right.
    private var classicSourceButton: some View {
        let focused = focusedRow == "classic:open"
        return Button {
            openSources()
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(focused ? theme.accent : .white.opacity(0.5))
                Text("Chọn nguồn")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(focused ? theme.accent : .white)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(totalSources) nguồn")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(rowFaceBackground(focused: focused, theme: theme))
        }
        .tvCardButton()
        .focused($focusedRow, equals: "classic:open")
    }

    // MARK: MU board (1.7.0 — IMPL-SPEC TVPlayerView section)

    /// The MU board backdrop (1.7.1 D1), shared verbatim by
    /// the open board and the 1.7.4 landing: the current MU
    /// wallpaper under a boardBG wash — the design's
    /// stadium-art slot, fed by the app's real wallpaper
    /// machinery — with the crimson gradient above it at
    /// reduced strength.
    private var muBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: [theme.unitedRed.opacity(0.10), theme.boardBG, .black],
                startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
        // 1.7.6 (FL-439): the wallpaper layer + its wash sit
        // in this backdrop's BACKGROUND, not its stack — the
        // same binding as the board root, the picker and the
        // design centre. As a sibling the photo negotiated
        // the board/landing stack's size (a taller-than-
        // stage image pushed the top bar off the edge); as
        // background content it is sized BY the backdrop.
        // Dim and wash values unchanged.
        .background {
            // The full backdrop stack, in the ORIGINAL
            // order — boardBG under the photo under its
            // wash (boardBG is opaque: left as a stack child
            // above this background it would hide the
            // photo). With no wallpaper the stack is boardBG
            // alone, exactly the old first child.
            ZStack {
                theme.boardBG
                if let url = muWallpaperURL {
                    TVMUWallpaperLayer(url: url, dim: 0.82)
                    theme.boardBG.opacity(0.55)
                }
            }
            .ignoresSafeArea()
        }
    }

    /// The open MU board (1.7.0/1.7.1 composition, verbatim):
    /// the info column + the source column side by side.
    /// 1.7.4: the timeline band now renders ONLY for a
    /// fixture WITH a matched state — before, the band drew
    /// its 0'/90' football scale unconditionally, so a
    /// no-state or non-football fixture wore a football
    /// timeline it has no data for (audit Q1 conviction).
    private var muBoard: some View {
        ZStack {
            muBackdrop
            VStack(alignment: .leading, spacing: 26) {
                muTopBar(board: true)
                HStack(alignment: .top, spacing: 22) {
                    muLeftColumn
                    // 1.7.1 (D1): vertical hairline divider
                    // between the columns (22 + divider + 22 =
                    // the old 45 total).
                    Rectangle()
                        .fill(Color.white.opacity(0.10))
                        .frame(width: 1)
                        .padding(.vertical, 6)
                    muRightColumn
                }
                // 1.7.7 (item c): a bound NBA state must not
                // switch ON the football 90-minute timeline.
                if liveEntry.state != nil, liveEntry.competition != .nba {
                    timelineBand
                }
            }
            .padding(.horizontal, 100)
            .padding(.top, 28)
            .padding(.bottom, 20)
        }
    }

    /// The MU Wally landing (1.7.4, S3): the board's own info
    /// column standing alone — same backdrop, same top bar
    /// (without the board's CHỌN NGUỒN caps), same timeline
    /// gate — with the column's one button opening the source
    /// list (muWatchButton's landing arm). The look is the
    /// shipped board's; only the source column moved behind
    /// the button, per the owner's ruling.
    private var muLanding: some View {
        ZStack {
            muBackdrop
            VStack(alignment: .leading, spacing: 26) {
                muTopBar(board: false)
                HStack(alignment: .top, spacing: 22) {
                    muLeftColumn
                    Spacer(minLength: 0)
                }
                // 1.7.7 (item c): same NBA timeline exclusion
                // as the MU board gate above.
                if liveEntry.state != nil, liveEntry.competition != .nba {
                    timelineBand
                }
            }
            .padding(.horizontal, 100)
            .padding(.top, 28)
            .padding(.bottom, 20)
        }
    }

    // MARK: Design Match Centre + board (1.7.4)

    /// "League · dd/MM/yyyy · HH:mm" — the fixture's own
    /// competition label and its device-local kickoff, shared
    /// by the Match Centre and the design board (the drawing's
    /// GMT+7 suffix is the mock's locale, not a design
    /// element; the app never prints a foreign zone). NO
    /// matchweek (answer Q8), NO stadium (Q2), NO Follow (Q3).
    private var boardMetadata: String {
        var parts = [entry.competitionLabel]
        if let kickoff = entry.channel.kickoff {
            parts.append(TVKickoffFormat.fullDate.string(from: kickoff))
            parts.append(TVKickoffFormat.time.string(from: kickoff))
        }
        return parts.joined(separator: " · ")
    }

    /// The Match Centre (delivery-united-tv-Match): the
    /// design header, the centred league + metadata lines,
    /// the giant central score between large crests, the
    /// scorer lines, ONE red CTA noting the real source
    /// count (disabled at zero sources), and — for football
    /// fixtures WITH a matched state only — the timeline.
    /// Every block sits in a FIXED slot (FL-360): a state
    /// landing on an open centre changes contents, never
    /// positions. The no-state form (answer Q1) centres "VS"
    /// + "Không có dữ liệu tỷ số", shows TRỰC TIẾP only when
    /// the fixture itself is live (never an invented minute),
    /// and drops scorers + timeline entirely; a missing crest
    /// is the team's initials tile, never a sport glyph.
    private var designCentre: some View {
        ZStack {
            LinearGradient(
                colors: [theme.boardBG.opacity(0.6), .clear,
                         theme.boardBG.opacity(0.85)],
                startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                TVDesignHeader()
                // 1.7.5 (RECALC-DABANH C3): the drawn back
                // line is in the Text colour, not Muted.
                Text("← Tất cả trận đấu")
                    .font(TVDesignFont.ui(21, .semibold))
                    .foregroundStyle(theme.teamTx)
                    .lineLimit(1)
                    .padding(.top, 26)
                centreLeagueBlock
                centreMainRow
                centreNamesRow
                centreScorersRow
                centreCTA
                Spacer(minLength: 0)
                // 1.7.7 (item c): same NBA timeline exclusion
                // as the MU board gates — no football timeline
                // for a bound basketball state.
                if liveEntry.state != nil, liveEntry.teams != nil,
                   liveEntry.competition != .nba {
                    designTimeline
                }
                // 1.7.5 (C14): the centre's fixed footer
                // bar — the drawing carries it; 1.7.4's
                // centre had none.
                TVDesignFooterBar(
                    position: wallpaperCounter.position,
                    count: wallpaperCounter.count,
                    focus: $focusedRow,
                    focusValue: "design:footer",
                    onChangeBackground: {
                        themeStore.cycleBackground(
                            count: wallpaperCounter.count)
                    })
                    .padding(.top, 16)
            }
            .padding(.horizontal, 100)
            .padding(.top, 28)
            .padding(.bottom, 24)
        }
        // 1.7.6 (FL-439): the wallpaper layer is this
        // surface's BACKGROUND, not a ZStack sibling — the
        // same binding as the board root and the picker. A
        // taller-than-stage photo (the set's 4:3 block, the
        // square crest) inflated the centre's stack exactly
        // as it did the board's, pushing the design header
        // off the top edge; as background content the photo
        // + its boardBG wash are sized BY the surface and
        // negotiate nothing. Dim and wash values unchanged.
        .background {
            // The full backdrop stack, in the ORIGINAL
            // order — boardBG under the photo under its
            // wash (boardBG is opaque: left as a ZStack
            // child it would hide the photo behind it).
            // With no wallpaper the stack is boardBG alone,
            // exactly the old first child.
            ZStack {
                theme.boardBG
                if let url = muWallpaperURL {
                    TVMUWallpaperLayer(url: url, dim: 0.5)
                    theme.boardBG.opacity(0.35)
                }
            }
            .ignoresSafeArea()
        }
    }

    private var centreLeagueBlock: some View {
        VStack(spacing: 8) {
            Text(entry.competitionLabel)
                .font(TVDesignFont.ui(17, .bold))
                .tracking(3)
                .foregroundStyle(theme.accent)
                .lineLimit(1)
            Text(boardMetadata)
                .font(TVDesignFont.ui(20))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var centreMainRow: some View {
        Group {
            if let teams = liveEntry.teams {
                HStack(alignment: .center, spacing: 0) {
                    TVDesignCrestSlot(url: liveEntry.displayCrests?.0 ?? nil,
                                      teamName: teams.0, size: 168, fontSize: 44)
                        .frame(width: 500)
                    centreScoreBlock
                        .frame(width: 420)
                    TVDesignCrestSlot(url: liveEntry.displayCrests?.1 ?? nil,
                                      teamName: teams.1, size: 168, fontSize: 44)
                        .frame(width: 500)
                }
                .frame(maxWidth: .infinity)
            } else {
                // Non-fixture entry: the channel's own art and
                // name, centred — no face-off exists to draw.
                VStack(spacing: 14) {
                    TVChannelLogo(channel: entry.channel, height: 110)
                    Text(entry.cleanTitle)
                        .font(TVDesignFont.ui(34, .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 250)
            }
        }
        .padding(.top, 26)
    }

    /// Score slot 176 + status slot 66, FIXED: the digits (or
    /// "VS") never move when the status line changes.
    private var centreScoreBlock: some View {
        VStack(spacing: 8) {
            Group {
                if let state = liveEntry.state,
                   let home = state.scoreHome, let away = state.scoreAway {
                    TVScoreDigits(home: home, away: away,
                                  size: 150, separator: " : ",
                                  design: true)
                } else {
                    Text("VS")
                        .font(TVDesignFont.display(150))
                        .foregroundStyle(.white)
                }
            }
            .frame(height: 176)
            centreStatusSlot
                .frame(height: 66, alignment: .top)
        }
    }

    @ViewBuilder
    private var centreStatusSlot: some View {
        let state = liveEntry.state
        if liveEntry.isLive {
            if let state, state.scoreHome != nil {
                HStack(spacing: 12) {
                    centreLivePill
                    if let minute = state.minuteText {
                        Text(minute)
                            .font(TVDesignFont.ui(22, .bold))
                            .foregroundStyle(theme.accent)
                    }
                }
            } else {
                // Live with no score data (Q1): the word, the
                // pill, and NO minute — the fixture says live,
                // nothing more is claimed.
                VStack(spacing: 8) {
                    Text("Không có dữ liệu tỷ số")
                        .font(TVDesignFont.ui(20))
                        .foregroundStyle(.white.opacity(0.6))
                    centreLivePill
                }
            }
        } else if let badge = liveEntry.badgeText {
            // Any non-live fixture carrying a badge renders
            // the badge — the board's arm 2, gated BEFORE
            // the score-less arm, so a score-less FT keeps
            // its "FT" instead of falling into the no-data
            // line (gate A-v3-1b).
            Text(badge)
                .font(TVDesignFont.ui(22, .bold))
                .foregroundStyle(theme.accent)
        } else if state?.scoreHome == nil {
            // Score-less or no state, not live, no badge:
            // the board's arm 3 composition — the no-data
            // line AND the kickoff line whenever a future
            // kickoff exists (gate A-v2-1). A nil state
            // lands here too (nil == nil), so the no-state
            // form carries the no-data line its Q1 doc
            // requires instead of the kickoff line alone
            // or nothing (gate A-v3-1a). Opacities are the
            // board's (0.7 / 1.0), aligned per Lens C's
            // N-2 note.
            VStack(spacing: 8) {
                Text("Không có dữ liệu tỷ số")
                    .font(TVDesignFont.ui(20))
                    .foregroundStyle(.white.opacity(0.7))
                if let kickoff = entry.channel.kickoff, kickoff > Date() {
                    Text("Khởi tranh " + TVKickoffFormat.time.string(from: kickoff))
                        .font(TVDesignFont.ui(20, .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        // Scored, non-live, badgeless (.pre / .postponed /
        // .cancelled carrying a score): nothing renders —
        // the board renders nothing for the same fixture.
    }

    private var centreLivePill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(.white)
                .frame(width: 9, height: 9)
            Text("TRỰC TIẾP")
                .font(TVDesignFont.ui(15, .heavy))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.liveRed))
    }

    private var centreNamesRow: some View {
        Group {
            if let teams = liveEntry.teams {
                HStack(alignment: .top, spacing: 0) {
                    centreNameBlock(name: teams.0, side: "ĐỘI NHÀ")
                        .frame(width: 500)
                    Color.clear.frame(width: 420)
                    centreNameBlock(name: teams.1, side: "ĐỘI KHÁCH")
                        .frame(width: 500)
                }
                .frame(maxWidth: .infinity)
            } else {
                Color.clear
            }
        }
        .frame(height: 122)
    }

    private func centreNameBlock(name: String, side: String) -> some View {
        VStack(spacing: 6) {
            Text(name)
                .font(TVDesignFont.ui(40, .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 96, alignment: .top)
            Text(side)
                .font(TVDesignFont.ui(15, .semibold))
                .tracking(2)
                .foregroundStyle(theme.leagueTx)
        }
    }

    /// The scorer lines under the names (FIXED slot): the
    /// matched state's goals per side, "Name 23'" joined —
    /// the state's own facts only.
    /// 1.7.6 (FL-437): the slot also carries each side's
    /// CARDS — until now the centre rendered goals only, so
    /// a match's yellow/red cards vanished on this surface
    /// while every other surface showed them (the owner's
    /// "Thiếu thông tin thẻ vàng thẻ đỏ"). The dress is the
    /// app's own TVEventColumns idiom carried into the
    /// centre: a card chip (r2.5, 12×16, theme.cardY/cardR)
    /// + "Name minute'" per card, under the side's goals.
    /// The slot is FIXED at 84 (goals two lines + the card
    /// line) as a CONSTANT — a state landing on an open
    /// centre changes contents, never positions (FL-360);
    /// the no-state form keeps the empty slot exactly as
    /// before.
    private var centreScorersRow: some View {
        Group {
            if let state = liveEntry.state, liveEntry.teams != nil {
                HStack(alignment: .top, spacing: 0) {
                    centreSideEvents(state: state, isHome: true)
                        .frame(width: 500)
                    Color.clear.frame(width: 420)
                    centreSideEvents(state: state, isHome: false)
                        .frame(width: 500)
                }
                .frame(maxWidth: .infinity)
            } else {
                Color.clear
            }
        }
        .frame(height: 84)
        .padding(.top, 10)
    }

    private func centreScorerText(_ goals: [MatchEvent]) -> some View {
        Text(goals.map { "\($0.playerName) \($0.minuteText)" }
                .joined(separator: " · "))
            .font(TVDesignFont.ui(20))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(2)
            .multilineTextAlignment(.center)
    }

    /// One side of the scorer slot: the goals text, then —
    /// when the side has cards — the card line. The card
    /// line is a RESERVED 24 pt row inside the fixed slot:
    /// with no cards it stays empty, so a card landing late
    /// (the board's FotMob detail upgrade) never moves the
    /// CTA below. Cap 2 cards + "+N", the TVEventColumns
    /// collapse carried to a single centred line.
    private func centreSideEvents(state: MatchState, isHome: Bool) -> some View {
        let cards = state.events.filter {
            $0.kind != .goal && $0.isHome == isHome
        }
        return VStack(spacing: 4) {
            centreScorerText(isHome ? state.homeGoals : state.awayGoals)
            Group {
                if cards.isEmpty {
                    Color.clear
                } else {
                    HStack(alignment: .center, spacing: 14) {
                        ForEach(Array(cards.prefix(2).enumerated()),
                                id: \.offset) { _, event in
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2.5)
                                    .fill(event.kind == .redCard
                                        ? theme.cardR : theme.cardY)
                                    .frame(width: 12, height: 16)
                                Text(event.playerName)
                                    .font(TVDesignFont.ui(18))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(1)
                                Text(event.minuteText)
                                    .font(TVDesignFont.ui(18, .semibold))
                                    .foregroundStyle(theme.leagueTx)
                                    .lineLimit(1)
                            }
                        }
                        if cards.count > 2 {
                            Text("+\(cards.count - 2)")
                                .font(TVDesignFont.ui(18))
                                .foregroundStyle(theme.leagueTx)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .frame(height: 24)
        }
    }

    /// The ONE red CTA: "▶ Xem trận đấu" + the real counts.
    /// It opens the source list (the owner's one-button
    /// ruling) — it never plays directly, so its destination
    /// is the board in every state. Round 1 review A-1
    /// reconciliation: the contracted set contains BOTH the
    /// Q3 line (CTA disabled at zero sources) AND the
    /// Detail-zero-sources state drawing; disabling the CTA
    /// made that drawing unreachable dead code, because this
    /// CTA is the board's only door. The ruling applied:
    /// the CTA stays focusable and opens the board at zero
    /// sources too — where the designed zero state renders —
    /// while its face drops the red fill for the muted tile
    /// fill (below), so it reads unavailable, and playback
    /// stays impossible (the board holds no rows). Q3's
    /// intent — no watch action at zero sources — holds;
    /// the zero-sources drawing is no longer dead.
    private var centreCTA: some View {
        let total = totalSources
        let focused = focusedRow == "design:cta"
        return HStack {
            Spacer(minLength: 0)
            Button {
                openSources()
            } label: {
                HStack(spacing: 14) {
                    Text("▶ Xem trận đấu")
                        .font(TVDesignFont.ui(21, .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(total) nguồn · \(selectableSources) có thể chọn")
                        .font(TVDesignFont.ui(14))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                .padding(.horizontal, 20)
                // 1.7.5 (RECALC-DABANH C10/C11): the drawn
                // CTA is 373 × 56 with text ≈21/14 — the
                // 1.7.4 build's 470 × 64 / 23/15 came from
                // the superseded capture, not the delivered
                // drawing.
                .frame(width: 373, height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(total == 0 ? theme.tileBG : theme.unitedRed)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(focused ? theme.focusRing : .clear,
                                              lineWidth: 3)))
            }
            .tvCardButton()
            .focused($focusedRow, equals: "design:cta")
            Spacer(minLength: 0)
        }
        .padding(.top, 30)
    }

    /// The centre timeline (football fixtures WITH state
    /// only — the caller gates it): hairline, "Diễn biến",
    /// the track with red progress to the state's own minute
    /// and gold dots at GOAL minutes, each labelled with its
    /// minute + scorer beneath — and, since 1.7.6 (FL-437),
    /// card chips on the track at CARD minutes. Positions
    /// are the parsed minutes on the 90-minute scale — the
    /// shipped band's honest scale; no 0'/90' edge labels
    /// (the drawing has none here).
    private var designTimeline: some View {
        let state = liveEntry.state
        let goals: [(minute: Int, text: String, name: String)] =
            (state?.goals ?? [])
                .compactMap { event in
                    Self.parsedMinute(event.minuteText).map {
                        (minute: $0, text: event.minuteText,
                         name: event.playerName)
                    }
                }
                .sorted { $0.minute < $1.minute }
        // 1.7.6 (FL-437): the band's card events — the same
        // parsed-minute scale, drawn as chips on the track
        // (the Wally timelineBand's idiom: r2, 8×12,
        // theme.cardY/cardR, no label; the label band below
        // stays goals-only, exactly as the band's).
        let cards: [(minute: Int, red: Bool)] =
            (state?.events ?? [])
                .filter { $0.kind != .goal }
                .compactMap { event in
                    Self.parsedMinute(event.minuteText).map {
                        (minute: $0, red: event.kind == .redCard)
                    }
                }
                .sorted { $0.minute < $1.minute }
        let liveMinute = Self.parsedMinute(state?.minuteText)
        return VStack(alignment: .leading, spacing: 12) {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
            Text("Diễn biến")
                .font(TVDesignFont.ui(20, .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.15))
                        .frame(height: 3)
                    if let liveMinute {
                        Rectangle()
                            .fill(theme.unitedRed)
                            .frame(width: geo.size.width
                                * CGFloat(min(max(liveMinute, 0), 90)) / 90,
                                   height: 3)
                    }
                    ForEach(Array(goals.enumerated()), id: \.offset) { _, goal in
                        Circle()
                            .fill(theme.accent)
                            .frame(width: 11, height: 11)
                            .position(x: geo.size.width
                                * CGFloat(min(max(goal.minute, 0), 90)) / 90,
                                      y: geo.size.height / 2)
                    }
                    ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(card.red ? theme.cardR : theme.cardY)
                            .frame(width: 8, height: 12)
                            .position(x: geo.size.width
                                * CGFloat(min(max(card.minute, 0), 90)) / 90,
                                      y: geo.size.height / 2)
                    }
                }
            }
            .frame(height: 20)
            GeometryReader { geo in
                ZStack {
                    ForEach(Array(goals.enumerated()), id: \.offset) { _, goal in
                        VStack(spacing: 2) {
                            Text(goal.text)
                                .font(TVDesignFont.ui(16))
                                .foregroundStyle(theme.leagueTx)
                                .lineLimit(1)
                            Text(goal.name)
                                .font(TVDesignFont.ui(18))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        .frame(width: 190)
                        .position(x: min(max(geo.size.width
                            * CGFloat(min(max(goal.minute, 0), 90)) / 90, 95),
                                         geo.size.width - 95),
                                  y: geo.size.height / 2)
                    }
                }
            }
            .frame(height: 52)
        }
    }

    /// The design source board (delivery-united-tv-Detail):
    /// the design header + "← Trận đấu", the info column
    /// left (headline per Q4, crest row, status, the two
    /// factual guidance lines), the source list right under
    /// "Chọn nguồn phát" with per-group counts, the Q5 health
    /// lines, and the verbatim unchecked-sources note. Both
    /// groups always render — at zero sources they stand at
    /// 0 with the drawing's empty message.
    private var designBoard: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 22) {
                TVDesignHeader()
                // 1.7.5 (C3 family): the board's back line
                // takes the Text colour too — the same drawn
                // element as the centre's.
                Text("← Trận đấu")
                    .font(TVDesignFont.ui(21, .semibold))
                    .foregroundStyle(theme.teamTx)
                    .lineLimit(1)
                HStack(alignment: .top, spacing: 22) {
                    designLeftColumn
                    Rectangle()
                        .fill(Color.white.opacity(0.10))
                        .frame(width: 1)
                        .padding(.vertical, 6)
                    designRightColumn
                }
            }
            .padding(.horizontal, 100)
            .padding(.top, 28)
            .padding(.bottom, 20)
        }
        // 1.7.6 (FL-439): the wallpaper layer + wash are
        // this board's BACKGROUND — the same binding as the
        // board root, the picker, the centre and the MU
        // backdrop. As ZStack siblings they negotiated the
        // stack's size; as background content they are sized
        // BY it. Dim and wash values unchanged.
        .background {
            // The full backdrop stack, in the ORIGINAL
            // order — boardBG under the photo under its
            // wash (boardBG is opaque: left as a ZStack
            // child it would hide the photo). With no
            // wallpaper the stack is boardBG alone, exactly
            // the old first child.
            ZStack {
                theme.boardBG
                if let url = muWallpaperURL {
                    TVMUWallpaperLayer(url: url, dim: 0.82)
                    theme.boardBG.opacity(0.55)
                }
            }
            .ignoresSafeArea()
        }
    }

    /// Q4 headline size: the design's system heavy 50, down
    /// to its 40 floor for long names; names wrap at word
    /// boundaries inside the same two-column budget — the
    /// column never widens and nothing is truncated
    /// mid-word.
    private var designHeadlineSize: CGFloat {
        guard let teams = liveEntry.teams else { return 40 }
        return max(teams.0.count, teams.1.count) > 20 ? 40 : 50
    }

    private var designLeftColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(entry.competitionLabel)
                .font(TVDesignFont.ui(17, .bold))
                .tracking(3)
                .foregroundStyle(theme.accent)
                .lineLimit(1)
            Group {
                if let teams = liveEntry.teams {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(teams.0.uppercased())
                            .font(.system(size: designHeadlineSize, weight: .heavy))
                            .foregroundStyle(.white)
                            .lineLimit(3)
                        Text("vs")
                            .font(TVDesignFont.ui(20, .semibold))
                            .foregroundStyle(theme.leagueTx)
                        Text(teams.1.uppercased())
                            .font(.system(size: designHeadlineSize, weight: .heavy))
                            .foregroundStyle(.white)
                            .lineLimit(3)
                    }
                } else {
                    Text(liveEntry.headline)
                        .font(TVDesignFont.ui(40, .bold))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                }
            }
            Text(boardMetadata)
                .font(TVDesignFont.ui(20))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
            designBoardCrestRow
            designBoardStatus
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 6) {
                Text("Có thể đổi nguồn trong trình phát.")
                Text("Nguồn Tiếng Việt hiển thị trước English.")
            }
            .font(TVDesignFont.ui(19))
            .foregroundStyle(theme.leagueTx)
        }
        .frame(width: 580, alignment: .leading)
    }

    @ViewBuilder
    private var designBoardCrestRow: some View {
        if let teams = liveEntry.teams {
            HStack(alignment: .center, spacing: 28) {
                TVDesignCrestSlot(url: liveEntry.displayCrests?.0 ?? nil,
                                  teamName: teams.0, size: 92, fontSize: 32)
                Group {
                    if let state = liveEntry.state,
                       let home = state.scoreHome, let away = state.scoreAway {
                        TVScoreDigits(home: home, away: away,
                                      size: 64, separator: " : ",
                                      design: true)
                    } else {
                        Text("VS")
                            .font(TVDesignFont.display(56))
                            .foregroundStyle(.white)
                    }
                }
                TVDesignCrestSlot(url: liveEntry.displayCrests?.1 ?? nil,
                                  teamName: teams.1, size: 92, fontSize: 32)
                Spacer(minLength: 0)
            }
            .frame(height: 96)
        } else {
            TVChannelLogo(channel: entry.channel, height: 84)
                .frame(height: 96, alignment: .leading)
        }
    }

    @ViewBuilder
    private var designBoardStatus: some View {
        if liveEntry.isLive {
            HStack(spacing: 12) {
                centreLivePill
                if let minute = liveEntry.state?.minuteText {
                    Text(minute)
                        .font(TVDesignFont.ui(22, .bold))
                        .italic()
                        .foregroundStyle(theme.accent)
                }
            }
            .frame(height: 34, alignment: .leading)
        } else if let badge = liveEntry.badgeText {
            Text(badge)
                .font(TVDesignFont.ui(22, .bold))
                .foregroundStyle(theme.accent)
                .frame(height: 34, alignment: .leading)
        } else if liveEntry.state?.scoreHome == nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("Không có dữ liệu tỷ số")
                    .font(TVDesignFont.ui(20))
                    .foregroundStyle(.white.opacity(0.7))
                if let kickoff = entry.channel.kickoff, kickoff > Date() {
                    Text("Khởi tranh " + TVKickoffFormat.time.string(from: kickoff))
                        .font(TVDesignFont.ui(20, .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private var designRightColumn: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Chọn nguồn phát")
                        .font(TVDesignFont.ui(44, .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(totalSources) nguồn · \(selectableSources) có thể chọn")
                        .font(TVDesignFont.ui(20))
                        .foregroundStyle(theme.leagueTx)
                        .lineLimit(1)
                }
                designVNGroup
                designENGroup
                if totalSources == 0 {
                    VStack(alignment: .leading, spacing: 18) {
                        Rectangle()
                            .fill(Color.white.opacity(0.12))
                            .frame(height: 1)
                        Text("Chưa có nguồn phát cho trận đấu này. Quay lại để chọn trận khác.")
                            .font(TVDesignFont.ui(20))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(2)
                    }
                }
                Text("\"Có thể chọn\" bao gồm nguồn chưa kiểm tra; không xác nhận đang phát.")
                    .font(TVDesignFont.ui(17))
                    .italic()
                    .foregroundStyle(theme.leagueTx)
                    .lineLimit(2)
            }
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var designVNGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            designBoardGroupHeader(
                title: "Tiếng Việt", total: vnSources.count,
                selectable: vnSources.filter {
                    SourceHealth.status(for: $0.url) != .dead
                }.count)
            ForEach(Array(vnSources.enumerated()), id: \.offset) { index, ch in
                Button {
                    playRequest = BoardPlayRequest(
                        resolution: store.resolution(for: ch), enItemID: nil,
                        vnURL: ch.url)
                } label: {
                    TVDesignSourceRow(
                        title: MatchTitle.clean(ch.title),
                        detail: ch.group,
                        isPrimary: index == 0,
                        isVN: true,
                        chipChannel: ch,
                        healthText: tvSourceHealthText(for: ch.url),
                        unavailable: SourceHealth.status(for: ch.url) == .dead,
                        playing: false,
                        focused: focusedRow == "vn:" + ch.url,
                        theme: theme)
                }
                .tvCardButton()
                .focused($focusedRow, equals: "vn:" + ch.url)
            }
        }
    }

    private var designENGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            designBoardGroupHeader(title: "English", total: enItems.count,
                                   selectable: enItems.count)
            ForEach(enItems) { item in
                Button {
                    playRequest = BoardPlayRequest(
                        resolution: nuvio.resolution(for: item), enItemID: item.id,
                        vnURL: nil)
                } label: {
                    TVDesignSourceRow(
                        title: item.league ?? item.displayName,
                        detail: item.league != nil ? item.displayName : "Nuvio",
                        isPrimary: false,
                        isVN: false,
                        chipChannel: item.poster.isEmpty ? nil : item.displayChannel,
                        healthText: "Chưa kiểm tra",
                        unavailable: false,
                        playing: false,
                        focused: focusedRow == "nv:" + item.id,
                        theme: theme)
                }
                .tvCardButton()
                .focused($focusedRow, equals: "nv:" + item.id)
            }
        }
    }

    private func designBoardGroupHeader(title: String, total: Int,
                                        selectable: Int) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(TVDesignFont.ui(24, .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(total) nguồn · \(selectable) có thể chọn")
                .font(TVDesignFont.ui(17))
                .foregroundStyle(theme.leagueTx)
                .lineLimit(1)
        }
    }

    /// The wallpaper counter for the design footer bar
    /// (1.7.5): the shared list's count + the persisted
    /// choice's 1-based position in it (0 when the list is
    /// empty — the bar then hides its control).
    private var wallpaperCounter: (position: Int, count: Int) {
        let images = Wallpapers.images()
        guard !images.isEmpty else { return (0, 0) }
        let count = images.count
        return (((themeStore.bgIndex % count) + count) % count + 1, count)
    }

    /// The current MU wallpaper, if any: the shared list in
    /// file order, indexed by the persisted choice (the same
    /// resolution the home background uses). Empty list → nil
    /// (gradient only, fail-open).
    private var muWallpaperURL: URL? {
        let images = Wallpapers.images()
        guard !images.isEmpty else { return nil }
        let count = images.count
        return images[((themeStore.bgIndex % count) + count) % count]
    }

    /// The MU top bar: the back label left; the board's
    /// CHỌN NGUỒN caps at the right ONLY on the open board
    /// (1.7.4: the landing has not opened the list yet, so
    /// the caps would name a screen the viewer is not on).
    private func muTopBar(board: Bool) -> some View {
        HStack(alignment: .center, spacing: 14) {
            // Non-focusable label — Menu is the real exit
            // (.onExitCommand on the board, unchanged).
            Text("← Tất cả trận")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(theme.leagueTx)
                .lineLimit(1)
            Spacer(minLength: 0)
            // 1.7.1 (D2): the centre title is REMOVED and the
            // live badge leaves the top row (the left column's
            // status row carries it); the right slot is the
            // design's coverage caps in app language.
            if board {
                Text("CHỌN NGUỒN")
                    .font(.system(size: 17, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(theme.leagueTx)
                    .lineLimit(1)
            }
            // 1.7.6 (FL-441, RECALC-DABANH RULING 1): the
            // compact brand wordmark at the bar's right end —
            // 21 semibold in THIS bar's own face and size,
            // "Joe" white, " Soccer" in the Wally gold
            // (theme.accent). It rides the bar's fixed 39 pt
            // height; the caps keep their place ahead of it
            // on the open board, and the landing (no caps)
            // gains the wordmark in the same slot. The gap
            // after the caps is the ruling's 18 pt: the
            // bar's own 14 spacing + 4 of leading padding
            // here (gate Round 1, Lens B — the first pass
            // shipped the bare 14).
            (Text("Joe").foregroundStyle(.white)
                + Text(" Soccer").foregroundStyle(theme.accent))
                .font(.system(size: 21, weight: .semibold))
                .lineLimit(1)
                .padding(.leading, board ? 4 : 0)
        }
        .frame(height: 39)
    }

    private var muLeftColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 1.7.1 (D3): league caps at design scale.
            Text(entry.competitionLabel)
                .font(.system(size: 17, weight: .bold))
                .tracking(3)
                .foregroundStyle(theme.accent)
                .lineLimit(1)
            // 1.7.1 (D3): headline slot FIXED 278 in every
            // state (FL-360) — name block 124 (50 pt heavy,
            // 2 lines) + VS row 30 + name block 124, spacings
            // 0. The non-fixture headline fallback occupies
            // the same slot. Matchweek has no datum (OMIT).
            Group {
                if let teams = liveEntry.teams {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(teams.0)
                            .font(.system(size: 50, weight: .heavy))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .frame(height: 124, alignment: .leading)
                        Text("VS")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(theme.minuteRed.opacity(0.55))
                            .frame(height: 30, alignment: .leading)
                        Text(teams.1)
                            .font(.system(size: 50, weight: .heavy))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .frame(height: 124, alignment: .leading)
                    }
                } else {
                    Text(liveEntry.headline)
                        .font(.system(size: 50, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 278, alignment: .topLeading)
            // 1.7.1 (D4): crest pair (96) flanking the score.
            // FL-360: the row height is FIXED 96 in every
            // state — with a score, without a score, live or
            // not — so nothing below ever moves when the
            // score lands.
            HStack(alignment: .center, spacing: 28) {
                if let crests = liveEntry.displayCrests {
                    TVCrestImage(url: crests.0, size: 96)
                }
                Group {
                    if let state = liveEntry.state,
                       let home = state.scoreHome, let away = state.scoreAway {
                        TVScoreDigits(home: home, away: away,
                                      size: 64, separator: " : ")
                    } else {
                        Color.clear
                    }
                }
                .frame(height: 96)
                if let crests = liveEntry.displayCrests {
                    TVCrestImage(url: crests.1, size: 96)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 96)
            // 1.7.0 fix round 1 (FL-360): the LIVE/badge row's
            // container is ALWAYS rendered at a FIXED height
            // of 32 pt in every state (empty = clear), so a
            // badge appearing never shifts the column below.
            // 32 pt = the row's tallest current content: the
            // LIVE capsule — 20 pt text (≈24 pt line) + 4 + 4
            // vertical padding = 32 — which covers the 24 pt
            // badge/minute text (≈29 pt line) in the other
            // states.
            Group {
                if liveEntry.isLive {
                    HStack(spacing: 12) {
                        Text("LIVE")
                            .font(.system(size: 20, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(theme.liveRed))
                        if let minute = liveEntry.state?.minuteText {
                            Text(minute)
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(theme.accent)
                        }
                    }
                } else if let badge = liveEntry.badgeText {
                    Text(badge)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(theme.accent)
                } else {
                    Color.clear
                }
            }
            .frame(height: 32)
            if let state = liveEntry.state {
                if !state.events.isEmpty {
                    TVEventColumns(state: state)
                } else if state.status == .live || state.status == .ht {
                    // Classic reservation rule: a live board
                    // whose events have not landed reserves the
                    // event columns' fullest height (121).
                    Color.clear
                        .frame(height: 121)
                }
            }
            if !(vnSources.isEmpty && enItems.isEmpty) {
                muWatchButton
                Text("Nguồn tiếng Việt được xếp trước · đổi nguồn ngay trong lúc xem")
                    .font(.system(size: 19))
                    .foregroundStyle(theme.leagueTx)
                    .lineLimit(2)
            }
            // NO Follow button, NO venue block (SURVEY-B register
            // items 1 / spec): no such feature / datum exists.
        }
        .frame(width: 580, alignment: .leading)
    }

    /// The board column's red button. On the OPEN board its
    /// action is EXACTLY the first source row's action (VN
    /// first if any, else the first EN item), building the
    /// same BoardPlayRequest that row builds — the shipped
    /// behaviour, verbatim. On the 1.7.4 LANDING the same
    /// face is the detail's ONE small button: it opens the
    /// source list and says so ("▶ Chọn nguồn"). The button
    /// is omitted by the caller when both lists are empty.
    @ViewBuilder
    private var muWatchButton: some View {
        let total = vnSources.count + enItems.count
        let focused = focusedRow == "mu:watch"
        Button {
            if !showSources {
                openSources()
            } else if let ch = vnSources.first {
                playRequest = BoardPlayRequest(
                    resolution: store.resolution(for: ch), enItemID: nil,
                    vnURL: ch.url)
            } else if let item = enItems.first {
                playRequest = BoardPlayRequest(
                    resolution: nuvio.resolution(for: item), enItemID: item.id,
                    vnURL: nil)
            }
        } label: {
            // 1.7.1 (D7): the design's two-part label — the
            // action left, the source count small at the right.
            HStack(spacing: 12) {
                Text(showSources ? "▶ Xem ngay" : "▶ Chọn nguồn")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(total) nguồn")
                    .font(.system(size: 19))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .frame(minWidth: 340, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(
                        colors: [theme.unitedRed, theme.minuteRed],
                        startPoint: .leading, endPoint: .trailing))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(focused ? theme.focusRing : .clear,
                                          lineWidth: 3)))
        }
        .tvCardButton()
        .focused($focusedRow, equals: "mu:watch")
    }

    private var muRightColumn: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                muVNSection
                if !enItems.isEmpty {
                    muENSection
                }
                // 1.7.1 (D11): app-truth bottom note — 1.6.0's
                // auto-failover described in the design's slot.
                // Rendered when at least one section exists.
                if !(vnSources.isEmpty && enItems.isEmpty) {
                    Text("ⓘ Nguồn nào lỗi, máy sẽ tự chuyển nguồn khác.")
                        .font(.system(size: 19))
                        .foregroundStyle(theme.leagueTx)
                        .lineLimit(2)
                }
            }
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: MU sections (1.7.1 — D9/D10; the classic
    // vnSection / enSection / rowFace above the board's MARK
    // Sections stay untouched and shared with the classic board)

    private enum MUSourceGroup { case vn, en }

    private var muVNSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            muGroupHeader(isVN: true, title: "Tiếng Việt",
                          count: vnSources.count)
            ForEach(Array(vnSources.enumerated()), id: \.offset) { index, ch in
                Button {
                    playRequest = BoardPlayRequest(
                        resolution: store.resolution(for: ch), enItemID: nil,
                        vnURL: ch.url)
                } label: {
                    muRowFace(title: MatchTitle.clean(ch.title),
                              detail: ch.group,
                              focused: focusedRow == "vn:" + ch.url,
                              theme: theme,
                              logoChannel: ch,
                              isPrimary: index == 0,
                              group: .vn)
                }
                .tvCardButton()
                .focused($focusedRow, equals: "vn:" + ch.url)
            }
        }
    }

    private var muENSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            muGroupHeader(isVN: false, title: "Tiếng Anh",
                          count: enItems.count)
            ForEach(enItems) { item in
                Button {
                    playRequest = BoardPlayRequest(
                        resolution: nuvio.resolution(for: item), enItemID: item.id,
                        vnURL: nil)
                } label: {
                    muRowFace(title: item.league ?? item.displayName,
                              detail: item.league != nil ? item.displayName : "Nuvio",
                              focused: focusedRow == "nv:" + item.id,
                              theme: theme,
                              // Same logo rule as the classic
                              // EN section: chip source only when
                              // a poster URL actually exists.
                              logoChannel: item.poster.isEmpty ? nil : item.displayChannel,
                              isPrimary: false,
                              group: .en)
                }
                .tvCardButton()
                .focused($focusedRow, equals: "nv:" + item.id)
            }
        }
    }

    /// 1.7.1 (D9): MU group header — maroon chip (letters for
    /// VN, globe for EN) + name + the VN priority marker; the
    /// real source count at the right. NO quality pill, NO
    /// signal bars anywhere in these sections (SURVEY-B
    /// register items 2–3 stand).
    private func muGroupHeader(isVN: Bool, title: String, count: Int) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.tileFocusedBG)
                if isVN {
                    Text("VI")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.cream)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.cream)
                }
            }
            .frame(width: 30, height: 30)
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if isVN {
                Text("Ưu tiên")
                    .font(.system(size: 17))
                    .foregroundStyle(theme.accent)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("\(count) nguồn")
                .font(.system(size: 19))
                .foregroundStyle(theme.leagueTx)
                .lineLimit(1)
        }
    }

    /// 1.7.1 (D10): MU source row. The logo chip slot is FIXED
    /// 68×52 in every row (FL-360) — light tile always reserved;
    /// the logo image rides inside when one exists, else a dark
    /// play glyph. The face is the existing MU arm of
    /// rowFaceBackground (shared, not copied).
    private func muRowFace(title: String, detail: String, focused: Bool,
                           theme: TVThemeTokens,
                           logoChannel: Channel? = nil,
                           isPrimary: Bool, group: MUSourceGroup) -> some View {
        // VN sub-line carries the position-derived primary /
        // backup suffix (real: the first row IS the primary);
        // EN keeps its detail verbatim.
        let sub: String
        switch group {
        case .vn:
            let suffix = isPrimary ? "Nguồn chính" : "Nguồn dự phòng"
            sub = detail.isEmpty ? suffix : detail + " · " + suffix
        case .en:
            sub = detail
        }
        return HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.92))
                if let logoChannel, logoChannel.logoURL != nil {
                    TVChannelLogo(channel: logoChannel, height: 44)
                } else {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.black.opacity(0.55))
                }
            }
            .frame(width: 68, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    // 1.7.2 (audit M17): the design keeps the
                    // focused row's title WHITE — the gold
                    // lives in the border and the ▶.
                    Text(title)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if group == .vn && isPrimary {
                        Text("KHUYÊN DÙNG")
                            .font(.system(size: 15, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(theme.accent)
                            .lineLimit(1)
                    }
                }
                Text(sub)
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .frame(height: 26, alignment: .leading)
            }
            Spacer(minLength: 0)
            // Trailing slot FIXED 30: gold play on focus, the
            // design's grey arrow otherwise.
            Image(systemName: focused ? "play.fill" : "arrow.right")
                .font(.system(size: 20))
                .foregroundStyle(focused ? theme.accent : .white.opacity(0.35))
                .frame(width: 30)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(rowFaceBackground(focused: focused, theme: theme))
    }

    /// First integer run of a minute text ("45'+3'" -> 45,
    /// "61'" -> 61); nil when the text carries no leading
    /// minute — the caller then draws nothing for it (never
    /// fabricates a position).
    private static func parsedMinute(_ text: String?) -> Int? {
        guard let text else { return nil }
        let digits = text.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    /// FIXED 84 pt slot (FL-360) whenever it renders — and
    /// since 1.7.4 it renders only for a fixture WITH a
    /// matched state (the call sites gate it; see muBoard):
    /// title 20 + track 20 + label row 24 with 10 pt spacings.
    /// Track + end labels always; the progress portion, the
    /// event dots and the goal/"Now" labels come only from
    /// real parsed minutes.
    private var timelineBand: some View {
        let state = liveEntry.state
        let liveMinute = Self.parsedMinute(state?.minuteText)
        // 1.7.1 (D12): goal labels — goal events with parsed
        // minutes, sorted; a label is skipped when the previous
        // LABELLED goal is < 6 min away (its dot always stays).
        // "Now" shows at the live minute when no labelled goal
        // sits within 6 min of it.
        let goalEvents: [(minute: Int, text: String)] = (state?.events ?? [])
            .filter { $0.kind == .goal }
            .compactMap { event in
                Self.parsedMinute(event.minuteText)
                    .map { (minute: $0, text: event.minuteText) }
            }
            .sorted { $0.minute < $1.minute }
        var labelledGoals: [(minute: Int, text: String)] = []
        for goal in goalEvents {
            if let last = labelledGoals.last, goal.minute - last.minute < 6 {
                continue
            }
            labelledGoals.append(goal)
        }
        let showNow = liveMinute.map { minute in
            !labelledGoals.contains { abs($0.minute - minute) < 6 }
        } ?? false
        return VStack(alignment: .leading, spacing: 10) {
            Text("DIỄN BIẾN")
                .font(.system(size: 15, weight: .semibold))
                .tracking(2)
                .foregroundStyle(theme.leagueTx)
                .lineLimit(1)
                .frame(height: 20, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(theme.eventsLine)
                        .frame(height: 3)
                    if let liveMinute {
                        Rectangle()
                            .fill(theme.unitedRed)
                            .frame(width: geo.size.width
                                * CGFloat(min(max(liveMinute, 0), 90)) / 90,
                                   height: 3)
                    }
                    if let state {
                        ForEach(Array(state.events.enumerated()), id: \.offset) { _, event in
                            if let minute = Self.parsedMinute(event.minuteText) {
                                let x = geo.size.width
                                    * CGFloat(min(max(minute, 0), 90)) / 90
                                Group {
                                    if event.kind == .goal {
                                        Circle()
                                            .fill(theme.accent)
                                            .frame(width: 11, height: 11)
                                    } else {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(event.kind == .redCard
                                                ? theme.cardR : theme.cardY)
                                            .frame(width: 8, height: 12)
                                    }
                                }
                                .position(x: x, y: geo.size.height / 2)
                            }
                        }
                    }
                }
            }
            .frame(height: 20)
            // Label row FIXED 24 (D12): end labels at the
            // edges; goal-minute labels and "Now" centred on
            // their track x. Every label is lineLimit 1 in the
            // fixed row — the band never resizes (FL-360).
            GeometryReader { geo in
                let width = geo.size.width
                ZStack {
                    HStack {
                        Text("0'")
                            .font(.system(size: 16))
                            .foregroundStyle(theme.leagueTx)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text("90'")
                            .font(.system(size: 16))
                            .foregroundStyle(theme.leagueTx)
                            .lineLimit(1)
                    }
                    ForEach(Array(labelledGoals.enumerated()), id: \.offset) { _, goal in
                        Text(goal.text)
                            .font(.system(size: 15))
                            .foregroundStyle(theme.accent)
                            .lineLimit(1)
                            .position(x: min(max(width
                                * CGFloat(min(max(goal.minute, 0), 90)) / 90, 26),
                                             width - 26),
                                      y: geo.size.height / 2)
                    }
                    if showNow, let liveMinute {
                        Text("Now")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(theme.accent)
                            .lineLimit(1)
                            .position(x: min(max(width
                                * CGFloat(min(max(liveMinute, 0), 90)) / 90, 26),
                                             width - 26),
                                      y: geo.size.height / 2)
                    }
                }
            }
            .frame(height: 24)
        }
        .frame(height: 84)
    }

    // MARK: Header (the full cluster, §2.4 as amended 2026-11-21)

    /// 1.5.1 (FL-370): the board's entry is a value snapshot
    /// taken when the fixture was tapped — before this fix the
    /// header read that frozen copy forever, so a detail
    /// upgrade landing in the store while the board stood open
    /// (more scorers, the cards) never reached the screen the
    /// owner was looking at. The header now resolves the
    /// fixture's CURRENT bound state from the store on every
    /// render (PlaylistStore republishes on state changes, so
    /// the board tracks the match live), falling back to the
    /// snapshot when the store has nothing bound.
    private var liveEntry: TVFixtureEntry {
        var e = entry
        if let s = store.matchState(for: entry.channel) {
            e.state = s
        }
        return e
    }

    /// The crest pair row (1.5.1, FL-370): the board header
    /// carried NO crest slots at all before this fix — the
    /// tiles and the hero render displayCrests, the board
    /// never did, which is half of the owner's "mất logo"
    /// verdict. Fixed 92 pt slots, home left / away right —
    /// the same x positions in every state, so a state change
    /// never moves them.
    @ViewBuilder
    private var crestRow: some View {
        if let crests = liveEntry.displayCrests {
            HStack(alignment: .center) {
                TVCrestImage(url: crests.0, size: 92)
                Spacer(minLength: 0)
                TVCrestImage(url: crests.1, size: 92)
            }
            .frame(height: 92)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                Text(entry.competitionLabel)
                    .font(.system(size: 19, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(theme.leagueTx)
                    .lineLimit(1)
                Spacer(minLength: 0)
                // 1.7.6 (FL-441, RECALC-DABANH RULING 1):
                // the compact brand wordmark at the right
                // end of the header's first row, LEFT of the
                // live badge — 21 semibold in this header's
                // own face, "Joe" white, " Soccer" in the
                // Classic sky (theme.accent). The row's fixed
                // 39 pt height (FL-360) already fits it; the
                // badge keeps its place and its height.
                (Text("Joe").foregroundStyle(.white)
                    + Text(" Soccer").foregroundStyle(theme.accent))
                    .font(.system(size: 21, weight: .semibold))
                    .lineLimit(1)
                if let badge = liveEntry.badgeText {
                    Text(badge)
                        .font(.system(size: 25, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(liveEntry.state?.status == .ht
                                ? theme.htAmber : theme.minuteRed))
                }
            }
            // 1.4.9 (FL-360, audit S-4): the first row holds the
            // badge's height (25 pt line + its padding ≈ 39)
            // whether or not a badge is showing, so a badge
            // can never push the headline row down inside the
            // header cluster.
            .frame(height: 39)
            HStack(alignment: .center, spacing: 22) {
                Text(entry.headline)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Spacer(minLength: 0)
                // 1.5.0: the kickoff keeps its place on the
                // headline row in EVERY state — in 1.4.9 the
                // score text displaced it, so a live board
                // showed no kickoff at all. The score itself
                // moves to the full block below.
                if let kickoff = entry.channel.kickoff {
                    Text(TVKickoffFormat.timeDay.string(from: kickoff))
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .lineLimit(1)
                }
            }
            // 1.5.0 (owner redesign ruling): the FULL score
            // block — the same rendering the hero carried in
            // 1.4.7–1.4.9 (TVScoreDigits + TVEventColumns,
            // TVMatchViews): digits, then the per-side event
            // columns with every scorer and the card lines.
            // It replaces the two-goal-lines-plus-card-counts
            // summary this header showed before: inside the
            // board is where the full info belongs ("vào
            // trong thì hiện đủ thông tin").
            if let state = liveEntry.state,
               let home = state.scoreHome, let away = state.scoreAway {
                VStack(alignment: .leading, spacing: 12) {
                    // 1.5.1 (FL-370): the crests flank the
                    // digits — home crest, score, away crest,
                    // the board family's own crest-vs-crest
                    // idiom (TVLiveBoardView). The digits keep
                    // their centred place; the crest slots are
                    // a fixed 92 pt, inside the reservations
                    // below, so their presence moves nothing.
                    HStack(alignment: .center, spacing: 28) {
                        if let crests = liveEntry.displayCrests {
                            TVCrestImage(url: crests.0, size: 92)
                        }
                        Spacer(minLength: 0)
                        TVScoreDigits(home: home, away: away)
                        Spacer(minLength: 0)
                        if let crests = liveEntry.displayCrests {
                            TVCrestImage(url: crests.1, size: 92)
                        }
                    }
                    if !state.events.isEmpty {
                        TVEventColumns(state: state)
                    } else if state.status == .live || state.status == .ht {
                        // The S-4 reservation at the full
                        // block's size: a live board whose
                        // events have not landed reserves the
                        // event columns' fullest height (121),
                        // so the first goal/card arriving can
                        // never push the source rows below
                        // while the owner is reading them. A
                        // finished board reserves nothing: its
                        // events are final, and the space
                        // would be dead.
                        Color.clear
                            .frame(height: 121)
                    }
                }
            } else if liveEntry.state?.status == .live || liveEntry.state?.status == .ht {
                // A live board whose SCORE has not landed
                // either: reserve the whole block (digits 86
                // + spacing 12 + event area 121 = 219), so
                // its arrival moves nothing below. The crest
                // row (92) rides inside the reservation, the
                // clear remainder is 219 − 92 − 12 = 115.
                VStack(alignment: .leading, spacing: 12) {
                    crestRow
                    Color.clear
                        .frame(height: 115)
                }
            } else {
                // No score block (a pre-match board, or no
                // state bound yet): the crest row stands alone
                // so the fixture's badges still show.
                crestRow
            }
        }
    }

    // MARK: Sections

    private var vnSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("LINK TIẾNG VIỆT")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
            ForEach(vnSources, id: \.url) { ch in
                Button {
                    playRequest = BoardPlayRequest(
                        resolution: store.resolution(for: ch), enItemID: nil,
                        vnURL: ch.url)
                } label: {
                    rowFace(title: MatchTitle.clean(ch.title),
                            detail: ch.group,
                            focused: focusedRow == "vn:" + ch.url,
                            theme: theme,
                            logoChannel: ch)
                }
                .tvCardButton()
                .focused($focusedRow, equals: "vn:" + ch.url)
            }
        }
    }

    private var enSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("LINK TIẾNG ANH · BLV ANH")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
            ForEach(enItems) { item in
                Button {
                    playRequest = BoardPlayRequest(
                        resolution: nuvio.resolution(for: item), enItemID: item.id,
                        vnURL: nil)
                } label: {
                    rowFace(title: item.league ?? item.displayName,
                            detail: item.league != nil ? item.displayName : "Nuvio",
                            focused: focusedRow == "nv:" + item.id,
                            theme: theme,
                            // NuvioItem exposes a logo via `poster`
                            // (and via displayChannel, which wraps
                            // poster as the channel logo — see
                            // NuvioAddon.swift): chip only when a
                            // poster URL actually exists.
                            logoChannel: item.poster.isEmpty ? nil : item.displayChannel)
                }
                .tvCardButton()
                .focused($focusedRow, equals: "nv:" + item.id)
            }
        }
    }

    private func rowFace(title: String, detail: String, focused: Bool,
                         theme: TVThemeTokens,
                         logoChannel: Channel? = nil) -> some View {
        HStack(spacing: 16) {
            // MU only: channel logo chip at the row's left, only
            // when a logo actually exists (SURVEY-B register
            // item 4). Classic rows never carry the chip — the
            // classic face below is today's face verbatim.
            // NO quality pill, NO signal bars (register 2-3).
            if theme.id.isMU, let logoChannel, logoChannel.logoURL != nil {
                TVChannelLogo(channel: logoChannel, height: 40)
            }
            Image(systemName: "play.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(focused ? theme.accent : .white.opacity(0.5))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(focused ? theme.accent : .white)
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(rowFaceBackground(focused: focused, theme: theme))
    }

    @ViewBuilder
    private func rowFaceBackground(focused: Bool, theme: TVThemeTokens) -> some View {
        if theme.id.isMU {
            // MU: charcoal fill; focused = maroon gradient +
            // gold 3 pt stroke (one owner of the silhouette —
            // the rounded rect below — as on classic). Radius
            // 8 since 1.7.2 (audit M18) and the gradient's
            // second stop is OPAQUE (audit H23) — the classic
            // arm below keeps radius 14 verbatim.
            RoundedRectangle(cornerRadius: 8)
                .fill(focused
                    ? AnyShapeStyle(LinearGradient(
                        colors: [theme.tileFocusedBG, theme.minuteRed],
                        startPoint: .leading, endPoint: .trailing))
                    : AnyShapeStyle(theme.tileBG))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(focused ? theme.focusRing : theme.tileBorder,
                                      lineWidth: focused ? 3 : 1.5))
        } else {
            // Classic: today's face verbatim (theme.accent is
            // TVPalette.boardSky and the tile tokens are the
            // TVPalette tile constants under classic).
            RoundedRectangle(cornerRadius: 14)
                .fill(focused ? theme.tileFocusedBG : theme.tileBG)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(focused ? theme.accent : theme.tileBorder,
                                      lineWidth: focused ? 3 : 1.5))
        }
    }
}

private struct PlayerController: UIViewControllerRepresentable {
    let channel: Channel
    let onFail: () -> Void
    let onReady: () -> Void
    var showsSwitchButton: Bool = false
    var onSwitchButton: () -> Void = {}
    /// While the switch overlay is up, the controller's whole
    /// view stops taking interaction, so neither the transport
    /// bar nor the switch button can receive focus behind the
    /// panel (review S1/S2/S3-D2).
    var interactionLocked: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator(rungURL: channel.url, onFail: onFail, onReady: onReady)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let item = AVPlayerItem(asset: Self.asset(for: channel))
        let player = AVPlayer(playerItem: item)
        controller.player = player
        controller.view.isUserInteractionEnabled = !interactionLocked
        context.coordinator.observe(item, player: player)
        installSwitchMenuItem(in: controller)
        player.play()
        return controller
    }

    /// KH-8 (ĐG-2): "Đổi nguồn" is a transport-bar custom menu
    /// item — `transportBarCustomMenuItems`, the surface Apple
    /// provides for exactly this (WWDC21 10191): the player
    /// itself owns focus in its transport bar, so the item is
    /// reachable from the seek bar by the remote, which is the
    /// whole point. The previous construction put a UIButton
    /// in `contentOverlayView`, which Apple's documentation
    /// defines as the surface for NON-interactive content —
    /// the player never routes focus there, so the button was
    /// unreachable and focus stayed trapped on the seek bar
    /// (the owner's 1.4.2 report). Direct launches without a
    /// switch context install nothing, exactly as before.
    private func installSwitchMenuItem(in controller: AVPlayerViewController) {
        guard showsSwitchButton else {
            controller.transportBarCustomMenuItems = []
            return
        }
        let action = onSwitchButton
        let item = UIAction(
            title: "Đổi nguồn",
            image: UIImage(systemName: "arrow.triangle.2.circlepath")
        ) { _ in action() }
        controller.transportBarCustomMenuItems = [item]
    }

    /// The asset carries exactly the headers the entry itself
    /// declared (#EXTVLCOPT for playlist entries; the addon's
    /// proxyHeaders for Nuvio ladder channels) — nothing
    /// invented, nothing blanket.
    static func asset(for channel: Channel) -> AVURLAsset {
        let url = channel.streamURL ?? URL(fileURLWithPath: "/dev/null")
        var headers: [String: String] = [:]
        if !channel.userAgent.isEmpty { headers["User-Agent"] = channel.userAgent }
        if !channel.referrer.isEmpty { headers["Referer"] = channel.referrer }
        if !channel.origin.isEmpty { headers["Origin"] = channel.origin }
        if headers.isEmpty { return AVURLAsset(url: url) }
        return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.view.isUserInteractionEnabled = !interactionLocked
        installSwitchMenuItem(in: controller)
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.invalidate()
        controller.player?.pause()
        controller.player = nil
    }

    /// Watches the item: ready → tell the view to drop its "loading"
    /// label; failed (status or end-of-playback error) → advance to
    /// the fixture's next source, at most once per item.
    ///
    /// MainActor-isolated (Swift 6): the observation callbacks arrive
    /// from non-isolated contexts — the KVO handler runs on whatever
    /// thread changed the item's status, and the NotificationCenter
    /// block carries no isolation of its own — while everything the
    /// coordinator touches (its tokens, its `fired` flag, the view's
    /// callbacks) is main-actor state. Isolating the class makes the
    /// once-only flag race-free by construction (the old code set it
    /// directly on the KVO thread). The KVO path reads the status
    /// VALUE inside the handler and hops to the main actor carrying
    /// only that Sendable value, never the item; the notification is
    /// delivered on the main queue (queue: .main), so touching the
    /// isolated state synchronously via assumeIsolated is sound
    /// there. Both callbacks still reach the view on the main actor,
    /// exactly as the old DispatchQueue.main hops delivered them.
    @MainActor
    final class Coordinator {
        private var statusToken: NSKeyValueObservation?
        private var failToken: NSObjectProtocol?
        private let onFail: () -> Void
        private let onReady: () -> Void
        private var fired = false

        // MARK: Stall watchdog (1.6.0, web standard / FL-355)
        //
        // The item's own failure events convict only failures
        // the ITEM reports. A server that accepts the connection
        // and never sends fails nothing — the item sits in
        // .unknown forever — and a mid-play stall (the player
        // waiting, the clock frozen, no error) is the same
        // silence. The watchdog speaks for both, with the iOS
        // 1.30 pair of numbers: no readyToPlay within 6 s of the
        // rung being handed over, or a playing clock that has
        // not moved for 10 s while the player waits, is a dead
        // rung — reported through the same once-only fire as an
        // item failure, so the surface advances and the health
        // memory records it. The owner's own pause stands the
        // stall half down (timeControlStatus .paused keeps the
        // progress clock fresh).
        //
        // 1.7.10 (FL-486): the PRE-READY half no longer fires
        // on the fixed wall alone — it is progress-aware (see
        // tickLoadWatchdog below). The post-ready stall half
        // is unchanged since 1.6.0.
        //
        // These three numbers are the AVERAGE base — the
        // pre-ready deadlines for a rung whose host has no
        // reputation record or an AVERAGE one. observe()
        // re-sizes them per rung from the host's reputation
        // tier (owner amendment, 2026-11-25 — see
        // loadDeadlines(for:) below). stallTimeout also
        // remains the post-ready stall half's window, at
        // every tier.
        private static let loadTimeout: TimeInterval = 6
        private static let stallTimeout: TimeInterval = 10
        /// Absolute bound on the pre-ready wait (1.7.10): a
        /// rung whose data keeps trickling but never produces
        /// a first frame is still abandoned at 20 s.
        private static let loadHardCap: TimeInterval = 20

        /// Pre-ready deadlines by reputation tier (owner
        /// amendment, 2026-11-25): the class sizes the wait,
        /// so a GOOD source is not cut early just for being
        /// slow. GOOD earns patience on every axis. BAD keeps
        /// the 6 s no-progress floor — FL-486's surviving
        /// frame arrived at 5.882 s, so no tier may wait less
        /// than that for a first byte — and keeps its full
        /// chance while data is actually arriving; it only
        /// loses the benefit of the doubt sooner once the
        /// data stops (8 s stall window, 15 s cap).
        private static func loadDeadlines(for tier: SourceReputation.Tier)
            -> (noProgress: TimeInterval, progressStall: TimeInterval,
                hardCap: TimeInterval) {
            switch tier {
            case .good:
                return (noProgress: 12, progressStall: 15, hardCap: 30)
            case .bad:
                return (noProgress: loadTimeout, progressStall: 8, hardCap: 15)
            case .average:
                return (noProgress: loadTimeout, progressStall: stallTimeout,
                        hardCap: loadHardCap)
            }
        }
        private var watchdog: Task<Void, Never>?
        private weak var player: AVPlayer?
        private var ready = false
        private var observedAt = Date()
        private var lastTime: Double = -1
        private var lastProgressAt = Date()
        // Pre-ready loading-progress sampling (1.7.10): the
        // high-water marks of the current item's two loading
        // signals, the last tick either grew, and the
        // once-only flag for the "holding" log line.
        private var lastBufferedEnd: Double = -1
        private var lastBytesReceived: Int64 = -1
        private var lastLoadProgressAt: Date?
        private var loggedHolding = false
        // Tier-sized pre-ready wait (owner amendment,
        // 2026-11-25): the rung's URL, wired in from
        // PlayerController at construction; observe()
        // snapshots its host's reputation tier and the
        // deadline tuple that tier earns. The three limits
        // start at the AVERAGE base (== loadTimeout /
        // stallTimeout / loadHardCap) and observe() replaces
        // them before the first tick can run.
        private let rungURL: String
        private var rungTier: SourceReputation.Tier = .average
        private var tierNoProgress: TimeInterval = 6
        private var tierProgressStall: TimeInterval = 10
        private var tierHardCap: TimeInterval = 20

        /// " (tier GOOD)" / " (tier BAD)" appended to the
        /// pre-ready watchdog lines, so a device log proves
        /// the tier-sized wait was applied. AVERAGE appends
        /// nothing — its lines stay byte-identical.
        private var tierLogSuffix: String {
            rungTier == .average ? "" : " (tier \(rungTier.label))"
        }

        init(rungURL: String, onFail: @escaping () -> Void,
             onReady: @escaping () -> Void) {
            self.rungURL = rungURL
            self.onFail = onFail
            self.onReady = onReady
        }

        func observe(_ item: AVPlayerItem, player: AVPlayer) {
            self.player = player
            observedAt = Date()
            lastProgressAt = Date()
            lastTime = -1
            lastBufferedEnd = -1
            lastBytesReceived = -1
            lastLoadProgressAt = nil
            loggedHolding = false
            // Snapshot this rung's patience from its host's
            // reputation, keyed exactly as the outcome
            // records are (the host of the rung's URL). No
            // record reads .average — the base deadlines.
            rungTier = SourceReputation.tier(
                forHost: URL(string: rungURL)?.host ?? "")
            let limits = Self.loadDeadlines(for: rungTier)
            tierNoProgress = limits.noProgress
            tierProgressStall = limits.progressStall
            tierHardCap = limits.hardCap
            statusToken = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                // Read the status VALUE here and hop: the KVO handler
                // is a non-isolated context, the coordinator's state
                // is main-actor state (Swift 6).
                let status = item.status
                guard let self else { return }
                Task { @MainActor in
                    self.handleStatus(status)
                }
            }
            failToken = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                // Delivered on the main queue (queue: .main), so the
                // coordinator's main-actor state may be touched
                // synchronously via assumeIsolated.
                MainActor.assumeIsolated {
                    self?.fireOnce()
                }
            }
            watchdog = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    // Re-check AFTER the sleep (fix round,
                    // review B-MINOR-1): a task cancelled while
                    // sleeping must not tick once more on a
                    // surface that is already tearing down.
                    guard let self, !Task.isCancelled, !self.fired else { return }
                    self.watchdogTick()
                }
            }
        }

        private func watchdogTick() {
            guard let player else { return }
            let now = Date()
            if !ready {
                tickLoadWatchdog(player: player, now: now)
                return
            }
            let t = player.currentTime().seconds
            if t.isFinite, t > lastTime + 0.05 {
                lastTime = t
                lastProgressAt = now
            }
            switch player.timeControlStatus {
            case .waitingToPlayAtSpecifiedRate:
                if now.timeIntervalSince(lastProgressAt) > Self.stallTimeout {
                    DiagLog.write("player", "watchdog: playback stalled "
                        + "\(Int(Self.stallTimeout)) s — advancing")
                    fireOnce()
                }
            case .paused, .playing:
                // The owner's own pause is not a stall, and a
                // playing player is making progress by definition.
                lastProgressAt = now
            @unknown default:
                break
            }
        }

        /// The pre-ready half of the watchdog (1.7.10, FL-486).
        /// The fixed 6 s wall killed rungs whose bytes were
        /// demonstrably still arriving: the owner's log showed
        /// both rungs of a ladder shot at exactly 6 s with no
        /// first frame, then — on his second manual open — a
        /// rung producing its first frame at 5,882 ms, 118 ms
        /// under the line. The wait is now progress-aware.
        /// Each tick samples the CURRENT item's loading
        /// signals: the buffered end of its first loaded time
        /// range, and the byte count of its access log's
        /// latest event. Either signal growing — or reading
        /// positive for the first time, which already proves
        /// data arrived — stamps `lastLoadProgressAt`. The
        /// rung then advances ONLY when:
        /// - nothing ever arrived within the no-progress
        ///   deadline (a silent server still dies fast);
        /// - data arrived but has not grown for the
        ///   progress-stall window;
        /// - or the wait passes the absolute hard cap.
        /// All three numbers are THIS RUNG's tier-sized tuple
        /// (see loadDeadlines(for:)): the AVERAGE base is
        /// 6 / 10 / 20, a GOOD host waits 12 / 15 / 30, a BAD
        /// host 6 / 8 / 15. The advance line keeps the
        /// historic prefix and now states the TRUE elapsed
        /// seconds and whether any progress was seen; a
        /// non-AVERAGE rung's lines also name its tier.
        private func tickLoadWatchdog(player: AVPlayer, now: Date) {
            var progressed = false
            var bufferedEnd = max(lastBufferedEnd, 0)
            if let item = player.currentItem {
                if let range = item.loadedTimeRanges.first {
                    let end = range.timeRangeValue.end.seconds
                    if end.isFinite {
                        bufferedEnd = end
                        if end > lastBufferedEnd {
                            if end > 0 { progressed = true }
                            lastBufferedEnd = end
                        }
                    }
                }
                if let event = item.accessLog()?.events.last {
                    let bytes = event.numberOfBytesTransferred
                    if bytes > lastBytesReceived {
                        if bytes > 0 { progressed = true }
                        lastBytesReceived = bytes
                    }
                }
            }
            if progressed { lastLoadProgressAt = now }
            let elapsed = now.timeIntervalSince(observedAt)
            if let lastProgress = lastLoadProgressAt {
                if elapsed > tierNoProgress, !loggedHolding {
                    loggedHolding = true
                    DiagLog.write("player", "watchdog: first frame pending — data arriving "
                        + "(buffered \(String(format: "%.1f", bufferedEnd)) s), holding"
                        + tierLogSuffix)
                }
                if now.timeIntervalSince(lastProgress) > tierProgressStall
                    || elapsed > tierHardCap {
                    DiagLog.write("player", "watchdog: no first frame in "
                        + "\(Int(elapsed)) s — advancing (progress: yes)"
                        + tierLogSuffix)
                    fireOnce()
                }
            } else if elapsed > tierNoProgress {
                DiagLog.write("player", "watchdog: no first frame in "
                    + "\(Int(elapsed)) s — advancing (progress: no)"
                    + tierLogSuffix)
                fireOnce()
            }
        }

        private func handleStatus(_ status: AVPlayerItem.Status) {
            switch status {
            case .readyToPlay:
                ready = true
                onReady()
            case .failed:
                fireOnce()
            default:
                break
            }
        }

        private func fireOnce() {
            guard !fired else { return }
            fired = true
            watchdog?.cancel()
            watchdog = nil
            onFail()
        }

        func invalidate() {
            watchdog?.cancel()
            watchdog = nil
            statusToken?.invalidate()
            statusToken = nil
            if let failToken {
                NotificationCenter.default.removeObserver(failToken)
                self.failToken = nil
            }
        }
    }
}
