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
                          startURL: startURL,
                          surfaceLocked: switchOpen)
                .id(session)
                // While the overlay is up the surface leaves
                // the focus environment entirely (review
                // S1/S2/S3-D2): no directional input can land
                // on the dimmed player or its switch button
                // behind the panel.
                .disabled(switchOpen)
            if switchOpen, let switchContext {
                switchOverlay(switchContext)
            }
        }
        .onExitCommand {
            if switchOpen {
                switchOpen = false
            } else {
                dismiss()
            }
        }
    }

    // MARK: Switch overlay (the board's arrangement, spec §2)

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
                    .fill(TVPalette.boardBG)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22)
                            .strokeBorder(TVPalette.tileBorder, lineWidth: 2)))
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
                                  focused: switchFocus == "vn:" + ch.url)
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
                                  focused: switchFocus == "nv:" + item.id)
                }
                .tvCardButton()
                .focused($switchFocus, equals: "nv:" + item.id)
            }
        }
    }

    /// The board's row face with one addition: the playing row
    /// carries a check and "(đang phát)" so the eye lands on it
    /// before focus even moves.
    private func switchRowFace(title: String, detail: String,
                               playing: Bool, focused: Bool) -> some View {
        HStack(spacing: 16) {
            Image(systemName: playing ? "checkmark.circle.fill" : "play.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(playing || focused
                    ? TVPalette.boardSky : .white.opacity(0.5))
            VStack(alignment: .leading, spacing: 3) {
                Text(playing ? title + "  (đang phát)" : title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(focused ? TVPalette.boardSky : .white)
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
                .fill(focused ? TVPalette.tileFocusedBG : TVPalette.tileBG)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(focused ? TVPalette.boardSky : TVPalette.tileBorder,
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
    @ObservedObject var resolution: MatchResolution
    /// The shell's switch hooks (v1.4.1, 2.22 parity): the
    /// switch button is installed only for board-launched
    /// sessions, and the playing URL is reported up so the
    /// shell's overlay can mark the playing row.
    var showsSwitchButton: Bool = false
    var onSwitchButton: (() -> Void)? = nil
    var onPlayingURL: ((String?) -> Void)? = nil
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
    @State private var currentURL: String?
    @State private var tried: Set<String> = []
    @State private var exhausted = false
    @State private var switching = true

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
                                     onReady: { switching = false },
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
                    .background(Capsule().fill(Color.black.opacity(0.55)))
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
        guard !exhausted, currentURL == nil else { return }
        // A switch pick outranks the ladder's own order: the
        // picked rung plays first; the rest of the ladder
        // stays behind it as the fallback, in ladder order.
        // Once the pick has been tried, this branch is inert.
        if let startURL, !tried.contains(startURL) {
            if let picked = resolution.sources.first(
                where: { $0.channel.url == startURL }) {
                currentURL = picked.channel.url
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
            switching = true
        } else if resolution.finished {
            exhausted = true
        } else {
            switching = true
        }
    }

    private func advance() {
        if let currentURL {
            tried.insert(currentURL)
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
            Color(red: 0.05, green: 0.07, blue: 0.08).ignoresSafeArea()
            VStack(spacing: 18) {
                Text("MẤT TÍN HIỆU")
                    .font(.system(size: 54, weight: .bold))
                    .tracking(4)
                    .foregroundStyle(.white)
                Text("Tất cả các nguồn của trận này đều không phát được. Bấm Menu để quay lại.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
    }
}


// MARK: - Link board (1.4.1, spec §2)

/// The fixture's link board — the only place the VN/EN choice is
/// made (spec §2.1). Header = the fixture's live cluster (§2.4:
/// big score, minute/status badge, up to two event lines; with
/// no matched state it shows the kickoff and the board is still
/// usable — it never waits for state). Below: LINK TIẾNG VIỆT —
/// the fixture's grouped mirror channels in ladder order,
/// representative first, labelled by their cleaned titles
/// verbatim (the trailing "(Name)" IS the commentator choice,
/// §2.3a) — then LINK TIẾNG ANH · BLV ANH with one row per
/// attached Nuvio event meta (§2.3b), the whole section omitted
/// when nothing attached (fail closed — never faked). Focus
/// starts on the first VN row (spec §2.6); the header is a
/// static strip, never focusable. A row tap plays that row: VN
/// rows enter the player with the store's ladder rotated to the
/// row (PlaylistStore.resolution(for:) is tapped-first by
/// construction), EN rows resolve through the addon store.
struct TVMatchBoardView: View {
    @EnvironmentObject private var store: PlaylistStore
    let entry: TVFixtureEntry
    let vnSources: [Channel]
    let enItems: [NuvioItem]
    @ObservedObject var nuvio: NuvioStore
    @Environment(\.dismiss) private var dismiss
    @State private var playRequest: BoardPlayRequest?
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

    var body: some View {
        ZStack {
            TVPalette.boardBG.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 26) {
                header
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 30) {
                        vnSection
                        if !enItems.isEmpty {
                            enSection
                        }
                    }
                    .padding(.bottom, 10)
                }
            }
            .padding(.horizontal, 60)
            .padding(.top, 40)
            .padding(.bottom, 28)
        }
        .onExitCommand { dismiss() }
        .onAppear {
            focusedRow = vnSources.first.map { "vn:" + $0.url }
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
        }
    }

    // MARK: Header (the cluster, §2.4)

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                Text(entry.competitionLabel)
                    .font(.system(size: 19, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(TVPalette.leagueTx)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let badge = entry.badgeText {
                    Text(badge)
                        .font(.system(size: 25, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(entry.state?.status == .ht
                                ? TVPalette.htAmber : TVPalette.minuteRed))
                }
            }
            HStack(alignment: .center, spacing: 22) {
                Text(entry.headline)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if let state = entry.state, let score = state.scoreText {
                    Text(score)
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                } else if let kickoff = entry.channel.kickoff {
                    Text(TVKickoffFormat.timeDay.string(from: kickoff))
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(TVPalette.boardSky)
                        .lineLimit(1)
                }
            }
            if let state = entry.state, !state.events.isEmpty {
                eventLines(state)
            }
        }
    }

    /// Up to two event lines (spec §2.4): goals first, then a
    /// card-count line — the cluster, aggregated for the header.
    private func eventLines(_ state: MatchState) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(state.goals.prefix(2).enumerated()), id: \.offset) { _, goal in
                HStack(spacing: 8) {
                    Text("⚽")
                        .font(.system(size: 19))
                    Text(goal.playerName)
                        .font(.system(size: 19))
                        .foregroundStyle(TVPalette.evTx)
                    Text(goal.minuteText)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(TVPalette.evMin)
                }
            }
            if state.homeYellow + state.awayYellow + state.homeRed + state.awayRed > 0 {
                HStack(spacing: 14) {
                    cardCount(yellow: state.homeYellow, red: state.homeRed)
                    Text("·")
                        .foregroundStyle(TVPalette.evTx)
                    cardCount(yellow: state.awayYellow, red: state.awayRed)
                }
            }
        }
    }

    private func cardCount(yellow: Int, red: Int) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(TVPalette.cardY)
                .frame(width: 12, height: 16)
            Text("\(yellow)")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(TVPalette.evMin)
            RoundedRectangle(cornerRadius: 2.5)
                .fill(TVPalette.cardR)
                .frame(width: 12, height: 16)
            Text("\(red)")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(TVPalette.evMin)
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
                            focused: focusedRow == "vn:" + ch.url)
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
                            focused: focusedRow == "nv:" + item.id)
                }
                .tvCardButton()
                .focused($focusedRow, equals: "nv:" + item.id)
            }
        }
    }

    private func rowFace(title: String, detail: String, focused: Bool) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(focused ? TVPalette.boardSky : .white.opacity(0.5))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(focused ? TVPalette.boardSky : .white)
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
                .fill(focused ? TVPalette.tileFocusedBG : TVPalette.tileBG)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(focused ? TVPalette.boardSky : TVPalette.tileBorder,
                                      lineWidth: focused ? 3 : 1.5)))
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
        Coordinator(onFail: onFail, onReady: onReady)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let item = AVPlayerItem(asset: Self.asset(for: channel))
        let player = AVPlayer(playerItem: item)
        controller.player = player
        controller.view.isUserInteractionEnabled = !interactionLocked
        context.coordinator.observe(item)
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

        init(onFail: @escaping () -> Void, onReady: @escaping () -> Void) {
            self.onFail = onFail
            self.onReady = onReady
        }

        func observe(_ item: AVPlayerItem) {
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
        }

        private func handleStatus(_ status: AVPlayerItem.Status) {
            switch status {
            case .readyToPlay:
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
            onFail()
        }

        func invalidate() {
            statusToken?.invalidate()
            statusToken = nil
            if let failToken {
                NotificationCenter.default.removeObserver(failToken)
                self.failToken = nil
            }
        }
    }
}
