# Regenerates PeakOptimizations.ico (purple tile with a white mountain peak).
# Usage: powershell -NoProfile -File tools\New-Icon.ps1
Add-Type -AssemblyName System.Drawing

$root = Split-Path $PSScriptRoot -Parent
$sizes = 256, 64, 48, 32, 24, 16

function New-IconPng([int]$Size) {
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $s = $Size / 256.0

    # Rounded tile with a purple gradient
    $r = 56 * $s; $pad = 8 * $s; $w = $Size - 2 * $pad
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($pad, $pad, $r, $r, 180, 90)
    $path.AddArc($pad + $w - $r, $pad, $r, $r, 270, 90)
    $path.AddArc($pad + $w - $r, $pad + $w - $r, $r, $r, 0, 90)
    $path.AddArc($pad, $pad + $w - $r, $r, $r, 90, 90)
    $path.CloseFigure()
    $rect = New-Object System.Drawing.RectangleF($pad, $pad, $w, $w)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, [System.Drawing.Color]::FromArgb(255, 150, 120, 255), [System.Drawing.Color]::FromArgb(255, 92, 56, 230), 90.0)
    $g.FillPath($brush, $path)

    function Pt([double]$x, [double]$y) { [System.Drawing.PointF]::new($x * $s, $y * $s) }
    # Two white peaks, the taller one in front
    $back = [System.Drawing.PointF[]]@(
        (Pt 132 196), (Pt 172 104), (Pt 214 196))
    $front = [System.Drawing.PointF[]]@(
        (Pt 42 196), (Pt 112 60), (Pt 182 196))
    $g.FillPolygon([System.Drawing.Brush](New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(150, 255, 255, 255))), [System.Drawing.PointF[]]$back)
    $g.FillPolygon([System.Drawing.Brushes]::White, [System.Drawing.PointF[]]$front)
    # Snow-cap notch for a little depth (skipped at tiny sizes where it would blur)
    if ($Size -ge 32) {
        $cap = [System.Drawing.PointF[]]@(
            (Pt 92 99), (Pt 112 60), (Pt 132 99),
            (Pt 120 92), (Pt 112 104), (Pt 104 92))
        $g.FillPolygon([System.Drawing.Brush](New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 205, 195, 255))), [System.Drawing.PointF[]]$cap)
    }
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    , $ms.ToArray()
}

# ICO file: header, one directory entry per size, then the PNG images.
$images = foreach ($size in $sizes) { , (New-IconPng $size) }
$out = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($out)
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
    $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$images[$i].Length); $bw.Write([uint32]$offset)
    $offset += $images[$i].Length
}
foreach ($img in $images) { $bw.Write($img) }
$bw.Flush()
[System.IO.File]::WriteAllBytes((Join-Path $root 'PeakOptimizations.ico'), $out.ToArray())
[System.IO.File]::WriteAllBytes((Join-Path $root 'tools\icon-preview.png'), $images[0])
Write-Host "Wrote PeakOptimizations.ico ($($sizes -join ', ') px)"

