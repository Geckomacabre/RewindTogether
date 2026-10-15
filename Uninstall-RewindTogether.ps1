<#
.SYNOPSIS
    Removes the Rewind Together co-op mod and restores stock networking config.

.DESCRIPTION
    Deletes the mod from UE4SS's Mods folder, disables it in mods.txt, and
    removes the Engine.ini this mod installed (restoring a pre-existing backup
    if one was made). UE4SS itself is left alone.

.PARAMETER KeepConfig
    Leave the networking Engine.ini in place.
#>

[CmdletBinding()]
param(
    [string] $GameRoot,
    [switch] $KeepConfig
)

$ErrorActionPreference = 'Stop'

function Write-Step ($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   ($m) { Write-Host "    OK   $m" -ForegroundColor Green }
function Write-Warn2($m) { Write-Host "    WARN $m" -ForegroundColor Yellow }

# -Encoding utf8 would add a BOM, which breaks UE4SS's parsing of mods.txt.
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function Write-TextFile ($path, $content) {
    if ($content -is [array]) { $content = ($content -join "`r`n") }
    [System.IO.File]::WriteAllText($path, $content, $script:Utf8NoBom)
}

$ModName    = 'RewindTogether'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $GameRoot) { $GameRoot = Split-Path -Parent $ScriptRoot }
$BinDir = Join-Path $GameRoot 'RetroRewind\Binaries\Win64'

Write-Host ""
Write-Host "  Removing Rewind Together" -ForegroundColor White
Write-Host ""

# 1. Mod files ------------------------------------------------------------
Write-Step "Removing mod files"
$removed = $false
foreach ($base in @((Join-Path $BinDir 'ue4ss\Mods'), (Join-Path $BinDir 'Mods'))) {
    $target = Join-Path $base $ModName
    if (Test-Path $target) {
        Remove-Item -Recurse -Force $target
        Write-Ok "Deleted $target"
        $removed = $true
    }
}
if (-not $removed) { Write-Warn2 "No installed mod folder found" }

# 2. mods.txt -------------------------------------------------------------
Write-Step "Updating mods.txt"
foreach ($base in @((Join-Path $BinDir 'ue4ss\Mods'), (Join-Path $BinDir 'Mods'))) {
    $modsTxt = Join-Path $base 'mods.txt'
    if (Test-Path $modsTxt) {
        $lines = @(Get-Content -Path $modsTxt) | Where-Object { $_ -notmatch "^\s*$ModName\s*:" }
        Write-TextFile $modsTxt $lines
        Write-Ok "Removed $ModName from $modsTxt"
    }
}

# 3. Engine.ini -----------------------------------------------------------
if ($KeepConfig) {
    Write-Warn2 "Leaving Engine.ini in place (-KeepConfig)"
} else {
    Write-Step "Restoring networking config"
    $ConfigDir = Join-Path $env:LOCALAPPDATA 'RetroRewind\Saved\Config\Windows'
    $TargetIni = Join-Path $ConfigDir 'Engine.ini'

    if (Test-Path $TargetIni) {
        $content = Get-Content -Raw -Path $TargetIni
        if ($content -match 'Rewind Together') {
            Remove-Item -Force $TargetIni
            Write-Ok "Removed the mod's Engine.ini"

            $backup = Get-ChildItem -Path $ConfigDir -Filter 'Engine.ini.pre-rewindtogether-*' -ErrorAction SilentlyContinue |
                      Sort-Object Name -Descending | Select-Object -First 1
            if ($backup) {
                Copy-Item $backup.FullName $TargetIni -Force
                Write-Ok "Restored your original Engine.ini from $($backup.Name)"
            }
        } else {
            Write-Warn2 "Engine.ini was not written by this mod - left untouched"
        }
    } else {
        Write-Ok "No Engine.ini to remove"
    }
}

Write-Host ""
Write-Host "  Done. Retro Rewind is back to single player." -ForegroundColor Green
Write-Host "  (UE4SS itself was left installed. To remove it too, delete" -ForegroundColor DarkGray
Write-Host "   dwmapi.dll and the ue4ss folder from $BinDir)" -ForegroundColor DarkGray
Write-Host ""
