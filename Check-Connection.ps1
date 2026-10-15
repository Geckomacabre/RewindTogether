<#
.SYNOPSIS
    Rewind Together - connection checker.

.DESCRIPTION
    Answers the three questions that decide whether your friend can join you,
    using facts read from the running system rather than from config files:

      1. Is the game actually listening on a UDP port right now, and which one?
      2. What address should your friend type?
      3. Is anything local (firewall) going to stop them getting in?

    Question 1 is the important one. The mod asks Unreal to listen on a
    particular port, but this game deletes its user Engine.ini on every launch,
    so no config setting survives to prove what happened. The only trustworthy
    answer is to look at the socket the process has open - which is what this
    does.

.PARAMETER Port
    The port you expect, i.e. Config.Port in the mod. Default 27015 - measured
    from the running game, not Unreal's documented 7777 default, which this
    build does not use.
#>

[CmdletBinding()]
param(
    [int] $Port = 27015
)

$ErrorActionPreference = 'Continue'

function Write-Head($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Write-Ok  ($t) { Write-Host "  [ok]   $t" -ForegroundColor Green }
function Write-Bad ($t) { Write-Host "  [BAD]  $t" -ForegroundColor Red }
function Write-Note($t) { Write-Host "  $t" -ForegroundColor Gray }

Write-Host ""
Write-Host "  Rewind Together - connection check" -ForegroundColor White
Write-Host "  expecting UDP port $Port" -ForegroundColor DarkGray

# ----------------------------------------------------------------------------
# 1. Is the game running, and is it listening?
# ----------------------------------------------------------------------------
Write-Head "Game process"

$proc = Get-Process -Name 'RetroRewind*' -ErrorAction SilentlyContinue
if (-not $proc) {
    Write-Bad "Retro Rewind is not running."
    Write-Note "Start the game, load your save, get inside your store, press F7"
    Write-Note "to host, and then run this again. Until the game is hosting there"
    Write-Note "is no socket to look at and this check cannot tell you anything."
    Write-Host ""
    Read-Host "Press Enter to close"
    exit 1
}
foreach ($p in $proc) { Write-Ok "running: $($p.ProcessName) (pid $($p.Id))" }
$pids = $proc.Id

Write-Head "Listening socket"

$eps = Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
       Where-Object { $pids -contains $_.OwningProcess }

if (-not $eps) {
    Write-Bad "The game has no UDP socket open - it is NOT hosting."
    Write-Note "Press F7 inside your store first, wait for the store to reload,"
    Write-Note "then run this again."
    $listenPort = $null
} else {
    # Ignore ephemeral high ports that Steam/telemetry open; report everything,
    # but call out the one that matches (or should have matched) the mod.
    $ports = $eps | Select-Object -ExpandProperty LocalPort -Unique | Sort-Object
    Write-Note ("open UDP ports: " + ($ports -join ', '))

    if ($ports -contains $Port) {
        Write-Ok "listening on $Port - this is the port your friend must use."
        $listenPort = $Port
    } else {
        # Unreal's listen server lands in the low range; Steam's own sockets sit
        # high. Anything in this window is almost certainly the game server.
        $likely = $ports | Where-Object { $_ -ge 7000 -and $_ -le 30000 }
        if ($likely) {
            $listenPort = $likely | Select-Object -First 1
            Write-Bad "NOT listening on $Port - the game is on $listenPort instead."
            Write-Note ""
            Write-Note "This is the mismatch that stops people joining. Set"
            Write-Note "  Config.Port = $listenPort"
            Write-Note "in config.lua on BOTH machines, or tell your friend to use"
            Write-Note "  rt.join <your-ip>:$listenPort"
        } else {
            Write-Bad "No game-server-looking UDP port found."
            Write-Note "The listen server probably did not start. Check the UE4SS"
            Write-Note "console for the 'Co-op session live' block."
            $listenPort = $null
        }
    }
}

# ----------------------------------------------------------------------------
# 2. What address does the friend type?
# ----------------------------------------------------------------------------
Write-Head "Your addresses"

# Pick the address on whichever interface actually owns the default route.
#
# Do NOT just take the lowest-metric address: a machine with Hyper-V, WSL,
# Docker or VirtualBox has virtual switches holding private addresses at a
# LOWER metric than the real network card, so metric order confidently returns
# an address that is not reachable from anywhere. The interface carrying
# 0.0.0.0/0 is the one that talks to the router, by definition.
$defaultRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                Sort-Object RouteMetric | Select-Object -First 1

$lanIp = $null
if ($defaultRoute) {
    $lanIp = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $defaultRoute.InterfaceIndex `
                               -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -ne '127.0.0.1' } |
              Select-Object -First 1).IPAddress
}

$all = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
       Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown' }

# A VPN address beats the LAN address when one exists: it is reachable from
# your friend's machine without touching the router at all.
$vpnIp = $null
foreach ($a in $all) {
    $tag = ''
    if ($a.IPAddress -eq $lanIp) { $tag = ' <-- your LAN address (router-facing)' }
    if ($a.InterfaceAlias -match 'Tailscale|ZeroTier|Radmin|Hamachi' -or
        $a.IPAddress -match '^(100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.|25\.)') {
        $tag = ' <-- VPN, USE THIS ONE'
        if (-not $vpnIp) { $vpnIp = $a.IPAddress }
    }
    if ($a.InterfaceAlias -match 'vEthernet|WSL|Docker|VirtualBox|VMware|Hyper-V') {
        $tag = ' (virtual adapter - ignore)'
    }
    Write-Note ("{0,-16} {1}{2}" -f $a.IPAddress, $a.InterfaceAlias, $tag)
}
if ($vpnIp) { $lanIp = $vpnIp }

$publicIp = $null
try {
    $publicIp = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 6).ip
    Write-Note ("{0,-16} public (as seen from the internet)" -f $publicIp)
} catch {
    Write-Note "public IP: could not look it up (no internet, or blocked)"
}

# ----------------------------------------------------------------------------
# 3. Firewall
# ----------------------------------------------------------------------------
Write-Head "Windows Firewall"

$checkPort = if ($listenPort) { $listenPort } else { $Port }
$rules = Get-NetFirewallRule -Direction Inbound -Enabled True -ErrorAction SilentlyContinue |
         Where-Object { $_.Action -eq 'Allow' }

$hasRule = $false
foreach ($r in $rules) {
    $pf = $r | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
    if ($pf -and $pf.Protocol -eq 'UDP') {
        foreach ($lp in @($pf.LocalPort)) {
            if ($lp -eq $checkPort -or $lp -eq 'Any') { $hasRule = $true; break }
        }
    }
    if ($hasRule) { break }
}

if ($hasRule) {
    Write-Ok "an inbound UDP rule covering $checkPort exists"
} else {
    Write-Bad "no inbound UDP rule for $checkPort"
    Write-Note "Run 'OPEN PORT FOR FRIENDS - Double click me.bat' as admin,"
    Write-Note "or your friend's packets will be dropped before the game sees them."
}

# ----------------------------------------------------------------------------
# 4. What to tell the friend
# ----------------------------------------------------------------------------
Write-Head "Tell your friend to type this"

if ($listenPort) {
    # rt.join appends Config.Port itself, so only spell the port out when the
    # game is on something other than what the mod is configured for.
    $suffix = if ($listenPort -eq $Port) { '' } else { ":$listenPort" }
    Write-Host ""
    if ($lanIp) {
        Write-Host "    Same house / same wifi / same VPN:" -ForegroundColor White
        Write-Host "        rt.join $lanIp$suffix" -ForegroundColor Yellow
    }
    if ($publicIp) {
        Write-Host ""
        Write-Host "    Over the internet (needs the port forwarded):" -ForegroundColor White
        Write-Host "        rt.join $publicIp$suffix" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Note "They must be INSIDE THEIR OWN STORE when they do it, not at the"
    Write-Note "main menu. At the menu there is no player yet and nothing happens."
} else {
    Write-Note "Nothing to give them until the game is actually hosting."
}

Write-Host ""
Read-Host "Press Enter to close"
