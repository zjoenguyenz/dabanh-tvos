# Đá Banh TV (tvOS)

Đá Banh for Apple TV — split out of the `dabanh-ios` monorepo
on 2026-11-18 so the app migrates and ships on its own track.

- Project: XcodeGen (`project.yml`) — run `xcodegen generate`,
  then build scheme `DaBanhTV` (plus its `DaBanhTVTopShelf`
  extension).
- CI: `.github/workflows/build-dabanhtv.yml` (manual dispatch)
  builds an unsigned IPA; the owner signs it himself.
