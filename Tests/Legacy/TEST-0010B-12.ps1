# ============================================================
# TEST-0010B-12
# DYNAMIC KITCHEN TICKET + THAI AUTO WRAP
# Epson TM-T82X
#
# Raster baseline:
#   Width       = 576 dots
#   Rendering   = AntiAliasGridFit
#   Threshold   = 180
#   Bit packing = X -shr 3
#   Graphics    = GS ( L
# ============================================================

$printerIp   = "192.0.2.10"
$printerPort = 9100

Add-Type -AssemblyName System.Drawing

# ============================================================
# CONFIG
# ============================================================

$widthDots   = 576
$bytesPerRow = 72
$threshold   = 180

$leftMargin  = 20
$rightMargin = 20

$qtyX        = 20
$itemX       = 85

$itemWidth =
    $widthDots - $itemX - $rightMargin

# ============================================================
# ORDER DATA
# ============================================================

$order = @(
    @{
        Qty  = "2"
        Name = "ต้มยำกุ้งแม่น้ำน้ำข้นหม้อไฟ"
        Note = "เผ็ดน้อย ไม่ใส่ผักชี ไม่ใส่เห็ด"
    },
    @{
        Qty  = "1"
        Name = "เนื้อปูผัดผงกะหรี่ใส่ไข่และต้นหอม"
        Note = "แยกต้นหอม ไม่ใส่ขึ้นฉ่าย"
    },
    @{
        Qty  = "3"
        Name = "ข้าวผัดปูเนื้อปูก้อนพิเศษ"
        Note = "ไม่ใส่หอมใหญ่"
    }
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
    "Tahoma",27,
    [System.Drawing.FontStyle]::Bold,
    [System.Drawing.GraphicsUnit]::Pixel
)

$fontFooter = New-Object System.Drawing.Font(
    "Tahoma",24,
    [System.Drawing.FontStyle]::Regular,
    [System.Drawing.GraphicsUnit]::Pixel
)

# ============================================================
# MEASUREMENT GRAPHICS
# ============================================================

$measureBitmap =
    New-Object System.Drawing.Bitmap(1,1)

$measureG =
    [System.Drawing.Graphics]::FromImage($measureBitmap)

$measureG.TextRenderingHint =
    [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

# ============================================================
# STRING FORMAT
#
# IMPORTANT:
# NoWrap is NOT enabled.
# GDI+ is allowed to wrap Thai text inside the rectangle.
# ============================================================

$wrapFormat =
    New-Object System.Drawing.StringFormat

$wrapFormat.Alignment =
    [System.Drawing.StringAlignment]::Near

$wrapFormat.LineAlignment =
    [System.Drawing.StringAlignment]::Near

$wrapFormat.Trimming =
    [System.Drawing.StringTrimming]::None

# ============================================================
# MEASURE WRAPPED TEXT
# ============================================================

function Measure-WrappedText {

    param(
        [string]$Text,
        [System.Drawing.Font]$Font,
        [float]$Width
    )

    $layoutSize =
        New-Object System.Drawing.SizeF(
            $Width,
            2000
        )

    $size =
        $measureG.MeasureString(
            $Text,
            $Font,
            $layoutSize,
            $wrapFormat
        )

    return [Math]::Ceiling($size.Height)
}

# ============================================================
# CALCULATE TICKET HEIGHT
# ============================================================

$headerHeight = 145

$contentHeight = 0

foreach ($item in $order) {

    $nameHeight =
        Measure-WrappedText `
            -Text $item.Name `
            -Font $fontItem `
            -Width $itemWidth

    $itemHeight =
        [Math]::Max(
            55,
            ($nameHeight + 10)
        )

    if (
        -not [string]::IsNullOrWhiteSpace(
            $item.Note
        )
    ) {

        $noteText =
            "*** $($item.Note) ***"

        $noteHeight =
            Measure-WrappedText `
                -Text $noteText `
                -Font $fontNote `
                -Width $itemWidth

        $itemHeight +=
            $noteHeight + 10
    }

    # spacing between items
    $itemHeight += 20

    $contentHeight += $itemHeight
}

$footerHeight = 100

$heightDots =
    $headerHeight +
    $contentHeight +
    $footerHeight

# Safety padding
$heightDots += 20

# ============================================================
# CREATE FINAL BITMAP
# ============================================================

$bitmap =
    New-Object System.Drawing.Bitmap(
        $widthDots,
        $heightDots,
        [System.Drawing.Imaging.PixelFormat]::Format24bppRgb
    )

$g =
    [System.Drawing.Graphics]::FromImage(
        $bitmap
    )

$g.Clear(
    [System.Drawing.Color]::White
)

$g.TextRenderingHint =
    [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

$brush =
    [System.Drawing.Brushes]::Black

$pen =
    New-Object System.Drawing.Pen(
        [System.Drawing.Color]::Black,
        2
    )

# ============================================================
# CENTER TEXT
# ============================================================

function Draw-CenteredText {

    param(
        [string]$Text,
        [System.Drawing.Font]$Font,
        [float]$Y
    )

    $size =
        $g.MeasureString(
            $Text,
            $Font
        )

    $x =
        ($widthDots - $size.Width) / 2

    $g.DrawString(
        $Text,
        $Font,
        $brush,
        $x,
        $Y
    )
}

# ============================================================
# HEADER
# ============================================================

Draw-CenteredText `
    -Text "ครัวร้อน" `
    -Font $fontHeader `
    -Y 15

$g.DrawLine(
    $pen,
    15,70,
    560,70
)

$g.DrawString(
    "โต๊ะ 12",
    $fontInfo,
    $brush,
    20,
    82
)

$g.DrawString(
    "#A002",
    $fontInfo,
    $brush,
    440,
    82
)

$g.DrawLine(
    $pen,
    15,125,
    560,125
)

# ============================================================
# DYNAMIC ITEMS
# ============================================================

$currentY = 145

foreach ($item in $order) {

    # --------------------------------------------------------
    # Quantity
    # --------------------------------------------------------

    $g.DrawString(
        $item.Qty,
        $fontQty,
        $brush,
        $qtyX,
        $currentY
    )

    # --------------------------------------------------------
    # Measure item name
    # --------------------------------------------------------

    $nameHeight =
        Measure-WrappedText `
            -Text $item.Name `
            -Font $fontItem `
            -Width $itemWidth

    $nameRect =
        New-Object System.Drawing.RectangleF(
            $itemX,
            ($currentY + 5),
            $itemWidth,
            $nameHeight
        )

    # --------------------------------------------------------
    # Draw wrapped item name
    # --------------------------------------------------------

    $g.DrawString(
        $item.Name,
        $fontItem,
        $brush,
        $nameRect,
        $wrapFormat
    )

    $blockHeight =
        [Math]::Max(
            55,
            ($nameHeight + 10)
        )

    # --------------------------------------------------------
    # Note
    # --------------------------------------------------------

    if (
        -not [string]::IsNullOrWhiteSpace(
            $item.Note
        )
    ) {

        $noteText =
            "*** $($item.Note) ***"

        $noteHeight =
            Measure-WrappedText `
                -Text $noteText `
                -Font $fontNote `
                -Width $itemWidth

        $noteY =
            $currentY +
            $blockHeight

        $noteRect =
            New-Object System.Drawing.RectangleF(
                $itemX,
                $noteY,
                $itemWidth,
                $noteHeight
            )

        $g.DrawString(
            $noteText,
            $fontNote,
            $brush,
            $noteRect,
            $wrapFormat
        )

        $blockHeight +=
            $noteHeight + 10
    }

    $currentY +=
        $blockHeight + 20
}

# ============================================================
# FOOTER
# ============================================================

$footerY =
    $currentY + 5

$g.DrawLine(
    $pen,
    15,$footerY,
    560,$footerY
)

$g.DrawString(
    "เวลา 12:30",
    $fontFooter,
    $brush,
    20,
    ($footerY + 15)
)

$g.DrawString(
    "TEST-0010B-12",
    $fontFooter,
    $brush,
    350,
    ($footerY + 15)
)

$g.Dispose()

# ============================================================
# MEASUREMENT CLEANUP
# ============================================================

$measureG.Dispose()
$measureBitmap.Dispose()

# ============================================================
# BITMAP -> 1-BIT RASTER
# ============================================================

$raster =
    New-Object byte[] (
        $bytesPerRow * $heightDots
    )

$blackPixels = 0

for ($y = 0; $y -lt $heightDots; $y++) {

    for ($x = 0; $x -lt $widthDots; $x++) {

        $pixel =
            $bitmap.GetPixel(
                $x,
                $y
            )

        $luminance =
            (0.299 * $pixel.R) +
            (0.587 * $pixel.G) +
            (0.114 * $pixel.B)

        if ($luminance -lt $threshold) {

            # Correct integer bit packing
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
# ============================================================

$xDots = $widthDots
$yDots = $heightDots

$xL = $xDots -band 0xFF
$xH = ($xDots -shr 8) -band 0xFF

$yL = $yDots -band 0xFF
$yH = ($yDots -shr 8) -band 0xFF

$parameterLength =
    10 + $raster.Length

$pL =
    $parameterLength -band 0xFF

$pH =
    ($parameterLength -shr 8) -band 0xFF

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

$init =
    [byte[]](0x1B,0x40)

$feed =
    [byte[]](0x1B,0x64,0x04)

$cut =
    [byte[]](0x1D,0x56,0x01)

# ============================================================
# VALIDATION
# ============================================================

Write-Host ""
Write-Host "========================================"
Write-Host " TEST-0010B-12"
Write-Host " DYNAMIC THAI AUTO WRAP"
Write-Host "========================================"
Write-Host ""

Write-Host "Width dots       : $widthDots"
Write-Host "Height dots      : $heightDots"
Write-Host "Bytes per row    : $bytesPerRow"
Write-Host "Raster bytes     : $($raster.Length)"
Write-Host "Black pixels     : $blackPixels"
Write-Host "Threshold        : $threshold"
Write-Host "Items            : $($order.Count)"
Write-Host ""

$expectedRasterLength =
    $bytesPerRow * $heightDots

$validationOK = $true

if ($widthDots -ne 576) {
    Write-Host "FAIL - width"
    $validationOK = $false
}

if ($bytesPerRow -ne 72) {
    Write-Host "FAIL - bytes per row"
    $validationOK = $false
}

if (
    $raster.Length -ne
    $expectedRasterLength
) {
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

$client =
    [System.Net.Sockets.TcpClient]::new()

$stream = $null

try {

    $client.SendTimeout = 5000

    Write-Host "[1] Connecting..."

    $client.Connect(
        $printerIp,
        $printerPort
    )

    $stream =
        $client.GetStream()

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

    Write-Host (
        "    {0} bytes sent" -f
        $raster.Length
    )

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

$wrapFormat.Dispose()
$pen.Dispose()

$fontHeader.Dispose()
$fontInfo.Dispose()
$fontQty.Dispose()
$fontItem.Dispose()
$fontNote.Dispose()
$fontFooter.Dispose()

Write-Host ""
Write-Host "Connection closed."
