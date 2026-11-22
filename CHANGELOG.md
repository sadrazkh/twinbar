# Changelog

All notable changes to Twinbar. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-11-22

Phase 1: the core command line.

### Added

- `twinbar new`: make a profile of an Electron app with its own data folder
  (so its own sign-in) and its own Start menu entry. Takes the app's `.exe`,
  its install folder or its Start menu shortcut. Handles normal installs and
  Squirrel per-user installs (following their updates).
- Each profile's shortcut has its own AppUserModelID.
- `twinbar list [-Json]`, `twinbar open`, `twinbar remove [-DeleteData]`.
  Removal uses the Recycle Bin, keeps the sign-in unless asked, and only
  deletes data folders that carry the profile's Twinbar marker.
- `tests/smoke.ps1`: static, unit and end-to-end tests with a fake Electron app,
  plus an optional run against a real app.
