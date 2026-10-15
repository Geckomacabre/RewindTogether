using System.Windows.Controls;

namespace RewindTogether.Launcher.UI;

public partial class PlayView : UserControl
{
    public PlayView() => InitializeComponent();

    /// <summary>Re-read the save folder each time the picker opens, so "last played" is current.</summary>
    private void OnSaveSlotsOpening(object? sender, EventArgs e) => (DataContext as PlayViewModel)?.RefreshSaveSlots();
}
