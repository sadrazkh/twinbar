// A stand-in for an Electron app, built by tests/smoke.ps1 (C# 5, Windows PowerShell's Add-Type).
// Like Electron apps, it sets its own AppUserModelID for the whole process ("Fake.App").
// It records how it was started in <user-data-dir>\launched.txt and exits, or stays
// while <user-data-dir>\stay.txt exists (up to 30 seconds) so tests can see it running.
// With <user-data-dir>\window.txt it shows a window while it stays.
using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyProduct("Fake App")]
[assembly: AssemblyTitle("Fake App")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

static class FakeApp {
  [StructLayout(LayoutKind.Sequential)]
  struct StartupInfo {
    public int cb;
    public IntPtr lpReserved, lpDesktop, lpTitle;
    public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
    public short wShowWindow, cbReserved2;
    public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
  }

  [DllImport("kernel32.dll", EntryPoint = "GetStartupInfoW")]
  static extern void GetStartupInfo(out StartupInfo info);

  [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
  static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

  const int STARTF_TITLEISLINKNAME = 0x800;
  const int STARTF_TITLEISAPPID = 0x1000;

  [STAThread]
  static int Main(string[] args) {
    SetCurrentProcessExplicitAppUserModelID("Fake.App");
    // Its data folder: Electron's --user-data-dir=<dir>, or Telegram's -workdir <dir>
    // (built as Telegram.exe with the product name "Telegram Desktop", it stands in
    // for Telegram Desktop).
    string dataDir = null;
    for (int i = 0; i < args.Length; i++) {
      if (args[i].StartsWith("--user-data-dir=", StringComparison.OrdinalIgnoreCase)) dataDir = args[i].Substring(16);
      if (args[i] == "-workdir" && i + 1 < args.Length) dataDir = args[i + 1].Replace('/', '\\').TrimEnd('\\');
    }
    if (dataDir == null || !Directory.Exists(dataDir)) return 2;

    StartupInfo info;
    GetStartupInfo(out info);
    string title = info.lpTitle == IntPtr.Zero ? "" : Marshal.PtrToStringUni(info.lpTitle);
    File.WriteAllLines(Path.Combine(dataDir, "launched.txt"), new string[] {
      "datadir=" + dataDir,
      "appid=" + ((info.dwFlags & STARTF_TITLEISAPPID) != 0 ? title : ""),
      "linkname=" + ((info.dwFlags & STARTF_TITLEISLINKNAME) != 0 ? title : ""),
      "https_proxy=" + (Environment.GetEnvironmentVariable("HTTPS_PROXY") ?? ""),
      "all_proxy=" + (Environment.GetEnvironmentVariable("ALL_PROXY") ?? ""),
      "testvar=" + (Environment.GetEnvironmentVariable("TWINBAR_TEST_VAR") ?? ""),
      "claudeconfig=" + (Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR") ?? ""),
      "codexhome=" + (Environment.GetEnvironmentVariable("CODEX_HOME") ?? ""),
      "commandline=" + Environment.CommandLine
    });

    string stay = Path.Combine(dataDir, "stay.txt");
    if (File.Exists(Path.Combine(dataDir, "window.txt"))) {
      Form form = new Form();
      form.Text = "Fake App";
      form.StartPosition = FormStartPosition.Manual;
      form.SetBounds(40, 40, 360, 160);
      int ticks = 0;
      System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
      timer.Interval = 100;
      timer.Tick += delegate { if (!File.Exists(stay) || ++ticks > 300) form.Close(); };
      timer.Start();
      Application.Run(form);
      return 0;
    }
    for (int i = 0; i < 300 && File.Exists(stay); i++) Thread.Sleep(100);
    return 0;
  }
}
