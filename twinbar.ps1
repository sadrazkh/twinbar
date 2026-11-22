<#
.SYNOPSIS
Twinbar: a second, separately signed-in copy of an Electron app on Windows.

.DESCRIPTION
  twinbar new -App APP -Name NAME [-Color C] [-Badge B] [-Style S] [-Appearance A]
              [-DataDir DIR] [-AdoptDataDir] [-ShortcutDir DIR]
  twinbar change PROFILE [-Color C] [-Badge B] [-Style S] [-Appearance A]
  twinbar rebuild PROFILE [-App APP] | twinbar rebuild -All
  twinbar doctor [PROFILE]
  twinbar list [-Json]
  twinbar open PROFILE
  twinbar remove PROFILE [-DeleteData]
  twinbar apps [-Json]
  twinbar gui
  twinbar install [-Dir DIR] [-AddToPath] [-ShortcutDir DIR]
  twinbar uninstall
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
  [string] $App,
  [string] $Name,
  [string] $Color,
  [string] $Badge,
  [string] $Style,
  [string] $Appearance,
  [string] $DataDir,
  [switch] $AdoptDataDir,
  [string] $ShortcutDir,
  [switch] $DeleteData,
  [switch] $All,
  [string] $Dir,
  [switch] $AddToPath,
  [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TwinbarVersion = '0.5.1'
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
  'dataDir', 'shortcut', 'aumid', 'launcher', 'style', 'color', 'badge', 'appearance', 'extraArgs',
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
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

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
    static string launchExe, appKind, packageApp, exeBaseName, extraArgs, dataDir;
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

    [STAThread]
    public static int Main(string[] args) {
      SetCurrentProcessExplicitAppUserModelID("Twinbar.App");
      SetProcessDPIAware();
      try {
        bool first;
        using (Mutex single = new Mutex(true, "Local\\Twinbar.App", out first)) {
          if (!first) {
            // Already open: bring that window forward instead.
            Process me = Process.GetCurrentProcess();
            foreach (Process p in Process.GetProcessesByName(me.ProcessName)) {
              if (p.Id != me.Id && p.MainWindowHandle != IntPtr.Zero) {
                ShowWindow(p.MainWindowHandle, 9); // SW_RESTORE
                SetForegroundWindow(p.MainWindowHandle);
              }
            }
            return 0;
          }
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
  $Record.extraArgs = $script:Appearances[$Record.appearance]
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
    [string] $ColorName, [string] $BadgeText, [string] $StyleName, [string] $AppearanceName
  )

  $label = Test-ProfileName $ProfileName
  $look = Resolve-Style $StyleName
  $badgeValue = Get-BadgeText $BadgeText $label
  $appearanceValue = Resolve-Appearance $AppearanceName
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
  param([string] $Which, [string] $ColorName, [string] $BadgeText, [string] $StyleName, [string] $AppearanceName)
  if (-not ($ColorName -or $BadgeText -or $StyleName -or $AppearanceName)) {
    Stop-Twinbar 'nothing to change; give -Color, -Badge, -Style or -Appearance'
  }
  $p = Find-Profile $Which
  Assert-NotRunning $p
  $record = ConvertTo-ProfileTable $p
  if ($StyleName) { $record.style = Resolve-Style $StyleName }
  if ($ColorName) { $record.color = Resolve-ProfileColor $ColorName $record.id }
  if ($BadgeText) { $record.badge = Get-BadgeText $BadgeText $record.name }
  if ($AppearanceName) { $record.appearance = Resolve-Appearance $AppearanceName }
  $pins = Publish-Profile $record
  "Changed ""$($record.appName) $($record.name)"": $(Get-LookNote $record)."
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
  foreach ($name in 'Edit', 'Open', 'Remove', 'Repair') { $script:Gui.Buttons[$name].Enabled = $has }
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

  $script:Gui = @{ Form = $form; List = $list; Images = $images; Status = $statusText; Rows = @(); Apps = $null; Buttons = @{} }
  $g = $script:Gui
  $g.Buttons.New = New-GuiButton 'New profile...' { Show-ProfileDialog $null }
  $g.Buttons.Edit = New-GuiButton 'Edit...' { $row = Get-SelectedRow; if ($row) { Show-ProfileDialog $row } }
  $g.Buttons.Open = New-GuiButton 'Open' { Open-SelectedProfile }
  $g.Buttons.Remove = New-GuiButton 'Remove...' { $row = Get-SelectedRow; if ($row) { Show-RemoveDialog $row } }
  $g.Buttons.Repair = New-GuiButton 'Repair' { Repair-SelectedProfile }
  $g.Buttons.Check = New-GuiButton 'Check all' { Show-CheckDialog }
  foreach ($name in 'New', 'Edit', 'Open', 'Remove', 'Repair', 'Check') { $buttons.Controls.Add($g.Buttons[$name]) }

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
  $timer.Add_Tick({ Update-ProfileList -Quiet })
  $g.Timer = $timer
  $form.Add_Shown({
      Update-ProfileList
      if ($script:Gui.Rows.Count) { Set-GuiStatus ('{0} profile(s). Double-click one to open it.' -f $script:Gui.Rows.Count) }
      $script:Gui.Timer.Start()
    })
  $form.Add_FormClosed({ $script:Gui.Timer.Stop(); $script:Gui.Timer.Dispose() })
  return $form
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
  $preview = New-Object Windows.Forms.PictureBox
  $preview.Size = New-Object Drawing.Size((Get-Scaled 128), (Get-Scaled 128))
  $preview.SizeMode = 'Zoom'
  $preview.Margin = New-Object Windows.Forms.Padding((Get-Scaled 16), 0, 0, 0)
  $hint = New-Object Windows.Forms.Label
  $hint.Text = "Leave the badge empty for the name's first letter. Light and dark work for apps that follow Windows."
  $hint.AutoSize = $true
  $hint.MaximumSize = New-Object Drawing.Size(($wide + (Get-Scaled 90)), 0)
  $hint.ForeColor = [Drawing.SystemColors]::GrayText

  $rowIndex = 0
  foreach ($pair in @(@('App', $appRow), @('Name', $name), @('Colour', $color), @('Badge', $badge), @('Icon', $style), @('Appearance', $appearance))) {
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
  $grid.SetRowSpan($preview, 6)
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
    Badge = $badge; Style = $style; Appearance = $appearance; Preview = $preview; Ok = $ok; ColorPicked = $false; Updating = $true
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

# Makes or changes the profile from the dialog's fields; returns whether it worked.
function Submit-ProfileDialog($State) {
  $hex = Get-ColorItemHex ([string]$State.Color.SelectedItem)
  $look = $script:StyleNames[[string]$State.Style.SelectedItem]
  $theme = $script:AppearanceNames[[string]$State.Appearance.SelectedItem]
  if ($State.Row) {
    $id = $State.Row.Id
    $letters = Get-DialogBadge $State
    return (Invoke-GuiAction { Invoke-Change -Which $id -ColorName $hex -BadgeText $letters -StyleName $look -AppearanceName $theme } $State.Form)
  }
  $chosen = Get-DialogApp $State
  if (-not $chosen) {
    [void](Show-GuiMessage $State.Form 'Pick an app first, or find it with "Find...".')
    return $false
  }
  $source = $chosen.Source
  $label = $State.Name.Text
  $letters = $State.Badge.Text.Trim()
  return (Invoke-GuiAction { Invoke-New -AppPath $source -ProfileName $label -ColorName $hex -BadgeText $letters -StyleName $look -AppearanceName $theme } $State.Form)
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

function Show-TwinbarWindow {
  Initialize-Forms
  [Windows.Forms.Application]::EnableVisualStyles()
  try {
    $form = New-MainForm
    [Windows.Forms.Application]::Run($form)
  } catch {
    [void](Show-GuiMessage $null ("Twinbar couldn't open its window: " + $_.Exception.Message) 'OK' 'Error')
    throw
  }
}

function Show-Help {
  @"
Twinbar $($script:TwinbarVersion): a second, separately signed-in copy of an Electron app.

  twinbar new -App APP -Name NAME [-Color C] [-Badge B] [-Style S] [-Appearance A]
              [-DataDir DIR] [-AdoptDataDir] [-ShortcutDir DIR]
      Make a profile. APP is the app's .exe, install folder or Start menu
      shortcut, or a Microsoft Store app's name ("Claude"). Adds "<App> <Name>"
      to the Start menu; the app then keeps that profile's sign-in, settings
      and data in a folder of its own, with a taskbar button and icon of its own.
        -Color       $($script:Palette.Keys -join ', ') or #RRGGBB
                     (default: picked from the name)
        -Badge       1 or 2 letters or digits (default: the name's first letter)
        -Style       tint+badge (default), tint, badge, or original (the app's icon)
        -Appearance  system (default), light or dark, for apps that follow Windows
  twinbar change PROFILE [-Color C] [-Badge B] [-Style S] [-Appearance A]
      Change a profile's icon or appearance. Its name and data stay.
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
  twinbar gui
      Open the Twinbar window.
  twinbar install [-Dir DIR] [-AddToPath] [-ShortcutDir DIR]
      Install Twinbar for you (no admin rights): the Twinbar window in the
      Start menu, in $(Get-DefaultInstallDir) unless -Dir says otherwise.
      -AddToPath lets you type twinbar in any terminal.
  twinbar uninstall
      Remove the installed Twinbar. Profiles stay and keep working.
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
        -ColorName $Color -BadgeText $Badge -StyleName $Style -AppearanceName $Appearance
    }
    'change' { Invoke-Change -Which $Target -ColorName $Color -BadgeText $Badge -StyleName $Style -AppearanceName $Appearance }
    'rebuild' { Invoke-Rebuild -Which $Target -AppPath $App -Every:$All }
    'doctor' { Invoke-Doctor $Target }
    'apps' { Invoke-Apps -AsJson:$Json }
    'gui' { Show-TwinbarWindow }
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
