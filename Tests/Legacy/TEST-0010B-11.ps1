# ============================================================
# TEST-0010B-11
# KITCHEN TICKET PROTOTYPE
# Epson TM-T82X
#
# Raster:
#   576 dots / 72 bytes per row
#   AntiAliasGridFit
#   Threshold 180
#   GS ( L Function 112 + Function 50
# ============================================================

$printerIp   = "192.0.2.10"
$printerPort = 9100

Add-Type -AssemblyName System.Drawing

# ============================================================
# CONFIG
# ============================================================

$widthDots   = 576
$heightDots  = 760
$bytesPerRow = 72
$threshold   = 180

# ============================================================
# BITMAP
# ============================================================

$bitmap = New-Object System.Drawing.Bitmap(
    $widthDots,
    $heightDots,
    [System.Drawing.Imaging.PixelFormat]::Format24bppRgb
)

$g = [System.Drawing.Graphics]::FromImage($bitmap)

$g.Clear([System.Drawing.Color]::White)

$g.TextRenderingHint =
    [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

$brush = [System.Drawing.Brushes]::Black
$pen   = New-Object System.Drawing.Pen(
    [System.Drawing.Color]::Black,
    2
)

# ============================================================
# FONTS
# ============================================================

$fontHeader = New-Object System.Drawing.Font(
    "Tahoma",40,
    [System.Drawing.FontStyle]::Bold,
    [System.Drawing.GraphicsUnit]::Pixel
)

$fontInfo = New-Object System.Drawing.Font(
    "Tahoma",26,
    [System.Drawing.FontStyle]::Regular,
    [System.Drawing.GraphicsUnit]::Pixel
)

$fontQty = New-Object System.Drawing.Font(
    "Tahoma",40,
    [System.Drawing.FontStyle]::Bold,
    [System.Drawing.GraphicsUnit]::Pixel
)

$fontItem = New-Object System.Drawing.Font(
    "Tahoma",30,
    [System.Drawing.FontStyle]::Regular,
    [System.Drawing.GraphicsUnit]::Pixel
)

$fontNote = New-Object System.Drawing.Font(
    "Tahoma",28,
    [System.Drawing.FontStyle]::Bold,
    [System.Drawing.GraphicsUnit]::Pixel
)

$fontFooter = New-Object System.Drawing.Font(
    "Tahoma",24,
    [System.Drawing.FontStyle]::Regular,
    [System.Drawing.GraphicsUnit]::Pixel
)

# ============================================================
# HELPER: CENTER TEXT
# ============================================================

function Draw-CenteredText {

    param(
        [string]$Text,
        [System.Drawing.Font]$Font,
        [float]$Y
    )

    $size = $g.MeasureString(
        $Text,
        $Font
    )

    $x = ($widthDots - $size.Width) / 2

    $g.DrawString(
        $Text,
        $Font,
        $brush,
        $x,
        $Y
    )
}

# ============================================================
# HELPER: ORDER ITEM
# Quantity deliberately larger than item name
# ============================================================

function Draw-OrderItem {

    param(
        [string]$Qty,
        [string]$Name,
        [string]$Note,
        [float]$Y
    )

    # Quantity
    $g.DrawString(
        $Qty,
        $fontQty,
        $brush,
        20,
        $Y
    )

    # Item name
    $g.DrawString(
        $Name,
        $fontItem,
        $brush,
        85,
        ($Y + 5)
    )

    # Optional note
    if (-not [string]::IsNullOrWhiteSpace($Note)) {

        $g.DrawString(
            "*** $Note ***",
            $fontNote,
            $brush,
            85,
            ($Y + 48)
        )

        return ($Y + 105)
    }

    return ($Y + 65)
}

# ============================================================
# DRAW TICKET
# ============================================================

Draw-CenteredText `
    -Text "ครัวร้อน" `
    -Font $fontHeader `
    -Y 15

# Header line
$g.DrawLine(
    $pen,
    15,70,
    560,70
)

# Table / order
$g.DrawString(
    "โต๊ะ 12",
    $fontInfo,
    $brush,
    20,
    82
)

$g.DrawString(
    "#A001",
    $fontInfo,
    $brush,
    440,
    82
)

# Separator
$g.DrawLine(
    $pen,
    15,125,
    560,125
)

$y = 145

$y = Draw-OrderItem `
    -Qty "2" `
    -Name "ต้มยำกุ้งน้ำข้น" `
    -Note "เผ็ดน้อย" `
    -Y $y

$y = Draw-OrderItem `
    -Qty "1" `
    -Name "เนื้อปูผัดผงกะหรี่" `
    -Note "ไม่ใส่ผักชี" `
    -Y $y

$y = Draw-OrderItem `
    -Qty "3" `
    -Name "ข้าวผัดปู" `
    -Note "" `
    -Y $y

# ------------------------------------------------------------
# Footer separator
# ------------------------------------------------------------

$footerY = $y + 10

$g.DrawLine(
    $pen,
    15,$footerY,
    560,$footerY
)

$g.DrawString(
    "เวลา 12:25",
    $fontFooter,
    $brush,
    20,
    ($footerY + 15)
)

$g.DrawString(
    "TEST-0010B-11",
    $fontFooter,
    $brush,
    350,
    ($footerY + 15)
)

$g.Dispose()

# ============================================================
# BITMAP -> 1-BIT RASTER
#
# Production candidate baseline:
#   Threshold 180
#   Correct byte packing: X -shr 3
# ============================================================

$raster = New-Object byte[] (
    $bytesPerRow * $heightDots
)

$blackPixels = 0

for ($y = 0; $y -lt $heightDots; $y++) {

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

            $bit =
                7 - ($x % 8)

            $raster[$byteIndex] =
                $raster[$byteIndex] -bor
                (1 -shl $bit)

            $blackPixels++
        }
    }
}

$bitmap.Dispose()

# ============================================================
# GS ( L
# Function 112 - Store raster
# ============================================================

$xDots = $widthDots
$yDots = $heightDots

$xL = $xDots -band 0xFF
$xH = ($xDots -shr 8) -band 0xFF

$yL = $yDots -band 0xFF
$yH = ($yDots -shr 8) -band 0xFF

$parameterLength =
    10 + $raster.Length

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

# Function 50 - Print graphics
$printGraphics = [byte[]](
    0x1D,0x28,0x4C,
    0x02,0x00,
    0x30,0x32
)

$init = [byte[]](
    0x1B,0x40
)

$feed = [byte[]](
    0x1B,0x64,0x04
)

$cut = [byte[]](
    0x1D,0x56,0x01
)

# ============================================================
# VALIDATION
# ============================================================

Write-Host ""
Write-Host "========================================"
Write-Host " TEST-0010B-11"
Write-Host " KITCHEN TICKET PROTOTYPE"
Write-Host "========================================"
Write-Host ""

Write-Host "Printer          : $printerIp`:$printerPort"
Write-Host "Width dots       : $widthDots"
Write-Host "Height dots      : $heightDots"
Write-Host "Bytes per row    : $bytesPerRow"
Write-Host "Raster bytes     : $($raster.Length)"
Write-Host "Black pixels     : $blackPixels"
Write-Host "Threshold        : $threshold"
Write-Host "Rendering        : AntiAliasGridFit"
Write-Host ""

$validationOK = $true

if ($widthDots -ne 576) {
    Write-Host "FAIL - width"
    $validationOK = $false
}

if ($bytesPerRow -ne 72) {
    Write-Host "FAIL - bytes per row"
    $validationOK = $false
}

# 72 * 760 = 54720
if ($raster.Length -ne 54720) {
    Write-Host "FAIL - raster length"
    $validationOK = $false
}

if ($storeHeader.Length -ne 15) {
    Write-Host "FAIL - header length"
    $validationOK = $false
}

if ($blackPixels -le 0) {
    Write-Host "FAIL - no black pixels"
    $validationOK = $false
}

if (-not $validationOK) {

    Write-Host ""
    Write-Host "VALIDATION FAILED"
    Write-Host "NOTHING SENT TO PRINTER"

    exit 1
}

Write-Host "VALIDATION PASS"
Write-Host ""

# ============================================================
# SEND
# ============================================================

$client = [System.Net.Sockets.TcpClient]::new()
$stream = $null

try {

    $client.SendTimeout = 5000

    Write-Host "[1] Connecting..."

    $client.Connect(
        $printerIp,
        $printerPort
    )

    $stream = $client.GetStream()

    Write-Host "    Connected"

    Write-Host "[2] ESC @"

    $stream.Write(
        $init,
        0,
        $init.Length
    )

    Write-Host "[3] GS ( L Function 112"

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

    Write-Host "[5] GS ( L Function 50"

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
    Write-Host " TICKET SENT"
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

# ============================================================
# CLEANUP
# ============================================================

$pen.Dispose()

$fontHeader.Dispose()
$fontInfo.Dispose()
$fontQty.Dispose()
$fontItem.Dispose()
$fontNote.Dispose()
$fontFooter.Dispose()

Write-Host ""
Write-Host "Connection closed."
