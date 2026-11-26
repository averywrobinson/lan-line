using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using LanLine.Core;

namespace LanLine.App;

/// <summary>
/// The notification-area (tray) icon (beta.9). With "Keep running in the tray" on (the default), closing the window
/// hides it and takes it off the taskbar; Lan-Line keeps receiving, and an arriving item still brings the window
/// back. Click the icon to show the window; right-click for the menu, whose Exit really quits. The icon is the app
/// icon, greyed while no computer is connected.
/// </summary>
sealed partial class MainWindow
{
    System.Windows.Forms.NotifyIcon? _tray;
    System.Drawing.Icon? _trayOn, _trayOff;
    bool _quitting, _trayDemo;
    /// <summary>The close came from the user (close button, Alt+F4, the taskbar's Close window), not from another
    /// program: a bare WM_CLOSE (the installer's taskkill, Restart Manager) still quits, so updates never stall.</summary>
    bool _userClose;

    bool KeepRunning => _storage.KeepRunningWhenClosedValue;

    /// <summary>Show or remove the tray icon to match the setting. Called at start and after Save.</summary>
    void ApplyKeepRunning()
    {
        if (KeepRunning && _tray == null)
        {
            LoadTrayIcons();
            _tray = new System.Windows.Forms.NotifyIcon { Icon = _trayOff, Text = "Lan-Line", Visible = true };
            _tray.MouseClick += (_, e) =>
            {
                if (e.Button == System.Windows.Forms.MouseButtons.Left) ShowFromTray();
                else if (e.Button == System.Windows.Forms.MouseButtons.Right) OpenTrayMenu();
            };
            // the fallback when Windows refuses toasts (beta.10): a click shows the window at that item
            _tray.BalloonTipClicked += (_, _) => { var id = _balloonItem; _balloonItem = null; HandleLink(ArrivalNotices.Link(NoticeAction.Show, id)); };
            RefreshTray();
        }
        else if (!KeepRunning && _tray != null)
        {
            RemoveTray();
            if (!IsVisible) ShowFromTray();   // never leave a hidden window with no way back
        }
    }

    void RemoveTray()
    {
        if (_tray == null) return;
        _tray.Visible = false;
        _tray.Dispose();
        _tray = null;
    }

    /// <summary>Close button, Alt+F4 or the taskbar's Close window: hide to the tray, unless the setting is off or
    /// Lan-Line is really quitting (Exit, sign-out, shutdown).</summary>
    void OnClosing(object? sender, CancelEventArgs e)
    {
        var user = _userClose;
        _userClose = false;
        if (_quitting || _tray == null || !user) return;
        e.Cancel = true;
        HideToTray();
    }

    /// <summary>The close button.</summary>
    void UserClose()
    {
        _userClose = true;
        Close();
    }

    const int WM_SYSCOMMAND = 0x0112, SC_CLOSE = 0xF060;

    /// <summary>Alt+F4 and the taskbar's Close window arrive as SC_CLOSE before their WM_CLOSE.</summary>
    IntPtr WatchCloseCommands(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_SYSCOMMAND && ((int)wParam & 0xFFF0) == SC_CLOSE) _userClose = true;
        return IntPtr.Zero;
    }

    void HideToTray()
    {
        Hide();
        if (_storage.TrayHintShown || _trayDemo) return;
        _balloonItem = null;
        _tray?.ShowBalloonTip(8000, "Lan-Line is still running",
            "It keeps receiving in the notification area by the clock (under ^ if Windows tucked it away). Right-click it to exit.",
            System.Windows.Forms.ToolTipIcon.None);
        _storage.TrayHintShown = true;
        try { _storage.Save(SettingsPath); } catch (Exception) { }
    }

    void ShowFromTray()
    {
        Show();
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
        _input.Focus();
    }

    /// <summary>Exit from the tray menu: really quit.</summary>
    void Quit()
    {
        _quitting = true;
        Close();
    }

    /// <summary>Keep the icon and its tooltip in step with the status line (called from RefreshStatus).</summary>
    void RefreshTray()
    {
        if (_tray == null) return;
        _tray.Icon = TrayIconNow();
        var text = _unread.Phrase is { } p ? $"Lan-Line · {p} · {_status.Text}" : $"Lan-Line · {_status.Text}";
        _tray.Text = text.Length > 120 ? text[..119] + "…" : text;
    }

    ContextMenu TrayMenu()
    {
        var m = new ContextMenu();
        var line = _unread.Phrase is { } p ? $"{p} · {_status.Text}" : _status.Text;
        m.Items.Add(new MenuItem { Header = new TextBlock { Text = line }, IsEnabled = false });   // no _ access keys
        m.Items.Add(new Separator());
        Add("Show Lan-Line", ShowFromTray);
        Add("Pair with another computer…", () => { ShowFromTray(); if (_hub != null) BeginPairing(show: false); });
        Add("Settings…", () => { ShowFromTray(); ShowSettings(); });
        Add("Check for updates…", () => _ = CheckForUpdates(manual: true));
        if (_storage.ShareClipboardValue)
        {
            var pause = new MenuItem { Header = "Pause clipboard sharing", IsCheckable = true, IsChecked = _clipPaused };
            pause.Click += (_, _) => _clipPaused = pause.IsChecked;
            m.Items.Add(pause);
        }
        m.Items.Add(new Separator());
        Add("Exit Lan-Line", Quit);
        return m;

        void Add(string header, Action act)
        {
            var mi = new MenuItem { Header = header };
            mi.Click += (_, _) => act();
            m.Items.Add(mi);
        }
    }

    void OpenTrayMenu()
    {
        var m = TrayMenu();
        m.Placement = PlacementMode.MousePoint;
        m.IsOpen = true;
        // A menu opened from the tray only closes on an outside click if its own window is in front.
        if (PresentationSource.FromVisual(m) is HwndSource src) SetForegroundWindow(src.Handle);
    }

    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr hIcon);

    /// <summary>The app icon at the tray's size, and a greyed, fainter copy for "no computer connected".</summary>
    void LoadTrayIcons()
    {
        if (_trayOn != null) return;
        var size = System.Windows.Forms.SystemInformation.SmallIconSize;
        using (var s = Application.GetResourceStream(new Uri("pack://application:,,,/Lan-Line;component/LanLine.ico")).Stream)
            _trayOn = new System.Drawing.Icon(s, size);
        using var src = _trayOn.ToBitmap();
        using var dim = new System.Drawing.Bitmap(src.Width, src.Height);
        using (var g = System.Drawing.Graphics.FromImage(dim))
        {
            // Greyscale at 55 % opacity.
            var cm = new System.Drawing.Imaging.ColorMatrix(
            [
                [0.30f, 0.30f, 0.30f, 0, 0],
                [0.59f, 0.59f, 0.59f, 0, 0],
                [0.11f, 0.11f, 0.11f, 0, 0],
                [0, 0, 0, 0.55f, 0],
                [0, 0, 0, 0, 1],
            ]);
            using var ia = new System.Drawing.Imaging.ImageAttributes();
            ia.SetColorMatrix(cm);
            g.DrawImage(src, new System.Drawing.Rectangle(0, 0, src.Width, src.Height), 0, 0, src.Width, src.Height, System.Drawing.GraphicsUnit.Pixel, ia);
        }
        var h = dim.GetHicon();
        _trayOff = (System.Drawing.Icon)System.Drawing.Icon.FromHandle(h).Clone();
        DestroyIcon(h);
    }

    internal void PrepareToQuit() => _quitting = true;
    internal void ShowFromTrayForTest() => ShowFromTray();
    internal void UserCloseForTest() => UserClose();

    /// <summary>--demo: show the tray icon too (screenshots), without the one-time note.</summary>
    internal void DemoTray()
    {
        _trayDemo = true;
        ApplyKeepRunning();
    }
}
