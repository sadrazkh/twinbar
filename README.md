# Twinbar

A second, separately signed-in copy of your Electron apps on Windows: work and
personal Slack, two Postman accounts, a test login next to your real one.

Twinbar adds an entry such as **Postman Work** to the Start menu. It opens the
same installed app, with its own sign-in, settings and local data. The original
app isn't changed, and both can run at the same time.

> **Status: early (0.1.0).** Phase 1 of 5 is done: the command line. An own icon
> and own taskbar button come in phase 2. See [docs/phases.md](docs/phases.md).

## Requirements

- Windows 10 or 11.
- Nothing to install: Twinbar is one PowerShell script that runs with the
  Windows PowerShell 5.1 built into Windows. No admin rights needed.
- The app must be built on Electron (Slack, Discord, Postman, Bruno, VS Code,
  Figma, Signal, MongoDB Compass, ...).

## Get it

```powershell
git clone https://github.com/sadrazkh/twinbar.git
cd twinbar
.\twinbar.cmd help
```

Or download the repository as a zip and unpack it anywhere. `twinbar.cmd` runs
`twinbar.ps1` whatever your PowerShell execution policy is.

## Use it

Make a profile. `-App` takes the app's `.exe`, its install folder or its Start
menu shortcut:

```powershell
.\twinbar.cmd new -App "C:\Program Files\Bruno\Bruno.exe" -Name Work
.\twinbar.cmd new -App "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Postman\Postman.lnk" -Name Personal
```

Then open **Bruno Work** from the Start menu (it's in the *Twinbar* folder), or:

```powershell
.\twinbar.cmd open "Bruno Work"
.\twinbar.cmd list
```

Remove a profile. Its sign-in is kept, so making the profile again brings it
back, unless you add `-DeleteData`:

```powershell
.\twinbar.cmd remove "Bruno Work"
.\twinbar.cmd remove "Bruno Work" -DeleteData
```

A profile can be named by its name (`Work`), its full name (`Bruno Work`) or
its id (`bruno.work`, shown by `list`). Names can use letters in any language,
digits, spaces, `.`, `_` and `-`.

| Command | What it does |
|---|---|
| `new -App PATH -Name NAME` | Make a profile. Options: `-DataDir DIR` (keep its data elsewhere), `-AdoptDataDir` (use a folder that already has data), `-ShortcutDir DIR` (put the shortcut elsewhere) |
| `list [-Json]` | Show the profiles and whether each is running |
| `open PROFILE` | Start a profile |
| `remove PROFILE [-DeleteData]` | Remove a profile's shortcut; with `-DeleteData`, its data too |
| `help`, `version` | |

## How it works

Electron apps accept `--user-data-dir=<folder>`: everything the app keeps about
you (sign-in, settings, caches) then lives in that folder. A second folder means
a second, independent copy, and Electron's one-copy-at-a-time lock is per
folder, so both copies can run together.

| | |
|---|---|
| Start menu entry | `Start Menu\Programs\Twinbar\<App> <Name>.lnk`, which starts the app with `--user-data-dir`. It carries its own AppUserModelID (`Twinbar.<app>.<name>`). |
| Profile data | `%APPDATA%\Twinbar\data\<app>\<name>\`, with a small `.twinbar-profile` marker file |
| Profile records | `%APPDATA%\Twinbar\profiles\<app>.<name>.json` |
| Normal installs | The shortcut starts the app's own `.exe`. |
| Squirrel installs (Slack, Discord, Postman...) | The shortcut starts the launcher in the install folder, which always runs the newest version, so profiles keep working after the app updates. |

Twinbar never modifies the app. Removing moves files to the Recycle Bin, and a
data folder is only ever removed if it carries that profile's marker.

## Limitations

- **Taskbar:** a profile's windows may share the original app's taskbar button
  and icon, because most Electron apps set their own taskbar ID. Fixing this is
  phase 2.
- **Shared storage:** data an app keeps outside its data folder is shared
  between profiles, for example passwords some apps store in Windows
  Credential Manager, or settings in the registry.
- **Microsoft Store apps** (installed under `WindowsApps`, such as Claude) aren't
  supported yet; that's phase 3.
- Tested so far with Bruno 4.3 (normal install) and Postman 12.33 (Squirrel install).

## Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1 -RealApp "C:\Program Files\Bruno\Bruno.exe" -Launch
```

The tests build a fake Electron app and work in a temporary folder, never in
your Start menu or profiles. A few small test files go to the Recycle Bin. With
`-RealApp ... -Launch`, the real app is opened once with an empty data folder
and closed again.

## Credits and licence

Inspired by [DoppelDock](https://github.com/ZarinLab/doppeldock), which does
this on macOS. Twinbar is a separate project written from scratch for Windows,
and isn't affiliated with DoppelDock or with the makers of any app it works with.

[MIT](LICENSE)
