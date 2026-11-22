# Changelog

All notable changes to Twinbar. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-11-22

Phase 2: own icon and own taskbar button.

### Added

- Each profile gets its own taskbar button. A small launcher, built on your
  computer the first time it's needed, starts the app and puts the profile's
  AppUserModelID on the app's windows (apps set their own ID, which would
  otherwise put every profile on the original app's button). Pinning the
  button pins the profile. Nothing is injected into the app.
- Each profile gets its own icon: the app's icon recoloured and/or with a
  letter badge. New options for `twinbar new`: `-Color` (a palette name or
  `#RRGGBB`; picked from the name by default), `-Badge` (1 or 2 letters; the
  name's first letter by default) and `-Style` (`tint+badge`, `tint`, `badge`
  or `original`).
- The launcher logs what it does in `%APPDATA%\Twinbar\logs\launcher.log`.

### Changed

- A profile's Start menu shortcut now starts the launcher with the profile's id
  instead of starting the app directly. Profiles made with 0.1.0 keep working
  as before; make them again to get the new icon and taskbar button.

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
