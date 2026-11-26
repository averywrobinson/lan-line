using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using LanLine.Core;

namespace LanLine.App;

/// <summary>
/// Clipboard sharing (beta.10): copy on this PC, paste on the other computer, and the other way round. Off until turned
/// on in Settings. Windows tells us about each change (AddClipboardFormatListener); copies that ask to stay out of
/// clipboard history or monitors (password managers do) are never sent, nothing is queued or kept, and what just
/// arrived is never sent back. Pictures go as PNG up to 10 MB; files are left to the normal send.
/// </summary>
sealed partial class MainWindow
{
    [DllImport("user32.dll", SetLastError = true)] static extern bool AddClipboardFormatListener(IntPtr hwnd);
    [DllImport("user32.dll", SetLastError = true)] static extern bool RemoveClipboardFormatListener(IntPtr hwnd);
    [DllImport("user32.dll")] static extern uint GetClipboardSequenceNumber();
    const int WM_CLIPBOARDUPDATE = 0x031D;

    bool _clipListening, _clipHooked, _clipPaused, _clipToldOld;
    uint _clipIgnoreSeq;
    string? _clipLastFingerprint;
    System.Windows.Threading.DispatcherTimer? _clipSettle;

    /// <summary>Start or stop listening to match the setting (at start and after Save).</summary>
    void ApplyClipboardShare()
    {
        if (_demo) return;
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero) return;
        if (!_clipHooked) { HwndSource.FromHwnd(hwnd)?.AddHook(WatchClipboard); _clipHooked = true; }
        if (_storage.ShareClipboardValue && !_clipListening) { _clipListening = AddClipboardFormatListener(hwnd); _clipIgnoreSeq = GetClipboardSequenceNumber(); }
        else if (!_storage.ShareClipboardValue && _clipListening) { RemoveClipboardFormatListener(hwnd); _clipListening = false; _clipPaused = false; }
    }

    IntPtr WatchClipboard(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg != WM_CLIPBOARDUPDATE) return IntPtr.Zero;
        // Apps put several formats on the clipboard one after another: read it once things settle.
        _clipSettle ??= new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(120) };
        _clipSettle.Stop();
        _clipSettle.Tick -= ClipChanged; _clipSettle.Tick += ClipChanged;
        _clipSettle.Start();
        return IntPtr.Zero;
    }

    void ClipChanged(object? s, EventArgs e)
    {
        _clipSettle?.Stop();
        if (GetClipboardSequenceNumber() == _clipIgnoreSeq || _hub == null) return;   // what we just put there
        ClipContent? content = null;
        string[] formats = [];
        var excluded = false;
        for (var attempt = 0; attempt < 2 && content == null; attempt++)
        {
            try
            {
                var data = Clipboard.GetDataObject();
                formats = data?.GetFormats(false) ?? [];
                if (formats.Contains("CanIncludeInClipboardHistory") && data!.GetData("CanIncludeInClipboardHistory") is MemoryStream ms && ms.Length >= 4)
                    excluded = BitConverter.ToInt32(ms.ToArray(), 0) == 0;
                if (Clipboard.ContainsFileDropList()) return;
                if (Clipboard.ContainsText()) content = new ClipContent.TextClip(Clipboard.GetText());
                else if (_storage.ShareClipboardPicturesValue && Clipboard.ContainsImage() && Clipboard.GetImage() is { } img)
                {
                    var enc = new PngBitmapEncoder();
                    enc.Frames.Add(BitmapFrame.Create(img));
                    using var png = new MemoryStream();
                    enc.Save(png);
                    content = new ClipContent.PngClip(png.ToArray());
                }
                else return;
            }
            catch (Exception) { Thread.Sleep(60); }   // another app still has the clipboard open
        }
        if (!ClipRules.ShouldSend(content, formats, _storage.ShareClipboardValue, _clipPaused, _storage.ShareClipboardPicturesValue, _clipLastFingerprint, excluded)) return;
        _clipLastFingerprint = ClipRules.Fingerprint(content!);
        _hub.SendClip(content!, (sent, tooOld) => Dispatcher.BeginInvoke(() =>
        {
            if (sent > 0 || tooOld == 0 || _clipToldOld) return;
            _clipToldOld = true;
            Note("To share the clipboard, update Lan-Line on the other computer too.", 10);
        }));
    }

    /// <summary>A partner's clipboard arrived: put it on this PC's clipboard, and don't send it straight back.</summary>
    void ClipReceived(ClipContent c)
    {
        if (!_storage.ShareClipboardValue || _clipPaused) return;
        if (c is ClipContent.PngClip && !_storage.ShareClipboardPicturesValue) return;
        try
        {
            switch (c)
            {
                case ClipContent.TextClip t: Clipboard.SetText(t.Text); break;
                case ClipContent.PngClip p:
                    var dec = BitmapDecoder.Create(new MemoryStream(p.Data), BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
                    var dobj = new DataObject();
                    dobj.SetImage(dec.Frames[0]);
                    dobj.SetData("PNG", new MemoryStream(p.Data));   // apps that read PNG get the original
                    Clipboard.SetDataObject(dobj, true);
                    break;
            }
            _clipIgnoreSeq = GetClipboardSequenceNumber();
            _clipLastFingerprint = ClipRules.Fingerprint(c);
        }
        catch (Exception) { /* the clipboard is busy: this one is skipped */ }
    }
}
