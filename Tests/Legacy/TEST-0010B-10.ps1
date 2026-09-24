Write-Host "TEST-0010B-10 PS1 WORKFLOW OK"
# ============================================================
# TEST-0010B-10
# THAI RASTER THRESHOLD COMPARISON
# Epson TM-T82X
# GS ( L
#
# A = AntiAliasGridFit + Threshold 160
# B = AntiAliasGridFit + Threshold 180
# C = AntiAliasGridFit + Threshold 200
# ============================================================

$printerIp   = "192.0.2.10"
$printerPort = 9100

Add-Type -AssemblyName System.Drawing

$widthDots   = 576
$heightDots  = 650
$bytesPerRow = 72

# ------------------------------------------------------------
# Main bitmap
# ------------------------------------------------------------

$bitmap = New-Object System.Drawing.Bitmap(
    $widthDots,
    $heightDots,
    [System.Drawing.Imaging.PixelFormat]::Format24bppRgb
)

$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.Clear([System.Drawing.Color]::White)

# ------------------------------------------------------------
# Fonts
# ------------------------------------------------------------

$fontLabel = New-Object System.Drawing.Font(
    "Tahoma",22,
    [System.Drawing.FontStyle]::Bold,
    [System.Drawing.GraphicsUnit]::Pixel
)

$fontThai = New-Object System.Drawing.Font(
    "Tahoma",28,
    [System.Drawing.FontStyle]::Regular,
    [System.Drawing.GraphicsUnit]::Pixel
)

$fontBold = New-Object System.Drawing.Font(
    "Tahoma",28,
    [System.Drawing.FontStyle]::Bold,
    [System.Drawing.GraphicsUnit]::Pixel
)

$brush = [System.Drawing.Brushes]::Black

# ------------------------------------------------------------
# Create one section
# ------------------------------------------------------------

function New-TestSection {

    param(
        [string]$Label
    )

    $section = New-Object System.Drawing.Bitmap(
        576,
        190,
        [System.Drawing.Imaging.PixelFormat]::Format24bppRgb
    )

    $g = [System.Drawing.Graphics]::FromImage($section)

    $g.Clear([System.Drawing.Color]::White)

    $g.TextRenderingHint =
        [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

    $g.DrawString(
        $Label,$fontLabel,$brush,20,5
    )

    $g.DrawString(
        "1  ข้าวผัดปู",$fontThai,$brush,20,42
    )

    $g.DrawString(
        "2  ต้มยำกุ้งน้ำข้น",$fontThai,$brush,20,80
    )

    $g.DrawString(
        "1  เนื้อปูผัดผงกะหรี่",$fontThai,$brush,20,118
    )

    $g.DrawString(
        "ไม่ใส่พริก  ABC 1234567890",
        $fontBold,$brush,20,155
    )

    $g.Dispose()

    return $section
}

# ------------------------------------------------------------
# Three identical renderings
# Threshold is changed later during 1-bit conversion
# ------------------------------------------------------------

$sectionA = New-TestSection "A  AntiAliasGridFit - TH160"
$sectionB = New-TestSection "B  AntiAliasGridFit - TH180"
$sectionC = New-TestSection "C  AntiAliasGridFit - TH200"

$graphics.DrawImageUnscaled($sectionA,0,10)
$graphics.DrawImageUnscaled($sectionB,0,220)
$graphics.DrawImageUnscaled($sectionC,0,430)

$graphics.Dispose()

# ============================================================
# BITMAP -> 1-BIT RASTER
#
# A = Threshold 160
# B = Threshold 180
# C = Threshold 200
#
# IMPORTANT:
# Correct byte packing = $x -shr 3
# ============================================================

$raster = New-Object byte[] ($bytesPerRow * $heightDots)

$blackPixelsA = 0
$blackPixelsB = 0
$blackPixelsC = 0

for ($y = 0; $y -lt $heightDots; $y++) {

    if ($y -lt 210) {
        $threshold = 160
        $sectionName = "A"
    }
    elseif ($y -lt 420) {
        $threshold = 180
        $sectionName = "B"
    }
    else {
        $threshold = 200
        $sectionName = "C"
    }

    for ($x = 0; $x -lt $widthDots; $x++) {

        $pixel = $bitmap.GetPixel($x,$y)

        $luminance =
            (0.299 * $pixel.R) +
            (0.587 * $pixel.G) +
            (0.114 * $pixel.B)

        if ($luminance -lt $threshold) {

            $byteIndex =
                ($y * $bytesPerRow) +
                ($x -shr 3)

            $bit = 7 - ($x % 8)

            $raster[$byteIndex] =
                $raster[$byteIndex] -bor
                (1 -shl $bit)

            switch ($sectionName) {
                "A" { $blackPixelsA++ }
                "B" { $blackPixelsB++ }
                "C" { $blackPixelsC++ }
            }
        }
    }
}

$bitmap.Dispose()
$sectionA.Dispose()
$sectionB.Dispose()
$sectionC.Dispose()

# ============================================================
# GS ( L Function 112
# ============================================================

$xDots = $widthDots
$yDots = $heightDots

$xL = $xDots -band 0xFF
$xH = ($xDots -shr 8) -band 0xFF

$yL = $yDots -band 0xFF
$yH = ($yDots -shr 8) -band 0xFF

$parameterLength = 10 + $raster.Length

$pL = $parameterLength -band 0xFF
$pH = ($parameterLength -shr 8) -band 0xFF

$storeHeader = [byte[]](
    0x1D,0x28,0x4C,
    $pL,$pH,
    0x30,0x70,
    0x30,0x01,0x01,0x31,
    $xL,$xH,
    $yL,$yH
)

$printGraphics = [byte[]](
    0x1D,0x28,0x4C,
    0x02,0x00,
    0x30,0x32
)

$init = [byte[]](0x1B,0x40)
$feed = [byte[]](0x1B,0x64,0x04)
$cut  = [byte[]](0x1D,0x56,0x01)

# ============================================================
# VALIDATION
# ============================================================

Write-Host ""
Write-Host "========================================"
Write-Host " TEST-0010B-10"
Write-Host " THRESHOLD 160 / 180 / 200"
Write-Host "========================================"
Write-Host ""

Write-Host "Width dots       : $widthDots"
Write-Host "Height dots      : $heightDots"
Write-Host "Bytes per row    : $bytesPerRow"
Write-Host "Raster bytes     : $($raster.Length)"
Write-Host "Parameter length : $parameterLength"
Write-Host ""

Write-Host "Black pixels A160: $blackPixelsA"
Write-Host "Black pixels B180: $blackPixelsB"
Write-Host "Black pixels C200: $blackPixelsC"
Write-Host ""

$validationOK = $true

if ($widthDots -ne 576) {
    Write-Host "FAIL - width"
    $validationOK = $false
}

if ($heightDots -ne 650) {
    Write-Host "FAIL - height"
    $validationOK = $false
}

if ($bytesPerRow -ne 72) {
    Write-Host "FAIL - bytesPerRow"
    $validationOK = $false
}

if ($raster.Length -ne 46800) {
    Write-Host "FAIL - raster length"
    $validationOK = $false
}

if ($storeHeader.Length -ne 15) {
    Write-Host "FAIL - header length"
    $validationOK = $false
}

if (
    $blackPixelsA -le 0 -or
    $blackPixelsB -le 0 -or
    $blackPixelsC -le 0
) {
    Write-Host "FAIL - black pixels"
    $validationOK = $false
}

if (-not $validationOK) {

    Write-Host ""
    Write-Host "VALIDATION FAILED"
    Write-Host "NOTHING SENT TO PRINTER"

    exit 1
}

Write-Host "BASIC VALIDATION PASS"
Write-Host ""

# ------------------------------------------------------------
# Exact header validation
# ------------------------------------------------------------

$actualHeader = (($storeHeader | ForEach-Object {
    "{0:X2}" -f $_
}) -join " ")

$expectedHeader =
    "1D 28 4C DA B6 30 70 30 01 01 31 40 02 8A 02"

Write-Host "HEADER:"
Write-Host $actualHeader
Write-Host ""

if ($actualHeader -ne $expectedHeader) {

    Write-Host "HEADER VALIDATION FAILED"
    Write-Host "Expected: $expectedHeader"
    Write-Host "Actual  : $actualHeader"
    Write-Host "NOTHING SENT TO PRINTER"

    exit 1
}

Write-Host "HEADER VALIDATION PASS"
Write-Host ""

# ============================================================
# SEND
# ============================================================

$client = [System.Net.Sockets.TcpClient]::new()
$stream = $null

try {

    $client.SendTimeout = 5000

    Write-Host "[1] Connecting..."
    $client.Connect($printerIp,$printerPort)

    $stream = $client.GetStream()

    Write-Host "    Connected"

    Write-Host "[2] ESC @"
    $stream.Write($init,0,$init.Length)

    Write-Host "[3] Function 112 header"
    $stream.Write(
        $storeHeader,
        0,
        $storeHeader.Length
    )

    Write-Host "[4] Raster data"
    $stream.Write(
        $raster,
        0,
        $raster.Length
    )

    $stream.Flush()

    Write-Host "    $($raster.Length) bytes sent"

    Start-Sleep -Milliseconds 500

    Write-Host "[5] Function 50"
    $stream.Write(
        $printGraphics,
        0,
        $printGraphics.Length
    )

    $stream.Flush()

    Start-Sleep -Milliseconds 1000

    Write-Host "[6] Feed"
    $stream.Write(
        $feed,
        0,
        $feed.Length
    )

    $stream.Flush()

    Start-Sleep -Milliseconds 300

    Write-Host "[7] Cut"
    $stream.Write(
        $cut,
        0,
        $cut.Length
    )

    $stream.Flush()

    Write-Host ""
    Write-Host "========================================"
    Write-Host " ALL COMMANDS SENT"
    Write-Host "========================================"
}
catch {

    Write-Host ""
    Write-Host "ERROR:"
    Write-Host $_.Exception.Message
}
finally {

    if ($null -ne $stream) {
        $stream.Dispose()
    }

    $client.Dispose()
}

$fontLabel.Dispose()
$fontThai.Dispose()
$fontBold.Dispose()

Write-Host ""
Write-Host "Connection closed."
