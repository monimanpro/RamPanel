# Draws the RamPanel icon (dark rounded tile with a blue memory stick) and writes a multi-size PNG-based .ico.
param([string]$Out = (Join-Path $PSScriptRoot 'RamPanel.ico'))
Add-Type -AssemblyName System.Drawing
function Draw([int]$s) {
    $bmp = New-Object Drawing.Bitmap($s, $s, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.Clear([Drawing.Color]::Transparent)
    function RR($x, $y, $w, $h, $r) {
        $p = New-Object Drawing.Drawing2D.GraphicsPath; $d = $r * 2
        $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
        $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90); $p.CloseFigure(); $p
    }
    $k = $s / 256.0
    $tile = RR (4 * $k) (4 * $k) (248 * $k) (248 * $k) (52 * $k)
    $g.FillPath((New-Object Drawing.SolidBrush([Drawing.ColorTranslator]::FromHtml('#16181c'))), $tile)
    $accent = [Drawing.ColorTranslator]::FromHtml('#4f8cff')
    # memory stick body
    $stick = RR (34 * $k) (78 * $k) (188 * $k) (86 * $k) (10 * $k)
    $g.FillPath((New-Object Drawing.SolidBrush($accent)), $stick)
    # chips
    $chip = New-Object Drawing.SolidBrush([Drawing.ColorTranslator]::FromHtml('#16181c'))
    foreach ($i in 0..3) { $g.FillRectangle($chip, [float]((50 + $i * 42) * $k), [float](96 * $k), [float](30 * $k), [float](40 * $k)) }
    # contacts
    $pin = New-Object Drawing.SolidBrush([Drawing.ColorTranslator]::FromHtml('#9cc4ff'))
    if ($s -ge 32) { for ($x = 44; $x -le 206; $x += 14) { if ($x -lt 120 -or $x -gt 134) { $g.FillRectangle($pin, [float]($x * $k), [float](170 * $k), [float](8 * $k), [float](24 * $k)) } } }
    else { $g.FillRectangle($pin, [float](44 * $k), [float](170 * $k), [float](168 * $k), [float](22 * $k)) }
    $g.Dispose(); return $bmp
}
$sizes = 16, 24, 32, 48, 64, 128, 256
$pngs = foreach ($s in $sizes) { $ms = New-Object IO.MemoryStream; (Draw $s).Save($ms, [Drawing.Imaging.ImageFormat]::Png); , $ms.ToArray() }
$fs = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter($fs)
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $len = $pngs[$i].Length
    $w.Write([byte]($s % 256)); $w.Write([byte]($s % 256)); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$len); $w.Write([uint32]$offset); $offset += $len
}
foreach ($p in $pngs) { $w.Write($p) }
$w.Flush(); [IO.File]::WriteAllBytes($Out, $fs.ToArray())
"icon written: $Out ($($fs.Length) bytes)"
