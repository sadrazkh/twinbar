# Security

## Reporting a problem

Please report security problems privately, through
[GitHub's private vulnerability reporting](https://github.com/sadrazkh/twinbar/security/advisories/new),
not in a public issue. Say what's affected, how to reproduce it, and what an
attacker could do. You'll get an answer within a week; the fix is published
with a note in the release once it's out.

## Supported versions

Only the latest release gets fixes.

## What Twinbar does and doesn't do

- It runs as you and needs no admin rights. It connects to the network only
  for these, and sends nothing about you or your profiles:
  - the update check: once a day while the window is open (it can be turned
    off under More...), and on `twinbar update`, it asks GitHub's API for the
    newest release; updating downloads that release's installer and
    `SHA256SUMS` from this repository's GitHub releases, checks the installer
    against its SHA-256, and only then runs it;
  - the IP check (`twinbar ip`, Check IP), when you ask: ipinfo.io, or
    api.ipify.org if that fails;
  - finding proxies (`twinbar proxies`, Find...): it asks proxies on this
    computer (and the one Windows is set to use) to connect to ipinfo.io.
- Downloads come only from `https://github.com/sadrazkh/twinbar/releases/download/`.
- It starts apps with `--user-data-dir` and a few Chromium switches, and sets
  window properties (taskbar ID, relaunch details, icon) on their windows from
  its launcher. It doesn't inject code into apps, patch them or re-sign them.
- It writes only to its own folders (`%APPDATA%\Twinbar`, the profiles' data
  folders, `%USERPROFILE%\Twinbar` for Store apps, its install folder), its
  own Start menu shortcuts, taskbar pins of its own profiles, its jump list,
  backups where you ask (`Documents\Twinbar backups` by default), and, only
  when you turn them on, your user PATH (`install -AddToPath`) and a
  `Twinbar` entry under your user's `Run` key (start with Windows).
- A backup holds a profile's sign-in (its cookies and tokens, still encrypted
  for your Windows account): treat the zip like a password. Restoring checks
  that every file lands inside the new profile's data folder.
- It compiles its launcher and `Twinbar.exe` on your computer from the C#
  source inside `twinbar.ps1`, so you can read exactly what runs.
- Release files come with `SHA256SUMS` and signed build provenance from this
  repository's Release workflow: `gh attestation verify <file> -R sadrazkh/twinbar`.
