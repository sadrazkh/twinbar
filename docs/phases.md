# Phases

Twinbar is built in phases. Each phase ends with working, tested code on
`main` and a line in [CHANGELOG.md](../CHANGELOG.md).

| Phase | What you get | Status |
|---|---|---|
| 1 | Core command line: profiles with their own sign-in, from the Start menu | Done (0.1.0) |
| 2 | Own icon and own taskbar button | Done (0.2.0) |
| 3 | Change and repair profiles; light/dark; Microsoft Store apps | Done (0.3.0) |
| 4 | The Twinbar app: windows and forms, no terminal needed | Done (0.4.0) |
| 5 | CI, signed releases, Scoop, docs | Done (0.5.0, the first release) |
| 6 | Updates from inside Twinbar; finding the proxy on this computer | Done (0.7.0) |
| 7 | An icon in the notification area, starting with Windows, and a jump list | Done (0.8.0) |
| 8 | Storage and cache, advanced options, backup and restore | Next (0.9.0) |

## Phase 1: core command line

Goal: a second, separately signed-in copy of an Electron app, started from its
own Start menu entry, without touching the original app.

- `twinbar new -App <exe | install folder | Start menu shortcut> -Name <name>`
  finds the app, makes a data folder for the profile and adds
  "&lt;App&gt; &lt;Name&gt;" to the Start menu. The shortcut starts the app with
  `--user-data-dir=<data folder>`.
- Works with normal installs (Program Files, `%LOCALAPPDATA%\Programs`) and with
  Squirrel per-user installs (Slack, Discord, Postman...). For Squirrel apps the
  shortcut goes through the launcher in the install root, so app updates are
  followed automatically.
- Each profile's shortcut carries its own AppUserModelID (`Twinbar.<app>.<name>`),
  the groundwork for phase 2.
- `list [-Json]`, `open`, `remove [-DeleteData]`. Removing moves things to the
  Recycle Bin, keeps the sign-in unless `-DeleteData` is given, and only ever
  deletes a data folder that carries this profile's Twinbar marker.
- Tests: `tests/smoke.ps1` runs static checks, unit checks and end-to-end
  checks against a fake Electron app, and optionally against a real app.

Done when: the tests pass and a real app opens signed out from its new
Start menu entry while the original keeps its sign-in.

## Phase 2: own icon and own taskbar button

- Recoloured icon and/or a letter badge (`-Color`, `-Badge`, `-Style`), drawn
  with System.Drawing into a multi-size `.ico` (16 to 256 pixels) kept with the
  profile. Below 24 pixels the badge is a plain dot.
- A separate taskbar button, through a launcher (see below).

What was measured first, reading each taskbar button's AppUserModelID through
UI Automation, with Bruno 4.3 and Postman 12.33:

| How the profile was started | Taskbar button |
|---|---|
| From a shortcut that has the profile's ID | The app's own (`com.usebruno.bruno`, `com.squirrel.Postman.Postman`) |
| With the profile's ID passed in the start-up information | The app's own |
| Then the profile's ID set on its windows from another process | **Its own**, straight away, no hide/show needed |

So the apps' own process-wide ID wins over anything given at start-up, and an
ID on the window wins over that. The profile's shortcut now starts
`twinbar-launcher.exe <profile id>`: a small C# program whose source is inside
`twinbar.ps1` and which is compiled on the user's computer. It starts the app
with the profile's data folder, finds the app's main process (our executable,
our `--user-data-dir`, no `--type=`, not Squirrel's launcher), and puts the
profile's relaunch name, command and icon and then its ID on every top-level
window of that process. It catches new windows with a WinEvent hook on that
process plus a check every 0.4 s, gives the app 2 minutes to start and
10 seconds to come back after it quits (apps restart to finish updates), and
lets only one launcher look after a profile at a time (a named mutex).

Done: the tests check the window's ID and the taskbar button (fake app, Bruno
and Postman); a screenshot of Bruno's button shows the recoloured, badged icon.
Not checked by hand yet: pinning the button and starting the profile from the
pin (the relaunch command and icon are set for it).

## Phase 3: change and repair profiles, more apps

- `change PROFILE` (colour, badge, style, appearance; the name and data folder
  stay). Icon files are named after their look (`<id>-<hash>.ico`) so Windows'
  icon cache can't show the old one, and taskbar pins with the profile's ID
  are pointed at the new icon.
- `rebuild PROFILE [-App APP]` and `rebuild -All`: the shortcut, icon, pins,
  launcher and record again, from the record. Follows Squirrel updates, moves
  a profile to the app's new place (only the same app: the id comes from the
  exe's name), and brings 0.1.0 and 0.2.0 profiles up to date.
- `doctor [PROFILE]`: app, shortcut, icon, data folder, launcher, taskbar
  button (through UI Automation) and the last log lines, each with what to run
  to fix it. Fails (exit code 1) when it finds a problem.
- `-Appearance system|light|dark`: the same Chromium switches DoppelDock uses,
  `--blink-settings=preferredColorScheme=1` and `--force-dark-mode`.
- The launcher gives the app's windows the profile's icon too (`WM_SETICON`,
  sized for each window's DPI), checked again every 0.4 s.
- Microsoft Store (MSIX) apps. Measured with Claude 6.28 first:
  `IApplicationActivationManager::ActivateApplication("<family>!<app>", args)`
  starts a second copy with the arguments, like any desktop app; its window
  joins the package's taskbar button, and the window property moves it to its
  own, as for other apps. Claude's package has file-system write virtualization
  on, so what it writes under AppData lands in the package's `LocalCache`;
  Store profiles therefore keep their data in `%USERPROFILE%\Twinbar`, and
  `new` refuses a `-DataDir` under AppData for them. Apps are found by package
  name (`-App Claude`), app id, exe under WindowsApps, or execution alias, from
  each package's `AppxManifest.xml`.

Done: 212 checks with the fake app (227 with a real one), and Bruno, Postman and
Claude each opened through their profiles with their own taskbar button, and
closed again without touching the copy already open. Checked on a real Bruno
window: title bar and Alt+Tab icons in the profile's colour.

Still not checked by hand: pinning a profile's button and opening it from the
pin.

## Phase 4: the Twinbar app

- The window, in WinForms, built in code inside `twinbar.ps1`: the profiles
  with icons and status (refreshed every 4 s); New and Edit with a live
  preview (`IconMaker.Preview`), colour swatches and any custom colour, the
  colour following the name as on the command line until picked by hand;
  Open; Remove, asking about the sign-in; Repair, asking where a moved app
  went; Check all (`doctor`). Every button calls the same `Invoke-*` function
  as the command line. Sized for the screen's DPI.
- `Twinbar.exe`: a small C# host, compiled by `install` like the launcher, that
  runs `twinbar.ps1 gui` in a PowerShell runspace, so there's no console. It
  sets its own AppUserModelID (`Twinbar.App`, matching its Start menu entry),
  is DPI-aware, opens only once (a second start brings the window forward) and
  has Twinbar's own icon (two overlapping windows, drawn like the profile icons).
- `install [-Dir] [-AddToPath]` / `uninstall`: `%LOCALAPPDATA%\Programs\Twinbar`
  by default, no admin rights; the user PATH entry is added and removed only if
  asked, with a settings-changed broadcast so new terminals see it. Uninstall
  leaves the profiles working (their launcher lives in `%APPDATA%\Twinbar`).
- `apps [-Json]`: Electron apps from the Start menu (a cheap look at each
  shortcut's folder first) and from the Store packages' manifests. Found 10 on
  the development machine, including Cursor, pgAdmin and two Store apps.

Measured: normal start of the window 1.5 s; the very first start of a freshly
compiled `Twinbar.exe` took over 20 s, most likely Windows checking the new
program. Windows PowerShell's UI Automation client sees the window's controls
only as plain panes, so the tests read the list's row count with
`LVM_GETITEMCOUNT` instead.

Done: 276 checks (289 with a real app), including the dialogs filled in and
submitted, and the installed `Twinbar.exe` opening, listing, staying single and
closing.

## Phase 5: CI, releases and docs

- CI (`.github/workflows/ci.yml`): the tests with PSScriptAnalyzer 1.25.0
  (`PSScriptAnalyzerSettings.psd1`) on `windows-latest`, for every push and
  pull request. A failed check also becomes an error annotation on the run.
- Release (`.github/workflows/release.yml`): on every push to `main`, a quick
  job reads `$script:TwinbarVersion`; if `v<version>` has no tag yet, a Windows
  job runs the tests, builds the files with `tools/make-release.ps1` (zip, Scoop
  manifest, `SHA256SUMS`, notes from the CHANGELOG section), records signed
  build provenance for the zip and manifest, and creates the tag and the
  release. Releasing is: raise the version, add its CHANGELOG section, push.
- Actions pinned to commit hashes (checkout v7.0.1, attest-build-provenance
  v4.2.2), the least permissions per job, `persist-credentials: false`;
  Dependabot keeps them current, waiting 14 days for new releases.
- CONTRIBUTING.md, SECURITY.md, and the README's download section and badges.

Added after 0.5.0 (0.5.1): a Windows installer, `Twinbar-Setup-<version>.exe`,
built with Inno Setup 6 (on GitHub's Windows runners already). It installs per
user with no admin rights, copies the files and then runs `twinbar install` in
that folder, so `Twinbar.exe` is still compiled on the user's computer; it adds
an uninstall entry to Settings > Apps (which runs `twinbar uninstall`), offers
the PATH option, waits for an open Twinbar window to close (`AppMutex`), and
after an upgrade runs `rebuild -All`. CI and Release test it on a clean
machine: silent install, the window, the installed `twinbar.cmd`, silent
uninstall. Not code-signed: a certificate costs money, so for now Windows
SmartScreen asks once ("More info", "Run anyway"). A double-click on
`twinbar.cmd` now opens the window too.

Added in 0.6.0: a proxy per profile (`-Proxy`, the window's Proxy field) and
`twinbar ip` / Check IP. The proxy is passed as Chromium switches, strict so it
doubles as a kill switch for the app's web traffic: `--proxy-server` (no fallback
to direct), `--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE <proxy> , EXCLUDE
localhost` (no local DNS) and `--force-webrtc-ip-handling-policy=disable_non_proxied_udp`;
plus `HTTPS_PROXY`/`HTTP_PROXY`/`ALL_PROXY` from the launcher where Windows allows
it (not for Store apps). The IP check uses its own small client (SOCKS5 with the
name, or HTTP CONNECT, then TLS) so it goes the same way as the profile. Measured
with a logging SOCKS5 proxy and every TCP connection of the app for 30 s:
Postman all through it, nothing around it, nothing out with the proxy down;
Bruno's web traffic through it, but one connection from its Node.js main process
goes around it (and out, with the proxy down); Claude (Store) doesn't start with
the DNS rule, so Store apps go without it, and then all through it, nothing
around it, nothing out with the proxy down. Also measured, for a slow Claude
profile: Twinbar's launcher used 0.5% of one core; the second Claude itself
collides with the first over its global shortcut, its service and shared folders.

Left out, on purpose: winget. Its manifests live in Microsoft's
`winget-pkgs` repository, so publishing there means a pull request there from
the owner's account; the zip and its hash are what it would need.
The tests against Electron from npm were left out too: the tests use a fake
Electron app, plus the real installed apps when run by hand.

## Phase 6: updates, and finding the proxy (0.7.0)

- The window checks GitHub's API for the newest release once a day while it's
  open (a setting under More...), shows Twinbar's version at the bottom right,
  and turns it into an "Update to x.y.z" link when there's a newer one, asking
  once per version with what's new. Update now downloads the release's
  `SHA256SUMS` and installer (only from this repository's release downloads),
  checks the SHA-256, and hands over to a hidden PowerShell that waits for
  Twinbar to close, runs the installer with `/SILENT` and opens Twinbar again.
  The network work runs as .NET tasks that a WinForms timer looks at, so the
  window doesn't wait and no script runs off the window's thread.
- `twinbar update [-Check]` does the same from a terminal and waits for the
  installer. A Twinbar from Scoop is pointed at `scoop update`; one installed
  from the zip gets the installer's window.
- `twinbar proxies` and Find... next to Proxy: the usual ports of v2rayN, Clash,
  Clash Verge, NekoRay, sing-box, Hiddify, Shadowsocks and Tor, plus Windows'
  proxy setting, each tried at once as HTTP (CONNECT) and SOCKS5 and asked to
  connect to the IP check service: works, can't get out, or wants a password.
- Tests: a local stand-in for GitHub (the API answer, `SHA256SUMS`, a redirect
  to the file like GitHub's CDN) and a fake installer that writes down how it
  was started; a matching download is installed quietly, a mismatched one or
  one from another server is refused and deleted.

## Phase 7: notification area and jump list (0.8.0)

- A `NotifyIcon` while Twinbar runs: click for the window; its menu is built
  each time it opens, with the profiles (running or not, and a quick TCP check
  of each proxy, half a second at most), an update if there is one, the
  switches, and Quit. Closing the window hides it (`FormClosing` cancelled for
  `UserClosing` only, so Windows shutting down still ends it); the app now runs
  on an `ApplicationContext`, so it lives on without the window.
- `Twinbar.exe --tray` starts with just the icon; `--quit` ends a running one.
  A second `Twinbar.exe` signals the first through named events
  (`Local\Twinbar.App.Show`, `Local\Twinbar.App.Quit`), which a 300 ms timer
  looks at, after `AllowSetForegroundWindow` so the window can come forward.
- Start with Windows: `"<dir>\Twinbar.exe" --tray` in
  `HKCU\...\CurrentVersion\Run`, only for an installed Twinbar; `uninstall`
  removes it, and the jump list.
- The jump list: `ICustomDestinationList` tasks (an `IShellLink` per profile:
  the launcher, the profile id, its icon, and `PKEY_Title`) under
  `Twinbar.App`. Tasks, not a custom category, because users can't remove
  tasks one by one, which would make the next update of the list fail.
- Tests use their own jump list ID and Run key; they check the list's file
  under `Recent\CustomDestinations` for the title, `--tray`, showing, hiding
  and `--quit` end to end, and the installer test closes to the tray.

## Phase 8: storage, advanced options, backup (0.9.0)

Planned: each profile's size and a Clear cache that keeps the sign-in; extra
command-line arguments and environment variables per profile; backing a profile
up to a zip and restoring it.

## Not planned

- macOS or Linux. On a Mac, use [DoppelDock](https://github.com/ZarinLab/doppeldock),
  which inspired this project.
- Apps that aren't built on Electron.
- Patching, injecting into or re-signing apps, or bypassing licence checks.
- Analytics, or any network connection beyond the update check, the IP check
  and finding proxies (see SECURITY.md).
