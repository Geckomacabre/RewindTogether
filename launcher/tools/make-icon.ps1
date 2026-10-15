<#
  Generates launcher\RewindTogether.Launcher\Assets\icon.ico - a neon VHS cassette - at
  16/24/32/48/64/128/256 px. Pure System.Drawing, no downloads. Re-run after changing the design.

    powershell -ExecutionPolicy Bypass -File tools\make-icon.ps1
#>
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'
$out = Join-Path $PSScriptRoot '..\RewindTogether.Launcher\Assets\icon.ico'

function New-RoundRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = 2 * $r
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Draw-Icon([int]$s) {
    $bmp = New-Object System.Drawing.Bitmap $s, $s, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $k = $s / 256.0

    # tile
    $bg = New-RoundRect (8*$k) (8*$k) (240*$k) (240*$k) (52*$k)
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.PointF 0,0), (New-Object System.Drawing.PointF $s,$s), ([System.Drawing.Color]::FromArgb(255,40,16,82)), ([System.Drawing.Color]::FromArgb(255,12,10,34))
    $g.FillPath($grad, $bg)
    $pinkPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255,255,62,165)), ([Math]::Max(1.5, 10*$k))
    $g.DrawPath($pinkPen, $bg)

    # cassette body
    $body = New-RoundRect (36*$k) (70*$k) (184*$k) (120*$k) (16*$k)
    $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255,24,20,52))), $body)
    $cyanPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255,45,226,230)), ([Math]::Max(1.5, 9*$k))
    $g.DrawPath($cyanPen, $body)

    # label window with reels
    $win = New-RoundRect (64*$k) (96*$k) (128*$k) (52*$k) (12*$k)
    $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255,255,62,165))), $win)
    $reel = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255,24,20,52))
    $g.FillEllipse($reel, 80*$k, 104*$k, 36*$k, 36*$k)
    $g.FillEllipse($reel, 140*$k, 104*$k, 36*$k, 36*$k)
    $hub = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255,255,211,25))
    $g.FillEllipse($hub, 92*$k, 116*$k, 12*$k, 12*$k)
    $g.FillEllipse($hub, 152*$k, 116*$k, 12*$k, 12*$k)

    # rewind arrows under the cassette
    if ($s -ge 32) {
        $y = 206*$k; $h = 26*$k
        $arrow = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255,45,226,230))
        foreach ($x0 in @(150, 104)) {
            $pts = @((New-Object System.Drawing.PointF ($x0*$k), $y), (New-Object System.Drawing.PointF (($x0-30)*$k), ($y + $h/2)), (New-Object System.Drawing.PointF ($x0*$k), ($y + $h)))
            $g.FillPolygon($arrow, [System.Drawing.PointF[]]$pts)
        }
    }
    $g.Dispose()
    return $bmp
}

$sizes = 16, 24, 32, 48, 64, 128, 256
$pngs = foreach ($s in $sizes) {
    $b = Draw-Icon $s
    $ms = New-Object System.IO.MemoryStream
    $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $b.Dispose()
    ,$ms.ToArray()
}

$fs = [System.IO.File]::Create($out)
$w = New-Object System.IO.BinaryWriter $fs
$w.Write([UInt16]0); $w.Write([UInt16]1); $w.Write([UInt16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]
    $w.Write([byte]($(if ($s -ge 256) { 0 } else { $s })))
    $w.Write([byte]($(if ($s -ge 256) { 0 } else { $s })))
    $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([UInt16]1); $w.Write([UInt16]32)
    $w.Write([UInt32]$pngs[$i].Length); $w.Write([UInt32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $w.Write($p) }
$w.Close()
Write-Host "Wrote $out"
