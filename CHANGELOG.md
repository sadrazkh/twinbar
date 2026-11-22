# Changelog

All notable changes to Twinbar. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.9.0] - 2026-11-22

Storage and cache, extra options per profile, and backups.

### Added

- `twinbar storage [PROFILE] [-Json]`: how much each profile's data takes, and
  how much of it is cache. More... > Storage of the profiles shows the same.
- `twinbar clean PROFILE` and Clear cache... (right-click a profile): deletes
  only the profile's caches (Chromium's Cache, Code Cache, GPU and shader
  caches, service worker caches and crash reports, in its session partitions
  too); its sign-in, settings and local data stay, and the app fills the
  cache again.
- `-AppArgs "..."` and `-Environment "NAME=value;NAME2=value"` for `new` and
  `change` (`none` removes them), and Arguments and Environment in the
  New/Edit window: extra command-line switches for the app (`--disable-gpu`,
  say) and environment variables for it. `--user-data-dir` stays Twinbar's.
  Windows doesn't let Store apps be given environment variables, so only the
  arguments apply to them.
- `twinbar backup PROFILE [-File FILE.zip]` and Back up... (right-click a
  profile): the profile's settings and data folder in a zip, without caches,
  in Documents\Twinbar backups unless you pick a file. `twinbar restore
  FILE.zip [-Name NAME] [-App APP]` and More... > Restore a backup... make the
  profile again from it, with its look, proxy and options (the window picks
  the next free name, "Work 2", while the original is still there). Apps tie
  their sign-in to your Windows account, so a backup restored on another
  computer or account has its data but usually needs signing in again
  (Twinbar says so). A backup holds the sign-in: keep it as safe as a
  password.
- Right-click a profile in the window for all it can do: Open, Edit, Check IP,
  Clear cache, Back up, Repair, Remove.
- The Twinbar window keeps a short log, `%APPDATA%\Twinbar\logs\window.log`:
  when it started, why its window closed and whether it stayed by the clock,
  requests from another Twinbar.exe, and slow refreshes. Useful when
  reporting a problem.

### Changed

- Every release on GitHub, old ones too, has fuller notes, from
  `docs/releases/`; the Release workflow keeps them up to date. Twinbar's
  update window shows just their what's-new part.

## [0.8.0] - 2026-11-22

An icon by the clock, starting with Windows, and a jump list.

### Added

- Twinbar's icon in the notification area while it runs. Click it for the
  window; right-click it for your profiles, each with whether it's running and
  whether its proxy answers ("proxy OK", "proxy down"), to open one with a
  click. The same menu has an update when there is one, Twinbar's switches and
  Quit Twinbar.
- Closing the window keeps Twinbar by the clock (it says so the first time);
  More... or the icon's menu turns that off. Quit is in the icon's menu.
- Start Twinbar when you sign in to Windows (off by default): just the icon by
  the clock, from `Twinbar.exe --tray` in your user's Run key. Uninstalling
  removes it.
- A jump list: right-click Twinbar's taskbar button (or its pinned icon) for
  your profiles. The window and, once Twinbar is installed, the commands that
  change profiles keep it up to date.
- `twinbar settings [NAME on|off]`: updates, tray and startup.
- `Twinbar.exe --quit` ends a running Twinbar; opening Twinbar while it runs
  by the clock shows its window. `twinbar gui -Tray` starts with just the icon.

### Changed

- With the window hidden, a new version is announced by a note by the clock
  instead of a dialog.

## [0.7.0] - 2026-11-22

Updates from inside Twinbar, and finding the proxy on your computer.

### Added

- Twinbar checks GitHub for a newer version once a day while its window is
  open (More > Check for updates automatically turns that off). When there is
  one, it says so once, with what's new, and the version at the bottom right
  turns into an "Update to x.y.z" link. Update now downloads the installer,
  checks it against the release's `SHA256SUMS` (and that it comes from
  Twinbar's own GitHub releases), closes Twinbar, installs quietly over it and
  opens it again. Profiles stay as they are. Traffic follows Windows' proxy
  setting.
- `twinbar update [-Check]`: the same from the command line. For a Twinbar from
  Scoop it says to run `scoop update twinbar`; for one installed from the zip
  it opens the installer's window.
- The window shows Twinbar's version at the bottom right, and a More menu:
  check for updates, the automatic check, find proxies, and about.
- `twinbar proxies [-Json]` and Find... next to the Proxy field: the proxies
  running on this computer (v2rayN, Clash, NekoRay, sing-box, Hiddify, Tor,
  ... on their usual ports) and the one Windows is set to use, each tried both
  as HTTP and SOCKS5 and asked to connect out, so you see which works. HTTP ones
  come first; picking one fills in the Proxy field.

## [0.6.1] - 2026-11-22

Better proxy advice, after Claude went wrong behind a SOCKS proxy.

### Fixed

- With a SOCKS proxy, the launcher no longer puts the SOCKS address in
  `HTTPS_PROXY` and `HTTP_PROXY` (most Node.js code can't use it there and
  fails); it goes in `ALL_PROXY` only. HTTP proxies still set all three.

### Changed

- Setting a SOCKS proxy (`new`, `change`, `doctor`, and the window's hint) now
  says that some apps' code outside Chromium can't use SOCKS and goes around
  it, and to use the proxy's HTTP address if it has one. Measured with Claude
  signed in: Claude Code's sessions skip a SOCKS proxy ("not supported by
  downstream HTTP agents") and try to connect directly, so sessions and folders
  don't load where that fails; through an HTTP proxy they work. xray's and
  v2ray's local ports usually speak HTTP as well as SOCKS.

## [0.6.0] - 2026-11-22

A proxy for each profile, with a kill switch, and an IP check.

### Added

- `-Proxy socks5://host:port` (or `http://`, `https://`) for `new` and
  `change`, and a Proxy field in the window; `-Proxy none` removes it. The
  profile's web traffic then goes only through it, and it's strict, so it
  works as a kill switch: Chromium never falls back to a direct connection,
  names are looked up through the proxy (only the proxy and localhost are
  looked up locally), and WebRTC can't send UDP around it. If the proxy is
  down, the profile is offline. For normal and Squirrel installs, the
  launcher also sets `HTTPS_PROXY`, `HTTP_PROXY` and `ALL_PROXY` for the app's
  code outside Chromium (Windows doesn't let Store apps be given these).
  Store apps go without the DNS rule: Claude from the Microsoft Store doesn't
  start with it (measured); its connections still go only through the proxy.
- `twinbar ip [PROFILE]` and a Check IP button: the IP address, place and
  network the world sees for the profile (through its proxy, the same way its
  traffic goes), next to the one without a proxy.
- `doctor` checks that a profile's proxy answers.

## [0.5.1] - 2026-11-22

A Windows installer.

### Added

- `Twinbar-Setup-<version>.exe` in each release: double-click it to install
  Twinbar for you (no admin rights) into `%LOCALAPPDATA%\Programs\Twinbar`,
  with Twinbar in the Start menu and in Settings > Apps, and an option to put
  `twinbar` on your PATH. It opens Twinbar when it's done. It runs
  `twinbar install` in that folder, so `Twinbar.exe` is still compiled on your
  computer; installing over an earlier version also brings your profiles up
  to date (`twinbar rebuild -All`). Uninstalling keeps your profiles. Built
  with Inno Setup; not code-signed yet, so Windows may ask you to confirm.
- CI builds the installer and tests a silent install, the window, and a silent
  uninstall on every push.

### Changed

- Double-clicking `twinbar.cmd` opens the Twinbar window instead of flashing
  the help text.
- `twinbar install -Dir <folder>` works from a copy that's already in that
  folder (as the installer runs it), and installs CHANGELOG.md too.

## [0.5.0] - 2026-11-22

The first release. Twinbar gives an Electron app (Slack, Discord, Postman,
Bruno, Cursor, Claude, ...) a second, separately signed-in copy on Windows,
with its own Start menu entry, taskbar button and icon, without changing the
app. In short, from the earlier versions:

- Profiles with their own data folder, so their own sign-in, for normal,
  Squirrel and Microsoft Store installs; `new`, `list`, `open`, `remove`.
- Their own taskbar button and icon (recoloured and/or badged), through a small
  launcher that puts the profile's ID on the app's windows.
- `change`, `rebuild`, `doctor`, and light/dark per profile.
- The Twinbar window, `install` and `uninstall`, and `apps`.

### Added

- Release files on GitHub: `twinbar-<version>.zip`, a Scoop manifest
  (`scoop install https://github.com/sadrazkh/twinbar/releases/download/v0.5.0/twinbar.json`),
  `SHA256SUMS`, and signed build provenance (`gh attestation verify`).
- GitHub Actions: CI runs the tests and PSScriptAnalyzer on every push and pull
  request; the Release workflow tests, builds and publishes a version, and
  makes its tag, as soon as `main` has a version without one.
- `tools/make-release.ps1` builds the release files (the tests check it too).
- CONTRIBUTING.md and SECURITY.md.

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
