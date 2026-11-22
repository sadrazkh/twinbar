# Contributing to Twinbar

Bug reports, ideas and pull requests are welcome.

- **Bugs and ideas:** open an [issue](https://github.com/sadrazkh/twinbar/issues).
  For a bug, `twinbar doctor` output and the end of
  `%APPDATA%\Twinbar\logs\launcher.log` help a lot.
- **Security problems:** report them privately; see [SECURITY.md](SECURITY.md).

## How it's laid out

| Path | What it is |
|---|---|
| `twinbar.ps1` | All of Twinbar: the commands, the window, and the C# for the launcher, `Twinbar.exe` and the Windows interop, compiled on the user's computer |
| `twinbar.cmd` | Runs `twinbar.ps1` whatever the execution policy is |
| `tests/smoke.ps1` | The tests: static checks, unit checks, and end-to-end checks with a fake Electron app (`tests/FakeApp.cs`) |
| `tools/make-release.ps1` | Builds the release files; with `-Installer`, the Windows installer too (needs [Inno Setup 6](https://jrsoftware.org/isinfo.php)) |
| `tools/release-notes.ps1`, `docs/releases/` | Each release's notes, and (`-Sync`, in the Release workflow) keeping the published ones up to date |
| `site/` | The website (one HTML file, English and Persian). The Website workflow publishes it to the `gh-pages` branch when it changes |
| `installer/twinbar.iss` | The Windows installer: copies the files, then runs `twinbar install` in that folder |
| `tests/installer.ps1` | Installs the built installer silently, opens the window, uninstalls; CI runs it |
| `docs/` | [phases](docs/phases.md) (what was built, and what was measured on the way) and images |
| `.github/workflows/` | CI and Release |

## Ground rules

- **Nothing to install.** Only what Windows has: Windows PowerShell 5.1, .NET
  Framework 4.8, and its C# compiler through `Add-Type` (C# 5: no string
  interpolation, `out var`, and so on). No admin rights.
- **ASCII source.** Windows PowerShell reads a file without a byte order mark in
  the computer's code page, so `twinbar.ps1` stays plain ASCII; build other
  characters at run time (`[char]0x200C`). The tests check this.
- **Never destroy user data.** Removing goes to the Recycle Bin; a data folder
  is only removed if it has the profile's marker; never change the app itself
  or a shortcut Twinbar didn't make; refuse to change a running profile.
- **Validate input with allow-lists,** and treat other programs' files
  (shortcuts, manifests, version info) as untrusted.
- **The window and the command line share the code:** every button calls an
  `Invoke-*` function.
- **Workflows:** actions pinned to a full commit hash with the version in a
  comment, releases at least two weeks old, the least permissions each job
  needs, `persist-credentials: false`.

## Testing

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1 -RealApp "C:\Program Files\Bruno\Bruno.exe" -Launch
```

Every change that adds or changes behaviour adds or updates checks in
`tests/smoke.ps1`; every bug fix adds a check that would have caught it. CI runs
the tests with [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer)
(settings in `PSScriptAnalyzerSettings.psd1`); to run it locally too:
`Install-Module PSScriptAnalyzer -Scope CurrentUser`.

## Releasing

1. Raise `$script:TwinbarVersion` at the top of `twinbar.ps1`.
2. Add a `## [x.y.z] - date` section to `CHANGELOG.md`, and the release's notes
   in `docs/releases/vx.y.z.md`: friendlier than the CHANGELOG, with what's new
   and why it matters (the tests check both are there). Keep a `---` line out
   of them: Twinbar's update window shows the notes up to the first one, and
   `tools/release-notes.ps1` adds how to install and check the download below it.
3. Push to `main`. The Release workflow sees a version without a tag, runs the
   tests, builds the files and the installer, tests installing and
   uninstalling, records their provenance, and creates the tag and the release
   with those notes. Changing an older release's notes file and pushing
   updates that release's notes too.

## Pull requests

Keep each one to one thing, explain the why, and update `README.md`,
`docs/phases.md` and `CHANGELOG.md` (under Unreleased) when behaviour changes.
By contributing, you agree that your contributions are licensed under the
[MIT licence](LICENSE).
