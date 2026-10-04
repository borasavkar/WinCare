#requires -Version 5.1
<#
    Draws the WinCare icon with WPF and writes:
        assets/WinCare.ico   (16, 20, 24, 32, 40, 48, 64, 128, 256)
        assets/icon-256.png
    Run:  powershell -NoProfile -STA -File build\New-Icon.ps1
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationCore, WindowsBase, PresentationFramework

$root   = Split-Path -Parent $PSScriptRoot
$assets = Join-Path $root 'assets'
if (-not (Test-Path $assets)) { New-Item -ItemType Directory -Path $assets | Out-Null }

function New-Brush([string]$hex) { New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($hex)) }

function Get-IconBitmap([int]$Size) {
    # Everything is drawn on a 256 x 256 canvas and scaled down.
    $dv = New-Object System.Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $dc.PushTransform((New-Object System.Windows.Media.ScaleTransform ($Size / 256.0), ($Size / 256.0)))

    $grad = New-Object System.Windows.Media.LinearGradientBrush
    $grad.StartPoint = '0,0'; $grad.EndPoint = '1,1'
    $grad.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.ColorConverter]::ConvertFromString('#FF3D9DFF')), 0))
    $grad.GradientStops.Add((New-Object System.Windows.Media.GradientStop ([System.Windows.Media.ColorConverter]::ConvertFromString('#FF0055B0')), 1))

    # Small sizes get a little less margin so the shape stays readable
    $m = if ($Size -le 24) { 4 } else { 14 }
    $dc.DrawRoundedRectangle($grad, $null, (New-Object System.Windows.Rect $m, $m, (256 - 2 * $m), (256 - 2 * $m)), 56, 56)

    $white  = New-Brush '#FFFFFFFF'
    $accent = New-Brush '#FF0060C0'

    if ($Size -le 24) {
        # 16-24 px: a bold check only
        $pen = New-Object System.Windows.Media.Pen $white, 34
        $pen.StartLineCap = 'Round'; $pen.EndLineCap = 'Round'; $pen.LineJoin = 'Round'
        $g = [System.Windows.Media.Geometry]::Parse('M 66,134 L 110,178 L 192,90')
        $dc.DrawGeometry($null, $pen, $g)
    } else {
        $shield = [System.Windows.Media.Geometry]::Parse('M 128,46 L 192,70 L 192,124 C 192,168 164,196 128,212 C 92,196 64,168 64,124 L 64,70 Z')
        $dc.DrawGeometry($white, $null, $shield)
        $pen = New-Object System.Windows.Media.Pen $accent, 18
        $pen.StartLineCap = 'Round'; $pen.EndLineCap = 'Round'; $pen.LineJoin = 'Round'
        $dc.DrawGeometry($null, $pen, [System.Windows.Media.Geometry]::Parse('M 98,128 L 120,150 L 160,108'))
    }
    $dc.Pop(); $dc.Close()

    $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap $Size, $Size, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($dv)
    $bmp
}

function Get-PngBytes($Bitmap) {
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($Bitmap))
    $ms = New-Object IO.MemoryStream; $enc.Save($ms)
    ,[byte[]]$ms.ToArray()   # comma: keep the array intact (PowerShell unrolls arrays on output)
}

function Get-DibBytes($Bitmap) {
    # Classic ICO entry: BITMAPINFOHEADER + bottom-up BGRA + AND mask.
    # Used for sizes below 256 for maximum compatibility (resource compilers, old viewers).
    $s = $Bitmap.PixelWidth
    $conv = New-Object System.Windows.Media.Imaging.FormatConvertedBitmap $Bitmap, ([System.Windows.Media.PixelFormats]::Bgra32), $null, 0
    $stride = $s * 4
    $px = New-Object byte[] ($stride * $s)
    $conv.CopyPixels($px, $stride, 0)
    $ms = New-Object IO.MemoryStream
    $bw = New-Object IO.BinaryWriter $ms
    $bw.Write([int]40); $bw.Write([int]$s); $bw.Write([int]($s * 2)); $bw.Write([int16]1); $bw.Write([int16]32)
    $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0)
    for ($y = $s - 1; $y -ge 0; $y--) { $bw.Write($px, $y * $stride, $stride) }
    $maskStride = [int]([math]::Ceiling($s / 32.0) * 4)
    $bw.Write((New-Object byte[] ($maskStride * $s)))   # all zero: alpha channel decides
    $bw.Flush()
    ,[byte[]]$ms.ToArray()
}

$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$images = foreach ($sz in $sizes) {
    $b = Get-IconBitmap $sz
    [byte[]]$bytes = if ($sz -ge 256) { Get-PngBytes $b } else { Get-DibBytes $b }
    [pscustomobject]@{ Size = $sz; Data = $bytes }
}

$ico = New-Object IO.MemoryStream
$w = New-Object IO.BinaryWriter $ico
$w.Write([int16]0); $w.Write([int16]1); $w.Write([int16]$images.Count)
$offset = 6 + 16 * $images.Count
foreach ($i in $images) {
    $d = if ($i.Size -ge 256) { 0 } else { $i.Size }
    $w.Write([byte]$d); $w.Write([byte]$d); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([int16]1); $w.Write([int16]32); $w.Write([int]$i.Data.Length); $w.Write([int]$offset)
    $offset += $i.Data.Length
}
foreach ($i in $images) { $w.Write([byte[]]$i.Data) }
$w.Flush()
[IO.File]::WriteAllBytes((Join-Path $assets 'WinCare.ico'), $ico.ToArray())
[IO.File]::WriteAllBytes((Join-Path $assets 'icon-256.png'), [byte[]](Get-PngBytes (Get-IconBitmap 256)))

# Preview sheet for review (not committed)
$sheet = New-Object System.Windows.Media.DrawingVisual
$sdc = $sheet.RenderOpen()
$sdc.DrawRectangle((New-Brush '#FF202020'), $null, (New-Object System.Windows.Rect 0, 0, 760, 300))
$sdc.DrawRectangle((New-Brush '#FFF3F3F3'), $null, (New-Object System.Windows.Rect 0, 300, 760, 300))
$x = 20
foreach ($sz in 16, 24, 32, 48, 64, 128, 256) {
    $bmp = Get-IconBitmap $sz
    foreach ($row in 0, 300) { $sdc.DrawImage($bmp, (New-Object System.Windows.Rect $x, ($row + (150 - $sz / 2)), $sz, $sz)) }
    $x += $sz + 24
}
$sdc.Close()
$sb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap 760, 600, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
$sb.Render($sheet)
$out = if ($env:WC_PREVIEW) { $env:WC_PREVIEW } else { Join-Path $env:TEMP 'wincare-icon-preview.png' }
[IO.File]::WriteAllBytes($out, [byte[]](Get-PngBytes $sb))

"Icon written: $(Join-Path $assets 'WinCare.ico') ($((Get-Item (Join-Path $assets 'WinCare.ico')).Length) bytes, $($images.Count) sizes)"
"Preview:      $out"
