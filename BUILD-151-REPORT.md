# DaBanhTV 1.5.1 — build report (FL-360 / FL-361 / FL-370)

Base: 1.5.0/32, head `7b41ecb6`. Owner device verdict on 1.5.0
(2026-11-21 15:36 CST): FAILED all three points — "1. Khung bị
cắt ở dưới. 2. Trận trùng 3. Bảng chi tiết mất logo mất thông
tin thẻ vàng thẻ đỏ." Owner geometry ruling (verbatim):
"Nâng box ở giữa lên cao hơn để lấy diện tích" + "Kéo viền 2
bên hông thêm diện tích" + "Hiện đóng khung nhỏ hơn nên thiếu
diện tích các khung".

---

## LEG 1 — FL-360: the vertical count (recounted from code)

### Why 1.5.0's sheet was wrong — two counting errors

1. **The tvOS safe area was never counted in ANY round.**
   Apple HIG (Layout): tvOS primary content is inset 60 pt
   top/bottom and 80 pt on the sides — the usable region is
   1760×960 of the 1920×1080 canvas. The root content stack
   does not ignore the safe area (only the background does),
   so every budget drawn against the full 1080 was 120 pt
   optimistic before it started.
2. **1.5.0's sheet dropped the rail's bottom inset.** It
   counted the rail's top vertical inset (14) and forgot the
   bottom 14 (`.padding(.vertical, 14)` pads both).

### 1.5.0 — the REAL count (1.5.0 file:line)

| Element | pt | Source |
|---|---|---|
| Canvas height | 1080 | — |
| tvOS safe area (top+bottom) | −120 | Apple HIG |
| Root padding top 40 + bottom 28 | −68 | TVContentView.swift:489–490 |
| Root VStack spacings 20 × 3 | −60 | TVContentView.swift:466 |
| Header (30 pt line 36.3 + bottom pad 4) | −40 | TVContentView.swift:690–718 |
| Tab bar (2 pill rows 44.2 + spacing 10) | −98 | TVContentView.swift:749, tabPill :856–866 |
| Status slot | −24 | TVContentView.swift:481 |
| **Body** | **669** | |
| Hero panel (column 330 + v-pad 18×2) | −366 | TVContentView.swift:1457, :1465 |
| Body spacing | −18 | TVContentView.swift:960 |
| **Rails viewport** | **285** | |
| Rail need: title 36.3 + spacing 4 + insets 14+14 + tile slot 342 | **410** | TVMatchViews.swift TVFixtureRail |
| **Shortfall** | **−125** | tiles visible ≈217/342 ≈ 63% |

63% is exactly the owner's frame (f-cliprail.png): tiles cut
just under the team names.

### 1.5.1 — the reclaim (owner's ruling applied literally)

Every inset stacked on top of the system's own safe margin
was wasted area; it is reclaimed, the hero keeps its slim
score-only CONTENT (column still 330, untouched):

| Change | Δ pt | Where |
|---|---|---|
| Root padding top 40 → 0, bottom 28 → 0 | +68 | TVContentView.swift body |
| Root horizontal padding 32 → 0 (safe-area 80 remains) | width | TVContentView.swift body |
| Root VStack spacing 20 → 12 (×3) | +24 | TVContentView.swift:466 |
| Header bottom pad 4 → 0 | +4 | TVContentView.swift header |
| Tab bar row spacing 10 → 6 | +4 | TVContentView.swift tabBar |
| Hero vertical padding 18 → 10 (panel 366 → 350) | +16 | TVContentView.swift heroLabel |
| Hero horizontal padding 40 → 24 | width | TVContentView.swift heroLabel |
| Body spacings 18 → 12 (scroll/cup/EN bodies) | +6 | TVContentView.swift bodies |
| Section VStacks spacing 30 → 12; cup/division titles folded into the first rail's title (every word preserved) | +18/section | TVContentView.swift cupSection, lowerDivisionSection |
| Rail vertical inset 14 → 4, horizontal 8 → 4 | +20 | TVMatchViews.swift TVFixtureRail |

Focus safety of the inset cut: `TVCardButtonStyle` returns
the label untouched with `.focusEffectDisabled()` — there is
NO focus scaling anywhere in the app; the focus ring is
strokeBorder INSIDE the tile frame. 4 pt clears it whole.

### 1.5.1 — the count

| Element | pt |
|---|---|
| Safe height | 960 |
| Root spacings 12 × 3 | −36 |
| Header (30 pt line, no pad) | −36 |
| Tab bar (44.2 × 2 + 6) | −94 |
| Status slot | −24 |
| **Body** | **770** |
| Hero panel (330 + 10×2) | −350 |
| Body spacing | −12 |
| **Rails viewport** | **≈405** |
| Rail need: title 36.3 + spacing 4 + insets 4+4 + slot 342 | **390** |
| **Margin** | **≈ +15 on every body** |

(The viewport is 408 by the stack arithmetic, less the
rails ScrollView's own ≈2–3 pt of vertical inset the stack
count cannot see — the review gate's independent recount.
Margin ≈ +15 either way; the conclusion is unchanged.)

Cup body: the competition title is folded into the first
rail's title, so the first cup rail faces the same 390 need
against the same ≈405 viewport (≈+15). Nuvio rails (cards
252 high) need ≈300–356 — fit with room to spare.

Horizontal: content width is now the full safe width 1760
(the GeometryReader's own 32 padding is also removed);
tileWidth = min(592, (1760 − 64)/3) = **565** (was 541);
a 3-across row = 3×565 + 2×28 spacing + 2×4 insets = 1760,
exactly the safe width — "kéo viền 2 bên hông" delivered.

Trade-off, stated plainly: the CÚP C1 section title used to
render in gold as its own row; folded into the rail title it
renders in the rail title's white. The words are unchanged;
only the gold tint is gone. If the owner wants the gold back,
the title row returns at a cost of 49 pt against the ≈+15
margin — his call, not hidden.

Ghosting: the hero is already ONE frame whose content swaps
in place (heroPanelView) — no view replacement on match
change exists in the home. The doubled "LINK TIẾNG VIỆT" in
f-detail.png is in the BOARD (a different screen); no
duplicated view exists in its code — the board header now
re-renders from live store state (Leg 3), and the doubling
is recorded as unconvicted (consistent with photo motion
blur); flagged for the owner's retest, not silently closed.

---

## LEG 2 — FL-361: systematic alias harvest (harness proof)

Method: Python replica of TeamNameNorm's pipeline with ALL
tables parsed from the Swift source (no transcription), run
over today's live data — playlist thtt.pages.dev/tttt.m3u
(485 channels), ESPN scoreboards (17 slugs × 3 Eastern days),
FotMob day feeds (2 days). Binding simulated exactly as the
app does it (own date key, ±1 day seam, ≤3 h kickoff
agreement). Harness + outputs: `harness-151/`
(harness.py, before2.txt, after.txt are pushed with this
report; the raw pulls — tttt.m3u, feed-states.json, the
FotMob payloads — stay in the workspace tree).

| | BEFORE (1.5.0 tables) | AFTER (1.5.1) |
|---|---|---|
| Fixture groups in the playlist | 153 | **134** |
| Groups bound to a feed state | 54 | **73** |
| Channels sitting in bound groups | 244 | **351** |
| Unbound though a feed fixture exists at the same instant | 30 | **2** |
| Unbound, no feed fixture near | 69 | 59 |

19 duplicate groups collapsed into their twins; every
specimen family merges at BOTH the canonical (binding) and
groupKey (tile grouping) level — the pipeline is shared, so
one table serves both:

- "RC Strasbourg Alsace" → strasbourg; "Stade Brestois 29" → brest
- "Lille OSC" / "LOSC Lille" → lille; "Lyonnais" / "Olympique Lyonnais" → lyon
- "RC Celta" / "Celta" / "Celta Vigo" → celta vigo (all three
  Real Madrid listings now form ONE group — the owner's
  photograph specimen)
- "Real Betis Balompie" → real betis (already in 1.4.9, re-proven)
- Bonus convergence: "Inter Milan" / "Internazionale" / "Inter" → inter

38 new whole-name aliases were added, each harvested from a
same-fixture, same-instant, other-side-anchored pair in the
live pull, each target stem passing the aarhus test (exactly
one producer club in the corpus). Full list with per-entry
evidence comments in TeamNameNorm.swift (the "1.5.1 (FL-361)"
block).

The 2 remaining unbound-with-feed cases are NOT name
variants: (1) "Pháp U17 vs Ả Rập Xê Út U17" — national teams
written in Vietnamese ("a rap xe ut" ≠ "saudi arabia");
translation names are outside the alias discipline and were
never bound. (2) "Adhyaksa FC Banten vs Pusamania Borneo
FC" — the playlist pairs Borneo with a different opponent
than the feed's fixture at that instant (a listing error,
not a spelling); the Borneo side itself now canonicalises
to "borneo samarinda" correctly.

---

## LEG 3 — FL-370: the detail board (conviction)

Live-data proof first: for the owner's specimen (AS Monaco
vs AJ Auxerre, 2026-11-21), ESPN's fra.1 scoreboard carries
3 details (Goal Faivre 29', Goal Diop 82', Yellow Card 88' —
all with resolvable team ids) and FotMob's matchDetails
carries both goals + 2 yellow cards. Both parses in
MatchStateStore.swift are complete and correct (verified
line by line). The data existed; the display lost it.
Four break points, each convicted from code:

1. **The board header had NO crest slots at all.**
   TVFixtureEntry.displayCrests exists and the hero/tiles
   render it; TVMatchBoardView's header never did. → FIXED:
   crests flank the score digits (fixed 92 pt slots), a
   crest row stands in the live-no-score reservation and on
   pre-match boards.
2. **The board header read a frozen snapshot.** The board
   holds `entry` as a let value captured at tap time;
   requestBoardDetail wrote upgrades into the store, but
   nothing re-read them — an open board could never show an
   event that landed after it opened. → FIXED: the header
   resolves the fixture's current bound state from the
   store on every render (`liveEntry`).
3. **The FotMob detail cache froze live events.** A
   non-empty detail answer was cached and re-applied
   forever; a live match's scorers/cards were capped at the
   first fetch's minute for the whole session (and
   applyBoardDetail refused to write into a state whose
   events were non-empty). → FIXED: cache entries carry a
   fetch stamp; a live answer expires after 120 s and earns
   a refetch (cycle pass + board request); write-backs
   accept any strictly richer list, never a shorter one.
4. **filledFromPool filled events only when the winner's
   list was EMPTY.** A partial winner blocked every donor's
   fuller list. → FIXED: richest-wins fill, gated on the
   donor's scoreline equalling the merged score exactly
   (fail closed — events describing a different score are
   never mixed in).

Honest note on the specimen: the yellow card in ESPN's
record is at 88' and the owner's photo was taken at ~84' —
that specific card had not happened yet when he looked.
What HAD happened and was missing is the 29' Faivre goal
(the away event column stood empty at 1-1). The four breaks
above are the mechanisms that produce exactly this class of
loss; the card path itself (parse → columns) was verified
complete, and with breaks 2–4 fixed a card lands on an open
board within one poll cycle of either source carrying it.

Card rendering itself was EXONERATED: TVEventColumns
renders goals first, then card lines (glyph + name +
minute, cap 3/side + "+N"), fed correctly by both parses.

---

## Gate + version

- project.yml: BOTH pairs set to 1.5.1 / 33 (settings
  MARKETING_VERSION/CURRENT_PROJECT_VERSION and
  info.properties CFBundleShortVersionString/CFBundleVersion).
- Swift review gate (this app's own team, 3 lenses —
  language, semantics, geometry): PASSED with 3 consecutive
  CLEAN rounds. The road there was not straight: four
  earlier attempts each fell to a real semantics defect,
  all in the FL-370 cache work — (1) the board path's
  unguarded cache store could shrink events via the cache;
  (2) filledFromPool took the first longer donor by rank,
  not the richest; (3) the cycle guarded its cache store
  against a pre-fetch snapshot while a board fetch could
  interleave; (4) the cycle's wholesale `states = next`
  could roll back a board enrichment landed mid-cycle;
  (5) a live snapshot was promoted to "final" at FT.
  Each was fixed and the count restarted; the final code
  passed rounds 1, 2 and 3 with no change in between.
  Two further findings were recorded as PRE-EXISTING
  (1.4.x mechanisms, not worsened by 1.5.1, out of this
  gate): the KH-3 staleness guard can replace a winner
  wholesale and drop its events under its frozen-minute
  preconditions, and a cross-source precedence takeover of
  a storage key discards the loser's richer detail events.
  Both are queued for the leader as separate items; the
  proposed shape for the second is the same scoreline-gated
  richer-events carry filledFromPool now uses.
