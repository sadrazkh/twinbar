# Changelog

All notable changes to Twinbar. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.4.0] - 2026-11-22

Phase 4: the Twinbar window, and installing Twinbar.

### Added

- The Twinbar window (`twinbar gui`, or Twinbar in the Start menu once
  installed): the profiles with their icons and whether they're running;
  New and Edit with a live icon preview (app, name, colour with swatches or
  any custom colour, badge, icon style, appearance); Open; Remove, asking
  whether to delete the sign-in too; Repair, which asks where the app went if
  it moved; and Check all, which shows what `doctor` finds.
- `twinbar install [-Dir DIR] [-AddToPath]`: installs Twinbar for you, without
  admin rights, in `%LOCALAPPDATA%\Programs\Twinbar`, with Twinbar in the Start
  menu. `Twinbar.exe` is compiled there from source inside `twinbar.ps1`; it
  shows the window without a console, has its own icon and taskbar button, and
  opens only once. `-AddToPath` lets you type `twinbar` in any terminal.
- `twinbar uninstall`: removes the installed Twinbar (and its PATH entry);
  profiles stay and keep working.
- `twinbar apps [-Json]`: the Electron apps found in the Start menu and among
  the Microsoft Store apps, with what to give `-App`.
- Twinbar's own icon: two overlapping windows.

### Changed

- `remove -DeleteData` also removes the empty folders it leaves behind in
  Twinbar's data folders.

## [0.3.0] - 2026-11-22

Phase 3: change and repair profiles, light/dark, Microsoft Store apps.

### Added

- `twinbar change PROFILE`: a new colour, badge, style or appearance. The name
  and data stay. Taskbar pins of the profile get the new icon too.
- `twinbar rebuild PROFILE [-App APP]` and `twinbar rebuild -All`: make the
  shortcut, icon and launcher again, after the app moved (`-App` with its new
  place), after an app or Twinbar update, or if something was deleted. Brings
  profiles made with 0.1.0 and 0.2.0 up to date.
- `twinbar doctor [PROFILE]`: checks Twinbar and the profiles (app, shortcut,
  icon, data, launcher, taskbar button, recent log lines) and says how to fix
  what's wrong.
- `-Appearance system|light|dark` for `new` and `change`, for apps that follow
  Windows' light or dark setting (`--blink-settings=preferredColorScheme=1`
  and `--force-dark-mode`).
- Microsoft Store (MSIX) Electron apps, such as Claude: `-App Claude` (the
  package name), the app id, the exe under WindowsApps, or its execution alias.
  They're started through Windows' package activation, and their data is kept
  in `%USERPROFILE%\Twinbar`, outside AppData, where Windows would otherwise
  redirect it into the app's package.
- The app's own window (title bar, Alt+Tab) shows the profile's icon too.

### Changed

- Icon files are named after their look (`<id>-<hash>.ico`), so Windows never
  shows a stale icon from its cache after a change.

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
