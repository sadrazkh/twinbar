# Twinbar

A second, separately signed-in copy of your Electron apps on Windows: work and
personal Slack, two Postman accounts, a test login next to your real one.

Twinbar adds an entry such as **Postman Work** to the Start menu. It opens the
same installed app, with its own sign-in, settings and local data, and its own
taskbar button and icon. The original app isn't changed, and both can run at
the same time.

![The same app's icon in Twinbar's four styles: original, colour and badge, colour only, badge only](docs/styles.png)

> **Status: early (0.2.0).** Phases 1 and 2 of 5 are done: the command line,
> and an own icon and taskbar button. See [docs/phases.md](docs/phases.md).

## Requirements

- Windows 10 or 11.
- Nothing to install: Twinbar is one PowerShell script that runs with the
  Windows PowerShell 5.1 and .NET Framework built into Windows. No admin rights
  needed.
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
.\twinbar.cmd new -App "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Postman\Postman.lnk" -Name Personal -Color green
```

Then open **Bruno Work** from the Start menu (it's in the *Twinbar* folder), or:

```powershell
.\twinbar.cmd open "Bruno Work"
.\twinbar.cmd list
```

It gets a taskbar button of its own; pin it like any other.

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
| `new -App PATH -Name NAME` | Make a profile. See the options below. |
| `list [-Json]` | Show the profiles and whether each is running |
| `open PROFILE` | Start a profile |
| `remove PROFILE [-DeleteData]` | Remove a profile's shortcut and icon; with `-DeleteData`, its data too |
| `help`, `version` | |

Options for `new`:

| Option | |
|---|---|
| `-Color C` | `blue`, `green`, `purple`, `orange`, `pink`, `teal`, `red`, `indigo`, `yellow`, `gray` or `#RRGGBB`. By default a colour is picked from the name. |
| `-Badge B` | 1 or 2 letters or digits. By default the name's first letter. |
| `-Style S` | `tint+badge` (default), `tint` (colour only), `badge` (original colours and a badge) or `original` (the app's own icon) |
| `-DataDir DIR` | Keep the profile's data in another folder |
| `-AdoptDataDir` | Use a data folder that already has data in it |
| `-ShortcutDir DIR` | Put the shortcut somewhere other than the Start menu |

## How it works

Electron apps accept `--user-data-dir=<folder>`: everything the app keeps about
you (sign-in, settings, caches) then lives in that folder. A second folder means
a second, independent copy, and Electron's one-copy-at-a-time lock is per
folder, so both copies can run together.

The taskbar groups windows by their AppUserModelID. Electron apps set one for
the whole app, so on its own a second copy would join the original's button.
A profile's shortcut therefore starts a small **launcher**, which starts the app
and then puts the profile's own ID, name and icon on the app's windows. The
taskbar then shows them as a button of their own, and pinning it pins the
profile. The launcher only sets these window properties: it doesn't inject
anything into the app or change it. It stays in the background while the
profile is open and quits after it closes.

| | |
|---|---|
| Start menu entry | `Start Menu\Programs\Twinbar\<App> <Name>.lnk`. It starts the launcher with the profile's id and carries the profile's AppUserModelID (`Twinbar.<app>.<name>`). |
| Launcher | `%APPDATA%\Twinbar\bin\twinbar-launcher.exe`, compiled on your computer from the source inside `twinbar.ps1` the first time it's needed, and again after a Twinbar update. Its log is `%APPDATA%\Twinbar\logs\launcher.log`. |
| Icons | `%APPDATA%\Twinbar\icons\<app>.<name>.ico`, drawn from the app's own icon, 16 to 256 pixels |
| Profile data | `%APPDATA%\Twinbar\data\<app>\<name>\`, with a small `.twinbar-profile` marker file |
| Profile records | `%APPDATA%\Twinbar\profiles\<app>.<name>.json` |
| Normal installs | The app's own `.exe` is started. |
| Squirrel installs (Slack, Discord, Postman...) | The launcher in the app's install folder is started; it always runs the newest version, so profiles keep working after the app updates. |

Twinbar never modifies the app. Removing moves files to the Recycle Bin, and a
data folder is only ever removed if it carries that profile's marker.

## Limitations

- **Window icon:** the taskbar button and the Start menu show the profile's
  icon, but the app's own window (title bar, Alt+Tab) keeps the app's icon.
- **Shared storage:** data an app keeps outside its data folder is shared
  between profiles, for example passwords some apps store in Windows
  Credential Manager, or settings in the registry.
- **Microsoft Store apps** (installed under `WindowsApps`, such as Claude) aren't
  supported yet; that's phase 3.
- **Profiles made with 0.1.0** keep working but have no icon or taskbar button
  of their own; make them again (`remove`, then `new`; the sign-in is kept).
- Where policy blocks programs in your user folder (AppLocker and the like),
  the launcher can't run.
- Tested so far with Bruno 4.3 (normal install) and Postman 12.33 (Squirrel
  install), on Windows 11.

## Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1 -RealApp "C:\Program Files\Bruno\Bruno.exe" -Launch
```

The tests build a fake Electron app and work in a temporary folder, never in
your Start menu or profiles. A few small test files go to the Recycle Bin. The
fake app briefly shows a window, to check that it gets a taskbar button of its
own. With `-RealApp ... -Launch`, the real app is opened once with an empty
data folder and closed again.

## Credits and licence

Inspired by [DoppelDock](https://github.com/ZarinLab/doppeldock), which does
this on macOS. Twinbar is a separate project written from scratch for Windows,
and isn't affiliated with DoppelDock or with the makers of any app it works with.

[MIT](LICENSE)
