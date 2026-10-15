# Lay out the primary monitor so the user can watch everything at once:
# Claude on the left, host game in the middle, guest game on the right.
param([int]$HostPid = 0, [int]$GuestPid = 0, [int]$ClaudePid = 0)
Add-Type @'
using System; using System.Runtime.InteropServices;
public class L {
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
}
'@
function Put($procId, $x, $y, $w, $h) {
  if ($procId -le 0) { return }
  $hw = (Get-Process -Id $procId -ErrorAction SilentlyContinue).MainWindowHandle
  if (-not $hw -or $hw -eq 0) { return }
  [L]::ShowWindow($hw, 9) | Out-Null                         # restore if maximised
  [L]::SetWindowPos($hw, [IntPtr]::Zero, $x, $y, $w, $h, 0x0004) | Out-Null   # NOZORDER
}
$cw = 900          # Claude column
$gw = 1270         # each game, outer width (client ~1254x705)
$gh = 744
Put $ClaudePid 0 0 $cw 1392
Put $HostPid  $cw 0 $gw $gh
Put $GuestPid ($cw + $gw) 0 $gw $gh
