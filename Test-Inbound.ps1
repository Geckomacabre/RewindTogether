<#
.SYNOPSIS
    Rewind Together - does your friend's traffic actually reach this PC?

.DESCRIPTION
    Captures inbound UDP on the game's port with pktmon (built into Windows)
    while your friend tries to join, then tells you whether a single packet
    from the outside world arrived.

    This is the one question left that cannot be answered from either game's
    log. The host log says nothing arrived - but "nothing arrived" is equally
    consistent with the router dropping it, the ISP filtering it, or his
    machine never sending it. A capture at the network adapter separates
    those: if his packets show up here, the network is fine and the fault is
    above it. If they never show up, the fault is below the game entirely and
    no amount of mod work will fix it.

.PARAMETER Port
    UDP port to watch. Default 27015.

.PARAMETER Seconds
    How long to capture. Default 60 - enough for your friend to press F5.
#>

[CmdletBinding()]
param(
    [int] $Port    = 27015,
    [int] $Seconds = 60
)

$ErrorActionPreference = 'Continue'

function Write-Head($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Write-Ok  ($t) { Write-Host "  [ok]   $t" -ForegroundColor Green }
function Write-Bad ($t) { Write-Host "  [BAD]  $t" -ForegroundColor Red }
function Write-Note($t) { Write-Host "  $t" -ForegroundColor Gray }

# --- must be admin -----------------------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "This needs Administrator (packet capture). Relaunching..." -ForegroundColor Yellow
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",
              '-Port',$Port,'-Seconds',$Seconds)
    Start-Process powershell -Verb RunAs -ArgumentList $args
    return
}

$work = Join-Path $env:TEMP 'RewindTogether-capture'
if (-not (Test-Path $work)) { New-Item -ItemType Directory -Path $work -Force | Out-Null }
$etl = Join-Path $work 'inbound.etl'
$txt = Join-Path $work 'inbound.txt'

Write-Host ""
Write-Host "  Rewind Together - inbound traffic test" -ForegroundColor White
Write-Host "  watching UDP $Port for $Seconds seconds" -ForegroundColor DarkGray

# --- set up the capture ------------------------------------------------------
Write-Head "Starting capture"

# Always stop first. pktmon is a single global session: if anything left one
# running - including an earlier run of this script - every start after that
# fails with "Packet Monitor is already started" and no capture happens.
& pktmon stop 2>&1 | Out-Null
Start-Sleep -Milliseconds 300

& pktmon filter remove 2>&1 | Out-Null
& pktmon filter add RewindTogether -t UDP -p $Port 2>&1 | Out-Null

# Old captures would otherwise be decoded and reported as this run's result.
if (Test-Path $etl) { Remove-Item -LiteralPath $etl -Force -ErrorAction SilentlyContinue }
if (Test-Path $txt) { Remove-Item -LiteralPath $txt -Force -ErrorAction SilentlyContinue }

$started = $false
$out = $null
foreach ($attempt in @(
    { & pktmon start --capture --pkt-size 0 --file-name $etl 2>&1 },
    { & pktmon start --capture --file-name $etl 2>&1 },
    { & pktmon start -c -f $etl 2>&1 }
)) {
    $out = & $attempt
    if ($LASTEXITCODE -eq 0) { $started = $true; break }
    # "already started" means a session survived our stop - kill it and retry.
    if ($out -match 'already started') {
        & pktmon stop 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500
        $out = & $attempt
        if ($LASTEXITCODE -eq 0) { $started = $true; break }
    }
}

if (-not $started) {
    Write-Bad "Could not start pktmon."
    Write-Note ($out -join "`n")
    Write-Note ""
    Write-Note "Run this in an admin PowerShell, then try again:"
    Write-Note "    pktmon stop"
    Read-Host "Press Enter to close"
    return
}
Write-Ok "capture running"

Write-Host ""
Write-Host "  >>> TELL YOUR FRIEND TO PRESS F5 NOW <<<" -ForegroundColor Yellow
Write-Host ""

for ($i = $Seconds; $i -gt 0; $i--) {
    Write-Host ("`r  {0,3} seconds left..." -f $i) -NoNewline -ForegroundColor DarkGray
    Start-Sleep -Seconds 1
}
Write-Host "`r                          "

& pktmon stop 2>&1 | Out-Null
Write-Ok "capture stopped"

# --- decode ------------------------------------------------------------------
Write-Head "Result"
& pktmon etl2txt $etl --out $txt 2>&1 | Out-Null
if (-not (Test-Path $txt)) { & pktmon etl2txt $etl -o $txt 2>&1 | Out-Null }

if (-not (Test-Path $txt)) {
    Write-Bad "Could not decode the capture."
    & pktmon filter remove 2>&1 | Out-Null
    Read-Host "Press Enter to close"
    return
}

$lines = Get-Content $txt -ErrorAction SilentlyContinue
$hits  = $lines | Where-Object { $_ -match "\.$Port\b|:$Port\b" }

# Pull out source IPs that are not on this LAN - those are the interesting ones.
$remote = @{}
foreach ($l in $hits) {
    foreach ($m in [regex]::Matches($l, '(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})')) {
        $ip = $m.Groups[1].Value
        if ($ip -notmatch '^(192\.168\.|10\.|127\.|0\.0\.0\.0|255\.)') { $remote[$ip] = $true }
    }
}

Write-Note ("packets touching UDP {0}: {1}" -f $Port, $hits.Count)

if ($remote.Count -gt 0) {
    Write-Ok "TRAFFIC FROM THE INTERNET REACHED THIS PC:"
    foreach ($ip in $remote.Keys) { Write-Host "         $ip" -ForegroundColor Green }
    Write-Host ""
    Write-Note "The router and your ISP are forwarding correctly."
    Write-Note "The failure is above the network - the game is receiving"
    Write-Note "packets and not completing the handshake. Send this to Claude."
} elseif ($hits.Count -gt 0) {
    Write-Bad "Only local traffic seen - nothing from the internet."
    Write-Note "His packets are not getting through the router or the ISP."
} else {
    Write-Bad "NOTHING arrived on UDP $Port at all."
    Write-Note "Either he never pressed F5 during the window, or his packets"
    Write-Note "are being dropped before they reach this machine."
}

Write-Host ""
Write-Note "full capture: $txt"

& pktmon filter remove 2>&1 | Out-Null
Write-Host ""
Read-Host "Press Enter to close"
