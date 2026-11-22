// A stand-in for an Electron app, built by tests/smoke.ps1 (C# 5, Windows PowerShell's Add-Type).
// It records how it was started in <user-data-dir>\launched.txt and exits, or waits
// while <user-data-dir>\stay.txt exists (up to 30 seconds) so tests can see it running.
using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;

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

  const int STARTF_TITLEISLINKNAME = 0x800;
  const int STARTF_TITLEISAPPID = 0x1000;

  static int Main(string[] args) {
    string dataDir = null;
    foreach (string a in args) {
      if (a.StartsWith("--user-data-dir=", StringComparison.OrdinalIgnoreCase)) dataDir = a.Substring(16);
    }
    if (dataDir == null || !Directory.Exists(dataDir)) return 2;

    StartupInfo info;
    GetStartupInfo(out info);
    string title = info.lpTitle == IntPtr.Zero ? "" : Marshal.PtrToStringUni(info.lpTitle);
    File.WriteAllLines(Path.Combine(dataDir, "launched.txt"), new string[] {
      "datadir=" + dataDir,
      "appid=" + ((info.dwFlags & STARTF_TITLEISAPPID) != 0 ? title : ""),
      "linkname=" + ((info.dwFlags & STARTF_TITLEISLINKNAME) != 0 ? title : ""),
      "commandline=" + Environment.CommandLine
    });

    string stay = Path.Combine(dataDir, "stay.txt");
    for (int i = 0; i < 300 && File.Exists(stay); i++) Thread.Sleep(100);
    return 0;
  }
}
