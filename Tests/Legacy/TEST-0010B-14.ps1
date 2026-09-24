# ============================================================
# TEST-0010B-13
# EPSON RASTER LIBRARY INTEGRATION
#
# Goal:
#   Render Kitchen Ticket
#       -> ConvertTo-EpsonRaster
#       -> EpsonRaster.ps1
#       -> GS ( L
#       -> Epson TM-T82X
#
# Verified baseline:
#   576 dots
#   72 bytes/row
#   AntiAliasGridFit
#   Threshold 180
# ============================================================

$printerIp   = "192.0.2.10"
$printerPort = 9100

# ============================================================
# LOAD LIBRARY
# ============================================================

$rasterLibraryPath =
    "C:\PrintGateway\Lib\EpsonRaster.ps1"

$transportLibraryPath =
    "C:\PrintGateway\Lib\EpsonTransport.ps1"

if (-not (Test-Path $rasterLibraryPath)) {
    throw "Library not found: $rasterLibraryPath"
}

if (-not (Test-Path $transportLibraryPath)) {
    throw "Library not found: $transportLibraryPath"
}

. $rasterLibraryPath
. $transportLibraryPath

Add-Type -AssemblyName System.Drawing

# ============================================================
# CONFIG
# ============================================================

$widthDots = 576
$threshold = 180

$qtyX  = 20
$itemX = 85

$itemWidth =
    $widthDots - $itemX - 20

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
# WRAP FORMAT
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
# MEASUREMENT CONTEXT
# ============================================================

$measureBitmap =
    New-Object System.Drawing.Bitmap(1,1)

$measureG =
    [System.Drawing.Graphics]::FromImage(
        $measureBitmap
    )

$measureG.TextRenderingHint =
    [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

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

    return [Math]::Ceiling(
        $size.Height
    )
}

# ============================================================
# CALCULATE DYNAMIC HEIGHT
# ============================================================

$headerHeight  = 145
$contentHeight = 0
$footerHeight  = 100

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

    $itemHeight += 20

    $contentHeight += $itemHeight
}

$heightDots =
    $headerHeight +
    $contentHeight +
    $footerHeight +
    20

# ============================================================
# CREATE BITMAP
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
    "#A004",
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
# ITEMS
# ============================================================

$currentY = 145

foreach ($item in $order) {

    # Quantity
    $g.DrawString(
        $item.Qty,
        $fontQty,
        $brush,
        $qtyX,
        $currentY
    )

    # Item name
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

    # Note
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
    "เวลา 12:45",
    $fontFooter,
    $brush,
    20,
    ($footerY + 15)
)

$g.DrawString(
    "TEST-0010B-14",
    $fontFooter,
    $brush,
    350,
    ($footerY + 15)
)

$g.Dispose()

$measureG.Dispose()
$measureBitmap.Dispose()

# ============================================================
# IMPORTANT:
# BITMAP -> RASTER NOW COMES FROM LIBRARY
# ============================================================

Write-Host ""
Write-Host "[LIB] ConvertTo-EpsonRaster"

$rasterResult =
    ConvertTo-EpsonRaster `
        -Bitmap $bitmap `
        -Threshold $threshold

$bitmap.Dispose()

$raster =
    $rasterResult.Data

# ============================================================
# ESC/POS COMMANDS NOW COME FROM LIBRARY
# ============================================================

Write-Host "[LIB] New-EpsonGraphicsStoreHeader"

$storeHeader =
    New-EpsonGraphicsStoreHeader `
        -WidthDots $rasterResult.WidthDots `
        -HeightDots $rasterResult.HeightDots `
        -RasterLength $raster.Length

$printGraphics =
    New-EpsonGraphicsPrintCommand

$init =
    New-EpsonInitializeCommand

$feed =
    New-EpsonFeedCommand -Lines 4

$cut =
    New-EpsonPartialCutCommand

# ============================================================
# VALIDATION
# ============================================================

Write-Host ""
Write-Host "========================================"
Write-Host " TEST-0010B-13"
Write-Host " LIBRARY INTEGRATION"
Write-Host "========================================"
Write-Host ""

Write-Host "Raster library    : $rasterLibraryPath"
Write-Host "Transport library : $transportLibraryPath"
Write-Host "Width dots        : $($rasterResult.WidthDots)"
Write-Host "Height dots       : $($rasterResult.HeightDots)"
Write-Host "Bytes per row     : $($rasterResult.BytesPerRow)"
Write-Host "Raster bytes      : $($raster.Length)"
Write-Host "Black pixels      : $($rasterResult.BlackPixels)"
Write-Host "Threshold         : $($rasterResult.Threshold)"
Write-Host "Items             : $($order.Count)"
Write-Host ""

$validationOK = $true

if ($rasterResult.WidthDots -ne 576) {
    Write-Host "FAIL - width"
    $validationOK = $false
}

if ($rasterResult.BytesPerRow -ne 72) {
    Write-Host "FAIL - bytes per row"
    $validationOK = $false
}

$expectedRasterLength =
    72 * $rasterResult.HeightDots

if ($raster.Length -ne $expectedRasterLength) {
    Write-Host "FAIL - raster length"
    $validationOK = $false
}

if ($rasterResult.Threshold -ne 180) {
    Write-Host "FAIL - threshold"
    $validationOK = $false
}

if ($storeHeader.Length -ne 15) {
    Write-Host "FAIL - store header"
    $validationOK = $false
}

if ($printGraphics.Length -ne 7) {
    Write-Host "FAIL - print command"
    $validationOK = $false
}

if (-not $validationOK) {

    Write-Host ""
    Write-Host "VALIDATION FAILED"
    Write-Host "NOTHING SENT TO PRINTER"

    exit 1
}

Write-Host "LIBRARY VALIDATION PASS"
Write-Host ""

# ============================================================
# SEND VIA TRANSPORT LIBRARY
# ============================================================

Write-Host ""
Write-Host "[LIB] Send-EpsonPrintData"
Write-Host ""

$result =
    Send-EpsonPrintData `
        -PrinterIp $printerIp `
        -PrinterPort $printerPort `
        -InitializeCommand $init `
        -StoreHeader $storeHeader `
        -RasterData $raster `
        -PrintGraphicsCommand $printGraphics `
        -FeedCommand $feed `
        -CutCommand $cut

# ============================================================
# TRANSPORT RESULT
# ============================================================

Write-Host ""
Write-Host "========================================"
Write-Host " TEST-0010B-14"
Write-Host " TRANSPORT RESULT"
Write-Host "========================================"
Write-Host ""

Write-Host "Transport status : $($result.TransportStatus)"
Write-Host "Send started     : $($result.SendStarted)"
Write-Host "Raster bytes     : $($result.RasterBytes)"

if ($null -ne $result.Error) {
    Write-Host "Error            : $($result.Error)"
}

Write-Host ""

switch ($result.TransportStatus) {

    "SENT" {

        Write-Host "RESULT:"
        Write-Host "TRANSPORT SENT"
        Write-Host ""
        Write-Host "IMPORTANT:"
        Write-Host "SENT does NOT mean COMPLETED."
        Write-Host "B-14 has no Process ID ACK yet."
    }

    "FAILED" {

        Write-Host "RESULT:"
        Write-Host "FAILED BEFORE SEND"
        Write-Host ""
        Write-Host "SAFE TO RETRY"
    }

    "UNKNOWN" {

        Write-Host "RESULT:"
        Write-Host "UNKNOWN"
        Write-Host ""
        Write-Host "DO NOT AUTO-RETRY"
    }

    default {

        Write-Host "RESULT:"
        Write-Host "UNEXPECTED TRANSPORT STATUS"
    }
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
