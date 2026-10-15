<#
.SYNOPSIS
    Installs the Rewind Together co-op mod for Retro Rewind.

.DESCRIPTION
    Copies the Lua mod into UE4SS's Mods folder, enables it, and installs the
    networking config profile into the game's user config directory.

    This script does not download anything. UE4SS is a third-party binary and
    you should get it yourself from its official releases page; the script
    tells you where it expects to find it.

.PARAMETER Transport
    "ip" (default) - direct UDP on port 27015, for LAN, VPN or a forwarded port.
    "steam"        - connect by Steam ID, relayed.

    The default is "ip" because "steam" does not work on this build. The
    SteamCoreSockets net driver is present but reports itself unavailable, so
    the engine silently substitutes IpNetDriver and every Steam-ID join gets
    bounced to the main menu with nothing logged. Direct IP is the transport
    that actually carries a session here.

.PARAMETER GameRoot
    Retro Rewind install folder. Auto-detected from this script's location.

.EXAMPLE
    .\Install-RewindTogether.ps1
    .\Install-RewindTogether.ps1 -Transport ip
#>

[CmdletBinding()]
param(
    [ValidateSet('steam', 'ip')]
    [string] $Transport = 'ip',

    [string] $GameRoot,

    [string] $Ue4ssZip,

    [switch] $SkipConfig
)

$ErrorActionPreference = 'Stop'

function Write-Step   ($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok     ($m) { Write-Host "    OK   $m" -ForegroundColor Green }
function Write-Warn2  ($m) { Write-Host "    WARN $m" -ForegroundColor Yellow }
function Write-Fail   ($m) { Write-Host "    FAIL $m" -ForegroundColor Red }

# Windows PowerShell's -Encoding utf8 emits a BOM. A BOM breaks Lua's load()
# and makes the first line of mods.txt / UE4SS-settings.ini parse wrong, so
# every text file this script writes goes through here instead.
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function Write-TextFile ($path, $content) {
    if ($content -is [array]) { $content = ($content -join "`r`n") }
    [System.IO.File]::WriteAllText($path, $content, $script:Utf8NoBom)
}

$ModName    = 'RewindTogether'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host ""
Write-Host "  Rewind Together - co-op multiplayer for Retro Rewind" -ForegroundColor White
Write-Host "  ----------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""

# --------------------------------------------------------------------------
# 1. Locate the game
# --------------------------------------------------------------------------
Write-Step "Locating Retro Rewind"

function Test-GameRoot ($path) {
    if (-not $path) { return $false }
    return (Test-Path (Join-Path $path 'RetroRewind\Binaries\Win64\RetroRewind-Win64-Shipping.exe'))
}

# Try, in order: what the user told us, the folder above this script, then
# every Steam library on the machine.
if (-not (Test-GameRoot $GameRoot)) {
    $GameRoot = Split-Path -Parent $ScriptRoot
}

if (-not (Test-GameRoot $GameRoot)) {
    Write-Host "    ...  searching Steam libraries" -ForegroundColor DarkGray
    $steamPath = $null
    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam')) {
        try {
            $v = (Get-ItemProperty -Path $key -ErrorAction Stop)
            if ($v.SteamPath)     { $steamPath = $v.SteamPath }
            elseif ($v.InstallPath) { $steamPath = $v.InstallPath }
            if ($steamPath) { break }
        } catch {}
    }

    $libraries = @()
    if ($steamPath) {
        $libraries += (Join-Path $steamPath 'steamapps\common')
        $vdf = Join-Path $steamPath 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($line in (Get-Content $vdf)) {
                if ($line -match '"path"\s*"(.+?)"') {
                    $libraries += (Join-Path ($matches[1] -replace '\\\\', '\') 'steamapps\common')
                }
            }
        }
    }
    # Fall back to a drive sweep of the usual layout.
    foreach ($d in (Get-PSDrive -PSProvider FileSystem)) {
        $libraries += (Join-Path $d.Root 'SteamLibrary\steamapps\common')
        $libraries += (Join-Path $d.Root 'Program Files (x86)\Steam\steamapps\common')
    }

    foreach ($lib in ($libraries | Select-Object -Unique)) {
        $candidate = Join-Path $lib 'RetroRewind'
        if (Test-GameRoot $candidate) { $GameRoot = $candidate; break }
    }
}

if (-not (Test-GameRoot $GameRoot)) {
    Write-Fail "Could not find Retro Rewind automatically."
    Write-Host "         Re-run with:  -GameRoot 'D:\path\to\RetroRewind'"
    exit 1
}

$BinDir = Join-Path $GameRoot 'RetroRewind\Binaries\Win64'
Write-Ok "Game: $GameRoot"

# --------------------------------------------------------------------------
# 2. Locate UE4SS
# --------------------------------------------------------------------------
Write-Step "Checking for UE4SS"

# UE4SS 3.x keeps everything under <Binaries>\ue4ss ; 2.x used <Binaries>\Mods
$Ue4ssDir   = Join-Path $BinDir 'ue4ss'
$ModsDir    = $null
$LoaderFound = $false

foreach ($proxy in @('dwmapi.dll', 'xinput1_3.dll', 'd3d11.dll', 'UE4SS.dll')) {
    if (Test-Path (Join-Path $BinDir $proxy)) { $LoaderFound = $true; break }
}

if (Test-Path $Ue4ssDir) {
    $ModsDir = Join-Path $Ue4ssDir 'Mods'
} elseif (Test-Path (Join-Path $BinDir 'Mods')) {
    $ModsDir = Join-Path $BinDir 'Mods'
}

if (-not $LoaderFound -or -not $ModsDir) {
    # Not installed. Look for a UE4SS zip the user has already downloaded and
    # deploy it for them - we never download anything ourselves.
    Write-Host "    ...  UE4SS not installed, looking for a downloaded copy" -ForegroundColor DarkGray

    $searchDirs = @(
        $ScriptRoot,
        (Join-Path $env:USERPROFILE 'Downloads'),
        (Join-Path $env:APPDATA 'Vortex\downloads'),
        (Join-Path $env:APPDATA 'Vortex\downloads\retrorewindvideostoresimulator')
    )
    if ($Ue4ssZip) { $searchDirs = @((Split-Path -Parent $Ue4ssZip)) + $searchDirs }

    $zip = $null
    if ($Ue4ssZip -and (Test-Path $Ue4ssZip)) {
        $zip = Get-Item $Ue4ssZip
    } else {
        foreach ($dir in $searchDirs) {
            if (-not (Test-Path $dir)) { continue }
            $found = Get-ChildItem -Path $dir -Filter 'UE4SS*.zip' -Recurse -Depth 1 -ErrorAction SilentlyContinue |
                     Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($found) { $zip = $found; break }
        }
    }

    if (-not $zip) {
        Write-Fail "UE4SS is not installed and no UE4SS zip was found."
        Write-Host ""
        Write-Host "    Rewind Together runs on UE4SS (Unreal Engine Scripting System)." -ForegroundColor Gray
        Write-Host "    It is a separate, third-party tool - download it yourself:" -ForegroundColor Gray
        Write-Host ""
        Write-Host "      1. Get the latest UE4SS release zip (the standard one, not zDEV)" -ForegroundColor Gray
        Write-Host "         from  https://github.com/UE4SS-RE/RE-UE4SS/releases" -ForegroundColor White
        Write-Host "      2. Leave it in your Downloads folder." -ForegroundColor Gray
        Write-Host "      3. Run this installer again - it will unpack it for you." -ForegroundColor Gray
        Write-Host ""
        exit 2
    }

    Write-Ok "Found $($zip.Name)"
    Write-Host "    ...  unpacking into the game" -ForegroundColor DarkGray

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zip.FullName)
    try {
        # Sanity check: a real UE4SS zip has a proxy DLL and a ue4ss folder.
        $hasProxy = $false
        foreach ($e in $archive.Entries) {
            if ($e.FullName -match '^(dwmapi|xinput1_3|d3d11)\.dll$') { $hasProxy = $true }
        }
        if (-not $hasProxy) {
            Write-Fail "$($zip.Name) does not look like a UE4SS release (no proxy DLL inside)."
            exit 2
        }

        foreach ($entry in $archive.Entries) {
            $dest = Join-Path $BinDir $entry.FullName
            if ($entry.FullName.EndsWith('/')) {
                New-Item -ItemType Directory -Force -Path $dest | Out-Null
                continue
            }
            $parent = Split-Path -Parent $dest
            if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
        }
    } finally {
        $archive.Dispose()
    }

    Write-Ok "UE4SS unpacked into $BinDir"

    $Ue4ssDir = Join-Path $BinDir 'ue4ss'
    if (Test-Path $Ue4ssDir) {
        $ModsDir = Join-Path $Ue4ssDir 'Mods'
    } elseif (Test-Path (Join-Path $BinDir 'Mods')) {
        $ModsDir = Join-Path $BinDir 'Mods'
    }
    if (-not $ModsDir -or -not (Test-Path $ModsDir)) {
        Write-Fail "UE4SS unpacked but its Mods folder is missing - is the zip complete?"
        exit 2
    }
}

Write-Ok "UE4SS mods folder: $ModsDir"

# Make sure the UE4SS console window is on, so rt.* commands are reachable
# and problems are visible rather than silent.
$settings = Join-Path $BinDir 'ue4ss\UE4SS-settings.ini'
if (Test-Path $settings) {
    $s = Get-Content -Raw -Path $settings
    $orig = $s
    $s = $s -replace '(?m)^\s*GuiConsoleEnabled\s*=.*$',        'GuiConsoleEnabled = 1'
    $s = $s -replace '(?m)^\s*GuiConsoleVisible\s*=.*$',        'GuiConsoleVisible = 1'
    $s = $s -replace '(?m)^\s*EnableHotReloadSystem\s*=.*$',    'EnableHotReloadSystem = 1'
    if ($s -ne $orig) {
        Copy-Item $settings "$settings.rewindtogether-backup" -Force
        Write-TextFile $settings $s
        Write-Ok "Enabled the UE4SS console window"
    } else {
        Write-Ok "UE4SS console already configured"
    }
}

# --------------------------------------------------------------------------
# 3. Install the mod
# --------------------------------------------------------------------------
Write-Step "Installing mod files"

$SourceMod = Join-Path $ScriptRoot "Mods\$ModName"
if (-not (Test-Path $SourceMod)) {
    Write-Fail "Mod source not found at $SourceMod"
    exit 3
}

$TargetMod = Join-Path $ModsDir $ModName

# Preserve a user-edited config across reinstalls.
$UserConfig  = Join-Path $TargetMod 'Scripts\config.lua'
$SourceConfig = Join-Path $SourceMod 'Scripts\config.lua'
$SavedConfig = $null

function Get-ConfigVersion ($path) {
    if (-not (Test-Path $path)) { return -1 }
    $m = [regex]::Match((Get-Content -Raw -Path $path), 'ConfigVersion\s*=\s*(\d+)')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return 0   # pre-versioning
}

if (Test-Path $UserConfig) {
    $installedVer = Get-ConfigVersion $UserConfig
    $sourceVer    = Get-ConfigVersion $SourceConfig
    if ($installedVer -eq $sourceVer) {
        $SavedConfig = Get-Content -Raw -Path $UserConfig
        Write-Ok "Existing config.lua found (v$installedVer) - it will be preserved"
    } else {
        # Keeping an old config across a schema change would silently re-apply
        # settings the new code no longer expects. Back it up OUTSIDE the mod
        # folder, which is about to be deleted and recreated.
        $bak = Join-Path $ModsDir ("RewindTogether-config.lua.v{0}-backup" -f $installedVer)
        Copy-Item $UserConfig $bak -Force -ErrorAction SilentlyContinue
        Write-Warn2 "config.lua is v$installedVer but this build expects v$sourceVer"
        Write-Ok    "Installing the new config (your old one is kept alongside it)"
    }
}

if (Test-Path $TargetMod) {
    Remove-Item -Recurse -Force $TargetMod
}
New-Item -ItemType Directory -Force -Path $TargetMod | Out-Null
Copy-Item -Recurse -Force -Path (Join-Path $SourceMod '*') -Destination $TargetMod

$scriptCount = (Get-ChildItem -Path (Join-Path $TargetMod 'Scripts') -Filter '*.lua' | Measure-Object).Count
Write-Ok "Copied $scriptCount Lua files to $TargetMod"

if ($SavedConfig) {
    Write-TextFile $UserConfig $SavedConfig
    Write-Ok "Restored your previous config.lua"
} else {
    # Bake the chosen transport into the fresh config so the two agree.
    $cfg = Get-Content -Raw -Path $UserConfig
    $cfg = $cfg -replace 'Config\.Transport\s*=\s*"[^"]*"', ('Config.Transport = "' + $Transport + '"')
    Write-TextFile $UserConfig $cfg
    Write-Ok "Transport set to '$Transport' in config.lua"
}

# --------------------------------------------------------------------------
# 4. Enable the mod
# --------------------------------------------------------------------------
Write-Step "Enabling the mod"

# UE4SS 3.x honours an 'enabled.txt' marker inside the mod folder.
Set-Content -Path (Join-Path $TargetMod 'enabled.txt') -Value '' -Encoding ascii
Write-Ok "Wrote enabled.txt"

# ...and also respects mods.txt, which older builds require.
$ModsTxt = Join-Path $ModsDir 'mods.txt'
if (Test-Path $ModsTxt) {
    $lines = @(Get-Content -Path $ModsTxt)
    $already = $false
    foreach ($l in $lines) {
        if ($l -match "^\s*$ModName\s*:") { $already = $true }
    }
    if (-not $already) {
        Copy-Item $ModsTxt "$ModsTxt.rewindtogether-backup" -Force
        # UE4SS ships a "Built-in keybinds, do not move up!" block that must
        # stay at the bottom, so insert ahead of it rather than appending.
        $anchor = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match 'Built-in keybinds') { $anchor = $i; break }
        }
        if ($anchor -ge 0) {
            $new = @()
            $new += $lines[0..($anchor - 1)]
            $new += "$ModName : 1"
            $new += $lines[$anchor..($lines.Count - 1)]
            Write-TextFile $ModsTxt $new
            Write-Ok "Added '$ModName : 1' to mods.txt (above the keybinds block)"
        } else {
            Write-TextFile $ModsTxt (($lines + "$ModName : 1") -join "`r`n")
            Write-Ok "Added '$ModName : 1' to mods.txt"
        }
    } else {
        # Make sure it is switched on rather than listed as 0.
        $updated = $lines -replace "^\s*$ModName\s*:\s*0\s*$", "$ModName : 1"
        Write-TextFile $ModsTxt $updated
        Write-Ok "mods.txt already lists $ModName (ensured enabled)"
    }
} else {
    Write-Warn2 "no mods.txt found - relying on enabled.txt (fine for UE4SS 3.x)"
}

# --------------------------------------------------------------------------
# 5. Networking config
# --------------------------------------------------------------------------
if ($SkipConfig) {
    Write-Warn2 "Skipping Engine.ini installation (-SkipConfig)"
} else {
    Write-Step "Installing networking profile ($Transport)"

    $ConfigDir = Join-Path $env:LOCALAPPDATA 'RetroRewind\Saved\Config\Windows'
    if (-not (Test-Path $ConfigDir)) {
        New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
        Write-Ok "Created $ConfigDir"
    }

    if ($Transport -eq 'steam') {
        $Profile = Join-Path $ScriptRoot 'config\Engine.SteamP2P.ini'
    } else {
        $Profile = Join-Path $ScriptRoot 'config\Engine.DirectIP.ini'
    }

    $TargetIni = Join-Path $ConfigDir 'Engine.ini'

    if (Test-Path $TargetIni) {
        $existing = Get-Content -Raw -Path $TargetIni
        if ($existing -notmatch 'Rewind Together') {
            $backup = Join-Path $ConfigDir ('Engine.ini.pre-rewindtogether-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Copy-Item $TargetIni $backup -Force
            Write-Ok "Backed up your existing Engine.ini to $(Split-Path -Leaf $backup)"
        }
    }

    Copy-Item $Profile $TargetIni -Force
    Write-Ok "Installed $(Split-Path -Leaf $Profile) -> $TargetIni"
}

# --------------------------------------------------------------------------
# 6. Verify
# --------------------------------------------------------------------------
Write-Step "Verifying"

$problems = 0

if (-not (Test-Path (Join-Path $TargetMod 'Scripts\main.lua'))) {
    Write-Fail "main.lua missing"; $problems++
} else {
    Write-Ok "main.lua present"
}

# Derived from what is actually in the source folder, not from a list typed
# out by hand. The hand-written version had drifted: it never mentioned
# spawn.lua or inspect.lua, so an install that silently dropped the file
# responsible for giving guests a body would have reported itself complete.
$sourceScripts = Get-ChildItem -Path (Join-Path $SourceMod 'Scripts') -Filter '*.lua' |
                 Select-Object -ExpandProperty Name
foreach ($f in $sourceScripts) {
    if ($f -eq 'main.lua') { continue }
    if (-not (Test-Path (Join-Path $TargetMod "Scripts\$f"))) {
        Write-Fail "$f missing"; $problems++
    }
}
if ($problems -eq 0) { Write-Ok "All $($sourceScripts.Count) script files present" }

if (-not $SkipConfig) {
    $TargetIni = Join-Path $env:LOCALAPPDATA 'RetroRewind\Saved\Config\Windows\Engine.ini'
    if (Test-Path $TargetIni) {
        $ini = Get-Content -Raw -Path $TargetIni
        if ($ini -match 'NetDriverDefinitions') {
            Write-Ok "Engine.ini contains a GameNetDriver definition"
        } else {
            Write-Fail "Engine.ini looks wrong - no NetDriverDefinitions"; $problems++
        }
    } else {
        Write-Fail "Engine.ini was not written"; $problems++
    }
}

Write-Host ""
if ($problems -eq 0) {
    Write-Host "  Installed successfully." -ForegroundColor Green
    Write-Host ""
    Write-Host "  How to play" -ForegroundColor White
    Write-Host "  -----------" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "   TO HOST:" -ForegroundColor White
    Write-Host "     1. Launch the game, load your save, walk into your store."
    Write-Host "     2. Press F7."
    Write-Host "     3. Press F9 to open Steam's invite window and pick a friend."
    Write-Host ""
    Write-Host "   TO JOIN:" -ForegroundColor White
    Write-Host "     Right-click your friend in Steam and choose 'Join Game'."
    Write-Host "     Or launch the game and click PLAY CO-OP on the main menu."
    Write-Host ""
    Write-Host "   That's it - nobody has to type an IP or a Steam ID." -ForegroundColor Green
    Write-Host "   (A UE4SS console window opens next to the game. rt.help lists"
    Write-Host "    every command if you ever need one.)" -ForegroundColor DarkGray
    Write-Host ""
} else {
    Write-Host "  Finished with $problems problem(s) - see above." -ForegroundColor Red
    Write-Host ""
    exit 4
}
