# Phases

Twinbar is built in five phases. Each phase ends with working, tested code on
`main` and a line in [CHANGELOG.md](../CHANGELOG.md).

| Phase | What you get | Status |
|---|---|---|
| 1 | Core command line: profiles with their own sign-in, from the Start menu | Done (0.1.0) |
| 2 | Own icon and own taskbar button | Done (0.2.0) |
| 3 | Change and repair profiles; light/dark; Microsoft Store apps | Done (0.3.0) |
| 4 | The Twinbar app: windows and forms, no terminal needed | Next |
| 5 | CI, signed releases, winget/Scoop, docs | Planned |

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

- A window (WinForms, from the same script): the profiles list, a New/Edit
  form with an icon preview, and a Remove dialog.
- `install` / `uninstall`: copy Twinbar to `%LOCALAPPDATA%\Programs\Twinbar`,
  add it to the Start menu and optionally put `twinbar` on PATH. No admin rights.

## Phase 5: CI, releases and docs

- GitHub Actions: PSScriptAnalyzer, tests on `windows-latest` against Electron
  from npm, actions pinned to commit hashes.
- Release workflow: zip, `SHA256SUMS` and build provenance; winget and Scoop
  manifests.
- CONTRIBUTING, SECURITY, screenshots, and optionally a small website.

## Not planned

- macOS or Linux. On a Mac, use [DoppelDock](https://github.com/ZarinLab/doppeldock),
  which inspired this project.
- Apps that aren't built on Electron.
- Patching, injecting into or re-signing apps, or bypassing licence checks.
- Network connections or analytics of any kind.
