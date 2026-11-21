# BUILD 1.4.9 — FL-360 full pin + single hero · FL-361 merge · credits rider

- **App:** DaBanhTV (tvOS), repo `zjoenguyenz/dabanh-tvos`, tree `~/workspace/dabanh-tvos/`
- **Base:** 1.4.8 / build 30, remote main `713689b19787a99df6758f327d2ae75a8a44450d`
- **Target:** 1.4.9 / build 31 (both project.yml pairs bumped)
- **Owner evidence:** 2 clips + words, 2026-11-21 (FL-360 / FL-361 in the central fault library). Acceptance standard, his words: *"nó phải chuyên nghiệp, nó phải nhìn nó phải cứng cáp"* — nothing may move, overlap, slide or clip during focus moves, data arrivals, or the 60 s poll.

---

## FL-361 — CONVICTION (written before the fix, per the round's process rule)

Full trace: `FL361-TRACE-20261121.md` (code trace, no code changed by the trace).

**The mechanism, convicted from code:** the board has no single fixture identity. Three identity systems run in parallel and never intersect at render time — (1) playlist grouping identity (`FixtureGrouping`: TeamNameNorm.groupKey pair + ICT stamp date + 45-min chain, Crests.swift), (2) state identity (`MatchPairKey` canonical pair + ICT date, a different key flavour, MatchStateStore.swift), (3) Nuvio addon identity (meta id, separate store, separate rails, NuvioAddon.swift). State attaches at exactly ONE point (`TVContentView.enriched` → `state(for:)` on the grouped entry's representative channel, fail-closed on pair + date with a ±1-day/≤3 h seam); `filledFromPool` only completes an already-found winner, so a key-missed duplicate is unrescuable and its hero renders no score/scorers. Escape points E1 (spelling variant with no alias), E2 (ICT date-boundary bucket partition), E3 (legacy identity), E4 (Nuvio cross-collection, zero dedupe), E5 (groupKey vs canonicalKey flavour split — recorded, not the specimen).

**The specimen, convicted from the owner's own clip:** frame extraction from clip 2 (`e2a797…mp4`, frames at 4 s intervals) shows the bare duplicate's hero headline reading **"…vs Real Betis Balompié"** with the playlist fixture-hero meta ("· 2 nguồn phát") — i.e. **Path B-spelling**: a playlist listing carries the club's full official name "Real Betis Balompié"; `balompie` is neither a filler token nor an alias, so groupKey/canonicalKey strand it as `real betis balompie vs sevilla` ≠ the feeds' `real betis vs sevilla` → its own group (2 members) AND a state-lookup miss → bare hero. The trace had named this exact variant as a Path B candidate; the clip's headline is the measurement the alias table's discipline requires. (The corpus mirror snapshot's 5 Sevilla listings would merge under the old code — an honest negative the trace recorded; the Balompié listing lives in the live mirror, not the snapshot.) Path A (Nuvio) is **not** the specimen (the duplicate's meta is the playlist form), but E4 is convicted in code independently and produces the identical symptom class, so it is fixed in the same round.

**Fixes (identity upstream; MatchStateStore untouched — no §2(iii)-class change):**
1. `DaBanh/TeamNameNorm.swift` — alias `"real betis balompie": "real betis"` (measured, comment in the table's own style; aarhus test: Balompié belongs to this one club's official name). One entry fixes grouping + state binding + crests together, since all delegate to this module.
2. `DaBanh/Crests.swift` — `FixtureGrouping.group`: per-bucket chain + live-merge unchanged, clusters collected across buckets, then a date bridge: same-pair clusters on different ICT dates chaining within the state layer's own 3 h seam merge into one group (earliest cluster's date as id basis; group id format unchanged). Same-date behaviour is byte-for-byte the old rule; clusters further apart stay separate.
3. `DaBanhTV/TVContentView.swift` — `rebuildSnapshot`: Nuvio events belonging to a board fixture (canonical pair + same ICT date + kickoff ≤3 h — the attach rule's core) are removed from the cups/fold-league slices; they remain that fixture's English board source via the existing `play(_:)` attach (which reads the addon store directly) and remain in the BLV Anh tab regardless.

## FL-360 — what was built

Suspect map: `FL360-GEOMETRY-AUDIT-20261121.md`. The 1.4.8 pin held the panel (516 + 56 = 572 in every state — audit-verified) but not its contents or its neighbours.

1. **Single hero frame (the ghosting kill).** The three hero view trees (`fixtureHero` / `englishHero` / `nuvioHero`) are replaced by ONE frame: every kind reduces to a `HeroModel` (badge text+colour, headline, meta, optional score state, art, focus key) rendered by `heroLabel`. A kind change is now a value change inside an unchanging structure — there is no second tree to ghost with. The badge computation moved verbatim into `heroBadgeInfo` returning data.
2. **Every hero region holds reserved geometry.** Slots: badge 40 · headline 114 (2 lines) · meta 30 · score 217 (the fullest score block) · button row as before; column total 511 ≤ 516. The score slot renders the block or stays empty — "Xem ngay" sits at one Y for every hero; events landing on a poll fill the slot's lower part without moving anything. The art slot is one 440×168 box for crest pair / channel logo / glyph / placeholder alike (1.4.8's variants carried different boxes — the clip's drifting crests).
3. **heroItem == nil** renders the same frame unfocusable with all slots empty (was `EmptyView`, 0 pt — the audit's S-5 collapse on a folded tab whose fixtures are empty but whose addon rails exist).
4. **Status row (S-1):** always present in the root VStack at a fixed 24 pt; a message arriving/clearing changes only the text (was: insert/remove ≈44 pt, shifting hero + rails while the screen settled).
5. **Rails (S-3):** `TVFixtureRail` tiles occupy a uniform slot — featured rails always 342 (the board height; a featured card keeps its 330 face), standard rails 342 when any entry renders as a board else 252 — top-aligned, so a taller sibling landing never moves an existing tile; the last board flipping to a card at FT no longer drops the featured rail.
6. **In-tile pins (S-7):** `TVCrestRow` holds 62 in both branches (logo branch was 54 — a late ESPN crest fallback grew the row 8 pt); `NuvioEventCard`'s crest row pinned to 62 likewise; `TVLiveBoardView`'s header row holds the badge's 39 whether or not a badge is showing.
7. **Link-board header (S-4):** first row pinned to the badge height 39; a live/HT board whose events have not landed reserves the event-lines space (81). Verified in code while building: the board's `entry` is a tap-time copy that never re-reads the store while open, so score/kickoff/headline cannot change under the owner — the reservations make the header robust regardless, at zero visual cost on boards that already carry their badge/events.

**Bounded residuals, stated honestly (not silently "fixed"):**
- Section appearance/disappearance at genuine data-truth changes (first fixtures landing, a league tab gaining its addon rails, the Hot rail arriving) still changes the scroll content's total height — reserving permanent empty rails for every possible section would flood the screen with dead bands, a worse always-visible defect. What the round guarantees: no shift from focus moves, hero-kind changes, state/badge/event arrivals on the poll, status messages, or tile-shape flips inside a rail.
- A standard rail's height can still change when its FIRST live board arrives (a data-truth change); within the rail, existing tiles no longer move (top-aligned slots).

## Rider

Footer gains **"Logos: football-logos.cc"** beside the version label — DaBanhTV has no Settings screen; the footer is its only persistent about surface (the placement is stated here per the brief).

## Files changed

`DaBanhTV/TVContentView.swift` · `DaBanhTV/TVMatchViews.swift` · `DaBanhTV/TVPlayerView.swift` · `DaBanhTV/NuvioAddon.swift` · `DaBanh/TeamNameNorm.swift` · `DaBanh/Crests.swift` · `project.yml`

## Gate / CI / dissection

- **Review gate, first attempt:** Round 1 CLEAN. Round 2 FINDINGS (3, all real, all fixed):
  1. *Crests bridge transitive over-merge* — the merge test compared against the group's retained earliest dateKey, so after a day-1+day-2 merge a second day-2 cluster could be pulled in, undoing a same-date judgement. Fixed: the test now compares against the previous cluster's date (`lastMergedDateKey`).
  2. *Suppression lacked the marker guard* — MatchPairKey canonicalises women's markers away, so a women's Nuvio event could be suppressed against a men's board entry. Fixed: suppression requires marker status to match.
  3. *Nil hero shell painted chrome* — the empty badge still rendered its padded teal capsule and the "Xem ngay" pill rendered on a content-less panel. Fixed: `heroLabel(model, chrome:)` — the shell renders empty slots and no pill.
  Gate count restarted on the fixed diff.
- **Review gate, second attempt: PASSED** — 3 consecutive CLEAN rounds on the fixed diff (each round an independent reviewer; the final round re-derived every trace and swept whole-file integrity: brace balance 0 in all six Swift files, no stale call sites, every pending cluster registers exactly once before the legacy pass).
- **Push:** commit `0f6ae18f7e603256fb1149afc60319be93959a88` on main (8 files: the 6 Swift/YAML changes + this report). First two push attempts died on network drops with the ref verified unmoved each time; third attempt landed. **Full-tree blob-SHA verify: 0 mismatches** (43 remote blobs; the 11 local-only working docs were never repo files).
- **CI dispatch: BLOCKED at the API** — workflow dispatch returned 403 "Resource not accessible by personal access token". Head SHA handed to the leader for browser dispatch (expected run #18, ≈1–2.5 min). IPA dissection + delivery follow the run.
