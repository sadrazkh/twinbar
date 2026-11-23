# Twinbar

[![CI](https://github.com/sadrazkh/twinbar/actions/workflows/ci.yml/badge.svg)](https://github.com/sadrazkh/twinbar/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/sadrazkh/twinbar)](https://github.com/sadrazkh/twinbar/releases/latest)
[![MIT licence](https://img.shields.io/github/license/sadrazkh/twinbar)](LICENSE)
[![Website](https://img.shields.io/badge/website-sadrazkh.github.io%2Ftwinbar-7c5cff)](https://sadrazkh.github.io/twinbar/)

A second, separately signed-in copy of your Electron apps and Telegram on
Windows: work and personal Slack or Telegram, two Claude or Postman accounts, a
test login next to your real one.

**[Website: try it in your browser](https://sadrazkh.github.io/twinbar/)**, with an
interactive desktop and an icon designer that writes the command for you
(in English and Persian).

Twinbar adds an entry such as **Postman Work** to the Start menu. It opens the
same installed app, with its own sign-in, settings and local data, and its own
taskbar button and icon. The original app isn't changed, and both can run at
the same time. Microsoft Store apps such as Claude work too.

![The same app's icon in Twinbar's four styles: original, colour and badge, colour only, badge only](docs/styles.png)

> **Status: early releases (0.x).** See [docs/phases.md](docs/phases.md) for
> what's done and what's next. It's young: tested on Windows 11 with a
> handful of apps, so please report what doesn't work.

## Requirements

- Windows 10 or 11.
- Nothing else: Twinbar is one PowerShell script that runs with the Windows
  PowerShell 5.1 and .NET Framework built into Windows. No admin rights needed.
- The app must be built on Electron (Slack, Discord, Postman, Bruno, VS Code,
  Cursor, Figma, Signal, MongoDB Compass, Claude, ...), or be Telegram Desktop
  from telegram.org (see [Telegram](#telegram)). For other apps Twinbar says
  why it can't twin them: Chromium browsers have profiles of their own, and
  apps built on CEF (Steam, Spotify) or most other frameworks have no way to
  be given a second data folder. Antigravity is refused too: it keeps its
  sign-in outside its data folder (see [Limitations](#limitations)).

## Get it

Download **`Twinbar-Setup-<version>.exe`** from the
[latest release](https://github.com/sadrazkh/twinbar/releases/latest) and run
it. It installs Twinbar for you only, with no admin rights, into
`%LOCALAPPDATA%\Programs\Twinbar`, puts **Twinbar** in the Start menu and opens
it; tick the option to also type `twinbar` in any terminal. Uninstall it from
Settings > Apps; your profiles stay and keep working.

The installer isn't code-signed yet, so Windows may say "Windows protected your
PC": click **More info**, then **Run anyway**.

Or download `twinbar-<version>.zip`, unpack it anywhere, and double-click
`twinbar.cmd` to open the window, or run `.\twinbar.cmd install -AddToPath`
there to install it the same way.

With [Scoop](https://scoop.sh), from the release's manifest (then
`twinbar install` for the Start menu entry):

```powershell
scoop install https://github.com/sadrazkh/twinbar/releases/latest/download/twinbar.json
```

Or from the source: `git clone https://github.com/sadrazkh/twinbar.git`, then
the same `.\twinbar.cmd install` in that folder.

Each release lists the files' SHA-256 in `SHA256SUMS` and has signed build
provenance: `gh attestation verify Twinbar-Setup-<version>.exe -R sadrazkh/twinbar`.

You can also use it without installing: `.\twinbar.cmd` runs `twinbar.ps1`
whatever your PowerShell execution policy is, and `.\twinbar.cmd gui` opens the
window.

### Updates

The window shows Twinbar's version at the bottom right and checks GitHub for a
newer one once a day. When there is one, it tells you once, with what's new,
and the version turns into an **Update to x.y.z** link. **Update now**
downloads the installer, checks its SHA-256 against the release's `SHA256SUMS`
(and that it comes from this repository's releases), closes Twinbar, installs
over it and opens it again; your profiles stay as they are. Turn the daily
check off under **More...**, where **Check for updates** checks right away.
From a terminal:

```powershell
twinbar update -Check   # is there a newer version?
twinbar update          # download, check and install it
```

The check and the download go the way Windows' proxy setting says, like a
browser's traffic. A Twinbar from Scoop updates with `scoop update twinbar`.

## Use the window

Open **Twinbar** from the Start menu. **New profile...** lists the Electron apps
it found (**Find...** for any other); pick one, give the profile a name, and
choose its colour, badge, icon style and appearance while the preview shows the
result. The list shows your profiles and whether each is running; select one to
**Open**, **Edit**, **Remove** (it asks whether to delete the sign-in too) or
**Repair** it (it asks where the app went if it moved). **Check all** runs the
same checks as `twinbar doctor`. **More...** has the update check, the proxy
finder and Twinbar's switches. Twinbar's version is at the bottom right.

While Twinbar runs, its icon sits by the clock. Click it for the window, or
right-click it for your profiles: each shows whether it's running and whether
its proxy answers, and opens with a click. Closing the window keeps Twinbar
there (turn that off in the same menu); **Quit Twinbar** ends it. Tick **Start
Twinbar when I sign in to Windows** to have the icon there from the start.
Right-clicking Twinbar's taskbar button (or its pinned icon) lists your
profiles too.

![The Twinbar window with two profiles](docs/window.png)

## Use the command line

Make a profile. `-App` takes the app's `.exe`, its install folder or its Start
menu shortcut, or the name `twinbar apps` shows for it (a Microsoft Store app's
name works too):

```powershell
.\twinbar.cmd new -App "C:\Program Files\Bruno\Bruno.exe" -Name Work
.\twinbar.cmd new -App "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Postman\Postman.lnk" -Name Personal -Color green
.\twinbar.cmd new -App Claude -Name Work -Appearance dark
```

Then open **Bruno Work** from the Start menu (it's in the *Twinbar* folder), or:

```powershell
.\twinbar.cmd open "Bruno Work"
.\twinbar.cmd list
```

It gets a taskbar button of its own; pin it like any other.

Change its look, or repair it after the app moved or something got deleted;
`doctor` says what's wrong and what to run:

```powershell
.\twinbar.cmd change "Bruno Work" -Color red -Badge B
.\twinbar.cmd rebuild "Bruno Work" -App "D:\Apps\Bruno\Bruno.exe"
.\twinbar.cmd doctor
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
| `new -App APP -Name NAME` | Make a profile. See the options below. |
| `change PROFILE` | Change its `-Color`, `-Badge`, `-Style` or `-Appearance`. Its name and data stay; taskbar pins get the new icon too. |
| `rebuild PROFILE [-App APP]` | Make its shortcut, icon and launcher again. `-App` points it at the app's new place. |
| `rebuild -All` | The same for every profile; run it after updating Twinbar |
| `doctor [PROFILE]` | Check Twinbar and the profiles (including whether a profile's proxy answers), and say how to fix what's wrong |
| `ip [PROFILE]` | The IP address, place and network the world sees for a profile (through its proxy), next to the one without a proxy. **Check IP** in the window does the same. |
| `proxies [-Json]` | The proxies running on this computer and the one Windows is set to use, and whether each gets out. **Find...** next to Proxy in the window does the same. |
| `update [-Check]` | Install a newer Twinbar from GitHub, or with `-Check` just say whether there is one |
| `list [-Json]` | Show the profiles and whether each is running |
| `open PROFILE` | Start a profile |
| `remove PROFILE [-DeleteData]` | Remove a profile's shortcut and icon; with `-DeleteData`, its data too |
| `storage [PROFILE] [-Json]` | How much each profile's data takes, and how much of that is cache |
| `clean PROFILE` | Clear a profile's cache; its sign-in and data stay |
| `backup PROFILE [-File FILE]` / `restore FILE [-Name NAME]` | Back a profile up to a zip, and make it again from one (see [Storage, cache and backups](#storage-cache-and-backups)) |
| `apps [-Json]` | The Electron apps and Telegram found in the Start menu and the Microsoft Store, with what to give `-App` |
| `gui [-Tray]` | Open the Twinbar window (with `-Tray`, just its icon by the clock) |
| `settings [NAME on\|off]` | Show or change Twinbar's settings: `updates` (check once a day), `tray` (closing the window keeps the icon by the clock), `startup` (start with Windows) |
| `install [-Dir DIR] [-AddToPath]` / `uninstall` | Install Twinbar for you, or remove it (profiles stay) |
| `help`, `version` | |

A running profile isn't changed, rebuilt or removed; quit it first.

Options for `new` (and, except the last three, `change`):

| Option | |
|---|---|
| `-Color C` | `blue`, `green`, `purple`, `orange`, `pink`, `teal`, `red`, `indigo`, `yellow`, `gray` or `#RRGGBB`. By default a colour is picked from the name. |
| `-Badge B` | 1 or 2 letters or digits. By default the name's first letter. |
| `-Style S` | `tint+badge` (default), `tint` (colour only), `badge` (original colours and a badge) or `original` (the app's own icon) |
| `-Appearance A` | `system` (default), `light` or `dark`. Works for apps that follow Windows' light or dark setting; apps with their own theme setting keep it per profile anyway. |
| `-Proxy P` | `socks5://host:port`, `http://host:port` or `https://host:port`: the profile's traffic goes through it, and if it's down the profile is offline rather than going around it (see [Proxy and kill switch](#proxy-and-kill-switch)). `-Proxy none` with `change` removes it. |
| `-AppArgs "..."` | Extra command-line switches for the app, after Twinbar's own, like `--disable-gpu`. `none` removes them. |
| `-Environment "N=v;N2=v"` | Environment variables for the app, `NAME=value` separated by `;`. Not for Microsoft Store apps (Windows starts those itself). `none` removes them. |
| `-DataDir DIR` | Keep the profile's data in another folder |
| `-AdoptDataDir` | Use a data folder that already has data in it |
| `-ShortcutDir DIR` | Put the shortcut somewhere other than the Start menu |

## Proxy and kill switch

Give a profile a proxy, for example the local port of your VPN or xray client,
and check where its traffic comes out:

```powershell
.\twinbar.cmd new -App Postman -Name Work -Proxy http://127.0.0.1:10809
.\twinbar.cmd ip "Postman Work"
```

Not sure of the address? `twinbar proxies` (or **Find...** next to Proxy in
the window) looks for proxy apps on this computer on their usual ports
(v2rayN, Clash and Clash Verge, NekoRay and sing-box, Hiddify, Shadowsocks,
Tor) and at the proxy Windows is set to use. It tries each as HTTP and as
SOCKS5, asks it to connect out, and lists what works, HTTP first:

```text
Proxies on this computer:
  http://127.0.0.1:10809     HTTP, works (Windows' proxy setting)
  socks5://127.0.0.1:10808   SOCKS5, works
Use it for a profile: twinbar change PROFILE -Proxy http://127.0.0.1:10809
```

**Prefer the proxy's HTTP address.** Chromium uses SOCKS5 and HTTP proxies
alike, but an app's own code outside Chromium often can't use SOCKS. Claude,
signed in, is one: Claude Code's sessions skip a SOCKS proxy and try to
connect directly, so its sessions and folders don't load if that fails (it
keeps asking you to choose a folder); with an HTTP proxy they go through it.
xray's and v2ray's local ports usually speak HTTP as well as SOCKS, so the same
port often works as `http://127.0.0.1:<port>`.

The proxy is strict, so it works as a kill switch for the app's web traffic:
Chromium never falls back to a direct connection, host names are looked up
through the proxy (only the proxy's own name and localhost are looked up on
your computer), and WebRTC can't send UDP around it. If the proxy is down, the
profile is offline. For normal and Squirrel installs Twinbar also sets
`ALL_PROXY` for the app's code outside Chromium, and `HTTPS_PROXY` and
`HTTP_PROXY` too for an HTTP proxy; Windows doesn't let Store apps be given
these (Claude's own code reads the proxy from Chromium instead). Store apps also go
without the "look nothing up locally" rule, because Claude doesn't start with
it; their connections still go only through the proxy, but some names may be
looked up through your normal DNS server.

What some apps do in their own Node.js code can still go around it, since that
code doesn't use Chromium's network stack. Measured on Windows 11 with a local
SOCKS5 proxy that logs every destination, watching every TCP connection of the
app for 30 seconds:

| App | Through the proxy | Around it | Proxy down |
|---|---|---|---|
| Postman 12.33 | all 7 destinations | nothing | nothing gets out |
| Bruno 4.3 | its web traffic | one connection from its main process, to an Amazon (AWS) server | that one connection still gets out |
| Claude 6.28 (Store), signed out | all 9 destinations (claude.ai, Anthropic, hCaptcha) | nothing | nothing gets out |
| Claude 6.28 (Store), signed in, SOCKS proxy | its web traffic | Claude Code's sessions skip a SOCKS proxy (its log: "Skipping SOCKS proxy entry") | those connections go around it; use an HTTP proxy |

Stopping that last kind of traffic needs a firewall rule, which needs admin
rights and applies to the app's program file, so it would cut off the
original app too; for that, use your VPN client's own kill switch.
`tests\smoke.ps1 -RealApp <app> -Launch` measures any app the same way.

## Storage, cache and backups

See how much each profile takes, and how much of it is cache:

```powershell
.\twinbar.cmd storage
.\twinbar.cmd clean "Slack Work"     # clear its cache; the sign-in stays
```

Clearing the cache deletes only Chromium's caches in the profile's data folder
(and in its session partitions): `Cache`, `Code Cache`, the GPU and shader
caches, service worker caches and crash reports. The sign-in, settings and
local data stay, and the app fills the cache again as it needs it.

Back a profile up to a zip (its settings and data folder, without caches), and
make it again from that zip later or on another computer:

```powershell
.\twinbar.cmd backup "Slack Work"                       # into Documents\Twinbar backups
.\twinbar.cmd backup "Slack Work" -File D:\slack-work.zip
.\twinbar.cmd restore D:\slack-work.zip                 # as it was
.\twinbar.cmd restore D:\slack-work.zip -Name "Work 2"  # next to the original
```

A backup holds the profile's sign-in, so keep it as safe as a password. Apps
encrypt their sign-in with your Windows account, so on another computer or
Windows account the restored profile has its data and settings but usually
asks you to sign in again; Twinbar says so when that's the case.

In the window, right-click a profile for **Clear cache...** and **Back up...**;
**More...** has **Storage of the profiles** and **Restore a backup...**.

## Telegram

Telegram Desktop isn't built on Electron, but it can keep its data in a folder
you give it, so Twinbar twins it the same way: its own sign-in, chats and
settings, its own taskbar button, icon, jump list and Start menu entry. Unlike
Telegram's own account switcher, it's a separate window, with no limit of
three accounts.

```powershell
.\twinbar.cmd new -App Telegram -Name Work -Color teal
.\twinbar.cmd open "Telegram Work"
```

What's different from an Electron app:

- **Links stay with your main Telegram.** Telegram claims `tg://` links on its
  first start and after each update; Twinbar turns on Telegram's own
  `skip-url-scheme-register` option in each twin (in its
  `tdata\experimental_options.json`) before starting it, so links keep
  opening your main Telegram.
- **Proxy and theme are Telegram's own,** kept for each profile: Settings >
  Advanced > Connection type, and Settings > Chat settings. `-Proxy` and
  `-Appearance` are refused for Telegram, and the window turns them off.
- **Leave "Launch Telegram when system starts" off in the twin:** Telegram has
  one start-up entry, so turning it on there would replace your main
  Telegram's.
- **Notifications** from the twin show under Telegram's name: Telegram sends
  them as the app it is, and changing that would stop them showing at all.
- **The cache** is cleared from Telegram: Settings > Advanced > Manage local
  storage. `twinbar storage` and backups work as for other profiles.
- **Telegram from the Microsoft Store** can't be given a folder of its own;
  use Telegram Desktop from telegram.org.

## How it works

Electron apps accept `--user-data-dir=<folder>`: everything the app keeps about
you (sign-in, settings, caches) then lives in that folder. A second folder means
a second, independent copy, and Electron's one-copy-at-a-time lock is per
folder, so both copies can run together. Telegram Desktop does the same with
`-workdir <folder>`: its one-copy check is per folder too.

The taskbar groups windows by their AppUserModelID. Electron apps set one for
the whole app, so on its own a second copy would join the original's button.
A profile's shortcut therefore starts a small **launcher**, which starts the app
and then puts the profile's own ID, name and icon on the app's windows. The
taskbar then shows them as a button of their own, and pinning it pins the
profile; the window's title bar and Alt+Tab show the profile's icon too. The
launcher only sets these window properties: it doesn't inject anything into the
app or change it. It stays in the background while the profile is open and
quits after it closes.

| | |
|---|---|
| Start menu entry | `Start Menu\Programs\Twinbar\<App> <Name>.lnk`. It starts the launcher with the profile's id and carries the profile's AppUserModelID (`Twinbar.<app>.<name>`). |
| Launcher | `%APPDATA%\Twinbar\bin\twinbar-launcher.exe`, compiled on your computer from the source inside `twinbar.ps1` the first time it's needed, and again after a Twinbar update (even while a profile is open: the running one is moved aside and deleted once it quits). Its log is `%APPDATA%\Twinbar\logs\launcher.log`. |
| Icons | `%APPDATA%\Twinbar\icons\<app>.<name>-<hash>.ico`, drawn from the app's own icon, 16 to 256 pixels. The name changes with the look, so Windows never shows a stale icon. |
| Profile data | `%APPDATA%\Twinbar\data\<app>\<name>\`, with a small `.twinbar-profile` marker file |
| Profile records | `%APPDATA%\Twinbar\profiles\<app>.<name>.json` |
| Normal installs | The app's own `.exe` is started. |
| Telegram Desktop | `Telegram.exe` is started with `-workdir` and the profile's folder. |
| Squirrel installs (Slack, Discord, Postman...) | The launcher in the app's install folder is started; it always runs the newest version, so profiles keep working after the app updates. |
| Microsoft Store apps (Claude...) | Started through Windows' package activation, with the profile's arguments. Their data is kept in `%USERPROFILE%\Twinbar\<app>\<name>\`: Windows redirects what a Store app writes under AppData into the app's own package, where Twinbar couldn't see or remove it. |
| The Twinbar window | `Twinbar.exe` in the install folder, next to `twinbar.ps1`, compiled on your computer by `install`. It runs the script's window inside PowerShell without a console, with its own icon and taskbar button. |

Twinbar never modifies the app. Removing moves files to the Recycle Bin, and a
data folder is only ever removed if it carries that profile's marker.

## Limitations

- **VS Code and editors built on it** (Cursor, Antigravity IDE...) keep
  extensions in `%USERPROFILE%\.vscode\extensions` (or `.cursor`, ...)
  whatever the data folder, so a twin shares your extensions; its sign-in,
  settings and history are its own. For extensions of its own, give it
  `-AppArgs '--extensions-dir "<a folder>"'`.
- **Antigravity** (Google's agent app) keeps your Google sign-in in Windows
  Credential Manager (`gemini:antigravity`) and its agent's data in
  `%USERPROFILE%\.gemini\antigravity`, so every copy would be signed in to
  the same account; Twinbar refuses it. Antigravity IDE can be twinned, but
  its agent's data (`%USERPROFILE%\.gemini\antigravity-ide`) is shared.
- **Shared storage:** data an app keeps outside its data folder is shared
  between profiles, for example passwords some apps store in Windows
  Credential Manager, or settings in the registry. Of the apps tested, Bruno,
  Postman and Claude keep their sign-in in the data folder (encrypted with a
  key that's in there too), so each profile signs in on its own. Claude also
  refers to fixed folders (`%LOCALAPPDATA%\Claude-Data` and `Claude-3p`);
  whatever it keeps there is shared with the original Claude.
- **Two Claudes at once** compete for things Claude expects to have to itself:
  its global shortcut (Ctrl+Alt+Space), its Windows service and those shared
  folders. A Claude profile's own log shows it, and it can make the second
  copy slow; Twinbar's own launcher uses well under 1% of one CPU core. For a
  second Claude account, claude.ai in a browser is lighter.
- **Appearance** only reaches apps that follow Windows' light or dark setting.
- **Window icon:** it's set by the launcher, so if the launcher is stopped while
  the profile is open, the window shows a blank icon until the profile is
  opened again.
- **After updating Twinbar,** run `twinbar rebuild -All`; profiles made with
  0.1.0 get their icon and taskbar button that way, and the sign-in is kept.
- Where policy blocks programs in your user folder (AppLocker and the like),
  the launcher and `Twinbar.exe` can't run.
- The first start of a freshly built `Twinbar.exe` or launcher can take a few
  seconds longer while Windows checks the new program.
- Tested so far on Windows 11 with Bruno 4.3 (normal install), Postman 12.33
  (Squirrel install) and Claude 6.28 (Microsoft Store).

## Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1 -RealApp "C:\Program Files\Bruno\Bruno.exe" -Launch
```

The tests build a fake Electron app and work in temporary folders, never in
your Start menu, taskbar pins or profiles. A few small test files go to the
Recycle Bin. The fake app briefly shows a window, to check that it gets a
taskbar button and icon of its own. With `-RealApp ... -Launch`, the real app
(`-RealApp Claude` for the Store app) is opened once, signed out, with an empty
data folder, and closed again; a copy of it you already have open isn't touched.

CI runs these, with PSScriptAnalyzer, on every push and pull request. See
[CONTRIBUTING.md](CONTRIBUTING.md) for how the code is laid out and how a
release is made, and [SECURITY.md](SECURITY.md) to report a security problem.

## Credits and licence

Inspired by [DoppelDock](https://github.com/ZarinLab/doppeldock), which does
this on macOS. Twinbar is a separate project written from scratch for Windows,
and isn't affiliated with DoppelDock or with the makers of any app it works with.

[MIT](LICENSE)
