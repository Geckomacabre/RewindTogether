using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace RewindTogether.Launcher;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        FitToWorkArea();
        SourceInitialized += (_, _) => ApplyDarkTitleBar();
    }

    /// <summary>
    /// On a 1280x800 screen the taskbar leaves about 750 px, less than the default 790: shrink to
    /// fit instead of hanging under the taskbar. The cards scroll if they need to.
    /// </summary>
    private void FitToWorkArea()
    {
        var wa = SystemParameters.WorkArea;
        MinWidth = Math.Min(MinWidth, wa.Width);
        MinHeight = Math.Min(MinHeight, wa.Height);
        if (Width > wa.Width - 8) Width = Math.Max(MinWidth, wa.Width - 8);
        if (Height > wa.Height - 8) Height = Math.Max(MinHeight, wa.Height - 8);
    }

    /// <summary>Called when a second launcher hands us its arguments.</summary>
    public void BringToFront()
    {
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
        Topmost = true;
        Topmost = false;
        Focus();
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    /// <summary>Dark native title bar tinted to the theme (Windows 11; silently ignored elsewhere).</summary>
    private void ApplyDarkTitleBar()
    {
        try
        {
            IntPtr hwnd = new WindowInteropHelper(this).Handle;
            int on = 1;
            DwmSetWindowAttribute(hwnd, 20, ref on, sizeof(int));        // DWMWA_USE_IMMERSIVE_DARK_MODE
            int caption = 0x001A0A0B;                                      // COLORREF 0x00BBGGRR = #0B0A1A
            DwmSetWindowAttribute(hwnd, 35, ref caption, sizeof(int));   // DWMWA_CAPTION_COLOR
            int text = 0x00FFF1F4;                                         // #F4F1FF
            DwmSetWindowAttribute(hwnd, 36, ref text, sizeof(int));      // DWMWA_TEXT_COLOR
            int border = 0x00A53EFF;                                       // #FF3EA5
            DwmSetWindowAttribute(hwnd, 34, ref border, sizeof(int));    // DWMWA_BORDER_COLOR
        }
        catch
        {
            // Older Windows: keep the default title bar.
        }
    }
}
