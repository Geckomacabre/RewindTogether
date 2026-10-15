using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;

namespace RewindTogether.Launcher.UI;

public abstract class ObservableObject : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Raise(name);
        return true;
    }

    protected void Raise([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    protected void RaiseAll() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
}

public sealed class RelayCommand : ICommand
{
    private readonly Action<object?> _run;
    private readonly Func<object?, bool>? _can;

    public RelayCommand(Action<object?> run, Func<object?, bool>? can = null)
    {
        _run = run;
        _can = can;
    }

    public RelayCommand(Action run, Func<bool>? can = null) : this(_ => run(), can == null ? null : _ => can()) { }

    public event EventHandler? CanExecuteChanged
    {
        add => CommandManager.RequerySuggested += value;
        remove => CommandManager.RequerySuggested -= value;
    }

    public bool CanExecute(object? p) => _can?.Invoke(p) ?? true;
    public void Execute(object? p) => _run(p);
}

/// <summary>An async command that disables itself while running and never lets an exception escape to the dispatcher.</summary>
public sealed class AsyncCommand : ICommand
{
    private readonly Func<object?, Task> _run;
    private readonly Func<object?, bool>? _can;
    private bool _running;

    public AsyncCommand(Func<object?, Task> run, Func<object?, bool>? can = null)
    {
        _run = run;
        _can = can;
    }

    public AsyncCommand(Func<Task> run, Func<bool>? can = null) : this(_ => run(), can == null ? null : _ => can()) { }

    public static Action<Exception>? OnError { get; set; }

    public event EventHandler? CanExecuteChanged
    {
        add => CommandManager.RequerySuggested += value;
        remove => CommandManager.RequerySuggested -= value;
    }

    public bool CanExecute(object? p) => !_running && (_can?.Invoke(p) ?? true);

    public async void Execute(object? p)
    {
        if (_running) return;
        _running = true;
        CommandManager.InvalidateRequerySuggested();
        try
        {
            await _run(p);
        }
        catch (Exception ex)
        {
            Core.Log.Error("Unhandled error in a command", ex);
            OnError?.Invoke(ex);
        }
        finally
        {
            _running = false;
            CommandManager.InvalidateRequerySuggested();
        }
    }
}

// ---------------------------------------------------------------------------------- converters

public sealed class BoolToVisibilityConverter : IValueConverter
{
    public bool Invert { get; set; }

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        bool b = value switch
        {
            bool x => x,
            string s => !string.IsNullOrWhiteSpace(s),
            int i => i != 0,
            System.Collections.ICollection c => c.Count > 0,
            null => false,
            _ => true,
        };
        if (Invert) b = !b;
        return b ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => Binding.DoNothing;
}

/// <summary>"ok" | "warn" | "bad" | "info" | "idle" → brush from the theme.</summary>
public sealed class ToneToBrushConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        string key = (value as string) switch
        {
            "ok" => "GreenBrush",
            "warn" => "YellowBrush",
            "bad" => "RedBrush",
            "info" => "CyanBrush",
            "pink" => "PinkBrush",
            _ => "TextFaintBrush",
        };
        return Application.Current.TryFindResource(key) as Brush ?? Brushes.Gray;
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => Binding.DoNothing;
}

public sealed class FirstLetterConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        string s = (value as string ?? "").Trim();
        return s.Length == 0 ? "?" : char.ToUpperInvariant(s[0]).ToString();
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => Binding.DoNothing;
}
