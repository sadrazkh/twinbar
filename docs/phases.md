# Phases

Twinbar is built in five phases. Each phase ends with working, tested code on
`main` and a line in [CHANGELOG.md](../CHANGELOG.md).

| Phase | What you get | Status |
|---|---|---|
| 1 | Core command line: profiles with their own sign-in, from the Start menu | Done (0.1.0) |
| 2 | Own icon and own taskbar button | Next |
| 3 | Change and repair profiles; light/dark; Microsoft Store apps | Planned |
| 4 | The Twinbar app: windows and forms, no terminal needed | Planned |
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
  with System.Drawing into a multi-size `.ico` kept with the profile.
- A separate taskbar button. What phase 1 measured: started from its Start
  menu shortcut, an app is told which shortcut started it
  (`STARTF_TITLEISLINKNAME`), so Windows can apply the shortcut's ID. But most
  Electron apps set their own AppUserModelID, which wins, and a Squirrel
  launcher starts the real app with fresh start-up information, so the link is
  probably lost there. Either way a profile's windows can group with the
  original app. Plan: measure this per app, then tag the profile's windows with
  the profile's ID (window property store) from a small hidden launcher, with
  relaunch command and icon set so that pinning the button pins the profile,
  not the original.
- A fallback for apps where tagging isn't possible, documented per app.

Done when: the original and the profile show as two taskbar buttons with
different icons, and pinning either one reopens the right one.

## Phase 3: change and repair profiles, more apps

- `change` (colour, badge, appearance; the name and data folder stay),
  `rebuild` (repair shortcuts after an app moves or is reinstalled), `doctor`.
- Appearance per profile: light, dark or the same as Windows.
- Microsoft Store (MSIX) apps such as Claude: start them through package
  activation with arguments, and keep their data outside AppData so Windows'
  per-package redirection doesn't hide it.

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
