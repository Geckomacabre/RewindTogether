using System.Windows;
using System.Windows.Threading;
using RewindTogether.Launcher.Core;
using RewindTogether.Launcher.Steam;
using RewindTogether.Launcher.UI;

namespace RewindTogether.Launcher;

/// <summary>
/// One exe, two jobs:
///   RewindTogetherLauncher.exe [--host | --join id]  - the launcher window
///   RewindTogetherLauncher.exe --steam-agent ...     - the headless Steam helper (see SteamAgent)
/// </summary>
public static class Program
{
    [STAThread]
    public static int Main(string[] argv)
    {
        var args = LaunchArgs.Parse(argv);
        var paths = new AppPaths(args.DataDir);
        try { paths.EnsureCreated(); } catch { }

        if (args.SteamAgent)
        {
            Log.Init(paths.AgentLogFile);
            if (string.IsNullOrWhiteSpace(args.SteamDll))
            {
                Console.Out.WriteLine("{\"evt\":\"fatal\",\"code\":\"dll_missing\",\"message\":\"No Steam library path was given.\"}");
                return 2;
            }
            return SteamAgent.RunProcess(args.SteamDll);
        }

        Log.Init(paths.LogFile);
        Log.Info($"Launcher {AppInfo.Version} starting: {string.Join(' ', argv)}");
        foreach (var p in args.Problems) Log.Warn(p);

        // One launcher per user (per data folder, so a --data-dir test copy can run beside the real one).
        using var single = new SingleInstance(paths.DataDir);
        if (!single.TryAcquire())
        {
            if (single.Forward(args.ForwardableArgs(), TimeSpan.FromSeconds(3)))
            {
                Log.Info("Another launcher is already open; handed the request to it.");
                return 0;
            }
            MessageBox.Show("Rewind Together Launcher is already open but is not responding.\n\n" +
                            "Close it from the taskbar (or Task Manager) and try again.",
                "Rewind Together", MessageBoxButton.OK, MessageBoxImage.Warning);
            return 1;
        }

        var app = new App();
        app.InitializeComponent();
        app.DispatcherUnhandledException += OnUiException;
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Log.Error("Unhandled: " + e.ExceptionObject);
        TaskScheduler.UnobservedTaskException += (_, e) => { Log.Error("Unobserved task error", e.Exception); e.SetObserved(); };

        var vm = new MainViewModel(paths, args);
        var window = new MainWindow { DataContext = vm };
        single.Listen(forwarded => app.Dispatcher.InvokeAsync(() =>
        {
            window.BringToFront();
            vm.HandleForwardedArgs(LaunchArgs.Parse(forwarded));
        }));
        window.Loaded += async (_, _) => await vm.StartAsync();
        window.Closing += (_, e) => vm.OnClosing(e);
        int code = app.Run(window);
        vm.Dispose();
        Log.Info("Launcher closed.");
        return code;
    }

    private static void OnUiException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        Log.Error("UI error", e.Exception);
        MessageBox.Show("Something went wrong inside the launcher:\n\n" + e.Exception.Message +
                        "\n\nThe launcher will keep running. If this keeps happening, use Diagnostics > Copy diagnostics and share it.",
            "Rewind Together", MessageBoxButton.OK, MessageBoxImage.Error);
        e.Handled = true;
    }
}
