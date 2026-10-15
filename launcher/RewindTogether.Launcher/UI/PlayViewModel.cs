using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Input;
using RewindTogether.Launcher.Core;
using RewindTogether.Launcher.Steam;

namespace RewindTogether.Launcher.UI;

public sealed class FriendItem : ObservableObject
{
    public FriendItem(FriendInfo f, ICommand join, ICommand invite)
    {
        Info = f;
        JoinCommand = join;
        InviteCommand = invite;
    }

    public FriendInfo Info { get; }
    public string Name => string.IsNullOrWhiteSpace(Info.Name) ? Info.Id.ToString() : Info.Name;
    public string StateText => Info.Hosting ? "Store open - ready to join" : Info.InGame ? "Playing Retro Rewind" : "Online";
    public bool Hosting => Info.Hosting;
    public ICommand JoinCommand { get; }
    public ICommand InviteCommand { get; }
}

public sealed record GuestItem(string Name, string Link, string Traffic, string Tone);

/// <summary>One row of the "which save to host" picker. Slot is null for "choose in the game".</summary>
public sealed class SaveSlotOption : ObservableObject
{
    private string _label;

    public SaveSlotOption(string? slot, string label)
    {
        Slot = slot;
        _label = label;
    }

    /// <summary>"Player_Save1".."Player_Save5", or null = let the player pick in the game.</summary>
    public string? Slot { get; }
    public string Label { get => _label; set => Set(ref _label, value); }
    /// <summary>"Save 3" for status lines.</summary>
    public string ShortName => Slot == null ? "your save" : $"Save {SaveSlotNames.NumberOf(Slot)}";
}

/// <summary>
/// The Play tab: the setup line, HOST and JOIN, and the live session display. Owns the Steam
/// helper process for the session (see SteamAgent for why it is a separate process).
/// </summary>
public sealed class PlayViewModel : ObservableObject, IDisposable
{
    private enum SessionKind { None, Host, JoinSteam, JoinDirect }

    private readonly MainViewModel _main;
    private SteamAgentClient? _agent;
    private bool _agentStarting;
    private bool _steamFailedThisSession;
    private SessionKind _session;
    private CancellationTokenSource _sessionCts = new();
    private DateTime _sessionStartedAt;
    private DateTime? _requestWrittenAt;
    private bool _sawGameRunning;
    private bool _presenceOn;
    private ulong _joinHost;
    private string _joinName = "";
    private AgentStats? _lastStats;
    private bool _wasConnected;
    private SaveSlotOption? _hostSlot;

    public PlayViewModel(MainViewModel main)
    {
        _main = main;
        HostCommand = new AsyncCommand(HostAsync, () => !FriendsLoading);
        StopCommand = new AsyncCommand(() => EndSessionAsync("Session stopped.", userStopped: true), () => InSession);
        // Not while a session is waiting for the game to start: a temporary Steam helper registering
        // as Retro Rewind at the same moment Steam is launching the real game is asking for trouble.
        RefreshFriendsCommand = new AsyncCommand(RefreshFriendsAsync, () => !FriendsLoading && !(InSession && !_main.GameRunning && _agent == null));
        JoinAddressCommand = new AsyncCommand(JoinAddressAsync, () => !FriendsLoading);
        JoinSteamIdCommand = new AsyncCommand(JoinSteamIdAsync, () => !FriendsLoading);
        JoinFriendCommand = new AsyncCommand(p => p is FriendItem f ? JoinSteamAsync(f.Info.Id, f.Name) : Task.CompletedTask, _ => !FriendsLoading);
        InviteFriendCommand = new RelayCommand(p => Invite(p as FriendItem), _ => _agent?.IsRunning == true && _session == SessionKind.Host);
        SetupCommand = new AsyncCommand(SetupAsync);
        ToggleOtherWaysCommand = new RelayCommand(() => OtherWaysOpen = !OtherWaysOpen);
        _joinAddress = main.Settings.LastJoinAddress ?? "";
        _joinSteamId = main.Settings.LastJoinSteamId ?? "";

        // "Choose my save in the game" is the default and writes no slot (LAUNCHER_CONTRACT.md §1).
        SaveSlotOptions.Add(new SaveSlotOption(null, "Choose my save in the game"));
        for (int n = 1; n <= SaveSlotNames.Count; n++)
            SaveSlotOptions.Add(new SaveSlotOption(SaveSlotNames.ForNumber(n), $"Save {n}"));
        _selectedSaveSlot = SaveSlotOptions[0];
        RefreshSaveSlots();
    }

    // ================================================================== which save to host

    private SaveSlotOption _selectedSaveSlot;

    public ObservableCollection<SaveSlotOption> SaveSlotOptions { get; } = new();

    public SaveSlotOption SelectedSaveSlot
    {
        get => _selectedSaveSlot;
        set => Set(ref _selectedSaveSlot, value ?? SaveSlotOptions[0]);
    }

    /// <summary>Re-reads the save folder so each row says "last played ..." or "empty" (labels change in place).</summary>
    public void RefreshSaveSlots()
    {
        foreach (var info in SaveSlots.Read(_main.Paths.SaveGamesDir))
        {
            var option = SaveSlotOptions.FirstOrDefault(o => o.Slot == info.Slot);
            if (option != null) option.Label = info.Label();
        }
    }

    // ================================================================== setup strip

    // One line and at most one button: the launcher does the steps itself (MainViewModel.SetUpAsync).
    private string _setupText = "", _setupDetail = "", _setupButton = "", _setupTone = "idle", _setupIcon = "", _buildWarning = "";

    public string SetupText { get => _setupText; private set => Set(ref _setupText, value); }
    public string SetupDetail { get => _setupDetail; private set => Set(ref _setupDetail, value); }
    /// <summary>The one button's caption; empty hides it.</summary>
    public string SetupButton { get => _setupButton; private set => Set(ref _setupButton, value); }
    public string SetupTone { get => _setupTone; private set => Set(ref _setupTone, value); }
    public string SetupIcon { get => _setupIcon; private set => Set(ref _setupIcon, value); }
    public string BuildWarning { get => _buildWarning; private set => Set(ref _buildWarning, value); }
    public bool SetupComplete => _main.Game != null && _main.ModReady;

    public ICommand SetupCommand { get; }

    public void RefreshSetup()
    {
        var g = _main.Game;
        var rt = _main.RewindTogether;
        var plan = _main.CurrentPlan;
        string? installed = rt is { Installed: true } ? rt.Version ?? "" : null;
        bool running = _main.GameRunning;

        void Show(string tone, string text, string detail, string button)
        {
            SetupTone = tone;
            SetupIcon = tone switch { "ok" => "✔", "bad" => "✖", "info" => "…", _ => "!" };
            SetupText = text;
            SetupDetail = detail;
            SetupButton = button;
        }

        if (g == null)
            Show("bad", "Retro Rewind was not found.",
                "Show the launcher where it is installed (in Steam: right-click Retro Rewind > Manage > Browse local files).", "Find the game...");
        else if (_main.SettingUp)
            Show("info", "Setting up Rewind Together...", plan.Describe(installed), "");
        else if (plan.NothingToDo)
            Show("ok", $"Ready to play: Rewind Together {rt?.Version} is installed.",
                $"Retro Rewind{(g.BuildId != null ? $" build {g.BuildId}" : "")} · {_main.Ue4ss?.Summary}", "");
        else if (plan.InstallMod && plan.ModVersion == null && _main.RunningFromZipPreview)
            Show("bad", "Unzip the download first.", MainViewModel.UnzipFirstText, "");
        else if ((plan.InstallUe4ss || plan.InstallMod) && running)
            Show("warn", "Close Retro Rewind to finish setting up - the launcher does the rest by itself.",
                "Still to do: " + plan.Describe(installed), "Close the game and set up");
        else if (plan.InstallMod && plan.ModVersion == null && !plan.InstallUe4ss)
            Show("warn", installed == null ? "Rewind Together is not installed." : "Rewind Together needs reinstalling.",
                "Pick the Rewind Together zip you downloaded, and the launcher installs it.", "Choose the zip...");
        else
        {
            bool damaged = rt is { Installed: true, HasMainLua: false };
            bool update = plan.InstallMod && !damaged && installed != null;
            string text = installed == null || plan.InstallUe4ss ? "One click to set up Rewind Together."
                : damaged ? "Rewind Together is damaged - one click repairs it."
                : update ? (_main.Bundled != null ? "A Rewind Together update came with this launcher." : $"Rewind Together {plan.ModVersion} is available.")
                : "Rewind Together is switched off.";
            string button = !plan.InstallUe4ss && !plan.InstallMod ? "Switch it on"
                : !plan.InstallUe4ss && update && plan.ModVersion != null ? $"Update to {plan.ModVersion}"
                : "Set up Rewind Together";
            string detail = !plan.InstallUe4ss && !plan.InstallMod
                ? "It is turned off in UE4SS's mod list, so the game will not load it. HOST and JOIN switch it back on too."
                : plan.Describe(damaged ? null : installed);
            Show("warn", text, detail, button);
        }

        BuildWarning = rt?.BuildWarning(g?.BuildId) ?? "";
        Raise(nameof(SetupComplete));
    }

    private async Task SetupAsync()
    {
        if (_main.Game == null)
        {
            // Finding the game sets up everything it can by itself; the line then shows what is left.
            await _main.BrowseForGameAsync();
            return;
        }
        await _main.SetUpAsync(MainViewModel.SetupTrigger.Button);
    }

    /// <summary>Everything a session needs, setting up what is missing. False = not ready.</summary>
    private async Task<bool> EnsureReadyAsync(bool needSteam)
    {
        // Installs whatever is missing, updates to the version that came with the launcher (everyone
        // in a session needs the same one) and switches the mod on - asking only to close the game.
        if (!await _main.SetUpAsync(MainViewModel.SetupTrigger.Session)) return false;
        if (needSteam && !File.Exists(_main.Game!.SteamApiDll))
        {
            await _main.InformAsync("Steam files missing",
                "The game's Steam library (steam_api64.dll) is missing, so the launcher cannot connect you through Steam.\n\n" +
                "In Steam, right-click Retro Rewind > Properties > Installed Files > Verify integrity of game files. " +
                "Until then you can still use \"Join by address\".", "bad");
            return false;
        }
        return true;
    }

    // ================================================================== host

    public ICommand HostCommand { get; }
    public ICommand StopCommand { get; }
    public ICommand InviteFriendCommand { get; }
    public ObservableCollection<GuestItem> Guests { get; } = new();
    public ObservableCollection<FriendItem> InvitableFriends { get; } = new();

    private async Task HostAsync()
    {
        if (!await EnsureReadyAsync(needSteam: true)) return;
        if (_session != SessionKind.None)
        {
            if (_session == SessionKind.Host) { _main.Notify("You are already hosting.", "info"); return; }
            if (!await _main.AskAsync("Leave your current session?", "You are joined to a friend right now. Stop that and host your own store instead?",
                    "Host instead", "Cancel", "warn"))
                return;
            await EndSessionAsync(null);
        }
        if (_main.Status?.IsClient == true)
        {
            await _main.InformAsync("You are in a friend's store",
                "Leave their store first (go back to the main menu in the game), then press HOST.", "warn");
            return;
        }

        var game = _main.Game!;
        var choice = SelectedSaveSlot;
        bool alreadyHosting = _main.Status?.IsHosting == true;
        BeginSession(SessionKind.Host);
        _hostSlot = choice;
        try
        {
            // Already hosting in the game (F7): nothing to ask the mod - just bring Steam in.
            // Otherwise the request names the chosen save, or none ("choose my save in the game").
            if (!alreadyHosting)
            {
                LaunchFiles.WriteLaunchRequest(game, LaunchRequest.Host(DateTimeOffset.UtcNow, choice.Slot));
                _requestWrittenAt = DateTime.UtcNow;
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            await FailSessionAsync("Could not prepare hosting", $"The launcher could not write to the game folder: {ex.Message}");
            return;
        }

        if (!_main.GameRunning && !GameProcess.IsRunning(game))
        {
            try
            {
                GameProcess.LaunchViaSteam();
                SetPhase("Starting Retro Rewind through Steam...", "info");
            }
            catch (InvalidOperationException ex)
            {
                SetPhase("Start Retro Rewind from Steam.", "warn");
                _main.Notify(ex.Message, "warn");
            }
        }
        else if (alreadyHosting)
        {
            SetPhase("Your store is open.", "pink");
        }
        else
        {
            SetPhase(WaitingForStorePhase(), "pink");
            // The mod loads a chosen save from the MAIN MENU only (LAUNCHER_CONTRACT.md §1).
            if (choice.Slot != null && _main.Status is { InStore: true, IsStandalone: true })
                _main.Notify($"{choice.ShortName} loads from the main menu. If you are in a store right now, go back to the main menu - " +
                             $"{choice.ShortName} then loads by itself and opens to friends.", "info");
        }
        OnTick();
    }

    /// <summary>What to tell the host while the game runs but the store is not open yet.</summary>
    private string WaitingForStorePhase()
        => _hostSlot?.Slot != null
            ? $"Loading {_hostSlot.ShortName} - it opens to friends by itself."
            : "Load your save and walk into your store - it opens to friends by itself.";

    private async Task StartHostAgentAsync()
    {
        if (_agentStarting || _agent != null || _steamFailedThisSession) return;
        _agentStarting = true;
        try
        {
            var agent = await StartAgentAsync();
            agent.StartHost(_main.Settings.HostGamePort, _main.Settings.HostFriendsOnly, _main.Settings.MaxGuests);
            _main.SteamChip = $"Steam: {agent.LocalName}";
            _main.SteamChipTone = "ok";
        }
        catch (Exception ex) when (ex is SteamInitException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            _steamFailedThisSession = true;
            _main.SteamChip = "Steam: not connected";
            _main.SteamChipTone = "bad";
            await _main.InformAsync("Friends cannot join over Steam yet",
                ex.Message + "\n\nYour store will still open for players on your own network or VPN (they can use \"Join by address\" " +
                "with your PC's IP). Fix the problem above, then press STOP and HOST again.", "warn");
        }
        finally
        {
            _agentStarting = false;
        }
    }

    private void Invite(FriendItem? f)
    {
        if (f == null || _agent == null) return;
        _agent.Invite(f.Info.Id);
        _main.Notify($"Invite sent to {f.Name}. They can accept it from Steam.", "ok");
    }

    // ================================================================== join

    private string _joinAddress, _joinSteamId;
    private bool _friendsLoading, _otherWaysOpen;
    private string _friendsStatus = "Press Refresh to see which friends have their store open.";

    public ObservableCollection<FriendItem> HostingFriends { get; } = new();
    public string JoinAddress { get => _joinAddress; set => Set(ref _joinAddress, value); }
    public string JoinSteamIdText { get => _joinSteamId; set => Set(ref _joinSteamId, value); }
    public bool FriendsLoading { get => _friendsLoading; private set { Set(ref _friendsLoading, value); CommandManager.InvalidateRequerySuggested(); } }
    public string FriendsStatus { get => _friendsStatus; private set => Set(ref _friendsStatus, value); }
    public bool OtherWaysOpen { get => _otherWaysOpen; set => Set(ref _otherWaysOpen, value); }

    public ICommand RefreshFriendsCommand { get; }
    public ICommand JoinFriendCommand { get; }
    public ICommand JoinAddressCommand { get; }
    public ICommand JoinSteamIdCommand { get; }
    public ICommand ToggleOtherWaysCommand { get; }

    private async Task RefreshFriendsAsync()
    {
        var game = _main.Game;
        if (game == null) { FriendsStatus = "Find Retro Rewind first (see Setup above)."; return; }
        if (!File.Exists(game.SteamApiDll)) { FriendsStatus = "The game's Steam library is missing - verify the game files in Steam."; return; }
        if (!SteamClientRunning()) { FriendsStatus = "Steam is not running. Start Steam and sign in, then press Refresh."; return; }

        FriendsLoading = true;
        FriendsStatus = "Asking Steam which friends have their store open...";
        try
        {
            IReadOnlyList<FriendInfo> friends;
            if (_agent?.IsRunning == true)
            {
                friends = await _agent.QueryFriendsAsync(TimeSpan.FromSeconds(15));
            }
            else
            {
                // A short-lived helper: Steam sees "Retro Rewind" for a few seconds, then it exits -
                // so it is long gone by the time anyone presses JOIN and the real game starts.
                var temp = StartAgentProcess();
                try
                {
                    await temp.WaitReadyAsync(TimeSpan.FromSeconds(20));
                    friends = await temp.QueryFriendsAsync(TimeSpan.FromSeconds(15));
                }
                finally
                {
                    await temp.DisposeAsync();
                }
            }

            HostingFriends.Clear();
            foreach (var f in friends.Where(f => f.Hosting)) HostingFriends.Add(new FriendItem(f, JoinFriendCommand, InviteFriendCommand));
            InvitableFriends.Clear();
            foreach (var f in friends.Where(f => !f.Hosting)) InvitableFriends.Add(new FriendItem(f, JoinFriendCommand, InviteFriendCommand));

            int playing = friends.Count(f => f.InGame && !f.Hosting);
            FriendsStatus = HostingFriends.Count > 0
                ? $"Updated {DateTime.Now:t}."
                : playing > 0
                    ? $"{playing} friend{(playing == 1 ? " is" : "s are")} playing Retro Rewind, but nobody has their store open. Ask them to press HOST in their launcher."
                    : "None of your Steam friends are hosting right now. Ask a friend to press HOST in their launcher, then press Refresh.";
            Raise(nameof(HasHostingFriends));
        }
        catch (SteamInitException ex) { FriendsStatus = ex.Message; }
        catch (TimeoutException ex) { FriendsStatus = ex.Message + " Try again."; }
        catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            FriendsStatus = "The Steam helper could not start: " + ex.Message;
        }
        finally
        {
            FriendsLoading = false;
        }
    }

    public bool HasHostingFriends => HostingFriends.Count > 0;

    private async Task JoinSteamIdAsync()
    {
        if (!SteamIds.TryParse(JoinSteamIdText, out ulong id))
        {
            await _main.InformAsync("That is not a Steam ID",
                "A Steam ID is a 17-digit number starting with 7656119. Your friend can find theirs in the launcher's Play tab " +
                "(it is shown while hosting), or on their Steam profile page link.", "warn");
            return;
        }
        _main.Settings.LastJoinSteamId = id.ToString();
        _main.SaveSettings();
        await JoinSteamAsync(id, "");
    }

    public async Task JoinSteamAsync(ulong hostId, string name)
    {
        if (!await EnsureReadyAsync(needSteam: true)) return;
        if (_session != SessionKind.None)
        {
            if (_session == SessionKind.JoinSteam && _joinHost == hostId) { _main.Notify("Already joining that store.", "info"); return; }
            if (!await _main.AskAsync("Leave your current session?",
                    _session == SessionKind.Host ? "You are hosting right now. Stop hosting and join your friend instead?" : "Stop the current join and join this friend instead?",
                    "Join instead", "Cancel", "warn"))
                return;
            await EndSessionAsync(null);
        }

        var game = _main.Game!;
        BeginSession(SessionKind.JoinSteam);
        _joinHost = hostId;
        _joinName = string.IsNullOrWhiteSpace(name) ? "your friend" : name;
        var ct = _sessionCts.Token;
        try
        {
            if (!GameProcess.IsRunning(game))
            {
                GameProcess.LaunchViaSteam();
                SetPhase("Starting Retro Rewind through Steam...", "info");
                if (!await GameProcess.WaitForStartAsync(game, TimeSpan.FromMinutes(3), ct))
                {
                    await FailSessionAsync("Retro Rewind did not start",
                        "Steam was asked to start the game, but it has not started after 3 minutes. Start Retro Rewind from your Steam library, then press JOIN again.");
                    return;
                }
            }
            ct.ThrowIfCancellationRequested();
            SetPhase("Connecting to Steam...", "info");
            var agent = await StartAgentAsync();
            ct.ThrowIfCancellationRequested();
            SetPhase($"Opening a Steam connection to {_joinName}...", "info");
            int port = await agent.StartJoinAsync(hostId, _main.Settings.GuestTunnelPort, TimeSpan.FromSeconds(10));
            ct.ThrowIfCancellationRequested();
            LaunchFiles.WriteLaunchRequest(game, LaunchRequest.Join($"127.0.0.1:{port}", name, DateTimeOffset.UtcNow));
            _requestWrittenAt = DateTime.UtcNow;
            SetPhase($"Joining {_joinName}... the game connects by itself, even from the main menu.", "info");
        }
        catch (OperationCanceledException) { }
        catch (SteamInitException ex) { await FailSessionAsync("Could not connect through Steam", ex.Message); }
        catch (TunnelBindException ex) { await FailSessionAsync("The tunnel port is busy", ex.Message); }
        catch (TimeoutException ex) { await FailSessionAsync("Steam did not respond", ex.Message + " Check that Steam is online and try again."); }
        catch (Exception ex) when (ex is InvalidOperationException or IOException or System.ComponentModel.Win32Exception)
        {
            await FailSessionAsync("Joining did not start", ex.Message);
        }
    }

    private async Task JoinAddressAsync()
    {
        string? addr = LaunchFiles.NormalizeAddress(JoinAddress, out string? problem);
        if (addr == null)
        {
            await _main.InformAsync("Check the address", problem ?? "That address is not valid.", "warn");
            return;
        }
        if (!await EnsureReadyAsync(needSteam: false)) return;
        if (_session != SessionKind.None)
        {
            if (!await _main.AskAsync("Leave your current session?", "Stop the current session and join this address instead?", "Join instead", "Cancel", "warn")) return;
            await EndSessionAsync(null);
        }

        var game = _main.Game!;
        _main.Settings.LastJoinAddress = addr;
        _main.SaveSettings();
        BeginSession(SessionKind.JoinDirect);
        _joinName = addr;
        try
        {
            LaunchFiles.WriteLaunchRequest(game, LaunchRequest.Join(addr, null, DateTimeOffset.UtcNow));
            _requestWrittenAt = DateTime.UtcNow;
            if (!GameProcess.IsRunning(game)) GameProcess.LaunchViaSteam();
            SetPhase($"Joining {addr}... the game connects by itself, even from the main menu.", "info");
        }
        catch (Exception ex) when (ex is IOException or InvalidOperationException)
        {
            await FailSessionAsync("Joining did not start", ex.Message);
        }
    }

    // ================================================================== command line / Steam "Join Game"

    public async Task HandleStartArgsAsync(LaunchArgs args)
    {
        if (args.JoinSteamId is ulong id)
        {
            _main.Tab = "play";
            await JoinSteamAsync(id, "");
        }
        else if (args.Host)
        {
            _main.Tab = "play";
            await HostAsync();
        }
    }

    // ================================================================== session lifecycle

    private string _phase = "", _phaseTone = "idle";
    public string Phase { get => _phase; private set => Set(ref _phase, value); }
    public string PhaseTone { get => _phaseTone; private set => Set(ref _phaseTone, value); }
    public bool InSession => _session != SessionKind.None;
    public bool IsHosting => _session == SessionKind.Host;
    public bool IsJoining => _session is SessionKind.JoinSteam or SessionKind.JoinDirect;

    private void SetPhase(string text, string tone)
    {
        Phase = text;
        PhaseTone = tone;
    }

    private void BeginSession(SessionKind kind)
    {
        _sessionCts.Cancel();
        _sessionCts = new CancellationTokenSource();
        _session = kind;
        _sessionStartedAt = DateTime.UtcNow;
        _requestWrittenAt = null;
        _sawGameRunning = _main.GameRunning;
        _steamFailedThisSession = false;
        _presenceOn = false;
        _wasConnected = false;
        _lastStats = null;
        _hostSlot = null;
        Guests.Clear();
        RaiseSession();
        Log.Info("Session started: " + kind);
    }

    private async Task FailSessionAsync(string title, string message)
    {
        await EndSessionAsync(null);
        SetPhase(title, "bad");
        await _main.InformAsync(title, message, "bad");
    }

    /// <summary>Stops the Steam helper (clearing rich presence) and forgets the session.</summary>
    public async Task EndSessionAsync(string? message, bool userStopped = false)
    {
        if (_session == SessionKind.None && _agent == null) return;
        var kind = _session;
        _sessionCts.Cancel();
        _session = SessionKind.None;
        _requestWrittenAt = null;
        // A request the mod has not consumed yet is stale now (e.g. a join whose tunnel we are about
        // to close). If the mod already acted on it, the file is gone and this does nothing.
        if (_main.Game != null) LaunchFiles.CancelLaunchRequest(_main.Game);
        await StopAgentAsync();
        _presenceOn = false;
        Guests.Clear();
        RaiseSession();
        if (message != null) SetPhase(message, "idle");
        if (userStopped && kind == SessionKind.Host && _main.GameRunning)
            _main.Notify("Steam friends can no longer join. Anyone already in your store stays until you leave co-op in the game.", "info");
        Log.Info($"Session ended ({kind}): {message}");
    }

    private void RaiseSession()
    {
        Raise(nameof(InSession));
        Raise(nameof(IsHosting));
        Raise(nameof(IsJoining));
        CommandManager.InvalidateRequerySuggested();
        UpdateDisplay();
    }

    /// <summary>Called every second by the main timer, after it has read status.json.</summary>
    public void OnTick()
    {
        var game = _main.Game;
        bool running = _main.GameRunning;
        var status = _main.Status;

        if (_session != SessionKind.None)
        {
            if (running) _sawGameRunning = true;
            if (_sawGameRunning && !running)
            {
                _ = EndSessionAsync("The game closed, so the co-op session ended.");
                return;
            }

            switch (_session)
            {
                case SessionKind.Host:
                    if (running && _agent == null && !_agentStarting && !_steamFailedThisSession) _ = StartHostAgentAsync();
                    bool wantPresence = _agent?.IsRunning == true && status?.IsHosting == true;
                    if (_agent != null && wantPresence != _presenceOn)
                    {
                        _agent.SetPresence(wantPresence);
                        _presenceOn = wantPresence;
                        if (wantPresence) _main.Notify("Your store is open. Steam friends can join from their launcher or with \"Join Game\" in Steam.", "pink");
                    }
                    if (status?.IsHosting == true)
                        SetPhase(_presenceOn ? "Your store is open - friends can join." : "Your store is open on your network. Connecting to Steam...", "pink");
                    else if (running && status != null)
                        // With a chosen save, "in_store" cannot tell the menu from the store reliably,
                        // so the loading message stays until the mod reports ListenServer.
                        SetPhase(_hostSlot?.Slot == null && status.InStore ? "Opening your store to friends..." : WaitingForStorePhase(), "pink");
                    else if (!running && DateTime.UtcNow - _sessionStartedAt > TimeSpan.FromMinutes(3))
                        SetPhase("Waiting for Retro Rewind. Start it from Steam if it did not open.", "warn");
                    break;

                case SessionKind.JoinSteam:
                case SessionKind.JoinDirect:
                    if (status?.IsClient == true)
                    {
                        SetPhase($"You are in {_joinName}'s store.", "ok");
                        _wasConnected = true;
                    }
                    else if (_wasConnected && status != null && !status.IsClient)
                    {
                        _wasConnected = false;
                        SetPhase($"You left {_joinName}'s store.", "idle");
                    }
                    else if (_requestWrittenAt is DateTime w && game != null)
                    {
                        var waited = DateTime.UtcNow - w;
                        if (waited > TimeSpan.FromSeconds(25) && File.Exists(game.LaunchJson))
                            SetPhase(status == null
                                ? "The game has not picked up the join yet - waiting for Rewind Together to load..."
                                : "The game has not picked up the join. Leave co-op in the game (back to the main menu) and try again.", "warn");
                        else if (waited > TimeSpan.FromSeconds(45) && _session == SessionKind.JoinSteam &&
                                 _lastStats?.Peers.FirstOrDefault() is { } p && p.Out > 0 && p.In == 0)
                            SetPhase($"Nothing is coming back from {_joinName}. Check their launcher says their store is open, then try again.", "warn");
                        else if (waited > TimeSpan.FromSeconds(60) && _session == SessionKind.JoinDirect)
                            SetPhase($"Still not connected to {_joinName}. Check the address, and that the host's store is open and reachable.", "warn");
                    }
                    break;
            }
        }
        UpdateDisplay();
    }

    // ================================================================== Steam helper

    private SteamAgentClient StartAgentProcess()
    {
        var game = _main.Game ?? throw new InvalidOperationException("Retro Rewind was not found.");
        string exe = Environment.ProcessPath ?? throw new InvalidOperationException("The launcher cannot find its own exe.");
        return SteamAgentClient.Start(exe, game.SteamApiDll, _main.StartArgs.DataDir);
    }

    private async Task<SteamAgentClient> StartAgentAsync()
    {
        if (_agent?.IsRunning == true) return _agent;
        if (!SteamClientRunning())
            throw new SteamInitException("steam_not_running", "Steam is not running. Start Steam and sign in, then try again.");

        var agent = StartAgentProcess();
        agent.StatsReceived += s => OnUi(() => OnStats(s));
        agent.PeerChanged += (id, name, state, reason) => OnUi(() =>
            _main.Notify(state == "joined" ? $"{Display(name, id)} walked into your store." : $"{Display(name, id)} left ({reason}).", state == "joined" ? "pink" : "info"));
        agent.JoinRequested += (id, name) => OnUi(() => OnSteamJoinRequest(id, name));
        agent.ErrorReceived += msg => OnUi(() => _main.Notify(msg, "bad"));
        agent.Exited += code => OnUi(() => OnAgentExited(agent));
        _agent = agent;
        _main.SteamChip = "Steam: connecting...";
        _main.SteamChipTone = "warn";
        try
        {
            await agent.WaitReadyAsync(TimeSpan.FromSeconds(25));
        }
        catch
        {
            _agent = null;
            await agent.DisposeAsync();
            _main.SteamChip = "Steam: not connected";
            _main.SteamChipTone = "bad";
            throw;
        }
        _main.SteamChip = $"Steam: {agent.LocalName}";
        _main.SteamChipTone = "ok";
        Raise(nameof(MySteamId));
        return agent;
    }

    private async Task StopAgentAsync()
    {
        var a = _agent;
        _agent = null;
        if (a != null) await a.DisposeAsync();
        _main.SteamChip = "Steam link: idle";
        _main.SteamChipTone = "idle";
        _lastStats = null;
        Raise(nameof(MySteamId));
    }

    private void OnAgentExited(SteamAgentClient agent)
    {
        if (_agent != agent) return; // a deliberate stop, or the short-lived friends helper
        _agent = null;
        _main.SteamChip = "Steam link: stopped";
        _main.SteamChipTone = "bad";
        if (_session is SessionKind.Host or SessionKind.JoinSteam)
        {
            _steamFailedThisSession = true;
            _main.Notify("The Steam connection stopped unexpectedly. Press STOP, then HOST or JOIN again. (Diagnostics has the details.)", "bad");
        }
    }

    private void OnSteamJoinRequest(ulong id, string name)
    {
        if (_session == SessionKind.Host)
        {
            _main.Notify($"{Display(name, id)} invited you to their store, but you are hosting. Stop hosting first to join them.", "warn");
            return;
        }
        _ = JoinSteamAsync(id, name);
    }

    private void OnStats(AgentStats s)
    {
        _lastStats = s;
        if (s.Mode == "host")
        {
            Guests.Clear();
            foreach (var p in s.Peers)
                Guests.Add(new GuestItem(Display(p.Name, p.Id), LinkLabel(p.Link), $"in {p.In:N0} / out {p.Out:N0}",
                    p.Link is "relay" or "direct" ? "ok" : "warn"));
        }
        UpdateDisplay();
    }

    public string MySteamId => _agent?.LocalSteamId is ulong id and not 0 ? id.ToString() : "";

    private static bool SteamClientRunning()
    {
        try
        {
            var procs = Process.GetProcessesByName("steam");
            bool any = procs.Length > 0;
            foreach (var p in procs) p.Dispose();
            return any;
        }
        catch
        {
            return true; // cannot tell; let the helper report the real problem
        }
    }

    private static void OnUi(Action a) => Application.Current?.Dispatcher.InvokeAsync(a);

    private static string Display(string name, ulong id) => string.IsNullOrWhiteSpace(name) ? id.ToString() : name;

    private static string LinkLabel(string link) => link switch
    {
        "relay" => "via Steam relay",
        "direct" => "direct connection",
        "connecting" => "connecting...",
        _ => link,
    };

    // ================================================================== VCR display

    private string _vcrMode = "STOP", _vcrTitle = "", _vcrDetail = "", _vcrTone = "idle", _linkText = "", _trafficText = "";

    public string VcrMode { get => _vcrMode; private set => Set(ref _vcrMode, value); }
    public string VcrTitle { get => _vcrTitle; private set => Set(ref _vcrTitle, value); }
    public string VcrDetail { get => _vcrDetail; private set => Set(ref _vcrDetail, value); }
    public string VcrTone { get => _vcrTone; private set => Set(ref _vcrTone, value); }
    public string LinkText { get => _linkText; private set => Set(ref _linkText, value); }
    public string TrafficText { get => _trafficText; private set => Set(ref _trafficText, value); }
    public string LastError => _main.Status?.LastError ?? "";
    public string ModVersionText => _main.Status != null ? "Mod " + _main.Status.Version : "";
    public string PlayersText => _main.Status is { } s && !s.IsStandalone ? $"{s.Players} player{(s.Players == 1 ? "" : "s")}" : "";

    private void UpdateDisplay()
    {
        var status = _main.Status;
        bool running = _main.GameRunning;

        if (_main.Game == null) { (VcrMode, VcrTitle, VcrTone) = ("NO TAPE", "Retro Rewind not found", "bad"); }
        else if (!running) { (VcrMode, VcrTitle, VcrTone) = (InSession ? "LOAD" : "STOP", InSession ? "Starting the game..." : "Game not running", InSession ? "info" : "idle"); }
        else if (status == null) { (VcrMode, VcrTitle, VcrTone) = ("LOAD", "Game running - waiting for Rewind Together", "warn"); }
        else if (status.IsHosting) { (VcrMode, VcrTitle, VcrTone) = ("● REC", $"Hosting your store - {PlayersText}", "pink"); }
        else if (status.IsClient) { (VcrMode, VcrTitle, VcrTone) = ("▶ PLAY", $"Visiting {(_joinName.Length > 0 ? _joinName : "a friend")}'s store", "info"); }
        else { (VcrMode, VcrTitle, VcrTone) = ("▶ PLAY", status.InStore ? "In your store (single player)" : "At the main menu", "ok"); }

        VcrDetail = InSession ? Phase : running && status == null && _main.GameStartedSeenAt is DateTime t && DateTime.UtcNow - t > TimeSpan.FromSeconds(90)
            ? "Rewind Together is not reporting. Check it is installed and switched on, and that UE4SS loads (see Diagnostics)."
            : "";

        var peers = _lastStats?.Peers ?? Array.Empty<PeerInfo>();
        if (_agent?.IsRunning == true && peers.Count > 0)
        {
            if (_lastStats!.Mode == "guest")
            {
                var p = peers[0];
                LinkText = $"LINK  {LinkLabel(p.Link).ToUpperInvariant()}";
                TrafficText = $"IN {p.In:N0}  OUT {p.Out:N0}";
            }
            else
            {
                LinkText = $"GUESTS  {peers.Count}   " + string.Join("  ", peers.Select(x => LinkLabel(x.Link).ToUpperInvariant()).Distinct());
                TrafficText = $"IN {peers.Sum(x => x.In):N0}  OUT {peers.Sum(x => x.Out):N0}";
            }
        }
        else if (_agent?.IsRunning == true)
        {
            LinkText = _session == SessionKind.Host ? "LINK  WAITING FOR GUESTS" : "LINK  OPEN";
            TrafficText = "IN 0  OUT 0";
        }
        else
        {
            LinkText = _session == SessionKind.JoinDirect ? "LINK  DIRECT (NO STEAM)" : "";
            TrafficText = "";
        }
        Raise(nameof(LastError));
        Raise(nameof(ModVersionText));
        Raise(nameof(PlayersText));
    }

    // ================================================================== shutdown

    public void OnWindowClosing()
    {
        // Stop the helper synchronously so Steam presence is cleared before we exit.
        var a = _agent;
        _agent = null;
        _sessionCts.Cancel();
        try { a?.StopBlocking(TimeSpan.FromSeconds(4)); } catch { }
    }

    public void Dispose() => OnWindowClosing();
}
