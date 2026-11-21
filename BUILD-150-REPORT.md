# BUILD 1.5.0 — slim score-only hero · full info in the board · full-frame tiles

- **App:** DaBanhTV (tvOS), repo `zjoenguyenz/dabanh-tvos`, tree `~/workspace/dabanh-tvos/`
- **Base:** 1.4.9 / build 31, remote main `0f6ae18f7e603256fb1149afc60319be93959a88`
- **Target:** 1.5.0 / build 32 (both project.yml pairs bumped)
- **Owner ruling (2026-11-21 14:03 CST, verbatim):** *"Không ổn. Thôi đề xuất lại là bảng lớn phía trên nhỏ lại chỉ ghi tỉ số thôi. Còn vào trong thì hiện đủ thông tin. Các khung phía dưới quay về đủ khung, không bị cắt."* — 1.4.9 failed his device test: the hero still ghosted/text-overlapped on match swaps and the lower tiles were cut. His evidence: clip `269b9403…mp4` + photo of the link-board screen (the screen where full info belongs).
- **Spec:** `DABANH-SCOREBOARD-SPEC.md` gained a dated amendment (2026-11-21) recording this ruling; where it conflicts with the spec body, the amendment governs.

---

## 1 · SLIM SCORE-ONLY HERO (TVContentView.swift)

The hero keeps 1.4.9's hard frame discipline — ONE `heroLabel` frame for every kind, `HeroModel` as data, fixed-height slots, nil hero = the same frame unfocusable with `chrome: false` — and loses everything that is not a score essential:

- **Removed from the hero:** the event columns under the digits (scorers + card lines), and the meta line (league · group · source count). `HeroModel` no longer carries `meta` or `scoreState`; `heroMeta(_:)` and `nuvioHeroMeta(_:)` are deleted, and `leagueChannelCopy` returns to a 3-tuple (its fourth element, the hero's channel line, had no other consumer).
- **Kept:** the status badge (heroBadgeInfo — live minute/status, kickoff, FT, unchanged computation), the headline (team names), the crest art in its one 440×168 box, the score digits, the "Xem ngay" pill, the hero button → board path, and the focus keys (`hero:`/`heroEN:`/`heroNV:`).
- **New fixed geometry:** slots badge 40 · headline 114 (2 lines) · score 86 (the 69-pt digits' line — digits or empty) · pill 54, column spacings 14 → 12 (×3 = 36) → **`heroColumnHeight` 516 → 330**; panel vertical padding 28 → 18 → **panel 572 → 366**.

## 2 · FULL INFO IN THE DETAIL SCREEN (TVPlayerView.swift + TVMatchViews.swift)

`TVMatchBoardView`'s header is now the cluster's full home (the screen in the owner's photo):

- Row 1 unchanged: competition label + minute/status badge, height-39 reservation kept.
- Row 2: headline + **kickoff, now visible in every state** — in 1.4.9 the 56-pt score text displaced the kickoff on exactly the live boards where both matter.
- **Full score block below:** `TVScoreDigits` (the 69-pt digits) + `TVEventColumns` — the 1.4.7 hero block's event rendering moved **verbatim** to TVMatchViews.swift as shared structs (per-side columns, goals first then cards, cap 3 + "+N"): every scorer with minutes, cards as glyph lines. This replaces the header's old summary (top-2 goal lines + aggregate card counts; `eventLines`/`cardCount` deleted).
- **Reservations at the full block's size** (the FL-360 S-4 discipline, re-sized): live/HT board with a score but no events yet reserves the event area's fullest height **121** (divider 1 + spacing 12 + four lines 108); a live/HT board whose score has not landed reserves the whole block **219** (86 + 12 + 121). A finished board reserves nothing. Link lists below the header are byte-for-byte the old sections; focus still starts on the first VN row; `requestBoardDetail` still fires on appear. `MatchStateStore` untouched — the header consumes `entry.state` read-only, exactly as before.

## 3 · FULL-FRAME TILES (TVContentView.swift + TVMatchViews.swift)

Tile geometry is NOT touched (board 342 · featured card 330 in a 342 slot · match card 252 · 3-across width from the measured `tvTileWidth`) — what changes is the vertical budget, computed at the house convention (line ≈ 1.24 × size) on the 1080 canvas:

| Band | 1.4.9 | 1.5.0 |
|---|---|---|
| Root pads (top 40 + bottom 28) | 68 | 68 |
| Header (30 pt + 4) | 41 | 41 |
| Tab bar (45 + 10 + 45) | 100 | 100 |
| Status slot (FL-360 S-1) | 24 | 24 |
| Root VStack spacings (3 × 20) | 60 | 60 |
| **Chrome total** | **293** | **293** |
| Body region (1080 − chrome) | 787 | 787 |
| Hero panel | 572 | **366** |
| Hero↔rails spacing | 22 | **18** |
| **Rails ScrollView viewport** | **193** | **403** |
| First fixture rail's need (title 37 + spacing 4 + top inset 14 + tile 342) | 415 (tile visible ≈ 136/342) | **397 ≤ 403 ✓** |

Supporting trims: the three hero+rails VStacks (scrollBody / cupBody / enBody) go spacing 22 → 18; `TVFixtureRail`'s LazyHStack vertical inset goes 16 → 14 (its ring is strokeBorder, inside the tile frame, so 14 clears it whole). Result: at rest, the first rail's tiles stand **fully** inside the viewport — only the rail's own bottom padding tail scrolls. Card-only rails need 307, the EN tab's first Nuvio rail 325 — both fit with room. (The cups tab's first section additionally carries its 30-pt section title + 30 spacing above the rail, as in every prior build; its tiles are whole once the section head is counted as list content, and no band above them grew.)

**Bounded residual, stated honestly:** the 1.4.9 residuals stand — a section appearing/disappearing at a genuine data-truth change still changes total scroll height, and a standard rail's height can still change when its FIRST live board arrives. The slim hero does not claim to fix those; it removes the hero's own contribution (572 pt of panel + the full cluster's internal growth) and guarantees the resting viewport fits the first rail whole.

## Preserved from 1.4.9 (verified in gate Round 3)

FL-361 in full: the `"real betis balompie": "real betis"` alias (TeamNameNorm.swift), the Crests.swift date bridge with `lastMergedDateKey`, the Nuvio board-duplication suppression **with** the women's-marker guard (rebuildSnapshot). The "Logos: football-logos.cc" footer credit beside the version label. MatchStateStore untouched.

## Files changed

`DaBanhTV/TVContentView.swift` · `DaBanhTV/TVMatchViews.swift` · `DaBanhTV/TVPlayerView.swift` · `project.yml` · this report. (The spec amendment lives in the dabanh-ios tree's `tvos-training/` doc, as before.)

## Gate

- **Review gate: PASSED — 3 consecutive CLEAN rounds** on the final diff, three independent reviewers:
  - Round 1 (correctness vs the ruling + geometry + reference integrity): CLEAN — every layout number re-derived from the code (330 / 366 / 403 vs 397), hero scope verified for all four hero kinds, zero stale references.
  - Round 2 (Swift 6 isolation + capture maps + SDK surface): CLEAN — moved structs read only Sendable value data (`MatchState`/`MatchEvent` are `Equatable, Sendable`); no `TVKickoffFormat` crossing; every SwiftUI API in the changed code verified against the tvOS 17 SDK; no new state/tasks/globals.
  - Round 3 (whole-file integrity + preservation + spec↔code agreement): CLEAN — delimiter balance exact in all three files, FL-361 fixes and footer credit re-verified in place, every amendment claim checked against the code, behaviour regression sweep (focus keys, board path, nil shell, slotHeight) clean.
- No local Swift toolchain exists on this VM — CI is the first compiler, as in every prior round.
