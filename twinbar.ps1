<#
.SYNOPSIS
Twinbar: a second, separately signed-in copy of an Electron app on Windows.

.DESCRIPTION
  twinbar new -App APP -Name NAME [-Color C] [-Badge B] [-Style S] [-Appearance A]
              [-Proxy P] [-DataDir DIR] [-AdoptDataDir] [-ShortcutDir DIR]
  twinbar change PROFILE [-Color C] [-Badge B] [-Style S] [-Appearance A] [-Proxy P]
  twinbar ip [PROFILE] [-Json]
  twinbar proxies [-Json]
  twinbar rebuild PROFILE [-App APP] | twinbar rebuild -All
  twinbar doctor [PROFILE]
  twinbar list [-Json]
  twinbar open PROFILE
  twinbar remove PROFILE [-DeleteData]
  twinbar apps [-Json]
  twinbar gui [-Tray]
  twinbar settings [NAME on|off]
  twinbar install [-Dir DIR] [-AddToPath] [-ShortcutDir DIR]
  twinbar uninstall
  twinbar update [-Check]
  twinbar help
  twinbar version

APP is the app's .exe, its install folder or its Start menu shortcut; for a
Microsoft Store app, its package name ("Claude") or app id.
PROFILE is a profile's name ("Work"), its full name ("Postman Work") or its id
("postman.work"); see twinbar list.

https://github.com/sadrazkh/twinbar (MIT licence)
#>
[CmdletBinding(PositionalBinding = $false)]
param(
  [Parameter(Position = 0)] [string] $Command = 'help',
  [Parameter(Position = 1)] [string] $Target,
  [Parameter(Position = 2)] [string] $Value,
  [string] $App,
  [string] $Name,
  [string] $Color,
  [string] $Badge,
  [string] $Style,
  [string] $Appearance,
  [string] $Proxy,
  [string] $DataDir,
  [switch] $AdoptDataDir,
  [string] $ShortcutDir,
  [switch] $DeleteData,
  [switch] $All,
  [string] $Dir,
  [switch] $AddToPath,
  [switch] $Check,
  [switch] $Tray,
  [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TwinbarVersion = '0.8.0'
$script:SelfPath = $MyInvocation.MyCommand.Path
$script:AppId = 'Twinbar.App' # the Twinbar window's own taskbar ID
$script:CommandGiven = $PSBoundParameters.ContainsKey('Command')
$script:MarkerName = '.twinbar-profile' # in each data folder Twinbar created or adopted
$script:AppIdPrefix = 'Twinbar'          # AppUserModelID: Twinbar.<app id>.<name key>
$script:LauncherName = 'twinbar-launcher.exe'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false
$script:Palette = [ordered]@{
  blue = '#0090FF'; green = '#30A46C'; purple = '#8E4EC6'; orange = '#F76B15'; pink = '#D6409F'
  teal = '#12A594'; red = '#E5484D'; indigo = '#3E63DD'; yellow = '#D4A017'; gray = '#6F6E77'
}
$script:Styles = @('tint+badge', 'tint', 'badge', 'original')
$script:Appearances = [ordered]@{
  system = ''                                       # whatever Windows uses
  light  = '--blink-settings=preferredColorScheme=1' # Chromium: prefer the light colour scheme
  dark   = '--force-dark-mode'                       # Chromium: dark native theme and colour scheme
}
# Every field of a profile record, in the order they're written.
$script:RecordFields = @(
  'schema', 'id', 'name', 'appName', 'appId', 'appKind', 'launchExe', 'realExe', 'packageApp',
  'dataDir', 'shortcut', 'aumid', 'launcher', 'style', 'color', 'badge', 'appearance', 'proxy', 'extraArgs',
  'icon', 'created', 'updated', 'twinbarVersion'
)

# ---------------------------------------------------------------------------
# Windows interop: shortcuts with an AppUserModelID, the Recycle Bin, and icons.
# Compiled once per run by Add-Type (C# 5, so it works with Windows PowerShell 5.1).
# ---------------------------------------------------------------------------

$script:InteropSource = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.IO;
using System.Net.Security;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Security.Authentication;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace TwinbarInterop {
  [StructLayout(LayoutKind.Sequential, Pack = 4)]
  public struct PropertyKey {
    public Guid FormatId;
    public uint PropertyId;
    public PropertyKey(Guid formatId, uint propertyId) { FormatId = formatId; PropertyId = propertyId; }
  }

  // PROPVARIANT: only the type and a pointer are used; Size covers 64-bit Windows.
  [StructLayout(LayoutKind.Explicit, Size = 24)]
  public struct PropVariant {
    [FieldOffset(0)] public ushort VarType;
    [FieldOffset(8)] public IntPtr Pointer;
  }

  [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IPropertyStore {
    [PreserveSig] int GetCount(out uint count);
    [PreserveSig] int GetAt(uint index, out PropertyKey key);
    [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
    [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
    [PreserveSig] int Commit();
  }

  [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IShellLinkW {
    void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder file, int cch, IntPtr findData, uint flags);
    void GetIDList(out IntPtr pidl);
    void SetIDList(IntPtr pidl);
    void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder name, int cch);
    void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
    void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder dir, int cch);
    void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string dir);
    void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder args, int cch);
    void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
    void GetHotkey(out short hotkey);
    void SetHotkey(short hotkey);
    void GetShowCmd(out int showCmd);
    void SetShowCmd(int showCmd);
    void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder iconPath, int cch, out int iconIndex);
    void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string iconPath, int iconIndex);
    void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string relPath, uint reserved);
    void Resolve(IntPtr hwnd, uint flags);
    void SetPath([MarshalAs(UnmanagedType.LPWStr)] string file);
  }

  [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
  public class ShellLinkObject { }

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct FileOperation {
    public IntPtr Hwnd;
    public uint Func;
    public string From;
    public string To;
    public ushort Flags;
    public int AnyOperationsAborted;
    public IntPtr NameMappings;
    public string ProgressTitle;
  }

  public static class Shell {
    static readonly Guid AppUserModelFormat = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
    const uint AppUserModelIdProperty = 5;
    const ushort VT_LPWSTR = 31;

    [DllImport("ole32.dll")]
    static extern int PropVariantClear(ref PropVariant value);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHFileOperation(ref FileOperation operation);

    static void Check(int hr, string what) {
      if (hr != 0) throw new InvalidOperationException("couldn't " + what + " (0x" + hr.ToString("X8") + ")");
    }

    public static void SaveLink(string path, string target, string arguments, string workingDirectory,
                                string iconPath, int iconIndex, string description, string appUserModelId) {
      IShellLinkW link = (IShellLinkW)new ShellLinkObject();
      try {
        link.SetPath(target);
        link.SetArguments(arguments ?? "");
        if (!String.IsNullOrEmpty(workingDirectory)) link.SetWorkingDirectory(workingDirectory);
        if (!String.IsNullOrEmpty(iconPath)) link.SetIconLocation(iconPath, iconIndex);
        if (!String.IsNullOrEmpty(description)) link.SetDescription(description);
        if (!String.IsNullOrEmpty(appUserModelId)) {
          IPropertyStore store = (IPropertyStore)link;
          PropertyKey key = new PropertyKey(AppUserModelFormat, AppUserModelIdProperty);
          PropVariant value = new PropVariant();
          value.VarType = VT_LPWSTR;
          value.Pointer = Marshal.StringToCoTaskMemUni(appUserModelId);
          try {
            Check(store.SetValue(ref key, ref value), "set the shortcut's AppUserModelID");
            Check(store.Commit(), "save the shortcut's properties");
          } finally {
            Marshal.FreeCoTaskMem(value.Pointer);
          }
        }
        ((IPersistFile)link).Save(path, true);
      } finally {
        Marshal.ReleaseComObject(link);
      }
    }

    // Returns target, arguments, working directory, icon path, icon index, AppUserModelID.
    public static string[] ReadLink(string path) {
      IShellLinkW link = (IShellLinkW)new ShellLinkObject();
      try {
        ((IPersistFile)link).Load(path, 0);
        StringBuilder text = new StringBuilder(32768);
        link.GetPath(text, text.Capacity, IntPtr.Zero, 0);
        string target = text.ToString();
        text.Length = 0;
        link.GetArguments(text, text.Capacity);
        string arguments = text.ToString();
        text.Length = 0;
        link.GetWorkingDirectory(text, text.Capacity);
        string workingDirectory = text.ToString();
        text.Length = 0;
        int iconIndex;
        link.GetIconLocation(text, text.Capacity, out iconIndex);
        string iconPath = text.ToString();
        string appUserModelId = "";
        IPropertyStore store = (IPropertyStore)link;
        PropertyKey key = new PropertyKey(AppUserModelFormat, AppUserModelIdProperty);
        PropVariant value;
        if (store.GetValue(ref key, out value) == 0) {
          try {
            if (value.VarType == VT_LPWSTR && value.Pointer != IntPtr.Zero) appUserModelId = Marshal.PtrToStringUni(value.Pointer);
          } finally {
            PropVariantClear(ref value);
          }
        }
        return new string[] { target, arguments, workingDirectory, iconPath, iconIndex.ToString(), appUserModelId };
      } finally {
        Marshal.ReleaseComObject(link);
      }
    }

    // Moves a file or folder to the Recycle Bin without asking. Windows still warns
    // before deleting outright, which happens only where there is no Recycle Bin.
    public static void Recycle(string path) {
      FileOperation op = new FileOperation();
      op.Func = 3;                                  // FO_DELETE
      op.From = path + "\0\0";
      op.Flags = 0x0040 | 0x0010 | 0x0004 | 0x0400 | 0x4000;
      // FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI | FOF_WANTNUKEWARNING
      int result = SHFileOperation(ref op);
      if (result != 0) throw new InvalidOperationException("couldn't move " + path + " to the Recycle Bin (error " + result + ")");
      if (op.AnyOperationsAborted != 0) throw new InvalidOperationException("moving " + path + " to the Recycle Bin was cancelled");
    }

    // Changes an existing shortcut in place (a taskbar pin, say), keeping everything else in it.
    public static void UpdateLink(string path, string target, string arguments, string iconPath, int iconIndex) {
      IShellLinkW link = (IShellLinkW)new ShellLinkObject();
      try {
        ((IPersistFile)link).Load(path, 2); // STGM_READWRITE
        if (!String.IsNullOrEmpty(target)) link.SetPath(target);
        if (arguments != null) link.SetArguments(arguments);
        if (!String.IsNullOrEmpty(iconPath)) link.SetIconLocation(iconPath, iconIndex);
        ((IPersistFile)link).Save(path, true);
      } finally {
        Marshal.ReleaseComObject(link);
      }
    }

    [DllImport("shell32.dll")]
    static extern void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);

    // Asks Explorer to redraw icons (Start menu, taskbar pins) after they changed.
    public static void NotifyIconsChanged() {
      SHChangeNotify(0x08000000, 0, IntPtr.Zero, IntPtr.Zero); // SHCNE_ASSOCCHANGED
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint message, IntPtr wParam, string lParam, uint flags, uint timeout, out IntPtr result);

    // Tells running programs (Explorer, new terminals) that the user's PATH changed.
    public static void NotifyEnvironmentChanged() {
      IntPtr result;
      SendMessageTimeoutW(new IntPtr(0xFFFF), 0x1A, IntPtr.Zero, "Environment", 2, 1000, out result); // HWND_BROADCAST, WM_SETTINGCHANGE
    }
    [DllImport("user32.dll")]
    static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);

    // The icon a window shows (title bar, Alt+Tab), or IntPtr.Zero.
    public static IntPtr GetWindowIcon(IntPtr hwnd, bool big) {
      IntPtr icon;
      SendMessageTimeoutW(hwnd, 0x7F, (IntPtr)(big ? 1 : 0), IntPtr.Zero, 2, 500, out icon); // WM_GETICON
      return icon;
    }

    [DllImport("shell32.dll")]
    static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);

    // The AppUserModelID set on a window (what the taskbar groups it by), or "" if none.
    public static string GetWindowAppId(IntPtr hwnd) {
      Guid iid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
      IPropertyStore store;
      if (SHGetPropertyStoreForWindow(hwnd, ref iid, out store) != 0 || store == null) return "";
      try {
        PropertyKey key = new PropertyKey(AppUserModelFormat, AppUserModelIdProperty);
        PropVariant value;
        if (store.GetValue(ref key, out value) != 0) return "";
        try {
          return (value.VarType == VT_LPWSTR && value.Pointer != IntPtr.Zero) ? Marshal.PtrToStringUni(value.Pointer) : "";
        } finally {
          PropVariantClear(ref value);
        }
      } finally {
        Marshal.ReleaseComObject(store);
      }
    }
  }

  [ComImport, Guid("92CA9DCD-5622-4BBA-A805-5E9F541BD8C9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IObjectArray {
    void GetCount(out uint count);
    void GetAt(uint index, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object item);
  }

  [ComImport, Guid("5632B1A4-E38A-400A-928A-D4CD63230295"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IObjectCollection {
    void GetCount(out uint count);
    void GetAt(uint index, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object item);
    void AddObject([MarshalAs(UnmanagedType.Interface)] object item);
    void AddFromArray([MarshalAs(UnmanagedType.Interface)] IObjectArray source);
    void RemoveObjectAt(uint index);
    void Clear();
  }

  [ComImport, Guid("2D3468C1-36A7-43B6-AC24-D3F02FD9607A")]
  public class EnumerableObjectCollection { }

  [ComImport, Guid("6332DEBF-87B5-4670-90C0-5E57B408A49E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface ICustomDestinationList {
    void SetAppID([MarshalAs(UnmanagedType.LPWStr)] string appId);
    void BeginList(out uint minSlots, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object removed);
    void AppendCategory([MarshalAs(UnmanagedType.LPWStr)] string category, [MarshalAs(UnmanagedType.Interface)] IObjectArray items);
    void AppendKnownCategory(int category);
    void AddUserTasks([MarshalAs(UnmanagedType.Interface)] IObjectArray tasks);
    void CommitList();
    void GetRemovedDestinations(ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object removed);
    void DeleteList([MarshalAs(UnmanagedType.LPWStr)] string appId);
    void AbortList();
  }

  [ComImport, Guid("77F10CF0-3DB5-4966-B520-B7C54FD35ED6")]
  public class DestinationList { }

  // Twinbar's jump list (right-click its taskbar button or its Start menu entry):
  // a task per profile, which starts it.
  public static class JumpList {
    static readonly Guid TitleFormat = new Guid("F29F85E0-4FF9-1068-AB91-08002B27B3D9");

    public static void SetTasks(string appId, string[] titles, string[] paths, string[] arguments, string[] icons, string[] descriptions) {
      ICustomDestinationList list = (ICustomDestinationList)new DestinationList();
      try {
        list.SetAppID(appId);
        uint slots;
        object removed;
        Guid arrayId = typeof(IObjectArray).GUID;
        list.BeginList(out slots, ref arrayId, out removed);
        IObjectCollection tasks = (IObjectCollection)new EnumerableObjectCollection();
        for (int i = 0; i < titles.Length; i++) {
          IShellLinkW link = (IShellLinkW)new ShellLinkObject();
          link.SetPath(paths[i]);
          link.SetArguments(arguments[i]);
          if (!String.IsNullOrEmpty(icons[i])) link.SetIconLocation(icons[i], 0);
          if (!String.IsNullOrEmpty(descriptions[i])) link.SetDescription(descriptions[i]);
          IPropertyStore store = (IPropertyStore)link;
          PropertyKey key = new PropertyKey(TitleFormat, 2); // PKEY_Title: the text the jump list shows
          PropVariant value = new PropVariant();
          value.VarType = 31; // VT_LPWSTR
          value.Pointer = Marshal.StringToCoTaskMemUni(titles[i]);
          try {
            Marshal.ThrowExceptionForHR(store.SetValue(ref key, ref value));
            Marshal.ThrowExceptionForHR(store.Commit());
          } finally {
            Marshal.FreeCoTaskMem(value.Pointer);
          }
          tasks.AddObject(link);
        }
        list.AddUserTasks((IObjectArray)tasks);
        list.CommitList();
      } finally {
        Marshal.ReleaseComObject(list);
      }
    }

    public static void Delete(string appId) {
      ICustomDestinationList list = (ICustomDestinationList)new DestinationList();
      try { list.DeleteList(appId); } finally { Marshal.ReleaseComObject(list); }
    }
  }

  // A small HTTP(S) client that goes the way a profile's traffic goes: through its
  // proxy (SOCKS5, which also resolves the name, or HTTP CONNECT), or directly.
  // Used to see which IP address the world sees for a profile.
  public static class Net {
    static byte[] ReadExactly(Stream s, int count) {
      byte[] buffer = new byte[count];
      int done = 0;
      while (done < count) {
        int n = s.Read(buffer, done, count - done);
        if (n <= 0) throw new IOException("the connection closed early");
        done += n;
      }
      return buffer;
    }

    static string ReadHeaderBlock(Stream s) {
      StringBuilder text = new StringBuilder();
      while (!text.ToString().EndsWith("\r\n\r\n")) {
        int b = s.ReadByte();
        if (b < 0) throw new IOException("the connection closed early");
        text.Append((char)b);
        if (text.Length > 16384) throw new IOException("the proxy's answer is too long");
      }
      return text.ToString();
    }

    static TcpClient Connect(string host, int port, int timeoutMs) {
      TcpClient client = new TcpClient();
      IAsyncResult pending = client.BeginConnect(host, port, null, null);
      if (!pending.AsyncWaitHandle.WaitOne(timeoutMs)) {
        client.Close();
        throw new IOException("no answer from " + host + ":" + port);
      }
      client.EndConnect(pending);
      client.ReceiveTimeout = timeoutMs;
      client.SendTimeout = timeoutMs;
      return client;
    }

    // Returns the body of url (http:// or https://), fetched through proxy ("" for none).
    public static string Fetch(string url, string proxy, int timeoutMs) {
      Uri target = new Uri(url);
      bool tls = target.Scheme == "https";
      int port = target.Port;
      TcpClient client;
      Stream stream;
      if (String.IsNullOrEmpty(proxy)) {
        client = Connect(target.Host, port, timeoutMs);
        stream = client.GetStream();
      } else {
        Uri p = new Uri(proxy);
        string proxyHost = p.Host.Trim('[', ']');
        client = Connect(proxyHost, p.Port, timeoutMs);
        stream = client.GetStream();
        if (p.Scheme == "socks5") {
          stream.Write(new byte[] { 5, 1, 0 }, 0, 3);
          byte[] hello = ReadExactly(stream, 2);
          if (hello[0] != 5 || hello[1] != 0) throw new IOException("the SOCKS5 proxy wants a sign-in method Twinbar doesn't speak");
          byte[] name = Encoding.ASCII.GetBytes(target.Host);
          MemoryStream request = new MemoryStream();
          request.Write(new byte[] { 5, 1, 0, 3, (byte)name.Length }, 0, 5);
          request.Write(name, 0, name.Length);
          request.WriteByte((byte)(port >> 8));
          request.WriteByte((byte)(port & 255));
          stream.Write(request.ToArray(), 0, (int)request.Length);
          byte[] reply = ReadExactly(stream, 4);
          if (reply[1] != 0) throw new IOException("the SOCKS5 proxy couldn't connect (code " + reply[1] + ")");
          int rest = reply[3] == 1 ? 4 : reply[3] == 4 ? 16 : ReadExactly(stream, 1)[0];
          ReadExactly(stream, rest + 2);
        } else {
          if (p.Scheme == "https") {
            SslStream toProxy = new SslStream(stream);
            toProxy.AuthenticateAsClient(proxyHost, null, SslProtocols.None, true);
            stream = toProxy;
          }
          byte[] connect = Encoding.ASCII.GetBytes("CONNECT " + target.Host + ":" + port + " HTTP/1.1\r\nHost: " + target.Host + ":" + port + "\r\n\r\n");
          stream.Write(connect, 0, connect.Length);
          string answer = ReadHeaderBlock(stream);
          string status = answer.Split(new string[] { "\r\n" }, StringSplitOptions.None)[0];
          if (!status.Contains(" 200")) throw new IOException("the proxy said: " + status);
        }
      }
      try {
        if (tls) {
          SslStream secure = new SslStream(stream);
          secure.AuthenticateAsClient(target.Host, null, SslProtocols.None, true);
          stream = secure;
        }
        byte[] get = Encoding.ASCII.GetBytes("GET " + target.PathAndQuery + " HTTP/1.0\r\nHost: " + target.Host +
          "\r\nUser-Agent: twinbar\r\nAccept: application/json\r\nConnection: close\r\n\r\n");
        stream.Write(get, 0, get.Length);
        MemoryStream body = new MemoryStream();
        stream.CopyTo(body);
        string response = Encoding.UTF8.GetString(body.ToArray());
        int split = response.IndexOf("\r\n\r\n");
        if (split < 0) throw new IOException("no answer from " + target.Host);
        string statusLine = response.Substring(0, response.IndexOf("\r\n"));
        if (!statusLine.Contains(" 200")) throw new IOException(target.Host + " said: " + statusLine);
        return response.Substring(split + 4);
      } finally {
        stream.Dispose();
        client.Close();
      }
    }

    // What answers at host:port when asked, as protocol ("http" or "socks5") says,
    // to connect to target:targetPort: "ok" (a proxy, and it got there), "fail" (a
    // proxy that couldn't get there), "auth" (a proxy that wants a password), or ""
    // (no proxy of that kind: nothing there, or something else).
    public static string Probe(string host, int port, string protocol, string target, int targetPort, int timeoutMs) {
      TcpClient client = null;
      try {
        client = Connect(host, port, timeoutMs);
        Stream s = client.GetStream();
        if (protocol == "socks5") {
          s.Write(new byte[] { 5, 1, 0 }, 0, 3);
          byte[] hello = ReadExactly(s, 2);
          if (hello[0] != 5) return "";
          if (hello[1] != 0) return "auth";
          byte[] name = Encoding.ASCII.GetBytes(target);
          MemoryStream request = new MemoryStream();
          request.Write(new byte[] { 5, 1, 0, 3, (byte)name.Length }, 0, 5);
          request.Write(name, 0, name.Length);
          request.WriteByte((byte)(targetPort >> 8));
          request.WriteByte((byte)(targetPort & 255));
          s.Write(request.ToArray(), 0, (int)request.Length);
          byte[] reply = ReadExactly(s, 2);
          if (reply[0] != 5) return "";
          return reply[1] == 0 ? "ok" : "fail";
        }
        byte[] connect = Encoding.ASCII.GetBytes("CONNECT " + target + ":" + targetPort + " HTTP/1.1\r\nHost: " + target + ":" + targetPort + "\r\n\r\n");
        s.Write(connect, 0, connect.Length);
        string status = ReadHeaderBlock(s).Split(new string[] { "\r\n" }, StringSplitOptions.None)[0];
        Match code = Regex.Match(status, "^HTTP/1\\.[01] ([0-9]{3})");
        if (!code.Success) return "";
        int number = int.Parse(code.Groups[1].Value);
        if (number == 200) return "ok";
        if (number == 407) return "auth";
        if (number >= 500) return "fail";
        return "";
      } catch (Exception) {
        return "";
      } finally {
        if (client != null) client.Close();
      }
    }

    // Probe for many places at once; the answers come back in the same order.
    public static string[] ProbeAll(string[] hosts, int[] ports, string[] protocols, string target, int targetPort, int timeoutMs) {
      string[] answers = new string[hosts.Length];
      Thread[] workers = new Thread[hosts.Length];
      for (int i = 0; i < hosts.Length; i++) {
        int n = i;
        workers[n] = new Thread(delegate () { answers[n] = Probe(hosts[n], ports[n], protocols[n], target, targetPort, timeoutMs); });
        workers[n].IsBackground = true;
        workers[n].Start();
      }
      foreach (Thread worker in workers) worker.Join();
      return answers;
    }
  }

  // Draws a profile's icon: the app's icon, recoloured and/or with a letter badge,
  // saved as a multi-size .ico (32-bit images, PNG for 256 x 256).
  public static class IconMaker {
    [StructLayout(LayoutKind.Sequential)]
    struct IconInfo { public bool IsIcon; public int HotspotX; public int HotspotY; public IntPtr MaskBitmap; public IntPtr ColorBitmap; }

    [StructLayout(LayoutKind.Sequential)]
    struct BitmapInfo {
      public int Size; public int Width; public int Height; public short Planes; public short BitCount;
      public int Compression; public int SizeImage; public int XPelsPerMeter; public int YPelsPerMeter; public int ClrUsed; public int ClrImportant;
      [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)] public int[] Colors;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct StockIconInfo {
      public int Size; public IntPtr Icon; public int SysImageIndex; public int IconIndex;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Path;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern uint PrivateExtractIconsW(string file, int index, int cx, int cy, IntPtr[] icons, int[] ids, uint count, uint flags);
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr icon);
    [DllImport("user32.dll")] static extern bool GetIconInfo(IntPtr icon, out IconInfo info);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] static extern int GetDIBits(IntPtr dc, IntPtr bitmap, uint start, uint lines, [Out] byte[] bits, ref BitmapInfo info, uint usage);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHGetStockIconInfo(uint id, uint flags, ref StockIconInfo info);

    public static readonly int[] Sizes = { 16, 20, 24, 32, 40, 48, 64, 256 };

    static byte[] Pixels(IntPtr bitmap, int size) {
      BitmapInfo info = new BitmapInfo();
      info.Colors = new int[256];
      info.Size = 40; info.Width = size; info.Height = -size; info.Planes = 1; info.BitCount = 32;
      byte[] bits = new byte[size * size * 4];
      IntPtr dc = GetDC(IntPtr.Zero);
      try {
        return GetDIBits(dc, bitmap, 0, (uint)size, bits, ref info, 0) == 0 ? null : bits;
      } finally {
        ReleaseDC(IntPtr.Zero, dc);
      }
    }

    [StructLayout(LayoutKind.Sequential)]
    struct BitmapHeader { public int Type; public int Width; public int Height; public int WidthBytes; public ushort Planes; public ushort BitsPixel; public IntPtr Bits; }
    [DllImport("gdi32.dll")] static extern int GetObject(IntPtr obj, int size, ref BitmapHeader header);

    // One size of an icon in a file, with its transparency, or null if the file has none.
    public static Bitmap Extract(string file, int index, int size) {
      IntPtr[] icons = new IntPtr[1];
      int[] ids = new int[1];
      uint found = PrivateExtractIconsW(file, index, size, size, icons, ids, 1, 0);
      if (found == 0 || found == 0xFFFFFFFF || icons[0] == IntPtr.Zero) return null;
      try {
        return FromHandle(icons[0]);
      } finally {
        DestroyIcon(icons[0]);
      }
    }

    // An icon handle (from a file, or from a window) as a bitmap with its transparency.
    public static Bitmap FromHandle(IntPtr icon) {
      if (icon == IntPtr.Zero) return null;
      IconInfo info;
      if (!GetIconInfo(icon, out info)) return null;
      try {
        if (info.ColorBitmap == IntPtr.Zero) return null;
        BitmapHeader header = new BitmapHeader();
        if (GetObject(info.ColorBitmap, Marshal.SizeOf(typeof(BitmapHeader)), ref header) == 0) return null;
        int size = header.Width;
        byte[] color = Pixels(info.ColorBitmap, size);
        if (color == null) return null;
        bool hasAlpha = false;
        for (int i = 3; i < color.Length; i += 4) { if (color[i] != 0) { hasAlpha = true; break; } }
        if (!hasAlpha) {
          byte[] mask = Pixels(info.MaskBitmap, size);
          for (int i = 0; i < color.Length; i += 4) color[i + 3] = (byte)(mask != null && mask[i] != 0 ? 0 : 255);
        }
        Bitmap bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        BitmapData data = bitmap.LockBits(new Rectangle(0, 0, size, size), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        try {
          for (int y = 0; y < size; y++) Marshal.Copy(color, y * size * 4, new IntPtr(data.Scan0.ToInt64() + (long)y * data.Stride), size * 4);
        } finally {
          bitmap.UnlockBits(data);
        }
        return bitmap;
      } finally {
        if (info.ColorBitmap != IntPtr.Zero) DeleteObject(info.ColorBitmap);
        if (info.MaskBitmap != IntPtr.Zero) DeleteObject(info.MaskBitmap);
      }
    }

    static void ToHsl(Color c, out double h, out double s, out double l) {
      double r = c.R / 255.0, g = c.G / 255.0, b = c.B / 255.0;
      double max = Math.Max(r, Math.Max(g, b)), min = Math.Min(r, Math.Min(g, b));
      l = (max + min) / 2;
      if (max == min) { h = 0; s = 0; return; }
      double d = max - min;
      s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
      if (max == r) h = (g - b) / d + (g < b ? 6 : 0);
      else if (max == g) h = (b - r) / d + 2;
      else h = (r - g) / d + 4;
      h /= 6;
    }

    static double HueToRgb(double p, double q, double t) {
      if (t < 0) t += 1;
      if (t > 1) t -= 1;
      if (t < 1.0 / 6) return p + (q - p) * 6 * t;
      if (t < 0.5) return q;
      if (t < 2.0 / 3) return p + (q - p) * (2.0 / 3 - t) * 6;
      return p;
    }

    static void FromHsl(double h, double s, double l, out byte r, out byte g, out byte b) {
      double rr, gg, bb;
      if (s == 0) { rr = gg = bb = l; }
      else {
        double q = l < 0.5 ? l * (1 + s) : l + s - l * s;
        double p = 2 * l - q;
        rr = HueToRgb(p, q, h + 1.0 / 3); gg = HueToRgb(p, q, h); bb = HueToRgb(p, q, h - 1.0 / 3);
      }
      r = (byte)Math.Round(rr * 255); g = (byte)Math.Round(gg * 255); b = (byte)Math.Round(bb * 255);
    }

    // Repaints the icon in one colour, keeping its light and shade:
    // dark stays dark, mid-tones become the colour, light goes towards white.
    static void Colorize(Bitmap bitmap, Color target) {
      double th, ts, tl;
      ToHsl(target, out th, out ts, out tl);
      Rectangle all = new Rectangle(0, 0, bitmap.Width, bitmap.Height);
      BitmapData data = bitmap.LockBits(all, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
      try {
        byte[] px = new byte[data.Stride * bitmap.Height];
        Marshal.Copy(data.Scan0, px, 0, px.Length);
        for (int i = 0; i + 3 < px.Length; i += 4) {
          if (px[i + 3] == 0) continue;
          double y = (0.299 * px[i + 2] + 0.587 * px[i + 1] + 0.114 * px[i]) / 255.0;
          double l = y < 0.5 ? tl * (y / 0.5) : tl + (1 - tl) * ((y - 0.5) / 0.5);
          byte r, g, b;
          FromHsl(th, ts, Math.Max(0, Math.Min(1, l)), out r, out g, out b);
          px[i] = b; px[i + 1] = g; px[i + 2] = r;
        }
        Marshal.Copy(px, 0, data.Scan0, px.Length);
      } finally {
        bitmap.UnlockBits(data);
      }
    }

    // A round badge in the bottom-right corner with a white ring; the letter is left
    // out below 24 x 24, where it couldn't be read anyway.
    static void DrawBadge(Graphics g, int size, Color fill, string text) {
      g.SmoothingMode = SmoothingMode.AntiAlias;
      g.PixelOffsetMode = PixelOffsetMode.HighQuality;
      float outer = size < 24 ? size * 0.68f : size * 0.52f;
      float ring = Math.Max(1f, outer * 0.09f);
      float x = size - outer, y = size - outer;
      using (SolidBrush white = new SolidBrush(Color.White)) g.FillEllipse(white, x, y, outer, outer);
      using (SolidBrush brush = new SolidBrush(fill)) g.FillEllipse(brush, x + ring, y + ring, outer - 2 * ring, outer - 2 * ring);
      if (size < 24 || String.IsNullOrEmpty(text)) return;
      float inner = outer - 2 * ring;
      FontFamily family;
      try { family = new FontFamily("Segoe UI"); } catch (ArgumentException) { family = new FontFamily(GenericFontFamilies.SansSerif); }
      using (family)
      using (GraphicsPath path = new GraphicsPath()) {
        path.AddString(text, family, (int)FontStyle.Bold, 100f, PointF.Empty, StringFormat.GenericTypographic);
        RectangleF bounds = path.GetBounds();
        if (bounds.Width <= 0 || bounds.Height <= 0) return;
        float scale = Math.Min(inner * 0.56f / bounds.Height, inner * 0.72f / bounds.Width);
        using (Matrix m = new Matrix()) {
          m.Translate(x + outer / 2f, y + outer / 2f);
          m.Scale(scale, scale);
          m.Translate(-(bounds.X + bounds.Width / 2f), -(bounds.Y + bounds.Height / 2f));
          path.Transform(m);
        }
        using (SolidBrush white = new SolidBrush(Color.White)) g.FillPath(white, path);
      }
    }

    static Bitmap Render(Bitmap source, int size, bool tint, bool badge, Color color, string text) {
      Bitmap result = new Bitmap(size, size, PixelFormat.Format32bppArgb);
      using (Graphics g = Graphics.FromImage(result)) {
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.DrawImage(source, new Rectangle(0, 0, size, size));
      }
      if (tint) Colorize(result, color);
      if (badge) {
        Color fill = tint ? Color.FromArgb(color.R * 72 / 100, color.G * 72 / 100, color.B * 72 / 100) : color;
        using (Graphics g = Graphics.FromImage(result)) DrawBadge(g, size, fill, text);
      }
      return result;
    }

    static byte[] Png(Bitmap image) {
      using (MemoryStream ms = new MemoryStream()) { image.Save(ms, ImageFormat.Png); return ms.ToArray(); }
    }

    // An icon directory entry's image: BITMAPINFOHEADER, bottom-up BGRA rows, AND mask.
    static byte[] Dib(Bitmap image) {
      int w = image.Width, h = image.Height;
      byte[] px = new byte[w * h * 4];
      BitmapData data = image.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
      try {
        for (int y = 0; y < h; y++) Marshal.Copy(new IntPtr(data.Scan0.ToInt64() + (long)y * data.Stride), px, y * w * 4, w * 4);
      } finally {
        image.UnlockBits(data);
      }
      int maskStride = ((w + 31) / 32) * 4;
      using (MemoryStream ms = new MemoryStream())
      using (BinaryWriter bw = new BinaryWriter(ms)) {
        bw.Write(40); bw.Write(w); bw.Write(h * 2); bw.Write((short)1); bw.Write((short)32);
        bw.Write(0); bw.Write(w * h * 4 + maskStride * h); bw.Write(0); bw.Write(0); bw.Write(0); bw.Write(0);
        for (int y = h - 1; y >= 0; y--) bw.Write(px, y * w * 4, w * 4);
        for (int y = h - 1; y >= 0; y--) {
          byte[] row = new byte[maskStride];
          for (int x = 0; x < w; x++) if (px[(y * w + x) * 4 + 3] == 0) row[x / 8] |= (byte)(0x80 >> (x % 8));
          bw.Write(row);
        }
        bw.Flush();
        return ms.ToArray();
      }
    }

    // The file and index to take the app's icon from; Windows' own "application"
    // icon when the app has none.
    static void ResolveSource(string source, out string file, out int index) {
      file = source;
      index = 0;
      using (Bitmap probe = Extract(source, 0, 32)) {
        if (probe != null) return;
      }
      StockIconInfo stock = new StockIconInfo();
      stock.Size = Marshal.SizeOf(typeof(StockIconInfo));
      if (SHGetStockIconInfo(2, 0, ref stock) != 0) throw new InvalidOperationException("couldn't find an icon to start from");
      file = stock.Path;
      index = stock.IconIndex;
    }

    static void WriteIco(string output, List<byte[]> images) {
      using (FileStream fs = File.Create(output))
      using (BinaryWriter bw = new BinaryWriter(fs)) {
        bw.Write((short)0); bw.Write((short)1); bw.Write((short)images.Count);
        int offset = 6 + 16 * images.Count;
        for (int i = 0; i < images.Count; i++) {
          int s = Sizes[i];
          bw.Write((byte)(s >= 256 ? 0 : s)); bw.Write((byte)(s >= 256 ? 0 : s)); bw.Write((byte)0); bw.Write((byte)0);
          bw.Write((short)1); bw.Write((short)32); bw.Write(images[i].Length); bw.Write(offset);
          offset += images[i].Length;
        }
        foreach (byte[] image in images) bw.Write(image);
      }
    }

    // style: tint+badge, tint, badge or original. Writes a preview PNG (256 x 256) too if asked.
    public static void Build(string source, string output, string style, string colorHex, string badgeText, string preview) {
      Color color = ColorTranslator.FromHtml(colorHex);
      bool tint = style == "tint" || style == "tint+badge";
      bool badge = style == "badge" || style == "tint+badge";
      string file;
      int index;
      ResolveSource(source, out file, out index);
      List<byte[]> images = new List<byte[]>();
      foreach (int size in Sizes) {
        using (Bitmap src = Extract(file, index, size)) {
          if (src == null) throw new InvalidOperationException("couldn't read the app's icon at " + size + " x " + size);
          using (Bitmap img = Render(src, size, tint, badge, color, badgeText)) {
            images.Add(size >= 256 ? Png(img) : Dib(img));
            if (size >= 256 && !String.IsNullOrEmpty(preview)) img.Save(preview, ImageFormat.Png);
          }
        }
      }
      WriteIco(output, images);
    }

    // One size of what Build would draw, for showing in a window.
    public static Bitmap Preview(string source, string style, string colorHex, string badgeText, int size) {
      string file;
      int index;
      ResolveSource(source, out file, out index);
      using (Bitmap src = Extract(file, index, size)) {
        if (src == null) throw new InvalidOperationException("couldn't read the app's icon");
        bool tint = style == "tint" || style == "tint+badge";
        bool badge = style == "badge" || style == "tint+badge";
        return Render(src, size, tint, badge, ColorTranslator.FromHtml(colorHex), badgeText);
      }
    }

    static GraphicsPath RoundedRectangle(RectangleF r, float radius) {
      GraphicsPath path = new GraphicsPath();
      float d = radius * 2;
      path.AddArc(r.X, r.Y, d, d, 180, 90);
      path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
      path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
      path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
      path.CloseFigure();
      return path;
    }

    // Twinbar's own icon: two overlapping windows, the front one cut out of the back one.
    public static void BuildAppIcon(string output) {
      List<byte[]> images = new List<byte[]>();
      foreach (int size in Sizes) {
        using (Bitmap img = new Bitmap(size, size, PixelFormat.Format32bppArgb))
        using (Graphics g = Graphics.FromImage(img)) {
          g.SmoothingMode = SmoothingMode.AntiAlias;
          g.PixelOffsetMode = PixelOffsetMode.HighQuality;
          float s = size, radius = s * 0.14f, gap = Math.Max(1f, s * 0.05f);
          RectangleF back = new RectangleF(s * 0.04f, s * 0.04f, s * 0.62f, s * 0.62f);
          RectangleF front = new RectangleF(s * 0.34f, s * 0.34f, s * 0.62f, s * 0.62f);
          using (GraphicsPath p = RoundedRectangle(back, radius))
          using (SolidBrush b = new SolidBrush(Color.FromArgb(0x8E, 0xA4, 0xF2))) g.FillPath(b, p);
          RectangleF cut = RectangleF.Inflate(front, gap, gap);
          g.CompositingMode = CompositingMode.SourceCopy;
          using (GraphicsPath p = RoundedRectangle(cut, radius + gap))
          using (SolidBrush b = new SolidBrush(Color.Transparent)) g.FillPath(b, p);
          g.CompositingMode = CompositingMode.SourceOver;
          using (GraphicsPath p = RoundedRectangle(front, radius))
          using (SolidBrush b = new SolidBrush(Color.FromArgb(0x3E, 0x63, 0xDD))) g.FillPath(b, p);
          images.Add(size >= 256 ? Png(img) : Dib(img));
        }
      }
      WriteIco(output, images);
    }
  }
}
'@

function Initialize-Interop {
  if (-not ('TwinbarInterop.Shell' -as [type])) {
    Add-Type -TypeDefinition $script:InteropSource -Language CSharp -ReferencedAssemblies 'System.Drawing'
  }
}

function Save-ShellLink {
  param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string] $TargetPath,
    [string] $Arguments = '',
    [string] $WorkingDirectory = '',
    [string] $IconPath = '',
    [int] $IconIndex = 0,
    [string] $Description = '',
    [string] $AppUserModelId = ''
  )
  Initialize-Interop
  [TwinbarInterop.Shell]::SaveLink($Path, $TargetPath, $Arguments, $WorkingDirectory, $IconPath, $IconIndex, $Description, $AppUserModelId)
}

function Read-ShellLink([string] $Path) {
  Initialize-Interop
  $v = [TwinbarInterop.Shell]::ReadLink($Path)
  [pscustomobject]@{
    TargetPath       = $v[0]
    Arguments        = $v[1]
    WorkingDirectory = $v[2]
    IconPath         = $v[3]
    IconIndex        = [int]$v[4]
    AppUserModelId   = $v[5]
  }
}

function Move-ToRecycleBin([string] $Path) {
  Initialize-Interop
  [TwinbarInterop.Shell]::Recycle($Path)
}

# ---------------------------------------------------------------------------
# The launcher: what a profile's shortcut starts. It starts the app with the
# profile's data folder, then puts the profile's AppUserModelID (and relaunch
# name, command and icon) on the app's windows, so the taskbar shows them as a
# button of their own. Apps set their own ID for the whole process, which wins
# over the shortcut's; an ID set on the window wins over that. Nothing is
# injected into the app. Built on this computer from the source below, once
# per Twinbar version, into <Twinbar home>\bin.
# ---------------------------------------------------------------------------

$script:LauncherSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

[assembly: AssemblyTitle("Twinbar launcher")]
[assembly: AssemblyProduct("Twinbar")]
[assembly: AssemblyVersion("{{VERSION}}.0")]
[assembly: AssemblyFileVersion("{{VERSION}}.0")]

namespace TwinbarLauncher {
  [StructLayout(LayoutKind.Sequential, Pack = 4)]
  struct PropertyKey {
    public Guid FormatId;
    public uint PropertyId;
    public PropertyKey(Guid formatId, uint propertyId) { FormatId = formatId; PropertyId = propertyId; }
  }

  [StructLayout(LayoutKind.Explicit, Size = 24)]
  struct PropVariant {
    [FieldOffset(0)] public ushort VarType;
    [FieldOffset(8)] public IntPtr Pointer;
  }

  [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IPropertyStore {
    [PreserveSig] int GetCount(out uint count);
    [PreserveSig] int GetAt(uint index, out PropertyKey key);
    [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
    [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
    [PreserveSig] int Commit();
  }

  [StructLayout(LayoutKind.Sequential)]
  struct Msg { public IntPtr Hwnd; public uint Message; public IntPtr WParam; public IntPtr LParam; public uint Time; public int X; public int Y; }

  // Starts Microsoft Store (packaged) apps, with arguments, as Windows itself does.
  [ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IApplicationActivationManager {
    [PreserveSig] int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId, [MarshalAs(UnmanagedType.LPWStr)] string arguments, int options, out uint processId);
    [PreserveSig] int ActivateForFile(IntPtr appUserModelId, IntPtr items, IntPtr verb, out uint processId);
    [PreserveSig] int ActivateForProtocol(IntPtr appUserModelId, IntPtr items, out uint processId);
  }

  [ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
  class ApplicationActivationManager { }

  static class Program {
    delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
    delegate void WinEventProc(IntPtr hook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
    delegate void TimerProc(IntPtr hwnd, uint message, UIntPtr id, uint time);

    [DllImport("shell32.dll")] static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);
    [DllImport("ole32.dll")] static extern int PropVariantClear(ref PropVariant value);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr hwnd, out int pid);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEventProc callback, uint pid, uint thread, uint flags);
    [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr hook);
    [DllImport("user32.dll")] static extern UIntPtr SetTimer(IntPtr hwnd, UIntPtr id, uint ms, TimerProc callback);
    [DllImport("user32.dll")] static extern int GetMessage(out Msg msg, IntPtr hwnd, uint min, uint max);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref Msg msg);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref Msg msg);
    [DllImport("user32.dll")] static extern void PostQuitMessage(int code);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int MessageBoxW(IntPtr hwnd, string text, string caption, uint type);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle, uint ms);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageNameW(IntPtr process, int flags, StringBuilder name, ref int size);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process, int infoClass, IntPtr buffer, int length, out int returned);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadImageW(IntPtr instance, string name, uint type, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr hwnd);

    static readonly Guid AppUserModel = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
    static Guid propertyStoreId = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
    const uint RelaunchCommandKey = 2, RelaunchIconKey = 3, RelaunchNameKey = 4, AppIdKey = 5;
    const uint QueryLimited = 0x1000, Synchronize = 0x100000;
    const uint EventObjectCreate = 0x8000, EventObjectDestroy = 0x8001, EventObjectShow = 0x8002;
    const uint WmGetIcon = 0x7F, WmSetIcon = 0x80, AbortIfHung = 2;

    static string logPath, profileId, appId, displayName, relaunchCommand, iconResource, iconFile;
    static string launchExe, appKind, packageApp, exeBaseName, extraArgs, dataDir, proxy;
    static readonly Dictionary<int, IntPtr> iconsBySize = new Dictionary<int, IntPtr>();
    static Regex dataDirArgument;
    static IntPtr mainProcess = IntPtr.Zero, hook = IntPtr.Zero;
    static int mainPid, tagged;
    static bool seen;
    static DateTime started, lastSeen;
    static readonly WinEventProc onWinEvent = OnWinEvent; // kept alive while hooked
    static readonly TimerProc onTimer = OnTimer;

    [STAThread]
    static int Main(string[] args) {
      try {
        return Run(args);
      } catch (Exception e) {
        Log("error: " + e);
        MessageBoxW(IntPtr.Zero, "Twinbar couldn't open this profile.\n\n" + e.Message, "Twinbar", 0x10);
        return 1;
      }
    }

    static string Text(Dictionary<string, object> record, string key) {
      object value;
      return record.TryGetValue(key, out value) && value != null ? value.ToString() : "";
    }

    static int Run(string[] args) {
      if (args.Length < 1) throw new ArgumentException("no profile was given.");
      profileId = args[0];
      if (!Regex.IsMatch(profileId, "^[a-z0-9][a-z0-9.-]*$")) throw new ArgumentException("'" + profileId + "' isn't a profile id.");
      string home = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, ".."));
      logPath = Path.Combine(Path.Combine(home, "logs"), "launcher.log");
      string recordPath = Path.Combine(Path.Combine(home, "profiles"), profileId + ".json");
      if (!File.Exists(recordPath)) {
        throw new InvalidOperationException("The profile '" + profileId + "' doesn't exist any more. Remove this shortcut, or make the profile again.");
      }
      Dictionary<string, object> record = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(recordPath, Encoding.UTF8));
      launchExe = Text(record, "launchExe");
      dataDir = Text(record, "dataDir");
      appId = Text(record, "aumid");
      appKind = Text(record, "appKind");
      packageApp = Text(record, "packageApp");
      extraArgs = Text(record, "extraArgs");
      proxy = Text(record, "proxy");
      exeBaseName = Path.GetFileNameWithoutExtension(Text(record, "realExe"));
      displayName = Text(record, "appName") + " " + Text(record, "name");
      iconFile = Text(record, "icon");
      iconResource = (iconFile.Length > 0 ? iconFile : launchExe) + ",0";
      relaunchCommand = "\"" + Assembly.GetExecutingAssembly().Location + "\" " + profileId;
      dataDirArgument = new Regex("--user-data-dir=\"?" + Regex.Escape(dataDir) + "\"?(?=\\s|$)", RegexOptions.IgnoreCase);
      // A Store app's folder changes with every update; Windows finds it by its package.
      if (appKind != "store" && !File.Exists(launchExe)) {
        throw new FileNotFoundException(displayName + ": the app isn't at " + launchExe + " any more. Run: twinbar rebuild " + profileId + " -App <new place>");
      }

      bool first;
      using (Mutex watcher = new Mutex(true, "Local\\" + appId, out first)) {
        StartApp();
        if (!first) {
          Log(profileId + ": already being looked after; asked the app to come forward");
          return 0;
        }
        Log(profileId + ": started " + launchExe);
        started = DateTime.UtcNow;
        SetTimer(IntPtr.Zero, UIntPtr.Zero, 400, onTimer);
        Msg msg;
        while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0) {
          TranslateMessage(ref msg);
          DispatchMessage(ref msg);
        }
        if (hook != IntPtr.Zero) UnhookWinEvent(hook);
        if (mainProcess != IntPtr.Zero) CloseHandle(mainProcess);
        Log(profileId + ": " + (seen ? "the app quit" : "the app never started") + "; " + tagged + " window(s) tagged");
        watcher.ReleaseMutex();
        return 0;
      }
    }

    static void StartApp() {
      string arguments = ("--user-data-dir=\"" + dataDir + "\" " + extraArgs).Trim();
      if (appKind == "store") {
        IApplicationActivationManager manager = (IApplicationActivationManager)new ApplicationActivationManager();
        uint pid;
        int hr = manager.ActivateApplication(packageApp, arguments, 0, out pid);
        if (hr != 0) {
          throw new InvalidOperationException(displayName + ": Windows couldn't start " + packageApp + " (0x" + hr.ToString("X8") + "). Is the app still installed?");
        }
        return;
      }
      ProcessStartInfo info = new ProcessStartInfo(launchExe, arguments);
      info.UseShellExecute = false;
      info.WorkingDirectory = Path.GetDirectoryName(launchExe);
      if (proxy.Length > 0) {
        // For the app's own code outside Chromium (Node.js), where it honours these.
        // HTTPS_PROXY and HTTP_PROXY only for an HTTP proxy: most Node code can't use a
        // SOCKS address there and would fail; ALL_PROXY takes either.
        if (proxy.StartsWith("http")) {
          info.EnvironmentVariables["HTTPS_PROXY"] = proxy;
          info.EnvironmentVariables["HTTP_PROXY"] = proxy;
        }
        info.EnvironmentVariables["ALL_PROXY"] = proxy;
        info.EnvironmentVariables["NO_PROXY"] = "localhost,127.0.0.1,::1";
      }
      using (Process.Start(info)) { }
    }

    static void OnTimer(IntPtr hwnd, uint message, UIntPtr id, uint time) {
      try {
        if (mainProcess != IntPtr.Zero && WaitForSingleObject(mainProcess, 0) == 0) {
          CloseHandle(mainProcess);
          mainProcess = IntPtr.Zero;
          mainPid = 0;
          if (hook != IntPtr.Zero) { UnhookWinEvent(hook); hook = IntPtr.Zero; }
          lastSeen = DateTime.UtcNow;
        }
        if (mainProcess == IntPtr.Zero) FindMainProcess();
        if (mainProcess != IntPtr.Zero) {
          TagAll();
          return;
        }
        // Give the app 2 minutes to start (it may update first), and 10 seconds to
        // come back after it quits (apps restart themselves to finish an update).
        double waited = (DateTime.UtcNow - (seen ? lastSeen : started)).TotalSeconds;
        if (waited > (seen ? 10 : 120)) PostQuitMessage(0);
      } catch (Exception e) {
        Log(profileId + ": " + e.Message);
      }
    }

    // The app's main process: our executable, started with our data folder, not a
    // helper (--type=...), and not Squirrel's launcher handing over to the real app.
    static void FindMainProcess() {
      foreach (Process p in Process.GetProcessesByName(exeBaseName)) {
        using (p) {
          if (mainProcess != IntPtr.Zero) continue;
          string commandLine = CommandLine(p.Id);
          if (commandLine == null || commandLine.Contains("--type=") || !dataDirArgument.IsMatch(commandLine)) continue;
          if (appKind == "squirrel" && String.Equals(ImagePath(p.Id), launchExe, StringComparison.OrdinalIgnoreCase)) continue;
          IntPtr handle = OpenProcess(Synchronize | QueryLimited, false, p.Id);
          if (handle == IntPtr.Zero) continue;
          mainProcess = handle;
          mainPid = p.Id;
          seen = true;
          hook = SetWinEventHook(EventObjectCreate, EventObjectShow, IntPtr.Zero, onWinEvent, (uint)p.Id, 0, 0);
          Log(profileId + ": looking after process " + p.Id);
        }
      }
    }

    static void TagAll() {
      EnumWindows(delegate (IntPtr hwnd, IntPtr lParam) {
        int pid;
        GetWindowThreadProcessId(hwnd, out pid);
        if (pid == mainPid) {
          Tag(hwnd);
          SetIcons(hwnd);
        }
        return true;
      }, IntPtr.Zero);
    }

    static void OnWinEvent(IntPtr hookHandle, uint eventType, IntPtr hwnd, int idObject, int idChild, uint thread, uint time) {
      if (eventType == EventObjectDestroy || idObject != 0 || idChild != 0 || hwnd == IntPtr.Zero) return;
      if (GetAncestor(hwnd, 2) != hwnd) return; // top-level windows only
      try {
        int pid;
        GetWindowThreadProcessId(hwnd, out pid);
        if (pid == mainPid) {
          Tag(hwnd);
          SetIcons(hwnd);
        }
      } catch (Exception e) {
        Log(profileId + ": " + e.Message);
      }
    }

    static IntPtr IconOfSize(int size) {
      IntPtr icon;
      if (!iconsBySize.TryGetValue(size, out icon)) {
        icon = LoadImageW(IntPtr.Zero, iconFile, 1, size, size, 0x10); // IMAGE_ICON, LR_LOADFROMFILE
        iconsBySize[size] = icon;
      }
      return icon;
    }

    // The profile's icon for the window itself (title bar, Alt+Tab), at the window's
    // DPI. These icons live as long as this launcher, which outlives the app.
    static void SetIcons(IntPtr hwnd) {
      if (iconFile.Length == 0 || !IsWindowVisible(hwnd)) return;
      uint dpi = 96;
      try { dpi = GetDpiForWindow(hwnd); } catch (EntryPointNotFoundException) { }
      if (dpi == 0) dpi = 96;
      IntPtr big = IconOfSize((int)(32 * dpi / 96)), small = IconOfSize((int)(16 * dpi / 96));
      if (big == IntPtr.Zero || small == IntPtr.Zero) return;
      IntPtr current;
      if (SendMessageTimeoutW(hwnd, WmGetIcon, (IntPtr)1, IntPtr.Zero, AbortIfHung, 200, out current) == IntPtr.Zero) return;
      if (current == big) return;
      SendMessageTimeoutW(hwnd, WmSetIcon, (IntPtr)1, big, AbortIfHung, 200, out current);
      SendMessageTimeoutW(hwnd, WmSetIcon, (IntPtr)0, small, AbortIfHung, 200, out current);
    }

    // Relaunch name, command and icon first, then the ID, which the taskbar acts on.
    static void Tag(IntPtr hwnd) {
      IPropertyStore store;
      if (SHGetPropertyStoreForWindow(hwnd, ref propertyStoreId, out store) != 0 || store == null) return;
      try {
        if (GetText(store, AppIdKey) == appId) return;
        SetText(store, RelaunchNameKey, displayName);
        SetText(store, RelaunchCommandKey, relaunchCommand);
        SetText(store, RelaunchIconKey, iconResource);
        SetText(store, AppIdKey, appId);
        tagged++;
      } finally {
        Marshal.ReleaseComObject(store);
      }
    }

    static string GetText(IPropertyStore store, uint id) {
      PropertyKey key = new PropertyKey(AppUserModel, id);
      PropVariant value;
      if (store.GetValue(ref key, out value) != 0) return null;
      try {
        return value.VarType == 31 && value.Pointer != IntPtr.Zero ? Marshal.PtrToStringUni(value.Pointer) : null;
      } finally {
        PropVariantClear(ref value);
      }
    }

    static void SetText(IPropertyStore store, uint id, string text) {
      PropertyKey key = new PropertyKey(AppUserModel, id);
      PropVariant value = new PropVariant();
      value.VarType = 31; // VT_LPWSTR
      value.Pointer = Marshal.StringToCoTaskMemUni(text);
      try {
        store.SetValue(ref key, ref value);
      } finally {
        Marshal.FreeCoTaskMem(value.Pointer);
      }
    }

    static string CommandLine(int pid) {
      IntPtr process = OpenProcess(QueryLimited, false, pid);
      if (process == IntPtr.Zero) return null;
      try {
        int length;
        NtQueryInformationProcess(process, 60, IntPtr.Zero, 0, out length); // ProcessCommandLineInformation
        if (length <= 0) return null;
        IntPtr buffer = Marshal.AllocHGlobal(length);
        try {
          if (NtQueryInformationProcess(process, 60, buffer, length, out length) != 0) return null;
          int bytes = (ushort)Marshal.ReadInt16(buffer);
          return Marshal.PtrToStringUni(Marshal.ReadIntPtr(buffer, IntPtr.Size), bytes / 2);
        } finally {
          Marshal.FreeHGlobal(buffer);
        }
      } finally {
        CloseHandle(process);
      }
    }

    static string ImagePath(int pid) {
      IntPtr process = OpenProcess(QueryLimited, false, pid);
      if (process == IntPtr.Zero) return null;
      try {
        StringBuilder name = new StringBuilder(32768);
        int size = name.Capacity;
        return QueryFullProcessImageNameW(process, 0, name, ref size) ? name.ToString() : null;
      } finally {
        CloseHandle(process);
      }
    }

    static void Log(string line) {
      try {
        if (logPath == null) return;
        Directory.CreateDirectory(Path.GetDirectoryName(logPath));
        FileInfo file = new FileInfo(logPath);
        if (file.Exists && file.Length > 262144) {
          File.Delete(logPath + ".old");
          File.Move(logPath, logPath + ".old");
        }
        File.AppendAllText(logPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + line + Environment.NewLine);
      } catch (Exception) {
        // Logging must never stop the launcher.
      }
    }
  }
}
'@

function Get-LauncherPath { Join-Path (Join-Path (Get-TwinbarHome) 'bin') $script:LauncherName }

# Builds the launcher if it's missing or from another Twinbar version.
function Initialize-Launcher {
  $path = Get-LauncherPath
  $want = "$($script:TwinbarVersion).0"
  if ((Test-Path -LiteralPath $path -PathType Leaf) -and
    [Diagnostics.FileVersionInfo]::GetVersionInfo($path).FileVersion -eq $want) {
    return $path
  }
  [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
  $tmp = "$path.$PID.tmp.exe"
  $source = $script:LauncherSource.Replace('{{VERSION}}', $script:TwinbarVersion)
  Add-Type -TypeDefinition $source -Language CSharp -OutputAssembly $tmp -OutputType WindowsApplication -ReferencedAssemblies 'System.Web.Extensions'
  try {
    Move-Item -LiteralPath $tmp -Destination $path -Force
  } catch {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $path) {
      Write-Warning "couldn't update $path while a profile is open; the older launcher keeps working"
      return $path
    }
    throw
  }
  return $path
}

function Get-IconsDir { Join-Path (Get-TwinbarHome) 'icons' }

# Icon files are named after what's in them, so a changed look gets a new file
# name and Windows can't show a stale copy from its icon cache.
function Get-IconPath($Record) {
  $look = '{0}|{1}|{2}|{3}|{4}' -f $Record.style, $Record.color, $Record.badge, $Record.launchExe, $script:TwinbarVersion
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($look)) } finally { $sha.Dispose() }
  $hash = (($bytes[0..3] | ForEach-Object { $_.ToString('x2') }) -join '')
  return (Join-Path (Get-IconsDir) "$($Record.id)-$hash.ico")
}

function New-ProfileIcon([string] $SourceExe, [string] $Path, [string] $StyleName, [string] $ColorHex, [string] $BadgeText) {
  Initialize-Interop
  [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
  $tmp = "$Path.$PID.tmp"
  [TwinbarInterop.IconMaker]::Build($SourceExe, $tmp, $StyleName, $ColorHex, $BadgeText, '')
  Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# The taskbar's buttons, by the AppUserModelID each stands for; $null when there's
# no taskbar to ask.
function Get-TaskbarAppIds {
  Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
  $a = [System.Windows.Automation.AutomationElement]
  $condition = New-Object System.Windows.Automation.PropertyCondition($a::ClassNameProperty, 'Shell_TrayWnd')
  $tray = $a::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $condition)
  if ($null -eq $tray) { return $null }
  $ids = @()
  foreach ($e in $tray.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
    if ($e.Current.AutomationId -like 'Appid:*') { $ids += $e.Current.AutomationId.Substring(6).Trim() }
  }
  return , $ids
}

# Launchers looking after a profile (their command line ends with the profile id).
function Get-ProfileLaunchers([string] $Id) {
  @(Get-CimInstance -ClassName Win32_Process -Filter "Name = '$($script:LauncherName)'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -match ('\s' + [regex]::Escape($Id) + '\s*$') })
}

# ---------------------------------------------------------------------------
# Twinbar.exe: the Twinbar window without a console. It runs twinbar.ps1 (next
# to it) inside PowerShell with "gui", and has its own icon and taskbar ID.
# Built by "twinbar install" on this computer, like the launcher.
# ---------------------------------------------------------------------------

$script:AppHostSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;

[assembly: AssemblyTitle("Twinbar")]
[assembly: AssemblyProduct("Twinbar")]
[assembly: AssemblyVersion("{{VERSION}}.0")]
[assembly: AssemblyFileVersion("{{VERSION}}.0")]

namespace TwinbarApp {
  public static class Program {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hwnd, int command);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int MessageBoxW(IntPtr hwnd, string text, string caption, uint type);
    [DllImport("user32.dll")] static extern bool AllowSetForegroundWindow(int processId);

    // Tells the running Twinbar to show its window or to quit; false if none listens.
    static bool Signal(string name) {
      AllowSetForegroundWindow(-1); // ASFW_ANY: it may bring its window to the front
      try {
        using (EventWaitHandle signal = EventWaitHandle.OpenExisting(name)) signal.Set();
        return true;
      } catch (WaitHandleCannotBeOpenedException) {
        return false;
      }
    }

    // Twinbar.exe             the window (or, if Twinbar runs already, show that one)
    // Twinbar.exe --tray      just the icon in the notification area (at sign-in)
    // Twinbar.exe --quit      ends a running Twinbar
    [STAThread]
    public static int Main(string[] args) {
      SetCurrentProcessExplicitAppUserModelID("Twinbar.App");
      SetProcessDPIAware();
      bool tray = Array.IndexOf(args, "--tray") >= 0, quit = Array.IndexOf(args, "--quit") >= 0;
      try {
        bool first;
        using (Mutex single = new Mutex(true, "Local\\Twinbar.App", out first)) {
          if (!first) {
            if (quit) { Signal("Local\\Twinbar.App.Quit"); return 0; }
            if (tray || Signal("Local\\Twinbar.App.Show")) return 0;
            // A Twinbar from before 0.8.0 doesn't listen: bring its window forward.
            Process me = Process.GetCurrentProcess();
            foreach (Process p in Process.GetProcessesByName(me.ProcessName)) {
              if (p.Id != me.Id && p.MainWindowHandle != IntPtr.Zero) {
                ShowWindow(p.MainWindowHandle, 9); // SW_RESTORE
                SetForegroundWindow(p.MainWindowHandle);
              }
            }
            return 0;
          }
          if (quit) return 0;
          string script = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "twinbar.ps1");
          if (!File.Exists(script)) throw new FileNotFoundException("twinbar.ps1 should be next to Twinbar.exe, in " + AppDomain.CurrentDomain.BaseDirectory);
          InitialSessionState state = InitialSessionState.CreateDefault();
          state.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
          using (Runspace runspace = RunspaceFactory.CreateRunspace(state)) {
            runspace.ApartmentState = ApartmentState.STA;
            runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
            runspace.Open();
            using (PowerShell shell = PowerShell.Create()) {
              shell.Runspace = runspace;
              shell.AddCommand(script).AddArgument("gui");
              if (tray) shell.AddParameter("Tray");
              shell.Invoke();
              if (shell.Streams.Error.Count > 0) throw new InvalidOperationException(shell.Streams.Error[0].ToString());
            }
          }
          single.ReleaseMutex();
        }
        return 0;
      } catch (Exception e) {
        MessageBoxW(IntPtr.Zero, "Twinbar couldn't start.\n\n" + e.Message, "Twinbar", 0x10);
        return 1;
      }
    }
  }
}
'@

# Twinbar's own icon, drawn once per version.
function Get-AppIconPath {
  $path = Join-Path (Get-IconsDir) "twinbar-$($script:TwinbarVersion).ico"
  if (-not (Test-Path -LiteralPath $path)) {
    Initialize-Interop
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    [TwinbarInterop.IconMaker]::BuildAppIcon("$path.$PID.tmp")
    Move-Item -LiteralPath "$path.$PID.tmp" -Destination $path -Force
  }
  return $path
}

function New-AppHost([string] $Path, [string] $IconPath) {
  $tmp = "$Path.$PID.tmp.exe"
  $parameters = New-Object System.CodeDom.Compiler.CompilerParameters
  $parameters.GenerateExecutable = $true
  $parameters.OutputAssembly = $tmp
  $parameters.CompilerOptions = "/target:winexe /win32icon:`"$IconPath`""
  foreach ($reference in @('System.dll', 'System.Core.dll', [psobject].Assembly.Location)) { [void]$parameters.ReferencedAssemblies.Add($reference) }
  Add-Type -TypeDefinition ($script:AppHostSource.Replace('{{VERSION}}', $script:TwinbarVersion)) -Language CSharp -CompilerParameters $parameters
  try {
    Move-Item -LiteralPath $tmp -Destination $Path -Force
  } catch {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Stop-Twinbar "couldn't replace $Path; close the Twinbar window and try again"
  }
}

# ---------------------------------------------------------------------------
# Finding Electron apps to make profiles of (for "twinbar apps" and the window)
# ---------------------------------------------------------------------------

function Get-StartMenuDirs {
  if ($env:TWINBAR_START_MENU) { return @($env:TWINBAR_START_MENU -split ';' | Where-Object { $_ }) }
  return @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('CommonPrograms'))
}

# Electron apps in the Start menu (normal and Squirrel installs) and in the
# Microsoft Store packages, one entry each, by name.
function Find-ElectronApps([switch] $NoStore) {
  $found = @{}
  foreach ($dir in Get-StartMenuDirs) {
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    foreach ($lnk in @(Get-ChildItem -LiteralPath $dir -Filter '*.lnk' -File -Recurse -ErrorAction SilentlyContinue)) {
      try { $link = Read-ShellLink $lnk.FullName } catch { continue }
      if ($link.AppUserModelId -like "$($script:AppIdPrefix).*" -or $link.TargetPath -notmatch '\.exe$') { continue }
      $target = [Environment]::ExpandEnvironmentVariables($link.TargetPath)
      $targetDir = Split-Path -Parent $target
      # A cheap look first, so most shortcuts are passed over quickly.
      if (-not ((Test-ElectronDir $targetDir) -or (Test-Path -LiteralPath (Join-Path $targetDir 'Update.exe')))) { continue }
      try { $app = Resolve-ElectronApp $lnk.FullName } catch { continue }
      $key = $app.LaunchExe.ToLowerInvariant()
      if (-not $found.ContainsKey($key)) {
        $found[$key] = [pscustomobject]@{ Name = $app.Name; Kind = $app.Kind; Source = $lnk.FullName; LaunchExe = $app.LaunchExe; Id = $app.Id }
      }
    }
  }
  if (-not $NoStore) {
    foreach ($package in @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { -not $_.IsFramework -and $_.InstallLocation -and $_.SignatureKind -ne 'System' })) {
      foreach ($entry in @(Get-StoreAppEntries $package)) {
        if (-not (Test-ElectronDir (Split-Path -Parent $entry.Exe))) { continue }
        $key = $entry.Exe.ToLowerInvariant()
        if ($found.ContainsKey($key)) { continue }
        $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($entry.Exe)
        $displayName = @($info.ProductName, $info.FileDescription, [IO.Path]::GetFileNameWithoutExtension($entry.Exe)) |
          Where-Object { $_ -and $_.Trim() } | Select-Object -First 1
        $found[$key] = [pscustomobject]@{
          Name = $displayName; Kind = 'store'; Source = "$($entry.PackageFamily)!$($entry.AppId)"
          LaunchExe = $entry.Exe; Id = Get-NameKey ([IO.Path]::GetFileNameWithoutExtension($entry.Exe))
        }
      }
    }
  }
  $found.Values | Sort-Object Name
}

function Invoke-Apps([switch] $AsJson) {
  $apps = @(Find-ElectronApps)
  if ($AsJson) { return (ConvertTo-Json -InputObject $apps -Depth 3) }
  if (-not $apps.Count) { return 'No Electron apps found in the Start menu or the Microsoft Store apps.' }
  $w = [Math]::Max(4, ($apps | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum)
  ('{0}  {1}  {2}' -f 'App'.PadRight($w), 'Kind'.PadRight(8), 'Give twinbar new -App')
  foreach ($a in $apps) { ('{0}  {1}  {2}' -f $a.Name.PadRight($w), $a.Kind.PadRight(8), $a.Source) }
}

# ---------------------------------------------------------------------------
# install and uninstall
# ---------------------------------------------------------------------------

$script:CmdWrapper = "@echo off`r`nrem Twinbar: runs twinbar.ps1 with Windows PowerShell, whatever the execution policy.`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0twinbar.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n"
$script:InstallMarker = '.twinbar-install'
$script:InstalledFiles = @('twinbar.ps1', 'twinbar.cmd', 'Twinbar.exe', 'twinbar.ico', 'LICENSE', 'README.md', 'CHANGELOG.md', '.twinbar-install')

function Get-DefaultInstallDir { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\Twinbar' }
function Get-InstallInfoPath { Join-Path (Get-TwinbarHome) 'install.json' }

# PATH is a ;-separated list; entries compare without a trailing backslash.
function Add-PathEntry([string] $PathValue, [string] $Folder) {
  $parts = @($PathValue -split ';' | Where-Object { $_ })
  if (@($parts | Where-Object { $_.TrimEnd('\') -ieq $Folder.TrimEnd('\') }).Count) { return $PathValue }
  return (@($parts) + $Folder) -join ';'
}

function Remove-PathEntry([string] $PathValue, [string] $Folder) {
  return (@($PathValue -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ine $Folder.TrimEnd('\') }) -join ';')
}

# The user's own PATH, as stored (with %VARIABLES% unexpanded).
function Get-UserPath {
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
  try { return [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } finally { $key.Close() }
}

function Set-UserPath([string] $Value) {
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
  try { $key.SetValue('Path', $Value, [Microsoft.Win32.RegistryValueKind]::ExpandString) } finally { $key.Close() }
  Initialize-Interop
  [TwinbarInterop.Shell]::NotifyEnvironmentChanged()
}

function Invoke-Install([string] $Folder, [string] $MenuDir, [switch] $OnPath) {
  $source = Split-Path -Parent $script:SelfPath
  $target = if ($Folder) { (Resolve-FullPath $Folder).TrimEnd('\') } else { Get-DefaultInstallDir }
  if (Test-ProtectedDir $target) { Stop-Twinbar "$target can't be Twinbar's folder; pick a folder of its own" }
  $marker = Join-Path $target $script:InstallMarker
  # Installing a copy into its own folder (as the Windows installer does) is fine;
  # otherwise only an empty folder, or one Twinbar installed into before.
  if ($source -ine $target -and (Test-Path -LiteralPath $target) -and -not (Test-Path -LiteralPath $marker) -and
    @(Get-ChildItem -LiteralPath $target -Force | Select-Object -First 1).Count) {
    Stop-Twinbar "$target already has other files in it; pick an empty folder"
  }
  [void][IO.Directory]::CreateDirectory($target)
  if ($source -ine $target) {
    foreach ($file in 'twinbar.ps1', 'LICENSE', 'README.md', 'CHANGELOG.md') {
      $from = Join-Path $source $file
      if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination (Join-Path $target $file) -Force }
    }
  }
  [IO.File]::WriteAllText((Join-Path $target 'twinbar.cmd'), $script:CmdWrapper, (New-Object Text.ASCIIEncoding))
  Copy-Item -LiteralPath (Get-AppIconPath) -Destination (Join-Path $target 'twinbar.ico') -Force
  New-AppHost (Join-Path $target 'Twinbar.exe') (Join-Path $target 'twinbar.ico')
  [IO.File]::WriteAllText($marker, $script:TwinbarVersion, $script:Utf8NoBom)
  [void](Initialize-Launcher)

  $menu = if ($MenuDir) { Resolve-FullPath $MenuDir } else { Get-DefaultShortcutDir }
  $shortcut = Join-Path $menu 'Twinbar.lnk'
  if ((Test-Path -LiteralPath $shortcut) -and (Read-ShellLink $shortcut).AppUserModelId -ne $script:AppId) {
    Stop-Twinbar "there's a shortcut at $shortcut that Twinbar didn't make; move it away first"
  }
  [void][IO.Directory]::CreateDirectory($menu)
  Save-ShellLink -Path $shortcut -TargetPath (Join-Path $target 'Twinbar.exe') -WorkingDirectory $target `
    -IconPath (Join-Path $target 'twinbar.ico') -Description 'Twinbar: second, separately signed-in copies of your apps' `
    -AppUserModelId $script:AppId

  $previous = if (Test-Path -LiteralPath (Get-InstallInfoPath)) { [IO.File]::ReadAllText((Get-InstallInfoPath)) | ConvertFrom-Json } else { $null }
  $addedToPath = $false
  if ($null -ne $previous -and (Get-RecordValue $previous 'dir') -ieq $target -and (Get-RecordValue $previous 'addedToPath') -eq 'True') { $addedToPath = $true }
  if ($OnPath) {
    $current = Get-UserPath
    $updated = Add-PathEntry $current $target
    if ($updated -ne $current) { Set-UserPath $updated; $addedToPath = $true }
  }
  [void][IO.Directory]::CreateDirectory((Get-TwinbarHome))
  $info = [ordered]@{ dir = $target; shortcut = $shortcut; addedToPath = $addedToPath; version = $script:TwinbarVersion; installed = (Get-Date).ToString('o') }
  [IO.File]::WriteAllText((Get-InstallInfoPath), ($info | ConvertTo-Json), $script:Utf8NoBom)
  [TwinbarInterop.Shell]::NotifyIconsChanged()

  "Installed Twinbar $($script:TwinbarVersion) in $target."
  "  Start menu:   $shortcut"
  if ($addedToPath) { '  Command line: on your PATH; in a new terminal, run: twinbar help' }
  else { "  Command line: $(Join-Path $target 'twinbar.cmd') (install again with -AddToPath to just type twinbar)" }
}

function Invoke-Uninstall([string] $Folder) {
  $info = if (Test-Path -LiteralPath (Get-InstallInfoPath)) { [IO.File]::ReadAllText((Get-InstallInfoPath)) | ConvertFrom-Json } else { $null }
  $target = if ($Folder) { (Resolve-FullPath $Folder).TrimEnd('\') } elseif ($info) { Get-RecordValue $info 'dir' } else { Get-DefaultInstallDir }
  if (-not (Test-Path -LiteralPath (Join-Path $target $script:InstallMarker))) { Stop-Twinbar "Twinbar isn't installed in $target" }
  $running = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'Twinbar.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.ExecutablePath -and $_.ExecutablePath -ieq (Join-Path $target 'Twinbar.exe') })
  if ($running.Count) { Stop-Twinbar 'the Twinbar window is open; close it first' }

  $shortcut = if ($info) { Get-RecordValue $info 'shortcut' } else { Join-Path (Get-DefaultShortcutDir) 'Twinbar.lnk' }
  if ($shortcut -and (Test-Path -LiteralPath $shortcut) -and (Read-ShellLink $shortcut).AppUserModelId -eq $script:AppId) {
    Remove-Item -LiteralPath $shortcut -Force
  }
  if ($info -and (Get-RecordValue $info 'addedToPath') -eq 'True') {
    $current = Get-UserPath
    $updated = Remove-PathEntry $current $target
    if ($updated -ne $current) { Set-UserPath $updated }
  }
  # Starting with Windows, and the jump list, go with the installed Twinbar.
  if ((Get-StartupEntry) -like ('"{0}"*' -f (Join-Path $target 'Twinbar.exe'))) { Remove-ItemProperty -Path (Get-RunKeyPath) -Name 'Twinbar' }
  try { Initialize-Interop; [TwinbarInterop.JumpList]::Delete((Get-JumpListAppId)) } catch { Write-Verbose "no jump list to remove: $($_.Exception.Message)" }
  foreach ($file in $script:InstalledFiles) {
    $path = Join-Path $target $file
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
  }
  if (-not @(Get-ChildItem -LiteralPath $target -Force | Select-Object -First 1).Count) { Remove-Item -LiteralPath $target -Force }
  if (Test-Path -LiteralPath (Get-InstallInfoPath)) { Remove-Item -LiteralPath (Get-InstallInfoPath) -Force }

  $count = @(Get-AllProfiles).Count
  "Uninstalled Twinbar from $target."
  if ($count) {
    "  Your $count profile(s) keep working from the Start menu. To remove them too, run twinbar remove"
    "  from a copy of Twinbar (the repository, say), or install it again."
  }
}

# ---------------------------------------------------------------------------
# Updates: the newest release on GitHub, its installer downloaded and checked
# against the release's SHA256SUMS, then run. Traffic goes the way Windows' proxy
# setting says (as a browser's would).
# ---------------------------------------------------------------------------

$script:Repository = 'sadrazkh/twinbar'

function Get-SettingsPath { Join-Path (Get-TwinbarHome) 'settings.json' }

$script:DefaultSettings = [ordered]@{ checkForUpdates = $true; lastUpdateCheck = ''; notifiedVersion = ''; closeToTray = $true; trayHintShown = $false }

# Twinbar's own settings (not a profile's), with defaults for what isn't set.
function Get-Settings {
  $s = [ordered]@{}
  foreach ($k in $script:DefaultSettings.Keys) { $s[$k] = $script:DefaultSettings[$k] }
  $path = Get-SettingsPath
  if (Test-Path -LiteralPath $path) {
    try {
      $saved = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
      foreach ($p in $saved.PSObject.Properties) { if ($s.Contains($p.Name)) { $s[$p.Name] = $p.Value } }
    } catch {
      Write-Warning "ignoring $($path): it isn't valid JSON"
    }
  }
  return $s
}

function Set-TwinbarSetting([string] $Name, $Value) {
  $s = Get-Settings
  $s[$Name] = $Value
  [void][IO.Directory]::CreateDirectory((Get-TwinbarHome))
  $path = Get-SettingsPath
  [IO.File]::WriteAllText("$path.tmp", ($s | ConvertTo-Json), $script:Utf8NoBom)
  Move-Item -LiteralPath "$path.tmp" -Destination $path -Force
}

function Get-UpdateSource {
  if ($env:TWINBAR_UPDATE_URL) { return $env:TWINBAR_UPDATE_URL }
  return "https://api.github.com/repos/$($script:Repository)/releases/latest"
}

function New-WebClient([string] $Url) {
  # GitHub only speaks TLS 1.2 and newer, which Windows PowerShell may not offer by default.
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $client = New-Object Net.WebClient
  $client.Headers['User-Agent'] = "Twinbar/$($script:TwinbarVersion)"
  $client.Encoding = [Text.Encoding]::UTF8
  if (([Uri]$Url).IsLoopback) { $client.Proxy = $null }
  return $client
}

# Downloads only come from Twinbar's own releases on GitHub (or, in tests, from the
# server TWINBAR_UPDATE_URL names).
function Test-UpdateUrl([string] $Url) {
  if ($env:TWINBAR_UPDATE_URL) {
    $source = [Uri]$env:TWINBAR_UPDATE_URL
    $u = [Uri]$Url
    return ($u.Scheme -eq $source.Scheme -and $u.Authority -eq $source.Authority)
  }
  return $Url.StartsWith("https://github.com/$($script:Repository)/releases/download/", [StringComparison]::Ordinal)
}

# The release described by GitHub's answer for the newest release.
function ConvertFrom-ReleaseJson([string] $Json) {
  $r = $Json | ConvertFrom-Json
  $tag = Get-RecordValue $r 'tag_name'
  $m = [regex]::Match($tag, '^v?([0-9]+\.[0-9]+\.[0-9]+)$')
  if (-not $m.Success) { Stop-Twinbar "the newest release has a version Twinbar doesn't understand: '$tag'" }
  $version = $m.Groups[1].Value
  $setupName = "Twinbar-Setup-$version.exe"
  $assets = @(if ($r.PSObject.Properties['assets'] -and $r.assets) { $r.assets })
  $setup = @($assets | Where-Object { $_.name -eq $setupName })
  $sums = @($assets | Where-Object { $_.name -eq 'SHA256SUMS' })
  return [pscustomobject]@{
    Version   = $version
    Page      = Get-RecordValue $r 'html_url'
    Notes     = (Get-RecordValue $r 'body').Replace("`r`n", "`n").Trim()
    SetupName = $setupName
    SetupUrl  = $(if ($setup.Count) { [string]$setup[0].browser_download_url } else { '' })
    SetupSize = $(if ($setup.Count) { [long]$setup[0].size } else { [long]0 })
    SumsUrl   = $(if ($sums.Count) { [string]$sums[0].browser_download_url } else { '' })
  }
}

function Get-LatestRelease {
  $url = Get-UpdateSource
  $client = New-WebClient $url
  try {
    $client.Headers['Accept'] = 'application/vnd.github+json'
    $json = $client.DownloadString($url)
  } catch {
    $e = $_.Exception
    while ($e.InnerException) { $e = $e.InnerException }
    Stop-Twinbar "couldn't ask GitHub for the newest version: $($e.Message)"
  } finally {
    $client.Dispose()
  }
  return (ConvertFrom-ReleaseJson $json)
}

function Test-NewerVersion([string] $Version) {
  return ([version]$Version -gt [version]$script:TwinbarVersion)
}

# How this copy of Twinbar was installed: setup (the Windows installer), scoop,
# install (twinbar install, from the zip) or copy (run where it is, a repository say).
function Get-InstallKind {
  $dir = Split-Path -Parent $script:SelfPath
  if (@(Get-ChildItem -LiteralPath $dir -Filter 'unins*.exe' -File -ErrorAction SilentlyContinue).Count) { return 'setup' }
  if ($dir -match '\\scoop\\apps\\') { return 'scoop' }
  if (Test-Path -LiteralPath (Join-Path $dir $script:InstallMarker)) { return 'install' }
  return 'copy'
}

function Get-UpdateDir { Join-Path (Get-TwinbarHome) 'updates' }

# The SHA-256 that a SHA256SUMS file gives for a file name.
function Get-ListedHash([string] $Sums, [string] $FileName) {
  foreach ($line in @($Sums -split "`n")) {
    $m = [regex]::Match($line.Trim(), '^([0-9A-Fa-f]{64}) [ *]?(.+)$')
    if ($m.Success -and $m.Groups[2].Value.Trim() -eq $FileName) { return $m.Groups[1].Value.ToLowerInvariant() }
  }
  Stop-Twinbar "the release's SHA256SUMS doesn't list $FileName, so it can't be checked; nothing was installed"
}

function Assert-UpdateRelease($Release) {
  if (-not $Release.SetupUrl -or -not $Release.SumsUrl) {
    Stop-Twinbar "Twinbar $($Release.Version) has no installer to download yet; try again in a few minutes, or see $($Release.Page)"
  }
  foreach ($url in $Release.SetupUrl, $Release.SumsUrl) {
    if (-not (Test-UpdateUrl $url)) { Stop-Twinbar "the release points somewhere other than Twinbar's GitHub releases ($url); nothing was downloaded" }
  }
}

# Checks a downloaded installer against its SHA-256 and gives it its final name.
function Complete-UpdateFile([string] $Partial, [string] $Expected, [string] $Target) {
  $actual = (Get-FileHash -LiteralPath $Partial -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $Expected) {
    Remove-Item -LiteralPath $Partial -Force -ErrorAction SilentlyContinue
    Stop-Twinbar "the downloaded installer isn't the one the release lists (its SHA-256 differs), so it was deleted; nothing was installed"
  }
  Move-Item -LiteralPath $Partial -Destination $Target -Force
  # Older downloads aren't needed any more.
  Get-ChildItem -LiteralPath (Split-Path -Parent $Target) -Filter 'Twinbar-Setup-*' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -ne $Target } | Remove-Item -Force -ErrorAction SilentlyContinue
  return $Target
}

# Downloads the release's installer and checks it; returns its path.
function Save-UpdateFile($Release) {
  Assert-UpdateRelease $Release
  $dir = Get-UpdateDir
  [void][IO.Directory]::CreateDirectory($dir)
  $target = Join-Path $dir $Release.SetupName
  $partial = "$target.part"
  $client = New-WebClient $Release.SumsUrl
  try {
    $expected = Get-ListedHash ($client.DownloadString($Release.SumsUrl)) $Release.SetupName
    $client.DownloadFile($Release.SetupUrl, $partial)
  } catch {
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    $e = $_.Exception
    while ($e.InnerException) { $e = $e.InnerException }
    if ($e.Message -match "SHA256SUMS") { throw }
    Stop-Twinbar "couldn't download Twinbar $($Release.Version): $($e.Message)"
  } finally {
    $client.Dispose()
  }
  return (Complete-UpdateFile $partial $expected $target)
}

# The installer's command line: quiet over a copy it installed (it keeps the folder
# and options from before), its own window otherwise.
function Get-SetupArguments([string] $Kind) {
  if ($Kind -eq 'setup') { return @('/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART') }
  return @('/NORESTART')
}

# For the window: runs the installer once this process has ended (it won't install
# while the Twinbar window is open), then, after a quiet update, opens Twinbar again.
function Start-UpdateAfterExit([string] $SetupPath) {
  $kind = Get-InstallKind
  $quote = { param($s) "'" + $s.Replace("'", "''") + "'" }
  $setupArgs = (@(Get-SetupArguments $kind) | ForEach-Object { & $quote $_ }) -join ', '
  $app = Join-Path (Split-Path -Parent $script:SelfPath) 'Twinbar.exe'
  $lines = @(
    "`$ErrorActionPreference = 'SilentlyContinue'",
    "Wait-Process -Id $PID -Timeout 120",
    "`$setup = Start-Process -FilePath $(& $quote $SetupPath) -ArgumentList @($setupArgs) -PassThru -Wait"
  )
  if ($kind -eq 'setup') { $lines += "if (Test-Path -LiteralPath $(& $quote $app)) { Start-Process -FilePath $(& $quote $app) }" }
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(($lines -join "`n")))
  Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -WindowStyle Hidden `
    -ArgumentList @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-EncodedCommand', $encoded)
}

function Test-TwinbarWindowOpen {
  $exe = Join-Path (Split-Path -Parent $script:SelfPath) 'Twinbar.exe'
  return [bool]@(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'Twinbar.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.ExecutablePath -and $_.ExecutablePath -ieq $exe }).Count
}

function Invoke-Update([switch] $CheckOnly) {
  $release = Get-LatestRelease
  Set-TwinbarSetting 'lastUpdateCheck' (Get-Date).ToString('o')
  if (-not (Test-NewerVersion $release.Version)) {
    "Twinbar $($script:TwinbarVersion) is the newest version."
    return
  }
  "Twinbar $($release.Version) is out (you have $($script:TwinbarVersion)): $($release.Page)"
  if ($CheckOnly) {
    'Run "twinbar update" to install it.'
    return
  }
  $kind = Get-InstallKind
  if ($kind -eq 'scoop') { Stop-Twinbar 'this Twinbar came from Scoop; update it with: scoop update twinbar' }
  if ($kind -eq 'setup' -and (Test-TwinbarWindowOpen)) { Stop-Twinbar 'the Twinbar window is open; close it first, or click the update in its status bar' }
  $setup = Save-UpdateFile $release
  "Downloaded $($release.SetupName); its SHA-256 matches the release's."
  if ($kind -eq 'setup') {
    $p = Start-Process -FilePath $setup -ArgumentList (Get-SetupArguments $kind) -PassThru -Wait
    if ($p.ExitCode -ne 0) { Stop-Twinbar "the installer stopped with code $($p.ExitCode); Twinbar wasn't updated" }
    "Updated Twinbar to $($release.Version)."
  } else {
    Start-Process -FilePath $setup -ArgumentList (Get-SetupArguments $kind)
    "Opened the installer: it installs Twinbar $($release.Version) for you, in $(Get-DefaultInstallDir) unless you pick another folder."
  }
}

# ---------------------------------------------------------------------------
# Starting with Windows, Twinbar's jump list, and its settings
# ---------------------------------------------------------------------------

function Get-RunKeyPath {
  if ($env:TWINBAR_RUN_KEY) { return $env:TWINBAR_RUN_KEY }
  return 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
}

function Get-AppExePath { Join-Path (Split-Path -Parent $script:SelfPath) 'Twinbar.exe' }

# What Windows runs when you sign in: Twinbar.exe, just its icon by the clock.
function Get-StartupCommand { '"{0}" --tray' -f (Get-AppExePath) }

function Get-StartupEntry {
  $entry = Get-ItemProperty -Path (Get-RunKeyPath) -Name 'Twinbar' -ErrorAction SilentlyContinue
  if ($null -eq $entry) { return '' }
  return [string]$entry.Twinbar
}

function Test-StartWithWindows { return ((Get-StartupEntry) -eq (Get-StartupCommand)) }

function Set-StartWithWindows([bool] $On) {
  $key = Get-RunKeyPath
  if ($On) {
    if (-not (Test-Path -LiteralPath (Get-AppExePath))) {
      Stop-Twinbar 'starting with Windows needs an installed Twinbar (its installer, or twinbar install)'
    }
    if (-not (Test-Path -Path $key)) { [void](New-Item -Path $key -Force) }
    Set-ItemProperty -Path $key -Name 'Twinbar' -Value (Get-StartupCommand)
  } elseif (Get-StartupEntry) {
    Remove-ItemProperty -Path $key -Name 'Twinbar'
  }
}

function Get-JumpListAppId {
  if ($env:TWINBAR_JUMPLIST_ID) { return $env:TWINBAR_JUMPLIST_ID }
  return $script:AppId
}

# Twinbar's jump list (right-click its taskbar button or its Start menu entry): one
# entry per profile, which opens it. The window keeps it up to date, and so do
# the commands that change profiles once Twinbar is installed.
function Update-JumpList {
  if (-not $script:Gui -and -not (Test-Path -LiteralPath (Get-InstallInfoPath))) { return }
  try {
    Initialize-Interop
    $rows = @(Get-AllProfiles | ForEach-Object { ConvertTo-ProfileTable $_ } | Where-Object { $_.launcher -and (Test-Path -LiteralPath $_.launcher) })
    # An empty list isn't saved; with no profiles, the list goes.
    if (-not $rows.Count) { [TwinbarInterop.JumpList]::Delete((Get-JumpListAppId)); return }
    [TwinbarInterop.JumpList]::SetTasks((Get-JumpListAppId),
      [string[]]@($rows | ForEach-Object { '{0} {1}' -f $_.appName, $_.name }),
      [string[]]@($rows | ForEach-Object { $_.launcher }),
      [string[]]@($rows | ForEach-Object { $_.id }),
      [string[]]@($rows | ForEach-Object { if ($_.icon) { $_.icon } else { $_.launchExe } }),
      [string[]]@($rows | ForEach-Object { "Open $($_.appName) $($_.name)" }))
  } catch {
    Write-Verbose "couldn't update the jump list: $($_.Exception.Message)"
  }
}

# twinbar settings [NAME on|off]
$script:SettingNames = [ordered]@{
  updates = 'Check for updates once a day while Twinbar runs'
  tray    = "Closing the window keeps Twinbar's icon by the clock"
  startup = 'Start Twinbar (just its icon by the clock) when you sign in to Windows'
}

function Get-SettingState([string] $Name) {
  $s = Get-Settings
  switch ($Name) {
    'updates' { return [bool]$s.checkForUpdates }
    'tray' { return [bool]$s.closeToTray }
    'startup' { return (Test-StartWithWindows) }
  }
}

function Invoke-Settings([string] $Name, [string] $State) {
  if ($Name) {
    $n = $Name.Trim().ToLowerInvariant()
    if (-not $script:SettingNames.Contains($n)) { Stop-Twinbar ('the settings are: {0}' -f ($script:SettingNames.Keys -join ', ')) }
    $on = switch -Regex ($State.Trim().ToLowerInvariant()) { '^(on|yes|true|1)$' { $true } '^(off|no|false|0)$' { $false } default { $null } }
    if ($null -eq $on) { Stop-Twinbar "say on or off: twinbar settings $n on" }
    switch ($n) {
      'updates' { Set-TwinbarSetting 'checkForUpdates' $on }
      'tray' { Set-TwinbarSetting 'closeToTray' $on }
      'startup' { Set-StartWithWindows $on }
    }
  }
  foreach ($k in $script:SettingNames.Keys) {
    '{0,-8} {1,-4} {2}' -f $k, $(if (Get-SettingState $k) { 'on' } else { 'off' }), $script:SettingNames[$k]
  }
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

function Stop-Twinbar([string] $Message) {
  throw $Message
}

function Get-TwinbarHome {
  if ($env:TWINBAR_HOME) { return $env:TWINBAR_HOME.TrimEnd('\') }
  return (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Twinbar')
}

function Get-ProfilesDir { Join-Path (Get-TwinbarHome) 'profiles' }

function Get-RecordPath([string] $Id) { Join-Path (Get-ProfilesDir) "$Id.json" }

function Get-DefaultShortcutDir {
  if ($env:TWINBAR_SHORTCUT_DIR) { return $env:TWINBAR_SHORTCUT_DIR.TrimEnd('\') }
  return (Join-Path ([Environment]::GetFolderPath('Programs')) 'Twinbar')
}

function Resolve-FullPath([string] $Path) {
  $p = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
  if (-not [IO.Path]::IsPathRooted($p)) {
    $p = Join-Path (Get-Location -PSProvider FileSystem).ProviderPath $p
  }
  return [IO.Path]::GetFullPath($p)
}

# Names: letters (any language), digits, spaces, '.', '_' and '-'; 1 to 40 characters.
# Inside a name, combining marks and the zero-width non-joiner (used in Persian) are fine too.
$script:NamePattern = '^[\p{L}\p{N}](?:[\p{L}\p{N}\p{Mn}' + [char]0x200C + ' ._-]*[\p{L}\p{N}\p{Mn}])?$'
function Test-ProfileName([string] $Value) {
  if ($null -eq $Value -or $Value.Trim().Length -eq 0) { Stop-Twinbar 'a profile name is required (-Name)' }
  $n = $Value.Trim()
  if ($n.Length -gt 40) { Stop-Twinbar 'the profile name must be at most 40 characters' }
  if ($n -cnotmatch $script:NamePattern) {
    Stop-Twinbar "the profile name may use letters, digits, spaces, '.', '_' and '-', and must start and end with a letter or digit"
  }
  if ($n -match '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])$') { Stop-Twinbar "'$n' is a name Windows reserves" }
  return $n
}

# A short ASCII key for ids and file names: "My Work 2" -> "my-work-2".
# Names with no ASCII letters or digits get a stable hash-based key instead.
function Get-NameKey([string] $Value) {
  $k = ($Value.ToLowerInvariant() -creplace '[^a-z0-9]+', '-').Trim('-')
  if ($k.Length -gt 32) { $k = $k.Substring(0, 32).Trim('-') }
  if ($k.Length -eq 0) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)) } finally { $sha.Dispose() }
    $k = 'p' + (($bytes[0..3] | ForEach-Object { $_.ToString('x2') }) -join '')
  }
  return $k
}

# A palette name or #RRGGBB; with none given, a palette colour picked from the
# profile id, so the same profile always gets the same colour.
function Resolve-ProfileColor([string] $Value, [string] $Id) {
  if ([string]::IsNullOrWhiteSpace($Value)) {
    $names = @($script:Palette.Keys | Where-Object { $_ -ne 'gray' })
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Id)) } finally { $sha.Dispose() }
    return $script:Palette[[string]$names[$bytes[0] % $names.Count]]
  }
  $v = $Value.Trim().ToLowerInvariant()
  if ($script:Palette.Contains($v)) { return $script:Palette[$v] }
  if ($v -match '^#?([0-9a-f]{6})$') { return '#' + $Matches[1].ToUpperInvariant() }
  Stop-Twinbar ('the colour must be one of {0}, or #RRGGBB' -f ($script:Palette.Keys -join ', '))
}

# 1 or 2 letters or digits; by default the first letter of the profile's name.
function Get-BadgeText([string] $Value, [string] $Label) {
  $t = if ([string]::IsNullOrWhiteSpace($Value)) { [Globalization.StringInfo]::GetNextTextElement($Label) } else { $Value.Trim() }
  $count = (New-Object Globalization.StringInfo $t).LengthInTextElements
  if ($count -lt 1 -or $count -gt 2 -or $t -cnotmatch '^[\p{L}\p{N}][\p{L}\p{N}\p{Mn}]*$') {
    Stop-Twinbar 'the badge must be 1 or 2 letters or digits'
  }
  return $t.ToUpperInvariant()
}

function Resolve-Style([string] $Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return 'tint+badge' }
  $v = $Value.Trim().ToLowerInvariant()
  if ($script:Styles -notcontains $v) { Stop-Twinbar ('the style must be one of: {0}' -f ($script:Styles -join ', ')) }
  return $v
}

# A proxy for a profile: socks5://, http:// or https:// with a host and a port, or
# "none" (also an empty value) for none. Returns the normalised value or "".
function Resolve-ProxyValue([string] $Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $v = $Value.Trim()
  if ($v -in 'none', 'direct', 'off') { return '' }
  $m = [regex]::Match($v, '^(?i)(socks5|http|https)://([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\]):([0-9]{1,5})/?$')
  if (-not $m.Success -or [int]$m.Groups[3].Value -lt 1 -or [int]$m.Groups[3].Value -gt 65535) {
    Stop-Twinbar "the proxy must look like socks5://127.0.0.1:10808 or http://host:8080 (or none)"
  }
  return '{0}://{1}:{2}' -f $m.Groups[1].Value.ToLowerInvariant(), $m.Groups[2].Value, $m.Groups[3].Value
}

# Chromium switches for a proxy, made strict so it works as a kill switch for the
# app's web traffic: with a fixed proxy Chromium never falls back to a direct
# connection; WebRTC can't use UDP around it; and, unless -NoDnsRule, no host name
# is looked up locally (only the proxy and localhost are; the rest goes through it).
# Measured: Claude from the Microsoft Store doesn't start with that DNS rule, so
# Store apps go without it (their connections still only go through the proxy).
function Get-ProxyArgs([string] $ProxyValue, [switch] $NoDnsRule) {
  if (-not $ProxyValue) { return '' }
  $proxyHost = ([regex]::Match($ProxyValue, '^[a-z0-9]+://(\[[^\]]+\]|[^:/]+)')).Groups[1].Value
  $parts = @("--proxy-server=$ProxyValue")
  if (-not $NoDnsRule) { $parts += ('"--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE {0} , EXCLUDE localhost"' -f $proxyHost) }
  $parts += '--force-webrtc-ip-handling-policy=disable_non_proxied_udp'
  return ($parts -join ' ')
}

# Measured with Claude signed in: its code outside Chromium (Claude Code's sessions)
# takes Chromium's proxy, but skips a SOCKS one ("not supported by downstream HTTP
# agents") and goes around it. An HTTP proxy it uses.
$script:SocksTip = "Tip: some apps' code outside Chromium (Claude's, for one) can't use a SOCKS proxy and goes around it. If your proxy also speaks HTTP (xray's and v2ray's ports usually do), use http://host:port instead."

function Get-ProxyNotes([string] $ProxyValue) {
  if ($ProxyValue -like 'socks5://*') { return $script:SocksTip }
}

function Get-ExtraArgs([string] $AppearanceValue, [string] $ProxyValue, [string] $AppKind) {
  $proxyArgs = Get-ProxyArgs $ProxyValue -NoDnsRule:($AppKind -eq 'store')
  return (@($script:Appearances[$AppearanceValue], $proxyArgs) | Where-Object { $_ }) -join ' '
}

function Resolve-Appearance([string] $Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return 'system' }
  $v = $Value.Trim().ToLowerInvariant()
  if (-not $script:Appearances.Contains($v)) { Stop-Twinbar ('the appearance must be one of: {0}' -f ($script:Appearances.Keys -join ', ')) }
  return $v
}

# Where Store apps' profiles keep their data: outside AppData, because Windows
# redirects what a Store app writes under AppData into the app's own package
# folder, where Twinbar couldn't see or remove it.
function Get-StoreDataRoot {
  if ($env:TWINBAR_STORE_DATA) { return $env:TWINBAR_STORE_DATA.TrimEnd('\') }
  return (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Twinbar')
}

function Get-PinnedDir {
  if ($env:TWINBAR_PINNED_DIR) { return $env:TWINBAR_PINNED_DIR }
  return (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar')
}

# The desktop apps in a Store package: exe, app id and execution aliases.
function Get-StoreAppEntries($Package) {
  $manifestPath = Join-Path $Package.InstallLocation 'AppxManifest.xml'
  if (-not (Test-Path -LiteralPath $manifestPath)) { return }
  try { $xml = [xml][IO.File]::ReadAllText($manifestPath) } catch { return }
  foreach ($node in @($xml.SelectNodes("//*[local-name()='Applications']/*[local-name()='Application']"))) {
    $exe = $node.GetAttribute('Executable')
    if (-not $exe -or $exe -notmatch '\.exe$') { continue }
    $aliases = @($node.SelectNodes(".//*[local-name()='ExecutionAlias']") | ForEach-Object { $_.GetAttribute('Alias') })
    [pscustomobject]@{
      Exe           = Join-Path $Package.InstallLocation $exe
      AppId         = $node.GetAttribute('Id')
      PackageFamily = $Package.PackageFamilyName
      Aliases       = $aliases
    }
  }
}

# A Microsoft Store (MSIX) app, from its exe under WindowsApps, its app id
# ("<package family>!<app>", optionally after "shell:AppsFolder\"), its
# package name ("Claude"), or its app execution alias.
function Resolve-StoreApp([string] $Value) {
  $v = $Value.Trim().Trim('"')
  if ($v -match '^shell:AppsFolder\\(.+)$') { $v = $Matches[1] }
  $packages = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { -not $_.IsFramework -and $_.InstallLocation })
  if ($v -match '^([^\\/!:]+)!([^\\/!:]+)$') {
    $family = $Matches[1]
    $appPart = $Matches[2]
    $entries = @($packages | Where-Object { $_.PackageFamilyName -ieq $family } | ForEach-Object { Get-StoreAppEntries $_ } | Where-Object { $_.AppId -ieq $appPart })
  } elseif ($v -match '\\Microsoft\\WindowsApps\\([^\\]+\.exe)$') {
    $alias = $Matches[1]
    $entries = @($packages | ForEach-Object { Get-StoreAppEntries $_ } | Where-Object { $_.Aliases -contains $alias })
  } elseif ($v -match '\\WindowsApps\\') {
    $full = [IO.Path]::GetFullPath($v)
    $owners = @($packages | Where-Object { $full.StartsWith($_.InstallLocation.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) })
    $entries = @($owners | ForEach-Object { Get-StoreAppEntries $_ } | Where-Object { $_.Exe -ieq $full -or (Test-Path -LiteralPath $full -PathType Container) })
  } else {
    $entries = @($packages | Where-Object { $_.Name -ieq $v } | ForEach-Object { Get-StoreAppEntries $_ })
  }
  if (-not $entries.Count) { Stop-Twinbar "no Microsoft Store app found for '$Value'" }
  $electron = @($entries | Where-Object { Test-ElectronDir (Split-Path -Parent $_.Exe) })
  if (-not $electron.Count) { Stop-Twinbar "'$Value' is a Microsoft Store app, but not an Electron app" }
  if ($electron.Count -gt 1) {
    Stop-Twinbar ("'{0}' matches more than one app; give one of: {1}" -f $Value, (($electron | ForEach-Object { "$($_.PackageFamily)!$($_.AppId)" }) -join ', '))
  }
  $e = $electron[0]
  $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($e.Exe)
  $displayName = @($info.ProductName, $info.FileDescription, [IO.Path]::GetFileNameWithoutExtension($e.Exe)) |
    Where-Object { $_ -and $_.Trim() } | Select-Object -First 1
  [pscustomobject]@{
    Name       = (($displayName -replace '[\\/:*?"<>|]', '').Trim())
    Id         = Get-NameKey ([IO.Path]::GetFileNameWithoutExtension($e.Exe))
    Kind       = 'store'
    LaunchExe  = $e.Exe
    RealExe    = $e.Exe
    PackageApp = "$($e.PackageFamily)!$($e.AppId)"
  }
}

# A record field that older profiles may not have.
function Get-RecordValue($Record, [string] $Field) {
  if ($Record -is [System.Collections.IDictionary]) {
    if ($Record.Contains($Field) -and $null -ne $Record[$Field]) { return [string]$Record[$Field] }
    return ''
  }
  if ($Record.PSObject.Properties[$Field] -and $null -ne $Record.$Field) { return [string]$Record.$Field }
  return ''
}

function Test-IsStoreAppPath([string] $Path) {
  return ($Path -match '\\WindowsApps\\')
}

function Test-ElectronDir([string] $Dir) {
  return ((Test-Path -LiteralPath (Join-Path $Dir 'resources\app.asar') -PathType Leaf) -or
    (Test-Path -LiteralPath (Join-Path $Dir 'resources\app\package.json') -PathType Leaf))
}

# The newest "app-<version>" folder of a Squirrel install that holds ExeName.
function Get-SquirrelLatestDir([string] $Root, [string] $ExeName) {
  $best = $null
  $bestVersion = $null
  foreach ($d in @(Get-ChildItem -LiteralPath $Root -Directory -Filter 'app-*' -ErrorAction SilentlyContinue)) {
    $v = $null
    $text = ($d.Name.Substring(4) -split '-')[0]
    if (-not [version]::TryParse($text, [ref] $v)) { continue }
    if (-not (Test-Path -LiteralPath (Join-Path $d.FullName $ExeName) -PathType Leaf)) { continue }
    if ($null -eq $bestVersion -or $v -gt $bestVersion) {
      $best = $d.FullName
      $bestVersion = $v
    }
  }
  return $best
}

function Find-AppExeInFolder([string] $Folder) {
  $skip = '^(update|squirrel|elevate|uninstall.*|unins\d+|.*helper.*|crashpad_handler)\.exe$'
  $exes = @(Get-ChildItem -LiteralPath $Folder -Filter '*.exe' -File | Where-Object { $_.Name -notmatch $skip })
  if (Test-Path -LiteralPath (Join-Path $Folder 'Update.exe') -PathType Leaf) {
    $exes = @($exes | Where-Object { Get-SquirrelLatestDir $Folder $_.Name })
  } elseif (-not (Test-ElectronDir $Folder)) {
    Stop-Twinbar "no Electron app found in $Folder"
  }
  if ($exes.Count -eq 1) { return $exes[0].FullName }
  if ($exes.Count -eq 0) { Stop-Twinbar "no program found in $Folder" }
  $leaf = (Split-Path -Leaf $Folder) -replace '[^a-z0-9]', ''
  $byName = @($exes | Where-Object { ($_.BaseName -replace '[^a-z0-9]', '') -ieq $leaf })
  if ($byName.Count -eq 1) { return $byName[0].FullName }
  Stop-Twinbar ("found several programs in {0}; pass the .exe instead: {1}" -f $Folder, (($exes | ForEach-Object { $_.Name }) -join ', '))
}

# Works out how to start an Electron app from its .exe, install folder or shortcut,
# or, for a Microsoft Store app, its package name or app id.
#   Kind      standard (one folder), squirrel (Update.exe + app-<version> folders)
#             or store (a Microsoft Store package; see Resolve-StoreApp)
#   LaunchExe what is started; for Squirrel the root launcher, which always starts
#             the newest version and passes the arguments on
#   RealExe   the Electron executable that ends up running
function Resolve-ElectronApp([string] $Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    Stop-Twinbar 'which app? Give -App: its .exe, its install folder or its Start menu shortcut'
  }
  $raw = $Path.Trim().Trim('"')
  if ($raw -match '^shell:AppsFolder\\' -or $raw -match '^[^\\/!:]+![^\\/!:]+$') { return (Resolve-StoreApp $raw) }
  $p = Resolve-FullPath $Path
  if (-not (Test-Path -LiteralPath $p)) {
    if ($raw -notmatch '[\\/]') {
      try { return (Resolve-StoreApp $raw) } catch { Stop-Twinbar "not found: there's no file, folder or Microsoft Store app called '$raw'" }
    }
    Stop-Twinbar "not found: $p"
  }

  $displayName = ''
  if ($p -match '\.lnk$') {
    $link = Read-ShellLink $p
    if ($link.AppUserModelId -like "$script:AppIdPrefix.*") {
      Stop-Twinbar 'that is a Twinbar profile; give the original app instead'
    }
    $displayName = [IO.Path]::GetFileNameWithoutExtension($p)
    $t = [Environment]::ExpandEnvironmentVariables($link.TargetPath)
    if (-not $t) { Stop-Twinbar "the shortcut doesn't point to a program: $p" }
    if ([IO.Path]::GetFileName($t) -ieq 'Update.exe' -and
      $link.Arguments -match '--processStart(?:=|\s+)(?:"([^"]+)"|(\S+))') {
      $exe = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
      $t = Join-Path (Split-Path -Parent $t) $exe
    }
    $p = $t
    if (-not (Test-Path -LiteralPath $p)) { Stop-Twinbar "the shortcut points to something that's missing: $p" }
  }
  if ([IO.Path]::GetFileName($p) -ieq $script:LauncherName) {
    Stop-Twinbar 'that is a Twinbar profile; give the original app instead'
  }
  if (Test-IsStoreAppPath $p) { return (Resolve-StoreApp $p) }
  if (Test-Path -LiteralPath $p -PathType Container) { $p = Find-AppExeInFolder $p }
  if ($p -notmatch '\.exe$') { Stop-Twinbar "not a program (.exe): $p" }

  $exeName = [IO.Path]::GetFileName($p)
  $dir = Split-Path -Parent $p
  $parent = Split-Path -Parent $dir
  # An exe inside a Squirrel app-<version> folder: use the root launcher instead.
  if ((Split-Path -Leaf $dir) -like 'app-*' -and $parent -and
    (Test-Path -LiteralPath (Join-Path $parent 'Update.exe') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $parent $exeName) -PathType Leaf)) {
    $dir = $parent
    $p = Join-Path $parent $exeName
  }
  $kind = ''
  $real = ''
  if (Test-Path -LiteralPath (Join-Path $dir 'Update.exe') -PathType Leaf) {
    $latest = Get-SquirrelLatestDir $dir $exeName
    if ($latest -and (Test-ElectronDir $latest)) {
      $kind = 'squirrel'
      $real = Join-Path $latest $exeName
    }
  }
  if (-not $kind -and (Test-ElectronDir $dir)) {
    $kind = 'standard'
    $real = $p
  }
  if (-not $kind) { Stop-Twinbar "$exeName doesn't look like an Electron app (there's no resources\app.asar next to it)" }

  if (-not $displayName) {
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($real)
    foreach ($candidate in @($info.ProductName, $info.FileDescription)) {
      if ($candidate -and $candidate.Trim()) {
        $displayName = $candidate.Trim()
        break
      }
    }
  }
  $displayName = ($displayName -replace '[\\/:*?"<>|]', '').Trim()
  if (-not $displayName) { $displayName = [IO.Path]::GetFileNameWithoutExtension($exeName) }

  [pscustomobject]@{
    Name      = $displayName
    Id        = Get-NameKey ([IO.Path]::GetFileNameWithoutExtension($exeName))
    Kind      = $kind
    LaunchExe = $p
    RealExe   = $real
    PackageApp = ''
  }
}

# missing | file | empty | ours | other:<profile id> | foreign (has files, no marker)
function Get-DataDirState([string] $Dir, [string] $Id) {
  if (-not (Test-Path -LiteralPath $Dir)) { return 'missing' }
  if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return 'file' }
  $marker = Join-Path $Dir $script:MarkerName
  if (Test-Path -LiteralPath $marker -PathType Leaf) {
    $owner = ([IO.File]::ReadAllText($marker)).Trim()
    if ($owner -ieq $Id) { return 'ours' }
    return "other:$owner"
  }
  if (@(Get-ChildItem -LiteralPath $Dir -Force | Select-Object -First 1).Count -eq 0) { return 'empty' }
  return 'foreign'
}

# Folders a profile must never use as its data folder (removing it would be a disaster).
function Test-ProtectedDir([string] $Dir) {
  $d = $Dir.TrimEnd('\')
  if ($d.Length -le 2) { return $true } # a drive root
  $twHome = Get-TwinbarHome
  $userProfile = [Environment]::GetFolderPath('UserProfile')
  $protected = @(
    $userProfile, (Split-Path -Parent $userProfile),
    [Environment]::GetFolderPath('ApplicationData'), [Environment]::GetFolderPath('LocalApplicationData'),
    [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'),
    [Environment]::GetFolderPath('ProgramFiles'), [Environment]::GetFolderPath('ProgramFilesX86'),
    [Environment]::GetFolderPath('Windows'), $env:TEMP,
    $twHome, (Join-Path $twHome 'data'), (Join-Path $twHome 'profiles'), (Get-IconsDir), (Get-StoreDataRoot)
  )
  foreach ($x in $protected) {
    if ($x -and $d -ieq $x.TrimEnd('\')) { return $true }
  }
  return $false
}

function Get-AllProfiles {
  $dir = Get-ProfilesDir
  if (-not (Test-Path -LiteralPath $dir)) { return }
  $required = 'id', 'name', 'appName', 'launchExe', 'realExe', 'dataDir', 'shortcut', 'aumid'
  foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File | Sort-Object Name)) {
    try {
      $record = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
      Write-Warning "skipping $($f.Name): it isn't valid JSON"
      continue
    }
    $names = @($record.PSObject.Properties | ForEach-Object { $_.Name })
    $missing = @($required | Where-Object { $names -notcontains $_ })
    if ($missing.Count) {
      Write-Warning "skipping $($f.Name): it has no $($missing -join ', ')"
      continue
    }
    $record
  }
}

function Write-Record($Record) {
  [void][IO.Directory]::CreateDirectory((Get-ProfilesDir))
  $path = Get-RecordPath $Record.id
  $tmp = "$path.tmp"
  [IO.File]::WriteAllText($tmp, ($Record | ConvertTo-Json -Depth 4), $script:Utf8NoBom)
  Move-Item -LiteralPath $tmp -Destination $path -Force
}

# A profile record (from its JSON file) as an ordered table with every field, filling
# in what records from older versions don't have.
function ConvertTo-ProfileTable($Record) {
  $t = [ordered]@{}
  foreach ($field in $script:RecordFields) { $t[$field] = Get-RecordValue $Record $field }
  if (-not $t.appKind) { $t.appKind = 'standard' }
  if (-not $t.style) { $t.style = 'tint+badge' }
  if (-not $t.color) { $t.color = Resolve-ProfileColor '' $t.id }
  if (-not $t.badge) { $t.badge = Get-BadgeText '' $t.name }
  if (-not $t.appearance) { $t.appearance = 'system' }
  if (-not $t.created) { $t.created = (Get-Date).ToString('o') }
  return $t
}

# Points taskbar pins of a profile (Windows makes them from the window's relaunch
# details) at its current launcher and icon. Returns how many it changed.
function Update-PinnedShortcuts($Record, [string] $IconLocation) {
  $dir = Get-PinnedDir
  if (-not (Test-Path -LiteralPath $dir)) { return 0 }
  $count = 0
  foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.lnk' -File -ErrorAction SilentlyContinue)) {
    try { $link = Read-ShellLink $f.FullName } catch { continue }
    if ($link.AppUserModelId -ne $Record.aumid) { continue }
    [TwinbarInterop.Shell]::UpdateLink($f.FullName, $Record.launcher, $Record.id, $IconLocation, 0)
    $count++
  }
  return $count
}

# Writes everything a profile is made of from its record: the launcher, the icon,
# the Start menu shortcut, any taskbar pins, and the record itself. Used by new,
# change and rebuild. Returns the number of taskbar pins it updated.
function Publish-Profile([System.Collections.IDictionary] $Record) {
  if (Test-Path -LiteralPath $Record.shortcut -PathType Leaf) {
    $existing = Read-ShellLink $Record.shortcut
    if ($existing.AppUserModelId -ne $Record.aumid) {
      Stop-Twinbar "there's a shortcut at $($Record.shortcut) that Twinbar didn't make; move it away first"
    }
  }
  $Record.launcher = Initialize-Launcher
  $Record.extraArgs = Get-ExtraArgs $Record.appearance $Record.proxy $Record.appKind
  $oldIcon = $Record.icon
  # Store apps move with every update, so even their original icon gets a copy.
  if ($Record.style -ne 'original' -or $Record.appKind -eq 'store') {
    $Record.icon = Get-IconPath $Record
    if (-not (Test-Path -LiteralPath $Record.icon)) {
      New-ProfileIcon $Record.launchExe $Record.icon $Record.style $Record.color $Record.badge
    }
  } else {
    $Record.icon = ''
  }
  $iconLocation = if ($Record.icon) { $Record.icon } else { $Record.launchExe }
  $workingDir = if ($Record.appKind -eq 'store') { Split-Path -Parent $Record.launcher } else { Split-Path -Parent $Record.launchExe }

  [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Record.shortcut))
  Save-ShellLink -Path $Record.shortcut -TargetPath $Record.launcher -Arguments $Record.id `
    -WorkingDirectory $workingDir -IconPath $iconLocation -IconIndex 0 `
    -Description "$($Record.appName) $($Record.name) (a Twinbar profile of $($Record.appName))" `
    -AppUserModelId $Record.aumid
  $pins = Update-PinnedShortcuts $Record $iconLocation
  $Record.schema = 3
  $Record.updated = (Get-Date).ToString('o')
  $Record.twinbarVersion = $script:TwinbarVersion
  Write-Record $Record

  if ($oldIcon -and $oldIcon -ne $Record.icon -and
    $oldIcon.StartsWith((Get-IconsDir) + '\', [StringComparison]::OrdinalIgnoreCase) -and
    (Test-Path -LiteralPath $oldIcon)) {
    Remove-Item -LiteralPath $oldIcon -Force -ErrorAction SilentlyContinue
  }
  [TwinbarInterop.Shell]::NotifyIconsChanged()
  Update-JumpList
  return $pins
}

function Get-LookNote($Record) {
  $look = switch ($Record.style) {
    'tint+badge' { "colour $($Record.color), badge $($Record.badge)" }
    'tint' { "colour $($Record.color)" }
    'badge' { "badge $($Record.badge) on $($Record.color)" }
    default { "the app's own icon" }
  }
  if ($Record.appearance -and $Record.appearance -ne 'system') { $look += "; always $($Record.appearance)" }
  if ($Record.proxy) { $look += "; via $($Record.proxy)" }
  return $look
}

function Find-Profile([string] $Which) {
  if ([string]::IsNullOrWhiteSpace($Which)) {
    Stop-Twinbar 'which profile? Give its name, its full name or its id (see: twinbar list)'
  }
  $t = $Which.Trim()
  $all = @(Get-AllProfiles)
  $found = @($all | Where-Object { $_.id -ieq $t })
  if (-not $found.Count) { $found = @($all | Where-Object { ('{0} {1}' -f $_.appName, $_.name) -ieq $t -or $_.shortcut -ieq $t }) }
  if (-not $found.Count) { $found = @($all | Where-Object { $_.name -ieq $t }) }
  if ($found.Count -eq 0) { Stop-Twinbar "there's no profile called '$t' (see: twinbar list)" }
  if ($found.Count -gt 1) {
    Stop-Twinbar ("'{0}' matches more than one profile; use the id: {1}" -f $t, (($found | ForEach-Object { $_.id }) -join ', '))
  }
  return $found[0]
}

# Processes started with --user-data-dir, fetched once per run.
$script:DataDirProcesses = $null
function Get-DataDirProcesses {
  if ($null -eq $script:DataDirProcesses) {
    $script:DataDirProcesses = @(Get-CimInstance -ClassName Win32_Process -Filter "CommandLine LIKE '%--user-data-dir%'" -ErrorAction SilentlyContinue)
  }
  return $script:DataDirProcesses
}

function Get-ProfileProcesses($Record) {
  $pattern = '--user-data-dir="?' + [regex]::Escape($Record.dataDir.TrimEnd('\')) + '"?(?=\s|$)'
  @(Get-DataDirProcesses) | Where-Object { $_.CommandLine -and $_.CommandLine -match $pattern }
}

function Get-ProfileStatus($Record) {
  if (@(Get-ProfileProcesses $Record).Count) { return 'running' }
  if (-not (Test-Path -LiteralPath $Record.shortcut -PathType Leaf)) { return 'shortcut missing' }
  if (-not (Test-Path -LiteralPath $Record.launchExe -PathType Leaf)) { return 'app missing' }
  return 'ready'
}

# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------

function Invoke-New {
  param(
    [string] $AppPath, [string] $ProfileName, [string] $DataFolder, [switch] $Adopt, [string] $MenuDir,
    [string] $ColorName, [string] $BadgeText, [string] $StyleName, [string] $AppearanceName, [string] $ProxyValue
  )

  $label = Test-ProfileName $ProfileName
  $look = Resolve-Style $StyleName
  $badgeValue = Get-BadgeText $BadgeText $label
  $appearanceValue = Resolve-Appearance $AppearanceName
  $proxyChoice = Resolve-ProxyValue $ProxyValue
  $app = Resolve-ElectronApp $AppPath
  $key = Get-NameKey $label
  $id = "$($app.Id).$key"
  $aumid = "$script:AppIdPrefix.$id"
  $fullName = "$($app.Name) $label"
  $colorHex = Resolve-ProfileColor $ColorName $id

  if (Test-Path -LiteralPath (Get-RecordPath $id)) {
    Stop-Twinbar "there's already a profile '$id' (see: twinbar list)"
  }
  $menu = if ($MenuDir) { Resolve-FullPath $MenuDir } else { Get-DefaultShortcutDir }
  $shortcut = Join-Path $menu "$fullName.lnk"
  if (Test-Path -LiteralPath $shortcut) {
    Stop-Twinbar "there's already a shortcut called '$fullName.lnk' in $menu; remove or rename it first"
  }

  $dataRoot = if ($app.Kind -eq 'store') { Join-Path (Get-StoreDataRoot) $app.Id } else { Join-Path (Join-Path (Get-TwinbarHome) 'data') $app.Id }
  $dd = if ($DataFolder) { Resolve-FullPath $DataFolder } else { Join-Path $dataRoot $key }
  $dd = $dd.TrimEnd('\')
  if ($app.Kind -eq 'store' -and $dd.StartsWith([Environment]::GetFolderPath('UserProfile') + '\AppData\', [StringComparison]::OrdinalIgnoreCase)) {
    Stop-Twinbar "a Store app's data can't go under AppData: Windows would redirect it into the app's package, out of Twinbar's reach. Pick a folder elsewhere"
  }
  if ($dd.Contains('"')) { Stop-Twinbar 'the data folder path may not contain quotes' }
  if (Test-ProtectedDir $dd) { Stop-Twinbar "$dd can't be a profile's data folder; pick a folder of its own" }
  foreach ($exe in @($app.LaunchExe, $app.RealExe)) {
    if ($exe.StartsWith($dd + '\', [StringComparison]::OrdinalIgnoreCase)) {
      Stop-Twinbar "the data folder can't contain the app itself: $dd"
    }
  }
  foreach ($other in @(Get-AllProfiles)) {
    if ($other.dataDir.TrimEnd('\') -ieq $dd) { Stop-Twinbar "the profile '$($other.id)' already uses $dd" }
  }

  $state = Get-DataDirState $dd $id
  $dataNote = 'new'
  if ($state -eq 'file') { Stop-Twinbar "the data folder is a file: $dd" }
  if ($state -like 'other:*') {
    $owner = $state.Substring(6)
    if (Test-Path -LiteralPath (Get-RecordPath $owner)) { Stop-Twinbar "that data folder belongs to the profile '$owner'" }
    if (-not $Adopt) { Stop-Twinbar "that data folder belonged to the removed profile '$owner'; add -AdoptDataDir to use it for this one" }
    $dataNote = 'adopted'
  }
  if ($state -eq 'foreign') {
    if (-not $Adopt) {
      Stop-Twinbar "the data folder already has files in it: $dd. Add -AdoptDataDir to use it for this profile (the app will see what's there)"
    }
    $dataNote = 'adopted'
  }
  if ($state -eq 'ours') { $dataNote = 'kept from before' }

  $record = [ordered]@{}
  foreach ($field in $script:RecordFields) { $record[$field] = '' }
  $record.id = $id
  $record.name = $label
  $record.appName = $app.Name
  $record.appId = $app.Id
  $record.appKind = $app.Kind
  $record.launchExe = $app.LaunchExe
  $record.realExe = $app.RealExe
  $record.packageApp = $app.PackageApp
  $record.dataDir = $dd
  $record.shortcut = $shortcut
  $record.aumid = $aumid
  $record.style = $look
  $record.color = $colorHex
  $record.badge = $badgeValue
  $record.appearance = $appearanceValue
  $record.proxy = $proxyChoice
  $record.created = (Get-Date).ToString('o')

  $createdDir = -not (Test-Path -LiteralPath $dd)
  $markerPath = Join-Path $dd $script:MarkerName
  $oldMarker = if (Test-Path -LiteralPath $markerPath -PathType Leaf) { [IO.File]::ReadAllText($markerPath) } else { $null }
  [void][IO.Directory]::CreateDirectory($dd)
  [IO.File]::WriteAllText($markerPath, $id, $script:Utf8NoBom)
  try {
    [void](Publish-Profile $record)
  } catch {
    if (Test-Path -LiteralPath $shortcut) { Remove-Item -LiteralPath $shortcut -Force }
    if ($record.icon -and (Test-Path -LiteralPath $record.icon)) { Remove-Item -LiteralPath $record.icon -Force }
    if (Test-Path -LiteralPath (Get-RecordPath $id)) { Remove-Item -LiteralPath (Get-RecordPath $id) -Force }
    if ($createdDir) {
      Remove-Item -LiteralPath $dd -Recurse -Force
    } elseif ($null -ne $oldMarker) {
      [IO.File]::WriteAllText($markerPath, $oldMarker, $script:Utf8NoBom)
    } else {
      Remove-Item -LiteralPath $markerPath -Force
    }
    throw
  }

  "Made ""$fullName""."
  "  Start menu:   $shortcut"
  "  Icon:         $(Get-LookNote $record)"
  "  Sign-in data: $dd ($dataNote)"
  "Open it from the Start menu, or run: twinbar open ""$fullName"""
  Get-ProxyNotes $record.proxy
}

# After a data folder went: its now-empty <app> folder, and the Store data root
# if that's empty too. Only ever inside Twinbar's own data folders.
function Remove-EmptyDataParents([string] $DataDir) {
  $roots = @((Join-Path (Get-TwinbarHome) 'data'), (Get-StoreDataRoot))
  $parent = Split-Path -Parent $DataDir
  foreach ($root in $roots) {
    if ($parent -and (Split-Path -Parent $parent) -ieq $root -and (Test-Path -LiteralPath $parent) -and
      -not @(Get-ChildItem -LiteralPath $parent -Force | Select-Object -First 1).Count) {
      Remove-Item -LiteralPath $parent -Force
    }
  }
  $storeRoot = Get-StoreDataRoot
  if ((Test-Path -LiteralPath $storeRoot) -and -not @(Get-ChildItem -LiteralPath $storeRoot -Force | Select-Object -First 1).Count) {
    Remove-Item -LiteralPath $storeRoot -Force
  }
}

function Assert-NotRunning($Record) {
  if (@(Get-ProfileProcesses $Record).Count) {
    Stop-Twinbar "$($Record.appName) $($Record.name) is running; quit it first"
  }
}

function Invoke-Change {
  param([string] $Which, [string] $ColorName, [string] $BadgeText, [string] $StyleName, [string] $AppearanceName, [string] $ProxyValue)
  if (-not ($ColorName -or $BadgeText -or $StyleName -or $AppearanceName -or $ProxyValue)) {
    Stop-Twinbar 'nothing to change; give -Color, -Badge, -Style, -Appearance or -Proxy'
  }
  $p = Find-Profile $Which
  Assert-NotRunning $p
  $record = ConvertTo-ProfileTable $p
  if ($StyleName) { $record.style = Resolve-Style $StyleName }
  if ($ColorName) { $record.color = Resolve-ProfileColor $ColorName $record.id }
  if ($BadgeText) { $record.badge = Get-BadgeText $BadgeText $record.name }
  if ($AppearanceName) { $record.appearance = Resolve-Appearance $AppearanceName }
  if ($ProxyValue) { $record.proxy = Resolve-ProxyValue $ProxyValue }
  $pins = Publish-Profile $record
  "Changed ""$($record.appName) $($record.name)"": $(Get-LookNote $record)."
  if ($ProxyValue) { Get-ProxyNotes $record.proxy }
  if ($pins) { "  Updated $pins taskbar pin(s)." }
}

# Makes a profile's files again from its record: after the app moved, was
# reinstalled or updated, after a Twinbar update, or when something was deleted.
function Invoke-Rebuild([string] $Which, [string] $AppPath, [switch] $Every) {
  if ($Every -and $AppPath) { Stop-Twinbar '-App works for one profile at a time' }
  if (-not $Every -and [string]::IsNullOrWhiteSpace($Which)) { Stop-Twinbar 'which profile? Give its name or id, or -All' }
  $targets = @(if ($Every) { Get-AllProfiles } else { Find-Profile $Which })
  if (-not $targets.Count) { return 'No profiles to rebuild.' }
  $failed = @()
  foreach ($p in $targets) {
    $fullName = '{0} {1}' -f $p.appName, $p.name
    try {
      Assert-NotRunning $p
      $record = ConvertTo-ProfileTable $p
      $source = if ($AppPath) { $AppPath } elseif ($record.appKind -eq 'store' -and $record.packageApp) { $record.packageApp } else { $record.launchExe }
      try {
        $app = Resolve-ElectronApp $source
      } catch {
        Stop-Twinbar "$($_.Exception.Message). If the app moved, run: twinbar rebuild $($record.id) -App <its new place>"
      }
      if ($record.appId -and $app.Id -ne $record.appId) {
        Stop-Twinbar "that's another app ($($app.Name)); a profile can only move to another copy of $($record.appName)"
      }
      $record.appId = $app.Id
      $record.appKind = $app.Kind
      $record.launchExe = $app.LaunchExe
      $record.realExe = $app.RealExe
      $record.packageApp = $app.PackageApp
      $pins = Publish-Profile $record
      "Rebuilt ""$fullName"" ($($app.Kind): $($app.RealExe))$(if ($pins) { "; updated $pins taskbar pin(s)" })."
    } catch {
      if (-not $Every) { throw }
      $failed += $fullName
      Write-Warning "$($fullName): $($_.Exception.Message)"
    }
  }
  if ($failed.Count) { Stop-Twinbar "couldn't rebuild: $($failed -join ', ')" }
}

function Test-TcpPort([string] $TargetHost, [int] $Port, [int] $TimeoutMs) {
  $client = New-Object Net.Sockets.TcpClient
  try {
    $pending = $client.BeginConnect($TargetHost, $Port, $null, $null)
    if (-not $pending.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
    $client.EndConnect($pending)
    return $true
  } catch {
    return $false
  } finally {
    $client.Close()
  }
}

# Services that answer with the caller's IP address (and where it is), tried in order.
$script:IpServices = @('https://ipinfo.io/json', 'https://api.ipify.org?format=json')

# The IP address the world sees for traffic through ProxyValue ("" for directly).
function Get-IpInfo([string] $ProxyValue) {
  Initialize-Interop
  $urls = if ($env:TWINBAR_IP_URL) { @($env:TWINBAR_IP_URL) } else { $script:IpServices }
  $problem = ''
  foreach ($url in $urls) {
    try {
      $answer = [TwinbarInterop.Net]::Fetch($url, $ProxyValue, 15000) | ConvertFrom-Json
      $where = @((Get-RecordValue $answer 'city'), (Get-RecordValue $answer 'region'), (Get-RecordValue $answer 'country')) | Where-Object { $_ }
      return [pscustomobject]@{
        Ok = $true; Ip = (Get-RecordValue $answer 'ip'); Where = (@($where) -join ', '); Network = (Get-RecordValue $answer 'org'); Error = ''
      }
    } catch {
      $e = $_.Exception
      while ($e.InnerException) { $e = $e.InnerException }
      $problem = $e.Message
    }
  }
  return [pscustomobject]@{ Ok = $false; Ip = ''; Where = ''; Network = ''; Error = $problem }
}

# Which IP address a profile's traffic comes from, next to the one without a proxy.
function Invoke-Ip([string] $Which, [switch] $AsJson) {
  $checks = @()
  $hasProxy = $false
  if ($Which) {
    $p = ConvertTo-ProfileTable (Find-Profile $Which)
    $hasProxy = [bool]$p.proxy
    $route = if ($hasProxy) { "through $($p.proxy)" } else { 'directly (it has no proxy)' }
    $checks += [pscustomobject]@{ Name = "$($p.appName) $($p.name)"; Route = $route; Proxy = $p.proxy; Info = (Get-IpInfo $p.proxy) }
  }
  if (-not $Which -or $hasProxy) {
    $checks += [pscustomobject]@{ Name = 'Without a proxy'; Route = 'directly, like the original app'; Proxy = ''; Info = (Get-IpInfo '') }
  }
  if ($AsJson) {
    $rows = @($checks | ForEach-Object {
        [pscustomobject]@{ name = $_.Name; route = $_.Route; proxy = $_.Proxy; ok = $_.Info.Ok; ip = $_.Info.Ip; where = $_.Info.Where; network = $_.Info.Network; error = $_.Info.Error }
      })
    return (ConvertTo-Json -InputObject $rows -Depth 3)
  }
  foreach ($c in $checks) {
    "$($c.Name), $($c.Route):"
    if ($c.Info.Ok) {
      $line = "  IP $($c.Info.Ip)"
      if ($c.Info.Where) { $line += "   $($c.Info.Where)" }
      if ($c.Info.Network) { $line += "   ($($c.Info.Network))" }
      $line
    } else {
      "  can't get out: $($c.Info.Error)"
      if ($c.Proxy) { '  So the profile is offline too until the proxy works: the kill switch keeps it from going around it.' }
    }
  }
  if ($checks.Count -eq 2 -and $checks[0].Info.Ok -and $checks[1].Info.Ok -and $checks[0].Info.Ip -eq $checks[1].Info.Ip) {
    'Note: both are the same IP address, so the proxy goes out through this same connection.'
  }
}

# Ports that proxy apps on this computer listen on by default: v2rayN (10808, 10809),
# Clash (7890, 7891) and Clash Verge (7897), NekoRay and sing-box (2080, 2081),
# Hiddify (12334), Shadowsocks and others (1080), Tor (9050, 9150); and 20808, 20809.
$script:CommonProxyPorts = @(10809, 10808, 20809, 20808, 7890, 7891, 7897, 2080, 2081, 12334, 1080, 9050, 9150)

# Windows' own proxy setting (Settings > Network > Proxy, which VPN apps often set),
# as places with the kind of proxy each is: http, socks5, or any (both are tried).
function Get-SystemProxyEntries {
  $server = $env:TWINBAR_SYSTEM_PROXY
  if ($null -eq $server) {
    try {
      $settings = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
    } catch {
      return
    }
    if ((Get-RecordValue $settings 'ProxyEnable') -ne '1') { return }
    $server = Get-RecordValue $settings 'ProxyServer'
  }
  foreach ($part in @($server -split ';' | Where-Object { $_.Trim() })) {
    $kind = 'any'
    $place = $part.Trim()
    $m = [regex]::Match($place, '^([a-z]+)=(.+)$')
    if ($m.Success) {
      $kind = switch ($m.Groups[1].Value) { 'socks' { 'socks5' } 'http' { 'http' } 'https' { 'http' } default { '' } }
      $place = $m.Groups[2].Value
    }
    $place = $place -replace '^[a-z0-9]+://', ''
    $hp = [regex]::Match($place, '^(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9.-]+):([0-9]{1,5})/?$')
    if ($kind -and $hp.Success) { [pscustomobject]@{ Host = $hp.Groups[1].Value; Port = [int]$hp.Groups[2].Value; Kind = $kind } }
  }
}

# Proxies running on this computer (on the usual ports) and the one Windows is set
# to use. Each is asked to connect to the IP check service, so "works" means it
# gets out. HTTP first: some apps can't use a SOCKS proxy outside Chromium.
function Find-LocalProxies {
  Initialize-Interop
  $places = New-Object System.Collections.Generic.List[object]
  $seen = @{}
  foreach ($e in @(Get-SystemProxyEntries)) {
    foreach ($kind in @(if ($e.Kind -eq 'any') { 'http', 'socks5' } else { $e.Kind })) {
      $key = "$kind|$($e.Host)|$($e.Port)"
      if (-not $seen.Contains($key)) { $seen[$key] = $true; $places.Add([pscustomobject]@{ Host = $e.Host; Port = $e.Port; Kind = $kind; System = $true }) }
    }
  }
  $ports = if ($env:TWINBAR_PROXY_PORTS) { @($env:TWINBAR_PROXY_PORTS -split ',' | Where-Object { $_ } | ForEach-Object { [int]$_ }) } else { $script:CommonProxyPorts }
  foreach ($port in $ports) {
    foreach ($kind in 'http', 'socks5') {
      $key = "$kind|127.0.0.1|$port"
      if (-not $seen.Contains($key)) { $seen[$key] = $true; $places.Add([pscustomobject]@{ Host = '127.0.0.1'; Port = $port; Kind = $kind; System = $false }) }
    }
  }
  $target = [Uri]$(if ($env:TWINBAR_IP_URL) { $env:TWINBAR_IP_URL } else { $script:IpServices[0] })
  $answers = [TwinbarInterop.Net]::ProbeAll(
    [string[]]@($places | ForEach-Object { $_.Host.Trim('[', ']') }), [int[]]@($places | ForEach-Object { $_.Port }),
    [string[]]@($places | ForEach-Object { $_.Kind }), $target.Host, $target.Port, 3000)
  $found = for ($i = 0; $i -lt $places.Count; $i++) {
    if (-not $answers[$i]) { continue }
    $p = $places[$i]
    $state = switch ($answers[$i]) { 'ok' { 'works' } 'fail' { "is there, but can't get out right now" } default { 'wants a password (not supported)' } }
    [pscustomobject]@{
      Url = '{0}://{1}:{2}' -f $p.Kind, $p.Host, $p.Port; Kind = $(if ($p.Kind -eq 'http') { 'HTTP' } else { 'SOCKS5' })
      Works = ($answers[$i] -eq 'ok'); State = $state; System = $p.System; Order = $i
    }
  }
  @($found | Sort-Object @{ Expression = { -not $_.Works } }, @{ Expression = { $_.Kind -ne 'HTTP' } }, @{ Expression = { -not $_.System } }, Order)
}

function Invoke-Proxies([switch] $AsJson) {
  $found = @(Find-LocalProxies)
  if ($AsJson) {
    $rows = @($found | ForEach-Object { [pscustomobject]@{ url = $_.Url; kind = $_.Kind; works = $_.Works; state = $_.State; windowsSetting = $_.System } })
    return (ConvertTo-Json -InputObject $rows -Depth 3)
  }
  if (-not $found.Count) {
    "No proxy found on this computer's usual ports, and Windows isn't set to use one."
    'Start your proxy or VPN app (v2rayN, Clash, NekoRay, ...), or give its address with -Proxy.'
    return
  }
  'Proxies on this computer:'
  $width = ($found | ForEach-Object { $_.Url.Length } | Measure-Object -Maximum).Maximum
  foreach ($f in $found) {
    $line = '  {0}  {1}, {2}' -f $f.Url.PadRight($width), $f.Kind, $f.State
    if ($f.System) { $line += " (Windows' proxy setting)" }
    $line
  }
  $best = @($found | Where-Object { $_.Works })
  if ($best.Count) { "Use it for a profile: twinbar change PROFILE -Proxy $($best[0].Url)" }
  if (@($found | Where-Object { $_.Kind -eq 'SOCKS5' }).Count -and -not @($found | Where-Object { $_.Kind -eq 'HTTP' -and $_.Works }).Count) {
    $script:SocksTip
  }
}

# Checks Twinbar and its profiles, and says what to do about anything wrong.
function Invoke-Doctor([string] $Which) {
  $script:doctorProblems = 0
  $ok = { param($text) "  ok    $text" }
  $note = { param($text) "  note  $text" }
  $warn = { param($text) $script:doctorProblems++; "  warn  $text" }

  "Twinbar $($script:TwinbarVersion); Windows PowerShell $($PSVersionTable.PSVersion); Windows $([Environment]::OSVersion.Version)"
  "Home: $(Get-TwinbarHome)"
  $launcherPath = Get-LauncherPath
  if (-not (Test-Path -LiteralPath $launcherPath)) {
    & $note "launcher: not built yet (it's built with the first profile)"
  } else {
    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($launcherPath).FileVersion
    if ($version -eq "$($script:TwinbarVersion).0") { & $ok "launcher: $launcherPath ($version)" }
    else { & $warn "launcher: $version is from another Twinbar version; run: twinbar rebuild -All" }
  }

  $profiles = @(if ($Which) { Find-Profile $Which } else { Get-AllProfiles })
  if (-not $profiles.Count) { 'No profiles yet.' }
  $logPath = Join-Path (Get-TwinbarHome) 'logs\launcher.log'
  $logLines = @(if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Tail 400 })
  $taskbar = $null
  $taskbarAsked = $false

  foreach ($p in $profiles) {
    $r = ConvertTo-ProfileTable $p
    ''
    "$($r.appName) $($r.name) ($($r.id))"
    if ([int](Get-RecordValue $p 'schema') -lt 3) {
      & $warn "made with an older Twinbar ($(Get-RecordValue $p 'twinbarVersion')); run: twinbar rebuild $($r.id)"
    }
    $source = if ($r.appKind -eq 'store' -and $r.packageApp) { $r.packageApp } else { $r.launchExe }
    try {
      $app = Resolve-ElectronApp $source
      & $ok "app: $($app.Name), $($app.Kind), $($app.RealExe)"
      if ($r.realExe -and $app.RealExe -ne $r.realExe) { & $note "the app was updated since the profile was made; that's fine" }
    } catch {
      & $warn "app: $($_.Exception.Message). If it moved, run: twinbar rebuild $($r.id) -App <its new place>"
    }
    if (-not (Test-Path -LiteralPath $r.shortcut -PathType Leaf)) {
      & $warn "shortcut: $($r.shortcut) is missing; run: twinbar rebuild $($r.id)"
    } else {
      $link = Read-ShellLink $r.shortcut
      if ($link.AppUserModelId -ne $r.aumid) {
        & $warn "shortcut: $($r.shortcut) isn't the one Twinbar made"
      } elseif ($link.TargetPath -ine $launcherPath -or $link.Arguments -ne $r.id) {
        & $warn "shortcut: doesn't start this profile through the launcher; run: twinbar rebuild $($r.id)"
      } else {
        & $ok "shortcut: $($r.shortcut)"
      }
    }
    if ($r.icon) {
      if (Test-Path -LiteralPath $r.icon) { & $ok "icon: $(Get-LookNote $r)" }
      else { & $warn "icon: $($r.icon) is missing; run: twinbar rebuild $($r.id)" }
    }
    switch -Wildcard (Get-DataDirState $r.dataDir $r.id) {
      'ours' { & $ok "data: $($r.dataDir)" }
      'missing' { & $note "data: $($r.dataDir) isn't there; the app starts signed out and makes it again" }
      'other:*' { & $warn "data: $($r.dataDir) belongs to another profile" }
      default { & $warn "data: $($r.dataDir) has lost its Twinbar marker" }
    }
    if ($r.appKind -eq 'store' -and $r.dataDir.StartsWith([Environment]::GetFolderPath('ApplicationData'), [StringComparison]::OrdinalIgnoreCase)) {
      & $warn "data: a Store app's data under AppData is redirected by Windows into the app's package; Twinbar can't remove it there"
    }
    if ($r.proxy) {
      $proxyUri = [Uri]$r.proxy
      if (Test-TcpPort $proxyUri.Host.Trim('[', ']') $proxyUri.Port 2000) { & $ok "proxy: $($r.proxy) answers" }
      else { & $warn "proxy: $($r.proxy) doesn't answer, so the profile stays offline until it does (that's the kill switch)" }
      if ($r.proxy -like 'socks5://*') { & $note ($script:SocksTip -replace '^Tip: ', '') }
    }
    if (@(Get-ProfileProcesses $p).Count) {
      if (@(Get-ProfileLaunchers $r.id).Count) { & $ok 'running, looked after by the launcher' }
      else { & $warn "running without the launcher, so it may share the app's taskbar button; quit it and open it from the Start menu" }
      if (-not $taskbarAsked) { $taskbar = Get-TaskbarAppIds; $taskbarAsked = $true }
      if ($null -ne $taskbar) {
        if ($taskbar -contains $r.aumid) { & $ok 'taskbar: a button of its own' }
        else { & $warn "taskbar: no button of its own yet (look in $logPath)" }
      }
    } else {
      & $note 'not running'
    }
    $mine = @($logLines | Where-Object { $_ -match ('  ' + [regex]::Escape($r.id) + ':') } | Select-Object -Last 3)
    foreach ($line in $mine) { "        log: $line" }
  }
  ''
  if ($script:doctorProblems) { Stop-Twinbar "$($script:doctorProblems) problem(s) found" }
  'No problems found.'
}

function Invoke-List([switch] $AsJson) {
  $rows = @(Get-AllProfiles | ForEach-Object {
      [pscustomobject]@{
        id       = $_.id
        name     = $_.name
        appName  = $_.appName
        fullName = '{0} {1}' -f $_.appName, $_.name
        status   = Get-ProfileStatus $_
        dataDir  = $_.dataDir
        shortcut = $_.shortcut
        appKind  = Get-RecordValue $_ 'appKind'
        aumid    = $_.aumid
        style    = Get-RecordValue $_ 'style'
        color    = Get-RecordValue $_ 'color'
        badge    = Get-RecordValue $_ 'badge'
        icon     = Get-RecordValue $_ 'icon'
        appearance = Get-RecordValue $_ 'appearance'
      }
    })
  if ($AsJson) {
    return (ConvertTo-Json -InputObject $rows -Depth 4)
  }
  if (-not $rows.Count) {
    return 'No profiles yet. Make one with: twinbar new -App <app> -Name <name>'
  }
  $w1 = [Math]::Max(7, ($rows | ForEach-Object { $_.fullName.Length } | Measure-Object -Maximum).Maximum)
  $w2 = [Math]::Max(2, ($rows | ForEach-Object { $_.id.Length } | Measure-Object -Maximum).Maximum)
  $w3 = [Math]::Max(6, ($rows | ForEach-Object { $_.status.Length } | Measure-Object -Maximum).Maximum)
  ('{0}  {1}  {2}  {3}' -f 'Profile'.PadRight($w1), 'Id'.PadRight($w2), 'Status'.PadRight($w3), 'Data folder')
  foreach ($r in $rows) {
    ('{0}  {1}  {2}  {3}' -f $r.fullName.PadRight($w1), $r.id.PadRight($w2), $r.status.PadRight($w3), $r.dataDir)
  }
}

function Invoke-Open([string] $Which) {
  $p = Find-Profile $Which
  $launcher = Get-RecordValue $p 'launcher'
  if (Test-Path -LiteralPath $p.shortcut -PathType Leaf) {
    Start-Process -FilePath $p.shortcut
  } elseif ($launcher -and (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    Write-Warning "the Start menu shortcut is missing ($($p.shortcut)); starting the profile anyway"
    Start-Process -FilePath $launcher -ArgumentList $p.id
  } else {
    Write-Warning "the Start menu shortcut is missing ($($p.shortcut)); starting the app directly"
    Start-Process -FilePath $p.launchExe -ArgumentList ('--user-data-dir="' + $p.dataDir + '" ' + (Get-RecordValue $p 'extraArgs')).Trim()
  }
  "Opening $($p.appName) $($p.name)."
}

function Invoke-Remove([string] $Which, [switch] $WithData) {
  $p = Find-Profile $Which
  $fullName = '{0} {1}' -f $p.appName, $p.name
  if (@(Get-ProfileProcesses $p).Count) { Stop-Twinbar "$fullName is running; quit it first" }

  $report = @()
  if (Test-Path -LiteralPath $p.shortcut -PathType Leaf) {
    $link = Read-ShellLink $p.shortcut
    if ($link.AppUserModelId -ne $p.aumid) {
      Write-Warning "left $($p.shortcut) alone: it isn't the shortcut Twinbar made"
    } else {
      Move-ToRecycleBin $p.shortcut
      $report += '  Start menu shortcut: moved to the Recycle Bin'
    }
  }
  if ($WithData) {
    $state = Get-DataDirState $p.dataDir $p.id
    if ($state -eq 'ours') {
      Move-ToRecycleBin $p.dataDir
      Remove-EmptyDataParents $p.dataDir
      $report += "  Sign-in data: moved to the Recycle Bin ($($p.dataDir))"
    } elseif ($state -ne 'missing') {
      Write-Warning "kept $($p.dataDir): it doesn't carry this profile's Twinbar marker"
    }
  } else {
    $report += "  Sign-in data: kept in $($p.dataDir) (make the profile again to use it, or add -DeleteData to remove it)"
  }
  # The icon is Twinbar's own drawing; it goes when the profile goes.
  $icon = Get-RecordValue $p 'icon'
  $iconsDir = Join-Path (Get-TwinbarHome) 'icons'
  if ($icon -and $icon.StartsWith($iconsDir + '\', [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $icon)) {
    Remove-Item -LiteralPath $icon -Force
  }
  Remove-Item -LiteralPath (Get-RecordPath $p.id) -Force
  Update-JumpList
  "Removed ""$fullName""."
  $report
}

# ---------------------------------------------------------------------------
# The Twinbar window: the same commands without a terminal. WinForms, built in
# code; every button calls the same Invoke-* function as the command line.
# Event handlers reach their state through $script:Gui and $script:Dialog
# (one window and one dialog at a time).
# ---------------------------------------------------------------------------

$script:Gui = $null
$script:Dialog = $null
$script:GuiScale = 1.0
$script:GuiNoDialogs = $false # tests: collect messages instead of showing them
$script:GuiMessages = New-Object System.Collections.Generic.List[string]
$script:StyleNames = [ordered]@{ 'Colour and badge' = 'tint+badge'; 'Colour only' = 'tint'; 'Badge only' = 'badge'; "The app's own icon" = 'original' }
$script:AppearanceNames = [ordered]@{ 'Same as Windows' = 'system'; 'Light' = 'light'; 'Dark' = 'dark' }

function Initialize-Forms {
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  Initialize-Interop
  $g = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
  try { $script:GuiScale = $g.DpiX / 96.0 } finally { $g.Dispose() }
}

function Get-Scaled([double] $Pixels) { [int][Math]::Round($Pixels * $script:GuiScale) }

function ConvertTo-Sentence([string] $Text) {
  if (-not $Text) { return $Text }
  $t = $Text.Trim()
  $t = $t.Substring(0, 1).ToUpperInvariant() + $t.Substring(1)
  if ($t -notmatch '[.!?]$') { $t += '.' }
  return $t
}

function Show-GuiMessage($Owner, [string] $Text, [string] $Buttons = 'OK', [string] $Icon = 'Warning') {
  if ($script:GuiNoDialogs) {
    $script:GuiMessages.Add($Text)
    return $(if ($Buttons -eq 'YesNo') { 'No' } else { 'OK' })
  }
  return [string][Windows.Forms.MessageBox]::Show($Owner, $Text, 'Twinbar', $Buttons, $Icon)
}

function Set-GuiStatus([string] $Text) {
  if ($script:Gui) { $script:Gui.Status.Text = $Text }
}

function New-GuiFont([double] $Size = 9, [string] $Family = 'Segoe UI') {
  New-Object Drawing.Font($Family, [single]$Size)
}

function New-GuiButton([string] $Text, [scriptblock] $OnClick) {
  $b = New-Object Windows.Forms.Button
  $b.Text = $Text
  $b.AutoSize = $true
  $b.AutoSizeMode = 'GrowAndShrink'
  $b.Padding = New-Object Windows.Forms.Padding((Get-Scaled 10), (Get-Scaled 3), (Get-Scaled 10), (Get-Scaled 3))
  $b.Margin = New-Object Windows.Forms.Padding(0, 0, (Get-Scaled 6), 0)
  if ($OnClick) { $b.Add_Click($OnClick) }
  return $b
}

# Runs one of the commands for the window: wait cursor, first line of its output
# in the status bar, any error in a message box. Returns whether it worked.
function Invoke-GuiAction([scriptblock] $Action, $Owner) {
  if ($null -eq $Owner) { $Owner = $script:Gui.Form }
  $output = New-Object System.Collections.Generic.List[string]
  $Owner.UseWaitCursor = $true
  [Windows.Forms.Application]::DoEvents()
  try {
    & $Action | ForEach-Object { $output.Add([string]$_) }
    if ($output.Count) { Set-GuiStatus $output[0] }
    return $true
  } catch {
    [void](Show-GuiMessage $Owner (ConvertTo-Sentence $_.Exception.Message))
    return $false
  } finally {
    $Owner.UseWaitCursor = $false
    if ($script:Gui) { Update-ProfileList }
  }
}

function Get-ProfileBitmap($Record, [int] $Size) {
  try {
    if ($Record.icon -and (Test-Path -LiteralPath $Record.icon)) { return [TwinbarInterop.IconMaker]::Extract($Record.icon, 0, $Size) }
    if ($Record.launchExe -and (Test-Path -LiteralPath $Record.launchExe)) { return [TwinbarInterop.IconMaker]::Extract($Record.launchExe, 0, $Size) }
  } catch {
    Write-Verbose "no icon for $($Record.id): $($_.Exception.Message)"
  }
  return $null
}

function Get-GuiRows {
  $script:DataDirProcesses = $null
  @(Get-AllProfiles | ForEach-Object {
      $t = ConvertTo-ProfileTable $_
      [pscustomobject]@{ Id = $t.id; FullName = "$($t.appName) $($t.name)"; Status = (Get-ProfileStatus $_); Look = (Get-LookNote $t); DataDir = $t.dataDir; Record = $t }
    })
}

function Get-SelectedRow {
  $g = $script:Gui
  if ($null -eq $g -or $g.List.SelectedItems.Count -eq 0) { return $null }
  $id = [string]$g.List.SelectedItems[0].Tag
  $match = @($g.Rows | Where-Object { $_.Id -eq $id })
  if ($match.Count) { return $match[0] }
  return $null
}

function Update-GuiButtons {
  $has = $null -ne (Get-SelectedRow)
  foreach ($name in 'Edit', 'Open', 'Remove', 'Repair', 'Ip') { $script:Gui.Buttons[$name].Enabled = $has }
}

# Fills the list; with -Quiet (the timer), only refreshes the statuses unless
# profiles came or went.
function Update-ProfileList([switch] $Quiet) {
  $g = $script:Gui
  $rows = @(Get-GuiRows)
  $sameProfiles = (@($rows | ForEach-Object { $_.Id }) -join '|') -eq (@($g.Rows | ForEach-Object { $_.Id }) -join '|')
  if ($Quiet -and $sameProfiles -and $g.List.Items.Count -eq $rows.Count) {
    for ($i = 0; $i -lt $rows.Count; $i++) {
      $sub = $g.List.Items[$i].SubItems[1]
      if ($sub.Text -ne $rows[$i].Status) { $sub.Text = $rows[$i].Status }
    }
    $g.Rows = $rows
    return
  }
  $selected = Get-SelectedRow
  $g.List.BeginUpdate()
  try {
    $g.List.Items.Clear()
    $g.Images.Images.Clear()
    foreach ($r in $rows) {
      $bitmap = Get-ProfileBitmap $r.Record $g.Images.ImageSize.Width
      if ($bitmap) { $g.Images.Images.Add($r.Id, $bitmap) }
      $item = New-Object Windows.Forms.ListViewItem
      $item.Text = $r.FullName
      $item.Tag = $r.Id
      $item.ImageKey = $r.Id
      foreach ($text in @($r.Status, $r.Look, $r.DataDir)) { [void]$item.SubItems.Add([string]$text) }
      [void]$g.List.Items.Add($item)
      if ($selected -and $selected.Id -eq $r.Id) { $item.Selected = $true }
    }
  } finally {
    $g.List.EndUpdate()
  }
  $g.Rows = $rows
  if (-not $rows.Count) { Set-GuiStatus 'No profiles yet. Click "New profile..." to make one.' }
  Update-GuiButtons
}

function New-MainForm {
  $form = New-Object Windows.Forms.Form
  $form.Text = 'Twinbar'
  $form.Font = New-GuiFont
  $form.StartPosition = 'CenterScreen'
  $form.ClientSize = New-Object Drawing.Size((Get-Scaled 860), (Get-Scaled 420))
  $form.MinimumSize = New-Object Drawing.Size((Get-Scaled 600), (Get-Scaled 300))
  try { $form.Icon = New-Object Drawing.Icon((Get-AppIconPath)) } catch { Write-Verbose "no window icon: $($_.Exception.Message)" }

  $list = New-Object Windows.Forms.ListView
  $list.View = 'Details'
  $list.FullRowSelect = $true
  $list.MultiSelect = $false
  $list.HideSelection = $false
  $list.Dock = 'Fill'
  foreach ($column in @(@('Profile', 220), @('Status', 90), @('Icon', 240), @('Data folder', 280))) {
    [void]$list.Columns.Add([string]$column[0], (Get-Scaled $column[1]))
  }
  $images = New-Object Windows.Forms.ImageList
  $images.ColorDepth = 'Depth32Bit'
  $images.ImageSize = New-Object Drawing.Size((Get-Scaled 24), (Get-Scaled 24))
  $list.SmallImageList = $images

  $buttons = New-Object Windows.Forms.FlowLayoutPanel
  $buttons.Dock = 'Bottom'
  $buttons.AutoSize = $true
  $buttons.Padding = New-Object Windows.Forms.Padding((Get-Scaled 8))
  $status = New-Object Windows.Forms.StatusStrip
  $statusText = New-Object Windows.Forms.ToolStripStatusLabel
  $statusText.Spring = $true
  $statusText.TextAlign = 'MiddleLeft'
  [void]$status.Items.Add($statusText)
  # Twinbar's version, at the right; it turns into a link when there's an update.
  $versionText = New-Object Windows.Forms.ToolStripStatusLabel
  $versionText.Text = "Twinbar $($script:TwinbarVersion)"
  $versionText.ToolTipText = 'Your version of Twinbar'
  $versionText.Add_Click({ if ($script:Gui.Update) { Show-UpdateDialog $script:Gui.Update } })
  [void]$status.Items.Add($versionText)

  $script:Gui = @{
    Form = $form; List = $list; Images = $images; Status = $statusText; Version = $versionText; Rows = @(); Apps = $null; Buttons = @{}
    Update = $null; Work = $null; NextUpdateCheck = [datetime]::MinValue
  }
  $g = $script:Gui
  $g.Buttons.New = New-GuiButton 'New profile...' { Show-ProfileDialog $null }
  $g.Buttons.Edit = New-GuiButton 'Edit...' { $row = Get-SelectedRow; if ($row) { Show-ProfileDialog $row } }
  $g.Buttons.Open = New-GuiButton 'Open' { Open-SelectedProfile }
  $g.Buttons.Remove = New-GuiButton 'Remove...' { $row = Get-SelectedRow; if ($row) { Show-RemoveDialog $row } }
  $g.Buttons.Repair = New-GuiButton 'Repair' { Repair-SelectedProfile }
  $g.Buttons.Ip = New-GuiButton 'Check IP' { Show-IpCheck }
  $g.Buttons.Check = New-GuiButton 'Check all' { Show-CheckDialog }
  $g.Buttons.More = New-GuiButton 'More...' { Show-MoreMenu }
  foreach ($name in 'New', 'Edit', 'Open', 'Remove', 'Repair', 'Ip', 'Check', 'More') { $buttons.Controls.Add($g.Buttons[$name]) }

  $list.Add_SelectedIndexChanged({ Update-GuiButtons })
  $list.Add_DoubleClick({ Open-SelectedProfile })
  $list.Add_KeyDown({
      param($control, $key)
      if ($key.KeyCode -eq 'Return') { Open-SelectedProfile }
      elseif ($key.KeyCode -eq 'Delete') { $row = Get-SelectedRow; if ($row) { Show-RemoveDialog $row } }
    })

  # Docking goes from the last control added to the first: status bar, buttons, then the list fills the rest.
  $form.Controls.Add($list)
  $form.Controls.Add($buttons)
  $form.Controls.Add($status)
  $form.AcceptButton = $null

  $timer = New-Object Windows.Forms.Timer
  $timer.Interval = 4000
  $timer.Add_Tick({
      $began = Get-Date
      if ($script:Gui.Form.Visible) { Update-ProfileList -Quiet }
      if ((Get-Date) -ge $script:Gui.NextUpdateCheck) { Start-UpdateCheck }
      $took = ((Get-Date) - $began).TotalSeconds
      if ($took -gt 2) { Write-WindowLog ('refreshing the list took {0:0.0} s' -f $took) }
    })
  $g.Timer = $timer
  $workTimer = New-Object Windows.Forms.Timer
  $workTimer.Interval = 250
  $workTimer.Add_Tick({ Update-GuiWork })
  $g.WorkTimer = $workTimer
  foreach ($k in 'Started', 'Stopped', 'Quitting') { $g[$k] = $false }
  foreach ($k in 'Tray', 'TrayMenu', 'Context', 'SignalTimer', 'ShowSignal', 'QuitSignal', 'BalloonAction') { $g[$k] = $null }
  $form.Add_Shown({
      Start-GuiBackground
      Update-ProfileList
      if ($script:Gui.Rows.Count) { Set-GuiStatus ('{0} profile(s). Double-click one to open it.' -f $script:Gui.Rows.Count) }
    })
  # With the icon by the clock, closing the window hides it (unless that's turned off).
  $form.Add_FormClosing({
      param($window, $closing)
      $g = $script:Gui
      $keep = $g.Tray -and -not $g.Quitting -and $closing.CloseReason -eq 'UserClosing' -and (Get-Settings).closeToTray
      Write-WindowLog ('closing ({0}): {1}' -f $closing.CloseReason, $(if ($keep) { 'hidden, Twinbar stays by the clock' } else { 'Twinbar ends' }))
      if ($keep) {
        $closing.Cancel = $true
        $window.Hide()
        if (-not (Get-Settings).trayHintShown) {
          Set-TwinbarSetting 'trayHintShown' $true
          $g.Tray.ShowBalloonTip(6000, 'Twinbar is still here', 'Click its icon for the window, or right-click it for your profiles. Quit is in that menu too.', 'Info')
        }
      }
    })
  $form.Add_FormClosed({ Stop-GuiApp })
  return $form
}

# The timers and the first update check; once, when the window first shows or
# when Twinbar starts by the clock.
function Start-GuiBackground {
  $g = $script:Gui
  if ($g.Started) { return }
  $g.Started = $true
  $g.Timer.Start()
  Start-UpdateCheck
}

# A short log of what the window did (logs\window.log), for when something goes wrong.
function Write-WindowLog([string] $Text) {
  try {
    $path = Join-Path (Get-TwinbarHome) 'logs\window.log'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 262144) { Move-Item -LiteralPath $path -Destination "$path.old" -Force }
    [IO.File]::AppendAllText($path, ('{0}  [{1}] {2}{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $PID, $Text, [Environment]::NewLine))
  } catch {
    Write-Verbose "couldn't write the window log: $($_.Exception.Message)"
  }
}

function Stop-GuiApp {
  $g = $script:Gui
  if ($null -eq $g -or $g.Stopped) { return }
  Write-WindowLog 'stopped'
  $g.Stopped = $true
  $g.Timer.Stop(); $g.Timer.Dispose()
  $g.WorkTimer.Stop(); $g.WorkTimer.Dispose()
  if ($g.Work) { $g.Work.Client.CancelAsync(); $g.Work.Client.Dispose(); $g.Work = $null }
  if ($g.SignalTimer) { $g.SignalTimer.Stop(); $g.SignalTimer.Dispose() }
  if ($g.Tray) { $g.Tray.Visible = $false; $g.Tray.Dispose() }
  if ($g.Context) { $g.Context.ExitThread() }
}

function Show-MainWindow {
  $f = $script:Gui.Form
  if (-not $f.Visible) { $f.Show() }
  if ($f.WindowState -eq 'Minimized') { $f.WindowState = 'Normal' }
  $f.Activate()
}

# Quit: the window and the icon by the clock.
function Exit-TwinbarWindow {
  $g = $script:Gui
  $g.Quitting = $true
  if ($g.Form.IsHandleCreated) { $g.Form.Close() } else { Stop-GuiApp }
}

# Twinbar's own switches, as menu items (in More... and in the icon's menu).
function Get-TwinbarSwitches {
  $labels = [ordered]@{
    startup = 'Start Twinbar when I sign in to Windows'
    tray    = 'Keep Twinbar by the clock when its window closes'
    updates = 'Check for updates automatically'
  }
  foreach ($name in $labels.Keys) {
    $item = New-Object Windows.Forms.ToolStripMenuItem $labels[$name]
    $item.Tag = $name
    $item.Checked = [bool](Get-SettingState $name)
    if ($name -eq 'startup' -and -not (Test-Path -LiteralPath (Get-AppExePath))) {
      $item.Enabled = $false
      $item.ToolTipText = 'Install Twinbar first'
    }
    $item.Add_Click({
        param($item)
        try {
          [void](Invoke-Settings ([string]$item.Tag) $(if ($item.Checked) { 'off' } else { 'on' }))
          $item.Checked = [bool](Get-SettingState ([string]$item.Tag))
        } catch {
          [void](Show-GuiMessage $script:Gui.Form (ConvertTo-Sentence $_.Exception.Message))
        }
      })
    $item
  }
}

# The icon's menu: Open Twinbar, the profiles (whether each runs, and whether its
# proxy answers), an update if there is one, Twinbar's switches, and Quit.
function Update-TrayMenu($Menu) {
  $Menu.Items.Clear()
  $open = New-Object Windows.Forms.ToolStripMenuItem 'Open Twinbar'
  $open.Font = New-Object Drawing.Font($Menu.Font, [Drawing.FontStyle]::Bold)
  $open.Add_Click({ Show-MainWindow })
  [void]$Menu.Items.Add($open)
  [void]$Menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
  $rows = @(Get-GuiRows)
  $answers = @{}
  foreach ($r in $rows) {
    $item = New-Object Windows.Forms.ToolStripMenuItem $r.FullName
    $item.Tag = $r.Id
    $notes = @()
    if ($r.Status -eq 'running') { $notes += 'running' }
    if ($r.Record.proxy) {
      if (-not $answers.Contains($r.Record.proxy)) {
        $u = [Uri]$r.Record.proxy
        $answers[$r.Record.proxy] = Test-TcpPort $u.Host.Trim('[', ']') $u.Port 500
      }
      $notes += $(if ($answers[$r.Record.proxy]) { 'proxy OK' } else { 'proxy down' })
    }
    $item.ShortcutKeyDisplayString = $notes -join ', '
    $bitmap = Get-ProfileBitmap $r.Record (Get-Scaled 16)
    if ($bitmap) { $item.Image = $bitmap }
    $item.Add_Click({ param($item) $id = [string]$item.Tag; [void](Invoke-GuiAction { Invoke-Open $id }) })
    [void]$Menu.Items.Add($item)
  }
  if (-not $rows.Count) {
    $none = New-Object Windows.Forms.ToolStripMenuItem 'No profiles yet'
    $none.Enabled = $false
    [void]$Menu.Items.Add($none)
  }
  [void]$Menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
  if ($script:Gui.Update) {
    $update = New-Object Windows.Forms.ToolStripMenuItem "Update to $($script:Gui.Update.Version)..."
    $update.Add_Click({ Show-MainWindow; Show-UpdateDialog $script:Gui.Update })
    [void]$Menu.Items.Add($update)
  }
  foreach ($toggle in @(Get-TwinbarSwitches)) { [void]$Menu.Items.Add($toggle) }
  [void]$Menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
  $quit = New-Object Windows.Forms.ToolStripMenuItem 'Quit Twinbar'
  $quit.Add_Click({ Exit-TwinbarWindow })
  [void]$Menu.Items.Add($quit)
}

function Add-TrayIcon {
  $g = $script:Gui
  $tray = New-Object Windows.Forms.NotifyIcon
  try {
    $tray.Icon = New-Object Drawing.Icon((Get-AppIconPath), (Get-Scaled 16), (Get-Scaled 16))
  } catch {
    $tray.Icon = [Drawing.SystemIcons]::Application
  }
  $tray.Text = 'Twinbar'
  $menu = New-Object Windows.Forms.ContextMenuStrip
  $menu.Font = New-GuiFont
  Update-TrayMenu $menu
  $menu.Add_Opening({ param($menu, $opening) Update-TrayMenu $menu; $opening.Cancel = $false })
  $tray.ContextMenuStrip = $menu
  $tray.Add_MouseClick({ param($icon, $click) if ($click.Button -eq 'Left') { Show-MainWindow } })
  $tray.Add_BalloonTipClicked({ if ($script:Gui.BalloonAction) { & $script:Gui.BalloonAction } })
  $tray.Visible = $true
  $g.Tray = $tray
  $g.TrayMenu = $menu
}

# --- updates and other network work in the window ---
# It runs as .NET tasks that a timer looks at, so the window never waits on the
# network and no script runs off the window's thread.

function Start-GuiWork([string] $Kind, $Task, $Client, $Data) {
  $g = $script:Gui
  $g.Work = @{ Kind = $Kind; Task = $Task; Client = $Client; Data = $Data; Started = (Get-Date) }
  $g.WorkTimer.Start()
}

function Get-TaskError($Task) {
  if ($Task.IsCanceled) { return 'it took too long' }
  $e = $Task.Exception
  while ($e.InnerException) { $e = $e.InnerException }
  return $e.Message
}

function Update-GuiWork {
  $g = $script:Gui
  $w = $g.Work
  if ($null -eq $w) { $g.WorkTimer.Stop(); return }
  if (-not $w.Task.IsCompleted) {
    $seconds = ((Get-Date) - $w.Started).TotalSeconds
    if ($w.Kind -ne 'setup' -and $seconds -gt 30) { $w.Client.CancelAsync() }
    if ($w.Kind -eq 'setup' -and $w.Data.Release.SetupSize -gt 0 -and (Test-Path -LiteralPath $w.Data.Partial)) {
      $done = [Math]::Min(99, [int](100 * (Get-Item -LiteralPath $w.Data.Partial).Length / $w.Data.Release.SetupSize))
      Set-GuiStatus ('Downloading Twinbar {0}... {1}%' -f $w.Data.Release.Version, $done)
    }
    return
  }
  $g.Work = $null
  $g.WorkTimer.Stop()
  $w.Client.Dispose()
  switch ($w.Kind) {
    'check' { Complete-UpdateCheck $w }
    'sums' { Complete-UpdateSums $w }
    'setup' { Complete-UpdateDownload $w }
  }
}

# Asks GitHub for the newest version, in the background: when it's due (once a
# day, if checking automatically is on), or now with -Manual (More > Check for updates).
function Start-UpdateCheck([switch] $Manual) {
  $g = $script:Gui
  $g.NextUpdateCheck = (Get-Date).AddMinutes(30)
  if ($g.Work) { if ($Manual) { Set-GuiStatus 'Twinbar is busy with an update; try again in a moment.' }; return }
  if (-not $Manual) {
    $s = Get-Settings
    if (-not $s.checkForUpdates) { return }
    $last = [datetime]::MinValue
    if ($s.lastUpdateCheck) { [void][datetime]::TryParse([string]$s.lastUpdateCheck, [ref]$last) }
    if (((Get-Date) - $last).TotalHours -lt 20) { return }
  }
  try {
    $url = Get-UpdateSource
    $client = New-WebClient $url
    $client.Headers['Accept'] = 'application/vnd.github+json'
    if ($Manual) { Set-GuiStatus 'Checking for updates...' }
    Start-GuiWork 'check' $client.DownloadStringTaskAsync($url) $client @{ Manual = [bool]$Manual }
  } catch {
    if ($Manual) { [void](Show-GuiMessage $g.Form ("Couldn't check for updates: " + (ConvertTo-Sentence $_.Exception.Message))) }
  }
}

function Complete-UpdateCheck($Work) {
  $manual = $Work.Data.Manual
  if ($Work.Task.IsFaulted -or $Work.Task.IsCanceled) {
    if ($manual) {
      Set-GuiStatus ''
      [void](Show-GuiMessage $script:Gui.Form ("Couldn't ask GitHub for the newest version: " + (ConvertTo-Sentence (Get-TaskError $Work.Task))))
    }
    return
  }
  try {
    $release = ConvertFrom-ReleaseJson $Work.Task.Result
  } catch {
    if ($manual) { [void](Show-GuiMessage $script:Gui.Form (ConvertTo-Sentence $_.Exception.Message)) }
    return
  }
  Set-TwinbarSetting 'lastUpdateCheck' (Get-Date).ToString('o')
  if (-not (Test-NewerVersion $release.Version)) {
    if ($manual) {
      Set-GuiStatus "Twinbar $($script:TwinbarVersion) is the newest version."
      [void](Show-GuiMessage $script:Gui.Form "Twinbar $($script:TwinbarVersion) is the newest version." 'OK' 'Information')
    }
    return
  }
  $g = $script:Gui
  $g.Update = $release
  $g.Version.Text = "Update to $($release.Version)"
  $g.Version.IsLink = $true
  $g.Version.ToolTipText = "Twinbar $($release.Version) is out; click to see what's new and update"
  Set-GuiStatus "Twinbar $($release.Version) is out."
  # Asked once per new version; after that, the link in the status bar stays. With
  # the window hidden, a note by the clock asks instead.
  if ($manual -or (Get-Settings).notifiedVersion -ne $release.Version) {
    Set-TwinbarSetting 'notifiedVersion' $release.Version
    if ($g.Tray -and -not $g.Form.Visible) {
      $g.BalloonAction = { Show-MainWindow; Show-UpdateDialog $script:Gui.Update }
      $g.Tray.ShowBalloonTip(10000, "Twinbar $($release.Version) is out", "Click here to see what's new and update.", 'Info')
    } else {
      Show-UpdateDialog $release
    }
  }
}

# What's new, and Update now / Later.
function Show-UpdateDialog($Release) {
  if ($script:GuiNoDialogs) {
    $script:GuiMessages.Add("Twinbar $($Release.Version) is out.")
    return
  }
  $d = New-Object Windows.Forms.Form
  $d.Text = 'Update Twinbar'
  $d.Font = New-GuiFont
  $d.StartPosition = 'CenterParent'
  $d.ShowInTaskbar = $false
  $d.MinimizeBox = $false
  $d.MaximizeBox = $false
  $d.ClientSize = New-Object Drawing.Size((Get-Scaled 560), (Get-Scaled 380))
  $d.Padding = New-Object Windows.Forms.Padding((Get-Scaled 12))
  $title = New-Object Windows.Forms.Label
  $title.Text = "Twinbar $($Release.Version) is out. You have $($script:TwinbarVersion)."
  $title.Font = New-GuiFont 11
  $title.Dock = 'Top'
  $title.Height = Get-Scaled 32
  $notes = New-Object Windows.Forms.TextBox
  $notes.Multiline = $true
  $notes.ReadOnly = $true
  $notes.ScrollBars = 'Vertical'
  $notes.Dock = 'Fill'
  $notes.Text = $(if ($Release.Notes) { $Release.Notes.Replace("`n", "`r`n") } else { "See what's new on the release page." })
  $note = New-Object Windows.Forms.Label
  $note.Text = $(if ((Get-InstallKind) -eq 'setup') {
      'Twinbar downloads the installer from GitHub, checks it, closes, updates and opens again. Your profiles stay as they are.'
    } else {
      "Twinbar downloads the installer from GitHub, checks it, and opens it. Your profiles stay as they are."
    })
  $note.Dock = 'Bottom'
  $note.Height = Get-Scaled 40
  $note.Padding = New-Object Windows.Forms.Padding(0, (Get-Scaled 8), 0, 0)
  $buttons = New-Object Windows.Forms.FlowLayoutPanel
  $buttons.Dock = 'Bottom'
  $buttons.AutoSize = $true
  $buttons.FlowDirection = 'RightToLeft'
  $later = New-GuiButton 'Later' $null
  $later.DialogResult = 'Cancel'
  $now = New-GuiButton 'Update now' $null
  $now.DialogResult = 'OK'
  $page = New-GuiButton 'Release page' { if ($script:UpdatePage) { Start-Process -FilePath $script:UpdatePage } }
  $script:UpdatePage = $Release.Page
  foreach ($b in @($later, $now, $page)) { $buttons.Controls.Add($b) }
  $d.Controls.Add($notes)
  $d.Controls.Add($title)
  $d.Controls.Add($note)
  $d.Controls.Add($buttons)
  $d.AcceptButton = $now
  $d.CancelButton = $later
  try {
    if ($d.ShowDialog($script:Gui.Form) -eq 'OK') { Start-GuiUpdate $Release }
  } finally {
    $d.Dispose()
  }
}

# Update now: the release's SHA256SUMS, then its installer, both in the background.
function Start-GuiUpdate($Release) {
  $g = $script:Gui
  try {
    if ((Get-InstallKind) -eq 'scoop') { Stop-Twinbar 'this Twinbar came from Scoop; update it with: scoop update twinbar' }
    Assert-UpdateRelease $Release
  } catch {
    [void](Show-GuiMessage $g.Form (ConvertTo-Sentence $_.Exception.Message))
    return
  }
  if ($g.Work) { $g.Work.Client.CancelAsync(); $g.Work.Client.Dispose(); $g.Work = $null }
  $client = New-WebClient $Release.SumsUrl
  Set-GuiStatus "Downloading Twinbar $($Release.Version)..."
  Start-GuiWork 'sums' $client.DownloadStringTaskAsync($Release.SumsUrl) $client @{ Release = $Release }
}

function Complete-UpdateSums($Work) {
  $release = $Work.Data.Release
  $g = $script:Gui
  try {
    if ($Work.Task.IsFaulted -or $Work.Task.IsCanceled) { Stop-Twinbar "couldn't download Twinbar $($release.Version): $(Get-TaskError $Work.Task)" }
    $expected = Get-ListedHash $Work.Task.Result $release.SetupName
  } catch {
    Set-GuiStatus ''
    [void](Show-GuiMessage $g.Form (ConvertTo-Sentence $_.Exception.Message))
    return
  }
  $dir = Get-UpdateDir
  [void][IO.Directory]::CreateDirectory($dir)
  $target = Join-Path $dir $release.SetupName
  $partial = "$target.part"
  $client = New-WebClient $release.SetupUrl
  Start-GuiWork 'setup' $client.DownloadFileTaskAsync($release.SetupUrl, $partial) $client @{ Release = $release; Expected = $expected; Partial = $partial; Target = $target }
}

function Complete-UpdateDownload($Work) {
  $d = $Work.Data
  $g = $script:Gui
  try {
    if ($Work.Task.IsFaulted -or $Work.Task.IsCanceled) {
      Remove-Item -LiteralPath $d.Partial -Force -ErrorAction SilentlyContinue
      Stop-Twinbar "couldn't download Twinbar $($d.Release.Version): $(Get-TaskError $Work.Task)"
    }
    $setup = Complete-UpdateFile $d.Partial $d.Expected $d.Target
  } catch {
    Set-GuiStatus ''
    [void](Show-GuiMessage $g.Form (ConvertTo-Sentence $_.Exception.Message))
    return
  }
  Set-GuiStatus "Downloaded Twinbar $($d.Release.Version); its SHA-256 matches. Updating..."
  if ($script:GuiNoDialogs) {
    $script:GuiMessages.Add("Ready to install $setup")
    return
  }
  Start-UpdateAfterExit $setup
  Exit-TwinbarWindow
}

function Show-MoreMenu {
  $g = $script:Gui
  $menu = New-Object Windows.Forms.ContextMenuStrip
  $menu.Font = New-GuiFont
  $check = $menu.Items.Add('Check for updates')
  $check.Add_Click({ Start-UpdateCheck -Manual })
  [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
  foreach ($toggle in @(Get-TwinbarSwitches)) { [void]$menu.Items.Add($toggle) }
  [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
  $proxies = $menu.Items.Add('Find proxies on this computer')
  $proxies.Add_Click({ Show-ProxiesFound })
  $about = $menu.Items.Add('About Twinbar')
  $about.Add_Click({
      [void](Show-GuiMessage $script:Gui.Form ("Twinbar $($script:TwinbarVersion)`r`n`r`nSecond, separately signed-in copies of your Electron apps.`r`n" +
          "https://github.com/$($script:Repository) (MIT licence)") 'OK' 'Information')
    })
  $button = $g.Buttons.More
  $menu.Show($button, 0, $button.Height)
}

function Show-ProxiesFound {
  $form = $script:Gui.Form
  $lines = New-Object System.Collections.Generic.List[string]
  $form.UseWaitCursor = $true
  Set-GuiStatus 'Looking for proxies on this computer...'
  [Windows.Forms.Application]::DoEvents()
  try {
    Invoke-Proxies | ForEach-Object { $lines.Add([string]$_) }
  } catch {
    $lines.Add((ConvertTo-Sentence $_.Exception.Message))
  } finally {
    $form.UseWaitCursor = $false
    Set-GuiStatus ''
  }
  Show-TextDialog 'Proxies on this computer' ($lines -join "`r`n")
}

function Open-SelectedProfile {
  $row = Get-SelectedRow
  if ($row) { [void](Invoke-GuiAction { Invoke-Open $row.Id }) }
}

function Select-AppFile($Owner) {
  $dialog = New-Object Windows.Forms.OpenFileDialog
  $dialog.Title = 'Find the app'
  $dialog.Filter = 'Programs and shortcuts (*.exe;*.lnk)|*.exe;*.lnk|All files (*.*)|*.*'
  $dialog.DereferenceLinks = $false
  try {
    if ($dialog.ShowDialog($Owner) -eq 'OK') { return $dialog.FileName }
    return $null
  } finally {
    $dialog.Dispose()
  }
}

function Repair-SelectedProfile {
  $row = Get-SelectedRow
  if (-not $row) { return }
  $form = $script:Gui.Form
  $form.UseWaitCursor = $true
  [Windows.Forms.Application]::DoEvents()
  $moved = $false
  try {
    $output = @(Invoke-Rebuild $row.Id)
    if ($output.Count) { Set-GuiStatus ([string]$output[0]) }
  } catch {
    $message = $_.Exception.Message
    if ($message -match 'If the app moved') { $moved = $true }
    else { [void](Show-GuiMessage $form (ConvertTo-Sentence $message)) }
  } finally {
    $form.UseWaitCursor = $false
  }
  if ($moved) {
    $answer = Show-GuiMessage $form "Twinbar can't find $($row.Record.appName) where it was. Show Twinbar where it is now?" 'YesNo' 'Question'
    if ($answer -eq 'Yes') {
      $file = Select-AppFile $form
      if ($file) { [void](Invoke-GuiAction { Invoke-Rebuild $row.Id -AppPath $file }) }
    }
  }
  Update-ProfileList
}

function Show-TextDialog([string] $Title, [string] $Text) {
  $d = New-Object Windows.Forms.Form
  $d.Text = $Title
  $d.Font = New-GuiFont
  $d.StartPosition = 'CenterParent'
  $d.ShowInTaskbar = $false
  $d.MinimizeBox = $false
  $d.ClientSize = New-Object Drawing.Size((Get-Scaled 780), (Get-Scaled 440))
  $box = New-Object Windows.Forms.TextBox
  $box.Multiline = $true
  $box.ReadOnly = $true
  $box.ScrollBars = 'Both'
  $box.WordWrap = $false
  $box.Dock = 'Fill'
  $box.Font = New-GuiFont 9 'Consolas'
  $box.Text = $Text
  $panel = New-Object Windows.Forms.FlowLayoutPanel
  $panel.Dock = 'Bottom'
  $panel.AutoSize = $true
  $panel.FlowDirection = 'RightToLeft'
  $panel.Padding = New-Object Windows.Forms.Padding((Get-Scaled 8))
  $close = New-GuiButton 'Close' $null
  $close.DialogResult = 'OK'
  $panel.Controls.Add($close)
  $d.Controls.Add($box)
  $d.Controls.Add($panel)
  $d.AcceptButton = $close
  $d.CancelButton = $close
  try { [void]$d.ShowDialog($script:Gui.Form) } finally { $d.Dispose() }
}

function Show-IpCheck {
  $row = Get-SelectedRow
  if (-not $row) { return }
  $form = $script:Gui.Form
  $lines = New-Object System.Collections.Generic.List[string]
  $form.UseWaitCursor = $true
  Set-GuiStatus "Checking the IP address of $($row.FullName)..."
  [Windows.Forms.Application]::DoEvents()
  try {
    Invoke-Ip $row.Id | ForEach-Object { $lines.Add([string]$_) }
  } catch {
    $lines.Add((ConvertTo-Sentence $_.Exception.Message))
  } finally {
    $form.UseWaitCursor = $false
    Set-GuiStatus ''
  }
  Show-TextDialog "IP address of $($row.FullName)" ($lines -join "`r`n")
}

function Show-CheckDialog {
  $form = $script:Gui.Form
  $lines = New-Object System.Collections.Generic.List[string]
  $form.UseWaitCursor = $true
  [Windows.Forms.Application]::DoEvents()
  try {
    Invoke-Doctor '' | ForEach-Object { $lines.Add([string]$_) }
  } catch {
    $lines.Add((ConvertTo-Sentence $_.Exception.Message))
  } finally {
    $form.UseWaitCursor = $false
  }
  Show-TextDialog 'Check' ($lines -join "`r`n")
}

function New-RemoveDialog($Row) {
  $d = New-Object Windows.Forms.Form
  $d.Text = "Remove $($Row.FullName)"
  $d.Font = New-GuiFont
  $d.FormBorderStyle = 'FixedDialog'
  $d.MaximizeBox = $false
  $d.MinimizeBox = $false
  $d.ShowInTaskbar = $false
  $d.StartPosition = 'CenterParent'
  $d.AutoSize = $true
  $d.AutoSizeMode = 'GrowAndShrink'
  $d.Padding = New-Object Windows.Forms.Padding((Get-Scaled 12))
  $layout = New-Object Windows.Forms.FlowLayoutPanel
  $layout.FlowDirection = 'TopDown'
  $layout.AutoSize = $true
  $title = New-Object Windows.Forms.Label
  $title.Text = "Remove $($Row.FullName)?"
  $title.Font = New-GuiFont 11
  $title.AutoSize = $true
  $text = New-Object Windows.Forms.Label
  $text.Text = 'Its Start menu entry and icon go. Its sign-in and data are kept, so making the profile again brings them back.'
  $text.AutoSize = $true
  $text.MaximumSize = New-Object Drawing.Size((Get-Scaled 420), 0)
  $text.Margin = New-Object Windows.Forms.Padding(0, (Get-Scaled 8), 0, (Get-Scaled 8))
  $deleteData = New-Object Windows.Forms.CheckBox
  $deleteData.Text = 'Also delete its sign-in and data (to the Recycle Bin)'
  $deleteData.AutoSize = $true
  $buttons = New-Object Windows.Forms.FlowLayoutPanel
  $buttons.AutoSize = $true
  $buttons.Margin = New-Object Windows.Forms.Padding(0, (Get-Scaled 12), 0, 0)
  $ok = New-GuiButton 'Remove' $null
  $ok.DialogResult = 'OK'
  $cancel = New-GuiButton 'Cancel' $null
  $cancel.DialogResult = 'Cancel'
  $buttons.Controls.Add($ok)
  $buttons.Controls.Add($cancel)
  foreach ($c in @($title, $text, $deleteData, $buttons)) { $layout.Controls.Add($c) }
  $d.Controls.Add($layout)
  $d.AcceptButton = $ok
  $d.CancelButton = $cancel
  return @{ Form = $d; DeleteData = $deleteData; Row = $Row }
}

function Show-RemoveDialog($Row) {
  $d = New-RemoveDialog $Row
  try {
    if ($d.Form.ShowDialog($script:Gui.Form) -eq 'OK') {
      $withData = $d.DeleteData.Checked
      [void](Invoke-GuiAction { Invoke-Remove $Row.Id -WithData:$withData })
    }
  } finally {
    $d.Form.Dispose()
  }
}

# --- the New / Edit dialog ---

function Get-ColorItemHex([string] $Text) {
  if (-not $Text) { return $null }
  $key = $Text.ToLowerInvariant()
  if ($script:Palette.Contains($key)) { return $script:Palette[$key] }
  if ($Text -match '^#[0-9A-Fa-f]{6}$') { return $Text.ToUpperInvariant() }
  return $null
}

function Select-ColorItem($Combo, [string] $Hex) {
  foreach ($item in @($Combo.Items)) {
    if ((Get-ColorItemHex ([string]$item)) -eq $Hex) { $Combo.SelectedItem = $item; return }
  }
  $Combo.Items.Insert($Combo.Items.Count - 1, $Hex)
  $Combo.SelectedItem = $Hex
}

function Format-AppItem($App) {
  if ($App.Kind -eq 'store') { return "$($App.Name) (Microsoft Store)" }
  return [string]$App.Name
}

function Get-DialogApp($State) {
  $i = $State.App.SelectedIndex
  if ($i -lt 0 -or $i -ge $State.AppList.Count) { return $null }
  return $State.AppList[$i]
}

function Get-DialogBadge($State) {
  $t = $State.Badge.Text.Trim()
  if ($t) { return $t.ToUpperInvariant() }
  $n = $State.Name.Text.Trim()
  if ($n) { return ([Globalization.StringInfo]::GetNextTextElement($n)).ToUpperInvariant() }
  return ''
}

function Update-ProfilePreview($State) {
  $source = if ($State.Row) { $State.Row.Record.launchExe } else { $a = Get-DialogApp $State; if ($a) { $a.LaunchExe } else { '' } }
  $bitmap = $null
  if ($source) {
    $hex = Get-ColorItemHex ([string]$State.Color.SelectedItem)
    if (-not $hex) { $hex = '#0090FF' }
    $look = $script:StyleNames[[string]$State.Style.SelectedItem]
    try { $bitmap = [TwinbarInterop.IconMaker]::Preview($source, $look, $hex, (Get-DialogBadge $State), $State.Preview.Width) } catch { $bitmap = $null }
  }
  $old = $State.Preview.Image
  $State.Preview.Image = $bitmap
  if ($old) { $old.Dispose() }
}

# For a new profile, the colour follows the name (as on the command line) until
# it's picked by hand.
function Update-DefaultColor($State) {
  if ($State.Row -or $State.ColorPicked) { return }
  $a = Get-DialogApp $State
  $appKey = if ($a) { $a.Id } else { 'app' }
  $hex = Resolve-ProfileColor '' ('{0}.{1}' -f $appKey, (Get-NameKey $State.Name.Text.Trim()))
  $State.Updating = $true
  try { Select-ColorItem $State.Color $hex } finally { $State.Updating = $false }
}

function New-ProfileDialog($Row) {
  $editing = $null -ne $Row
  $d = New-Object Windows.Forms.Form
  $d.Text = $(if ($editing) { "Edit $($Row.FullName)" } else { 'New profile' })
  $d.Font = New-GuiFont
  $d.FormBorderStyle = 'FixedDialog'
  $d.MaximizeBox = $false
  $d.MinimizeBox = $false
  $d.ShowInTaskbar = $false
  $d.StartPosition = 'CenterParent'
  $d.AutoSize = $true
  $d.AutoSizeMode = 'GrowAndShrink'
  $d.Padding = New-Object Windows.Forms.Padding((Get-Scaled 12))

  $grid = New-Object Windows.Forms.TableLayoutPanel
  $grid.AutoSize = $true
  $grid.ColumnCount = 3
  $wide = Get-Scaled 280

  $app = New-Object Windows.Forms.ComboBox
  $app.DropDownStyle = 'DropDownList'
  $app.Width = $wide
  $browse = New-GuiButton 'Find...' $null
  $appRow = New-Object Windows.Forms.FlowLayoutPanel
  $appRow.AutoSize = $true
  $appRow.WrapContents = $false
  $appRow.Margin = New-Object Windows.Forms.Padding(0)
  $appRow.Controls.Add($app)
  $appRow.Controls.Add($browse)
  $name = New-Object Windows.Forms.TextBox
  $name.Width = $wide
  $color = New-Object Windows.Forms.ComboBox
  $color.DropDownStyle = 'DropDownList'
  $color.DrawMode = 'OwnerDrawFixed'
  $color.ItemHeight = Get-Scaled 18
  $color.Width = $wide
  foreach ($key in $script:Palette.Keys) { [void]$color.Items.Add($key.Substring(0, 1).ToUpperInvariant() + $key.Substring(1)) }
  [void]$color.Items.Add('Custom...')
  $badge = New-Object Windows.Forms.TextBox
  $badge.Width = Get-Scaled 60
  $badge.MaxLength = 4
  $style = New-Object Windows.Forms.ComboBox
  $style.DropDownStyle = 'DropDownList'
  $style.Width = $wide
  foreach ($key in $script:StyleNames.Keys) { [void]$style.Items.Add($key) }
  $appearance = New-Object Windows.Forms.ComboBox
  $appearance.DropDownStyle = 'DropDownList'
  $appearance.Width = $wide
  foreach ($key in $script:AppearanceNames.Keys) { [void]$appearance.Items.Add($key) }
  $proxy = New-Object Windows.Forms.TextBox
  $proxy.Width = $wide
  $findProxy = New-GuiButton 'Find...' { Show-ProxyChoices $script:Dialog }
  $proxyRow = New-Object Windows.Forms.FlowLayoutPanel
  $proxyRow.AutoSize = $true
  $proxyRow.WrapContents = $false
  $proxyRow.Margin = New-Object Windows.Forms.Padding(0)
  $proxyRow.Controls.Add($proxy)
  $proxyRow.Controls.Add($findProxy)
  $preview = New-Object Windows.Forms.PictureBox
  $preview.Size = New-Object Drawing.Size((Get-Scaled 128), (Get-Scaled 128))
  $preview.SizeMode = 'Zoom'
  $preview.Margin = New-Object Windows.Forms.Padding((Get-Scaled 16), 0, 0, 0)
  $hint = New-Object Windows.Forms.Label
  $hint.Text = "Leave the badge empty for the name's first letter. Light and dark work for apps that follow Windows. " +
    'Proxy: like http://127.0.0.1:10809 or socks5://127.0.0.1:10808, or empty for none; if it is down, the profile stays offline. ' +
    "Find looks for proxies on this computer. Prefer the HTTP address: some apps (Claude) don't use a SOCKS proxy outside Chromium."
  $hint.AutoSize = $true
  $hint.MaximumSize = New-Object Drawing.Size(($wide + (Get-Scaled 90)), 0)
  $hint.ForeColor = [Drawing.SystemColors]::GrayText

  $rowIndex = 0
  foreach ($pair in @(@('App', $appRow), @('Name', $name), @('Colour', $color), @('Badge', $badge), @('Icon', $style), @('Appearance', $appearance), @('Proxy', $proxyRow))) {
    $label = New-Object Windows.Forms.Label
    $label.Text = [string]$pair[0]
    $label.AutoSize = $true
    $label.Anchor = 'Left'
    $grid.Controls.Add($label, 0, $rowIndex)
    $pair[1].Margin = New-Object Windows.Forms.Padding(0, (Get-Scaled 3), 0, (Get-Scaled 3))
    $grid.Controls.Add($pair[1], 1, $rowIndex)
    $rowIndex++
  }
  $grid.Controls.Add($preview, 2, 0)
  $grid.SetRowSpan($preview, 7)
  $grid.Controls.Add($hint, 1, $rowIndex)
  $grid.SetColumnSpan($hint, 2)
  $rowIndex++
  $buttons = New-Object Windows.Forms.FlowLayoutPanel
  $buttons.AutoSize = $true
  $buttons.FlowDirection = 'RightToLeft'
  $buttons.Anchor = 'Right'
  $buttons.Margin = New-Object Windows.Forms.Padding(0, (Get-Scaled 12), 0, 0)
  $cancel = New-GuiButton 'Cancel' $null
  $cancel.DialogResult = 'Cancel'
  $ok = New-GuiButton $(if ($editing) { 'Save' } else { 'Create' }) $null
  $buttons.Controls.Add($cancel)
  $buttons.Controls.Add($ok)
  $grid.Controls.Add($buttons, 0, $rowIndex)
  $grid.SetColumnSpan($buttons, 3)
  $d.Controls.Add($grid)
  $d.AcceptButton = $ok
  $d.CancelButton = $cancel

  $appList = New-Object System.Collections.Generic.List[object]
  $state = @{
    Form = $d; Row = $Row; App = $app; AppList = $appList; Browse = $browse; Name = $name; Color = $color
    Badge = $badge; Style = $style; Appearance = $appearance; Proxy = $proxy; FindProxy = $findProxy; Preview = $preview; Ok = $ok
    ColorPicked = $false; Updating = $true
  }
  $script:Dialog = $state

  if ($editing) {
    $r = $Row.Record
    $appList.Add([pscustomobject]@{ Name = $r.appName; Kind = $r.appKind; Source = $r.launchExe; LaunchExe = $r.launchExe; Id = $r.appId })
    [void]$app.Items.Add([string]$r.appName)
    $app.SelectedIndex = 0
    $app.Enabled = $false
    $browse.Enabled = $false
    $name.Text = $r.name
    $name.Enabled = $false
    $badge.Text = $r.badge
    $proxy.Text = $r.proxy
    Select-ColorItem $color $r.color
    $style.SelectedItem = @($script:StyleNames.Keys | Where-Object { $script:StyleNames[$_] -eq $r.style })[0]
    $appearance.SelectedItem = @($script:AppearanceNames.Keys | Where-Object { $script:AppearanceNames[$_] -eq $r.appearance })[0]
  } else {
    $apps = if ($script:Gui -and $script:Gui.Apps) { @($script:Gui.Apps) } else { @() }
    foreach ($a in $apps) { $appList.Add($a); [void]$app.Items.Add((Format-AppItem $a)) }
    if ($app.Items.Count) { $app.SelectedIndex = 0 }
    $style.SelectedIndex = 0
    $appearance.SelectedIndex = 0
    $state.Updating = $false
    Update-DefaultColor $state
  }
  $state.Updating = $false

  $color.Add_DrawItem({
      param($control, $draw)
      $draw.DrawBackground()
      if ($draw.Index -ge 0) {
        $text = [string]$control.Items[$draw.Index]
        $hex = Get-ColorItemHex $text
        $side = $draw.Bounds.Height - (Get-Scaled 6)
        $swatch = New-Object Drawing.Rectangle(($draw.Bounds.X + (Get-Scaled 3)), ($draw.Bounds.Y + (Get-Scaled 3)), $side, $side)
        if ($hex) {
          $brush = New-Object Drawing.SolidBrush([Drawing.ColorTranslator]::FromHtml($hex))
          $draw.Graphics.FillRectangle($brush, $swatch)
          $brush.Dispose()
        }
        $textBrush = New-Object Drawing.SolidBrush($draw.ForeColor)
        $draw.Graphics.DrawString($text, $draw.Font, $textBrush, [single]($swatch.Right + (Get-Scaled 6)), [single]($draw.Bounds.Y + 1))
        $textBrush.Dispose()
      }
      $draw.DrawFocusRectangle()
    })
  $color.Add_SelectedIndexChanged({
      $s = $script:Dialog
      if ($s.Updating) { return }
      if ([string]$s.Color.SelectedItem -eq 'Custom...') {
        $picker = New-Object Windows.Forms.ColorDialog
        $picker.FullOpen = $true
        $s.Updating = $true
        try {
          if ($picker.ShowDialog($s.Form) -eq 'OK') {
            Select-ColorItem $s.Color ('#{0:X2}{1:X2}{2:X2}' -f $picker.Color.R, $picker.Color.G, $picker.Color.B)
          } else {
            $s.Color.SelectedIndex = 0
          }
        } finally {
          $s.Updating = $false
          $picker.Dispose()
        }
      }
      $s.ColorPicked = $true
      Update-ProfilePreview $s
    })
  $app.Add_SelectedIndexChanged({ $s = $script:Dialog; if (-not $s.Updating) { Update-DefaultColor $s; Update-ProfilePreview $s } })
  $name.Add_TextChanged({ $s = $script:Dialog; Update-DefaultColor $s; Update-ProfilePreview $s })
  $badge.Add_TextChanged({ Update-ProfilePreview $script:Dialog })
  $style.Add_SelectedIndexChanged({ if (-not $script:Dialog.Updating) { Update-ProfilePreview $script:Dialog } })
  $browse.Add_Click({
      $s = $script:Dialog
      $file = Select-AppFile $s.Form
      if (-not $file) { return }
      try {
        $found = Resolve-ElectronApp $file
      } catch {
        [void](Show-GuiMessage $s.Form (ConvertTo-Sentence $_.Exception.Message))
        return
      }
      $s.AppList.Add([pscustomobject]@{ Name = $found.Name; Kind = $found.Kind; Source = $file; LaunchExe = $found.LaunchExe; Id = $found.Id })
      [void]$s.App.Items.Add((Format-AppItem $found))
      $s.App.SelectedIndex = $s.App.Items.Count - 1
    })
  $ok.Add_Click({
      $s = $script:Dialog
      if (Submit-ProfileDialog $s) {
        $s.Form.DialogResult = 'OK'
        $s.Form.Close()
      }
    })
  return $state
}

# The proxies found on this computer, as a menu under Find...; picking one fills
# in the Proxy field.
function New-ProxyMenu($State, $Found) {
  $menu = New-Object Windows.Forms.ContextMenuStrip
  $menu.Font = New-GuiFont
  foreach ($f in @($Found)) {
    $text = '{0}    {1}, {2}' -f $f.Url, $f.Kind, $f.State
    if ($f.System) { $text += " (Windows' proxy setting)" }
    $item = $menu.Items.Add($text)
    $item.Tag = $f.Url
    $item.Add_Click({ param($item) $script:Dialog.Proxy.Text = [string]$item.Tag })
  }
  return $menu
}

function Show-ProxyChoices($State) {
  $State.Form.UseWaitCursor = $true
  [Windows.Forms.Application]::DoEvents()
  try {
    $found = @(Find-LocalProxies)
  } catch {
    [void](Show-GuiMessage $State.Form (ConvertTo-Sentence $_.Exception.Message))
    return
  } finally {
    $State.Form.UseWaitCursor = $false
  }
  if (-not $found.Count) {
    [void](Show-GuiMessage $State.Form ("No proxy found on this computer's usual ports, and Windows isn't set to use one. " +
        'Start your proxy or VPN app (v2rayN, Clash, NekoRay, ...), or type its address.') 'OK' 'Information')
    return
  }
  $menu = New-ProxyMenu $State $found
  $menu.Show($State.FindProxy, 0, $State.FindProxy.Height)
}

# Makes or changes the profile from the dialog's fields; returns whether it worked.
function Submit-ProfileDialog($State) {
  $hex = Get-ColorItemHex ([string]$State.Color.SelectedItem)
  $look = $script:StyleNames[[string]$State.Style.SelectedItem]
  $theme = $script:AppearanceNames[[string]$State.Appearance.SelectedItem]
  $route = $State.Proxy.Text.Trim()
  if ($State.Row) {
    $id = $State.Row.Id
    $letters = Get-DialogBadge $State
    $routeOrNone = if ($route) { $route } else { 'none' }
    return (Invoke-GuiAction { Invoke-Change -Which $id -ColorName $hex -BadgeText $letters -StyleName $look -AppearanceName $theme -ProxyValue $routeOrNone } $State.Form)
  }
  $chosen = Get-DialogApp $State
  if (-not $chosen) {
    [void](Show-GuiMessage $State.Form 'Pick an app first, or find it with "Find...".')
    return $false
  }
  $source = $chosen.Source
  $label = $State.Name.Text
  $letters = $State.Badge.Text.Trim()
  return (Invoke-GuiAction { Invoke-New -AppPath $source -ProfileName $label -ColorName $hex -BadgeText $letters -StyleName $look -AppearanceName $theme -ProxyValue $route } $State.Form)
}

function Show-ProfileDialog($Row) {
  if (-not $Row -and $null -eq $script:Gui.Apps) {
    $script:Gui.Form.UseWaitCursor = $true
    Set-GuiStatus 'Looking for apps...'
    [Windows.Forms.Application]::DoEvents()
    try { $script:Gui.Apps = @(Find-ElectronApps) } finally { $script:Gui.Form.UseWaitCursor = $false }
    Set-GuiStatus ("Found {0} app(s) to make profiles of." -f $script:Gui.Apps.Count)
  }
  $state = New-ProfileDialog $Row
  try {
    Update-ProfilePreview $state
    [void]$state.Form.ShowDialog($script:Gui.Form)
  } finally {
    if ($state.Preview.Image) { $state.Preview.Image.Dispose() }
    $state.Form.Dispose()
    $script:Dialog = $null
  }
}

function Show-TwinbarWindow([switch] $InTray) {
  Initialize-Forms
  [Windows.Forms.Application]::EnableVisualStyles()
  try {
    $form = New-MainForm
    $g = $script:Gui
    # Twinbar runs until Quit, or until its window closes while it's not kept by the clock.
    $g.Context = New-Object Windows.Forms.ApplicationContext
    Add-TrayIcon
    # Another Twinbar.exe asks this one to show its window, or to quit.
    $g.ShowSignal = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::AutoReset, 'Local\Twinbar.App.Show')
    $g.QuitSignal = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::AutoReset, 'Local\Twinbar.App.Quit')
    $signals = New-Object Windows.Forms.Timer
    $signals.Interval = 300
    $signals.Add_Tick({
        $g = $script:Gui
        if ($g.QuitSignal.WaitOne(0)) { Write-WindowLog 'asked to quit'; Exit-TwinbarWindow }
        elseif ($g.ShowSignal.WaitOne(0)) { Write-WindowLog 'asked to show the window'; Show-MainWindow }
      })
    $g.SignalTimer = $signals
    $signals.Start()
    Write-WindowLog ("Twinbar $($script:TwinbarVersion) started" + $(if ($InTray) { ', by the clock' } else { '' }))
    if ($InTray) { Start-GuiBackground } else { $form.Show() }
    Update-JumpList
    [Windows.Forms.Application]::Run($g.Context)
  } catch {
    [void](Show-GuiMessage $null ("Twinbar couldn't open its window: " + $_.Exception.Message) 'OK' 'Error')
    throw
  }
}

function Show-Help {
  @"
Twinbar $($script:TwinbarVersion): a second, separately signed-in copy of an Electron app.

  twinbar new -App APP -Name NAME [-Color C] [-Badge B] [-Style S] [-Appearance A]
              [-Proxy P] [-DataDir DIR] [-AdoptDataDir] [-ShortcutDir DIR]
      Make a profile. APP is the app's .exe, install folder or Start menu
      shortcut, or a Microsoft Store app's name ("Claude"). Adds "<App> <Name>"
      to the Start menu; the app then keeps that profile's sign-in, settings
      and data in a folder of its own, with a taskbar button and icon of its own.
        -Color       $($script:Palette.Keys -join ', ') or #RRGGBB
                     (default: picked from the name)
        -Badge       1 or 2 letters or digits (default: the name's first letter)
        -Style       tint+badge (default), tint, badge, or original (the app's icon)
        -Appearance  system (default), light or dark, for apps that follow Windows
        -Proxy       socks5://host:port, http://host:port or https://host:port: the
                     profile's web traffic goes only through it (if it's down, the
                     profile is offline rather than going around it)
  twinbar change PROFILE [-Color C] [-Badge B] [-Style S] [-Appearance A] [-Proxy P]
      Change a profile's icon, appearance or proxy (-Proxy none removes it).
      Its name and data stay.
  twinbar ip [PROFILE] [-Json]
      Show the IP address a profile's traffic comes from (through its proxy),
      next to the one without a proxy.
  twinbar proxies [-Json]
      Find proxies running on this computer (v2rayN, Clash, NekoRay, ... on
      their usual ports) and the one Windows is set to use, and whether each
      gets out.
  twinbar rebuild PROFILE [-App APP]
  twinbar rebuild -All
      Make a profile's shortcut, icon and launcher again: after the app moved
      (give its new place with -App), after a Twinbar update, or if something
      was deleted.
  twinbar doctor [PROFILE]
      Check Twinbar and the profiles, and say how to fix what's wrong.
  twinbar list [-Json]
      Show the profiles.
  twinbar open PROFILE
      Start a profile.
  twinbar remove PROFILE [-DeleteData]
      Remove a profile's shortcut (to the Recycle Bin). Its sign-in is kept
      unless you add -DeleteData.
  twinbar apps [-Json]
      List the Electron apps found in the Start menu and the Microsoft Store.
  twinbar gui [-Tray]
      Open the Twinbar window, with its icon by the clock (right-click it for
      your profiles). -Tray starts with just the icon.
  twinbar settings [NAME on|off]
      Show or change Twinbar's settings: updates (check once a day), tray
      (closing the window keeps the icon by the clock) and startup (start
      with Windows, by the clock).
  twinbar install [-Dir DIR] [-AddToPath] [-ShortcutDir DIR]
      Install Twinbar for you (no admin rights): the Twinbar window in the
      Start menu, in $(Get-DefaultInstallDir) unless -Dir says otherwise.
      -AddToPath lets you type twinbar in any terminal.
  twinbar uninstall
      Remove the installed Twinbar. Profiles stay and keep working.
  twinbar update [-Check]
      Look for a newer Twinbar on GitHub and install it: its installer is
      downloaded, checked against the release's SHA-256 list, and run.
      -Check only says whether there is one. (The window checks once a day.)
  twinbar version

PROFILE is a name ("Work"), a full name ("Postman Work") or an id ("postman.work").
Profiles live in $(Get-TwinbarHome).
"@
}

# True when twinbar.cmd was double-clicked in Explorer (Explorer > cmd > PowerShell),
# rather than typed in a terminal.
function Test-StartedByDoubleClick {
  try {
    $me = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $PID"
    $parent = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($me.ParentProcessId)"
    if ($null -eq $parent -or $parent.Name -ine 'cmd.exe') { return $false }
    $grandparent = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($parent.ParentProcessId)"
    return ($null -ne $grandparent -and $grandparent.Name -ieq 'explorer.exe')
  } catch {
    return $false
  }
}

function Invoke-Twinbar {
  if (-not $script:CommandGiven -and (Test-StartedByDoubleClick)) {
    # A double-click on twinbar.cmd opens the window, not a flash of help text. The
    # window runs in a new process without a console, and this one ends, so no
    # console stays on screen (Windows Terminal doesn't let a console hide itself).
    $exe = Join-Path (Split-Path -Parent $script:SelfPath) 'Twinbar.exe'
    if (Test-Path -LiteralPath $exe) {
      Start-Process -FilePath $exe
    } else {
      Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -WindowStyle Hidden `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$($script:SelfPath)`"", 'gui')
    }
    return
  }
  $cmd = if ($Command) { $Command.Trim().ToLowerInvariant() } else { 'help' }
  switch ($cmd) {
    'new' {
      $profileName = if ($Name) { $Name } else { $Target }
      Invoke-New -AppPath $App -ProfileName $profileName -DataFolder $DataDir -Adopt:$AdoptDataDir -MenuDir $ShortcutDir `
        -ColorName $Color -BadgeText $Badge -StyleName $Style -AppearanceName $Appearance -ProxyValue $Proxy
    }
    'change' { Invoke-Change -Which $Target -ColorName $Color -BadgeText $Badge -StyleName $Style -AppearanceName $Appearance -ProxyValue $Proxy }
    'ip' { Invoke-Ip $Target -AsJson:$Json }
    'proxies' { Invoke-Proxies -AsJson:$Json }
    'update' { Invoke-Update -CheckOnly:$Check }
    'rebuild' { Invoke-Rebuild -Which $Target -AppPath $App -Every:$All }
    'doctor' { Invoke-Doctor $Target }
    'apps' { Invoke-Apps -AsJson:$Json }
    'gui' { Show-TwinbarWindow -InTray:$Tray }
    'settings' { Invoke-Settings $Target $Value }
    'install' { Invoke-Install -Folder $Dir -MenuDir $ShortcutDir -OnPath:$AddToPath }
    'uninstall' { Invoke-Uninstall -Folder $Dir }
    'list' { Invoke-List -AsJson:$Json }
    'open' { Invoke-Open $Target }
    'remove' { Invoke-Remove $Target -WithData:$DeleteData }
    'help' { Show-Help }
    'version' { "twinbar $script:TwinbarVersion" }
    default { Stop-Twinbar "unknown command '$Command' (see: twinbar help)" }
  }
}

# Run unless dot-sourced (the tests dot-source this file to reach its functions).
if ($MyInvocation.InvocationName -ne '.') {
  try {
    Invoke-Twinbar
    exit 0
  } catch {
    [Console]::Error.WriteLine('twinbar: ' + $_.Exception.Message)
    exit 1
  }
}
