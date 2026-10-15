param([int]$ProcId, [int]$X, [int]$Y)
Add-Type @'
using System; using System.Runtime.InteropServices;
public class WP { [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f); }
'@
$h = (Get-Process -Id $ProcId).MainWindowHandle
[WP]::SetWindowPos($h, [IntPtr]::Zero, $X, $Y, 0, 0, 0x0001 -bor 0x0004) | Out-Null   # NOSIZE | NOZORDER
