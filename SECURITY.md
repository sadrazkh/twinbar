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

- It runs as you, needs no admin rights, and makes no network connections.
- It starts apps with `--user-data-dir` and a few Chromium switches, and sets
  window properties (taskbar ID, relaunch details, icon) on their windows from
  its launcher. It doesn't inject code into apps, patch them or re-sign them.
- It writes only to its own folders (`%APPDATA%\Twinbar`, the profiles' data
  folders, `%USERPROFILE%\Twinbar` for Store apps, its install folder), its
  own Start menu shortcuts, taskbar pins of its own profiles, and, only with
  `install -AddToPath`, your user PATH.
- It compiles its launcher and `Twinbar.exe` on your computer from the C#
  source inside `twinbar.ps1`, so you can read exactly what runs.
- Release files come with `SHA256SUMS` and signed build provenance from this
  repository's Release workflow: `gh attestation verify <file> -R sadrazkh/twinbar`.
