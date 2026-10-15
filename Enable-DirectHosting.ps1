<#
.SYNOPSIS
    Opens everything needed to host Rewind Together over the internet on a
    direct connection - no VPN, no third-party service, nothing to pay for.

.DESCRIPTION
    Three things stop a friend reaching your listen server:

      1. Windows Firewall blocking inbound UDP on the game port.
      2. Your router not forwarding that port to this PC.
      3. Not knowing which address to give them.

    This handles all three. The firewall rule is created directly. The router
    forward is attempted over UPnP, which most home routers have enabled - if
    yours does not, the script tells you the exact three values to type into
    your router's admin page instead. Then it prints the address your friend
    needs.

    Run Disable-DirectHosting or pass -Remove to undo everything.

.PARAMETER Port
    UDP port to open. Must match Config.Port in the mod (default 27015).

    27015 was measured from the running game's socket, not assumed. Unreal's
    documented default is 7777, but this build's packaged DefaultEngine.ini
    sets [URL] Port=27015 and the travel URL cannot override it.

.PARAMETER Remove
    Undo the firewall rule and the UPnP mapping.

.PARAMETER SkipPublicIP
    Do not look up your public IP. Without this the script makes one request
    to a public "what is my IP" service.
#>

[CmdletBinding()]
param(
    [int]    $Port = 27015,
    [switch] $Remove,
    [switch] $SkipPublicIP
)

$ErrorActionPreference = 'Continue'

function Write-Step ($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   ($m) { Write-Host "    OK   $m" -ForegroundColor Green }
function Write-Warn2($m) { Write-Host "    WARN $m" -ForegroundColor Yellow }
function Write-Fail ($m) { Write-Host "    FAIL $m" -ForegroundColor Red }

$RuleName = "Rewind Together (Retro Rewind co-op)"
$MapDesc  = "RewindTogether"

# --------------------------------------------------------------------------
# Elevate - the firewall rule needs admin
# --------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host ""
    Write-Host "  Administrator rights are needed to add the firewall rule." -ForegroundColor Yellow
    Write-Host "  Re-launching - accept the Windows prompt." -ForegroundColor Yellow
    Write-Host ""
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-Port',$Port)
    if ($Remove)       { $argList += '-Remove' }
    if ($SkipPublicIP) { $argList += '-SkipPublicIP' }
    try {
        Start-Process powershell -Verb RunAs -ArgumentList $argList
    } catch {
        Write-Fail "Elevation was declined. Run this script as Administrator."
    }
    return
}

Write-Host ""
Write-Host "  Rewind Together - direct hosting setup" -ForegroundColor White
Write-Host "  --------------------------------------" -ForegroundColor DarkGray
Write-Host ""

# --------------------------------------------------------------------------
# Work out this PC's LAN address
# --------------------------------------------------------------------------
Write-Step "Finding your LAN address"

# Take the address on whichever interface owns the default route.
#
# Not the lowest-metric address: Get-NetIPAddress does not even return
# InterfaceMetric, so sorting on it sorts on nulls, and on a machine with
# Hyper-V or WSL the virtual switch outranks the real card anyway. The
# interface carrying 0.0.0.0/0 is the one the router is on, by definition.
$lan = $null
$defaultRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                Sort-Object RouteMetric | Select-Object -First 1
if ($defaultRoute) {
    $lan = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $defaultRoute.InterfaceIndex `
                            -ErrorAction SilentlyContinue |
           Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
           Select-Object -First 1
}

if (-not $lan) {
    # No usable default route - fall back to any real-looking adapter.
    $lan = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object {
               $_.IPAddress -notlike '127.*' -and
               $_.IPAddress -notlike '169.254.*' -and
               $_.InterfaceAlias -notmatch 'Loopback|vEthernet|VirtualBox|VMware|Hyper-V|WSL|Docker'
           } | Select-Object -First 1
}

if (-not $lan) {
    Write-Fail "Could not determine a LAN IPv4 address."
    return
}
$LocalIP = $lan.IPAddress
Write-Ok "LAN address: $LocalIP  ($($lan.InterfaceAlias))"

# --------------------------------------------------------------------------
# Firewall
# --------------------------------------------------------------------------
if ($Remove) {
    Write-Step "Removing the firewall rule"
    $existing = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
    if ($existing) {
        $existing | Remove-NetFirewallRule
        Write-Ok "Removed '$RuleName'"
    } else {
        Write-Ok "No rule to remove"
    }
} else {
    Write-Step "Allowing the game through Windows Firewall"
    Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    try {
        New-NetFirewallRule -DisplayName $RuleName `
            -Direction Inbound -Protocol UDP -LocalPort $Port `
            -Action Allow -Profile Any -ErrorAction Stop | Out-Null
        Write-Ok "Inbound UDP $Port allowed"
    } catch {
        Write-Fail "Could not create the firewall rule: $($_.Exception.Message)"
    }
}

# --------------------------------------------------------------------------
# Router forward over UPnP
# --------------------------------------------------------------------------
#
# Two routes are tried, because the obvious one is unreliable on exactly the
# machines most likely to be running this.
#
# Windows' HNetCfg.NATUPnP COM object performs its own SSDP discovery and sends
# the multicast out whichever interface Windows ranks first. Any machine with
# Hyper-V, WSL, Docker, VMware or VirtualBox has a virtual switch holding a
# private address at a LOWER interface metric than the real network card, so
# the discovery goes out a switch with no router on it, nothing answers, and
# the COM object returns null. It looks exactly like "the router has UPnP
# turned off" and no amount of changing router settings fixes it.
#
# So if the COM route comes up empty we do the discovery ourselves, bound to
# the interface that actually owns the default route, and speak SOAP to the
# Internet Gateway Device directly.

function Find-Igd {
    param([string] $BindAddress)

    $msg = "M-SEARCH * HTTP/1.1`r`nHOST: 239.255.255.250:1900`r`n" +
           "MAN: `"ssdp:discover`"`r`nMX: 3`r`nST: ssdp:all`r`n`r`n"
    $bytes = [Text.Encoding]::ASCII.GetBytes($msg)

    $udp = $null
    try {
        if ($BindAddress) {
            $udp = New-Object Net.Sockets.UdpClient (New-Object Net.IPEndPoint([Net.IPAddress]::Parse($BindAddress), 0))
        } else {
            $udp = New-Object Net.Sockets.UdpClient
        }
        $udp.Client.ReceiveTimeout = 3000
        [void]$udp.Send($bytes, $bytes.Length,
            (New-Object Net.IPEndPoint([Net.IPAddress]::Parse('239.255.255.250'), 1900)))

        $locations = @()
        $deadline = (Get-Date).AddSeconds(4)
        while ((Get-Date) -lt $deadline) {
            try {
                $remote = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
                $data = $udp.Receive([ref]$remote)
                $text = [Text.Encoding]::ASCII.GetString($data)
                $loc = ([regex]::Match($text, '(?im)^LOCATION:\s*(.+)$')).Groups[1].Value.Trim()
                if ($loc -and $locations -notcontains $loc) { $locations += $loc }
            } catch { break }
        }
        $udp.Close(); $udp = $null

        foreach ($loc in $locations) {
            try {
                $xml = Invoke-RestMethod -Uri $loc -TimeoutSec 6
            } catch { continue }

            $svcs = New-Object System.Collections.ArrayList
            $walk = {
                param($d)
                if ($d.serviceList) { $d.serviceList.service | ForEach-Object { [void]$svcs.Add($_) } }
                if ($d.deviceList)  { $d.deviceList.device  | ForEach-Object { & $walk $_ } }
            }
            & $walk $xml.root.device

            $svc = $svcs | Where-Object { $_.serviceType -match 'WANIPConnection|WANPPPConnection' } |
                   Select-Object -First 1
            if ($svc) {
                $u = [Uri]$loc
                $ctrl = $svc.controlURL
                if ($ctrl -notmatch '^https?://') {
                    if ($ctrl -notmatch '^/') { $ctrl = '/' + $ctrl }
                    $ctrl = "{0}://{1}:{2}{3}" -f $u.Scheme, $u.Host, $u.Port, $ctrl
                }
                return [pscustomobject]@{ ControlUrl = $ctrl; ServiceType = $svc.serviceType }
            }
        }
    } catch {
    } finally {
        if ($udp) { try { $udp.Close() } catch {} }
    }
    return $null
}

function Invoke-IgdAction {
    param($Igd, [string] $Action, [string] $ArgsXml)

    $body = @"
<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:$Action xmlns:u="$($Igd.ServiceType)">$ArgsXml</u:$Action></s:Body>
</s:Envelope>
"@
    Invoke-WebRequest -Uri $Igd.ControlUrl -Method Post -TimeoutSec 8 `
        -ContentType 'text/xml; charset="utf-8"' `
        -Headers @{ SOAPAction = "`"$($Igd.ServiceType)#$Action`"" } `
        -Body $body -UseBasicParsing
}

Write-Step "Asking your router to forward UDP $Port (UPnP)"

$upnpOk = $false
try {
    $nat = New-Object -ComObject HNetCfg.NATUPnP -ErrorAction Stop
    $maps = $nat.StaticPortMappingCollection

    if ($null -eq $maps) {
        Write-Warn2 "Router did not respond to UPnP (it may be disabled)"
    } else {
        # Clear any previous mapping so re-running is safe.
        try { $maps.Remove($Port, "UDP") } catch {}

        if ($Remove) {
            Write-Ok "UPnP mapping removed"
            $upnpOk = $true
        } else {
            $maps.Add($Port, "UDP", $Port, $LocalIP, $true, $MapDesc)
            Start-Sleep -Milliseconds 400
            $check = $null
            try { $check = $maps.Item($Port, "UDP") } catch {}
            if ($check) {
                Write-Ok "Router now forwards UDP $Port -> $LocalIP"
                $upnpOk = $true
            } else {
                Write-Warn2 "Router accepted the request but did not confirm it"
            }
        }
    }
} catch {
    Write-Warn2 "UPnP unavailable: $($_.Exception.Message)"
}

# Windows could not find the gateway. Do the discovery ourselves, bound to the
# NIC that owns the default route, and talk to the router directly.
if (-not $upnpOk) {
    Write-Warn2 "Windows' UPnP could not reach the router - trying it directly"

    $igd = Find-Igd -BindAddress $LocalIP
    if (-not $igd) { $igd = Find-Igd }

    if (-not $igd) {
        Write-Warn2 "No UPnP Internet Gateway Device answered"
    } else {
        Write-Ok "Found gateway: $($igd.ControlUrl)"
        try {
            # Clear a stale mapping first so re-running is safe.
            try {
                Invoke-IgdAction $igd 'DeletePortMapping' @"
<NewRemoteHost></NewRemoteHost><NewExternalPort>$Port</NewExternalPort><NewProtocol>UDP</NewProtocol>
"@ | Out-Null
            } catch {}

            if ($Remove) {
                Write-Ok "UPnP mapping removed"
                $upnpOk = $true
            } else {
                Invoke-IgdAction $igd 'AddPortMapping' @"
<NewRemoteHost></NewRemoteHost><NewExternalPort>$Port</NewExternalPort><NewProtocol>UDP</NewProtocol><NewInternalPort>$Port</NewInternalPort><NewInternalClient>$LocalIP</NewInternalClient><NewEnabled>1</NewEnabled><NewPortMappingDescription>$MapDesc</NewPortMappingDescription><NewLeaseDuration>0</NewLeaseDuration>
"@ | Out-Null

                # Read it back - an accepted SOAP call is not proof it stuck.
                Start-Sleep -Milliseconds 400
                $verified = $false
                try {
                    $r = Invoke-IgdAction $igd 'GetSpecificPortMappingEntry' @"
<NewRemoteHost></NewRemoteHost><NewExternalPort>$Port</NewExternalPort><NewProtocol>UDP</NewProtocol>
"@
                    # This router answers 200 with an EMPTY NewInternalClient
                    # when no mapping exists, rather than the SOAP fault the
                    # spec calls for - so the tag being present proves nothing.
                    # Require the value, and require it to be this machine.
                    $client = ([regex]::Match($r.Content,
                        '<NewInternalClient>\s*(.*?)\s*</NewInternalClient>')).Groups[1].Value
                    if ($client -eq $LocalIP) { $verified = $true }
                    elseif ($client) {
                        Write-Warn2 "Port $Port is already forwarded to a DIFFERENT device ($client)"
                    }
                } catch {}

                if ($verified) {
                    Write-Ok "Router now forwards UDP $Port -> $LocalIP (verified)"
                    $upnpOk = $true
                } else {
                    Write-Warn2 "Router accepted the request but did not confirm it"
                }
            }
        } catch {
            Write-Warn2 "Router refused the request: $($_.Exception.Message)"
        }
    }
}

if ($Remove) {
    Write-Host ""
    Write-Host "  Done - direct hosting turned off." -ForegroundColor Green
    Write-Host ""
    return
}

if (-not $upnpOk) {
    Write-Host ""
    Write-Host "  Your router did not do it automatically." -ForegroundColor Yellow
    Write-Host "  Open your router's admin page (usually http://192.168.1.1)," -ForegroundColor Gray
    Write-Host "  find 'Port Forwarding', and add ONE rule:" -ForegroundColor Gray
    Write-Host ""
    Write-Host "      Protocol :  UDP" -ForegroundColor White
    Write-Host "      External :  $Port" -ForegroundColor White
    Write-Host "      Internal :  $Port" -ForegroundColor White
    Write-Host "      Device   :  $LocalIP" -ForegroundColor White
    Write-Host ""
    Write-Host "  (Enabling UPnP in the router settings also works, then re-run this.)" -ForegroundColor DarkGray
}

# --------------------------------------------------------------------------
# The address to hand out
# --------------------------------------------------------------------------
Write-Step "Working out the address for your friend"

$publicIP = $null
if (-not $SkipPublicIP) {
    foreach ($svc in @('https://api.ipify.org', 'https://ifconfig.me/ip', 'https://icanhazip.com')) {
        try {
            $publicIP = (Invoke-RestMethod -Uri $svc -TimeoutSec 6).ToString().Trim()
            if ($publicIP -match '^\d+\.\d+\.\d+\.\d+$') { break } else { $publicIP = $null }
        } catch { }
    }
}

Write-Host ""
Write-Host "  ============================================================" -ForegroundColor White
Write-Host "   Tell your friend to type this in their UE4SS console:" -ForegroundColor White
Write-Host ""
if ($publicIP) {
    Write-Host "       rt.join $publicIP" -ForegroundColor Green
    Write-Host ""
    Write-Host "   (Same house / same wifi instead:  rt.join $LocalIP )" -ForegroundColor DarkGray
} else {
    Write-Host "       rt.join <your public IP>" -ForegroundColor Green
    Write-Host ""
    Write-Host "   Look it up at https://whatismyip.com" -ForegroundColor Gray
    Write-Host "   (Same house / same wifi instead:  rt.join $LocalIP )" -ForegroundColor DarkGray
}
Write-Host "  ============================================================" -ForegroundColor White
Write-Host ""
Write-Host "  Order of play:" -ForegroundColor White
Write-Host "    1. You:     load your save, walk into the store, press F7."
Write-Host "    2. Friend:  rt.join <the address above>"
Write-Host ""
Write-Host "  Note: your public IP can change when your router reboots." -ForegroundColor DarkGray
Write-Host "  Re-run this script if your friend suddenly cannot connect." -ForegroundColor DarkGray
Write-Host ""
