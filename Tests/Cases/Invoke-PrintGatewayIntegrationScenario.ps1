# ============================================================
# TEST-0010B-17A
# FULL PRINTGATEWAY INTEGRATION
#
# Raster + Transport + Process ID ACK + Job Manager
#
# Expected:
#
# NEW
#   -> QUEUED
#   -> SENDING
#   -> Send-EpsonPrintDataWithAck
#   -> matching ACK
#   -> COMPLETED
#
# Job ID     : ORDER-B17-004
# Process ID : 0020
# ============================================================

[CmdletBinding()]
param(
    [string]$DatabasePath = 'C:\PrintGateway\Data\printgateway.db',

    [string]$SqlitePath = (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\sqlite3.exe'),

    [string]$PrinterIp = '192.0.2.10',

    [int]$PrinterPort = 9100,

    [ValidateSet(
        'NoSend',
        'FailedBeforeSend',
        'UnknownAfterSend',
        'Completed',
        'Printer'
    )]
    [string]$TransportMode = 'NoSend',

    [switch]$AllowPrinterConnection
)

if ($TransportMode -eq 'Printer' -and -not $AllowPrinterConnection) {
    throw 'Printer mode is blocked. Use Invoke-PrintGatewayHardwareTest.ps1 and explicitly confirm the hardware print.'
}

if ($TransportMode -eq 'Printer' -and $PrinterIp -eq '192.0.2.10') {
    throw 'Printer mode requires a real -PrinterIp. The documentation address 192.0.2.10 is not valid for hardware printing.'
}

$jobId     = "ORDER-B17-004"
$processId = "0020"

# ============================================================
# LOAD LIBRARY
# ============================================================

$rasterLibraryPath =
    "C:\PrintGateway\Lib\EpsonRaster.ps1"

$transportLibraryPath =
    "C:\PrintGateway\Lib\EpsonTransport.ps1"

$jobManagerLibraryPath =
    "C:\PrintGateway\Lib\PrintJobManager.ps1"

if (-not (Test-Path $rasterLibraryPath)) {
    throw "Library not found: $rasterLibraryPath"
}

if (-not (Test-Path $transportLibraryPath)) {
    throw "Library not found: $transportLibraryPath"
}

if (-not (Test-Path $jobManagerLibraryPath)) {
    throw "Library not found: $jobManagerLibraryPath"
}

. $rasterLibraryPath
. $transportLibraryPath
. $jobManagerLibraryPath

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

$fontHeader   = $null
$fontInfo     = $null
$fontQty      = $null
$fontItem     = $null
$fontNote     = $null
$fontFooter   = $null
$wrapFormat   = $null
$measureBitmap = $null
$measureG     = $null
$bitmap       = $null
$g            = $null
$pen          = $null
$result       = $null
$managerConfiguration = $null
$startupRecoveredCount = 0

try {

Add-Type -AssemblyName System.Drawing

$managerConfiguration = Initialize-PrintGatewayJobManager `
    -DatabasePath $DatabasePath `
    -SqlitePath $SqlitePath

$startupRecoveredCount = Recover-PrintGatewaySendingJobs

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
    "#A006",
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
    "TEST-0010B-17A",
    $fontFooter,
    $brush,
    350,
    ($footerY + 15)
)

$g.Dispose()
$g = $null

$measureG.Dispose()
$measureG = $null

$measureBitmap.Dispose()
$measureBitmap = $null

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
$bitmap = $null

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

$processIdCommand =
    New-EpsonProcessIdCommand `
        -ProcessId $processId

[byte[]]$payloadBytes = @(
    $init
    $storeHeader
    $raster
    $printGraphics
    $feed
    $cut
    $processIdCommand
)

$payloadFingerprint =
    Get-PrintGatewayPayloadFingerprint `
        -Bytes $payloadBytes

# ============================================================
# VALIDATION
# ============================================================

Write-Host ""
Write-Host "========================================"
Write-Host " TEST-0010B-17A"
Write-Host " FULL PRINTGATEWAY INTEGRATION"
Write-Host "========================================"
Write-Host ""

Write-Host "Raster library     : $rasterLibraryPath"
Write-Host "Transport library  : $transportLibraryPath"
Write-Host "Job Manager library: $jobManagerLibraryPath"
Write-Host "Database            : $($managerConfiguration.DatabasePath)"
Write-Host "Transport mode      : $TransportMode"
Write-Host "Startup recovered   : $startupRecoveredCount"
Write-Host "Job ID             : $jobId"
Write-Host "Process ID         : $processId"
Write-Host "Payload fingerprint : $payloadFingerprint"
Write-Host "Width dots         : $($rasterResult.WidthDots)"
Write-Host "Height dots        : $($rasterResult.HeightDots)"
Write-Host "Bytes per row      : $($rasterResult.BytesPerRow)"
Write-Host "Raster bytes       : $($raster.Length)"
Write-Host "Black pixels       : $($rasterResult.BlackPixels)"
Write-Host "Threshold          : $($rasterResult.Threshold)"
Write-Host "Items              : $($order.Count)"
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

    throw "Library validation failed. Nothing sent to printer."
}

Write-Host "LIBRARY VALIDATION PASS"
Write-Host ""

if ($TransportMode -eq 'NoSend') {
    Write-Host "NO-SEND VALIDATION PASS"
    Write-Host "No job was registered and no printer connection was attempted."
    return
}

# ============================================================
# JOB SUBMISSION / IDEMPOTENCY CHECK
# ============================================================

Write-Host ""
Write-Host "[JOB] Checking submission..."
Write-Host "Job ID     : $jobId"
Write-Host "Process ID : $processId"
Write-Host ""

$submission =
    Test-PrintGatewayJobSubmission `
        -JobId $jobId `
        -ProcessId $processId `
        -PayloadFingerprint $payloadFingerprint

Write-Host "Allowed : $($submission.Allowed)"
Write-Host "Action  : $($submission.Action)"
Write-Host "Reason  : $($submission.Reason)"
Write-Host ""

if (-not $submission.Allowed) {

    Write-Host "========================================"
    Write-Host " JOB BLOCKED"
    Write-Host " NOTHING SENT TO PRINTER"
    Write-Host "========================================"

    return
}

# ============================================================
# REGISTER NEW JOB OR PREPARE SAFE RETRY
# ============================================================

if ($submission.Action -eq "NEW") {

    Write-Host "[JOB] Registering new job..."

    $job =
        New-PrintGatewayJob `
            -JobId $jobId `
            -ProcessId $processId `
            -PayloadFingerprint $payloadFingerprint
}
elseif ($submission.Action -eq "RETRY") {

    Write-Host "[JOB] Safe retry authorized."

    $job =
        Get-PrintGatewayJob `
            -JobId $jobId
}
else {

    throw "Unexpected submission action: $($submission.Action)"
}

Write-Host "Status  : $($job.Status)"
Write-Host "Attempt : $($job.Attempt)"
Write-Host ""

# ============================================================
# START JOB ATTEMPT
# ============================================================

Write-Host "[JOB] Starting attempt..."

$job =
    Start-PrintGatewayJobAttempt `
        -JobId $jobId

Write-Host "Status  : $($job.Status)"
Write-Host "Attempt : $($job.Attempt)"
Write-Host ""

# ============================================================
# SEND + FAIL-CLOSED TRANSPORT RESULT
# ============================================================

Write-Host "[TRANSPORT] Mode: $TransportMode"
Write-Host ""

try {

    # Job must already be SENDING before transport is called.
    if ($job.Status -ne "SENDING") {
        throw "Invariant violation: Job must be SENDING before transport."
    }

    switch ($TransportMode) {
        'FailedBeforeSend' {
            $result = [PSCustomObject]@{
                TransportStatus   = 'FAILED'
                SendStarted       = $false
                RasterBytes       = 0
                ProcessId         = $processId
                AckReceived       = $false
                AckValid          = $false
                AckBytes          = $null
                ReturnedProcessId = $null
                AckElapsedMs      = $null
                Error             = 'Simulated connection failure before send.'
            }
        }

        'UnknownAfterSend' {
            $result = [PSCustomObject]@{
                TransportStatus   = 'UNKNOWN'
                SendStarted       = $true
                RasterBytes       = $raster.Length
                ProcessId         = $processId
                AckReceived       = $false
                AckValid          = $false
                AckBytes          = [byte[]](0x1D, 0x49, 0x31)
                ReturnedProcessId = $null
                AckElapsedMs      = 5000
                Error             = 'Simulated ACK timeout after send.'
            }
        }

        'Completed' {
            $result = [PSCustomObject]@{
                TransportStatus   = 'COMPLETED'
                SendStarted       = $true
                RasterBytes       = $raster.Length
                ProcessId         = $processId
                AckReceived       = $true
                AckValid          = $true
                AckBytes          = [byte[]](0x1D, 0x49, 0x31)
                ReturnedProcessId = $processId
                AckElapsedMs      = 25
                Error             = $null
            }
        }

        'Printer' {
            $result =
                Send-EpsonPrintDataWithAck `
                    -PrinterIp $printerIp `
                    -PrinterPort $printerPort `
                    -InitializeCommand $init `
                    -StoreHeader $storeHeader `
                    -RasterData $raster `
                    -PrintGraphicsCommand $printGraphics `
                    -FeedCommand $feed `
                    -CutCommand $cut `
                    -ProcessId $processId `
                    -AckTimeoutMs 5000
        }

        default {
            throw "Unsupported TransportMode: $TransportMode"
        }
    }

    if ($null -eq $result) {
        throw "Transport returned no result."
    }

    Write-Host ""
    Write-Host "[JOB] Applying transport result..."

    $job =
        Complete-PrintGatewayJobFromTransportResult `
            -JobId $jobId `
            -TransportResult $result

    $result.TransportStatus = $job.Status
}
catch {

    # Once the job has entered SENDING, an unexpected exception
    # must fail closed as UNKNOWN. Never auto-retry.

    $errorMessage = $_.Exception.Message

    $currentJob = Get-PrintGatewayJob -JobId $jobId

    if ($null -ne $currentJob -and $currentJob.Status -eq "SENDING") {

        $job =
            Complete-PrintGatewayJobAttempt `
                -JobId $jobId `
                -TransportStatus "UNKNOWN" `
                -SendStarted:$true `
                -ErrorMessage $errorMessage `
                -AckReceived $false `
                -AckValid $false
    }

    if ($null -eq $result) {
        $result = [PSCustomObject]@{
            TransportStatus  = "UNKNOWN"
            SendStarted      = $true
            RasterBytes      = 0
            ProcessId        = $processId
            AckReceived      = $false
            AckValid         = $false
            ReturnedProcessId = $null
            AckElapsedMs     = $null
            AckBytes         = [byte[]]@()
            Error            = $errorMessage
        }
    }
    else {
        $result.TransportStatus = "UNKNOWN"
    }
}

# ============================================================
# RESULT
# ============================================================

Write-Host ""
Write-Host "========================================"
Write-Host " TEST-0010B-17A"
Write-Host " FULL INTEGRATION RESULT"
Write-Host "========================================"
Write-Host ""

Write-Host "Job ID           : $jobId"
Write-Host "Job status       : $($job.Status)"
Write-Host "Attempt          : $($job.Attempt)"
Write-Host "Transport status : $($result.TransportStatus)"
Write-Host "Send started     : $($result.SendStarted)"
Write-Host "Raster bytes     : $($result.RasterBytes)"
Write-Host "Process ID       : $($result.ProcessId)"
Write-Host "ACK received     : $($result.AckReceived)"
Write-Host "ACK valid        : $($result.AckValid)"

if ($null -ne $result.ReturnedProcessId) {
    Write-Host "Returned ID      : $($result.ReturnedProcessId)"
}

if ($null -ne $result.AckElapsedMs) {
    Write-Host "ACK elapsed      : $($result.AckElapsedMs) ms"
}

if ($null -ne $result.AckBytes) {

    $ackHex =
        ($result.AckBytes |
            ForEach-Object {
                "{0:X2}" -f $_
            }) -join " "

    Write-Host "ACK bytes        : $ackHex"
}

if ($null -ne $result.Error) {
    Write-Host "Error            : $($result.Error)"
}

# ============================================================
# STATE INTERPRETATION
# ============================================================

Write-Host ""

if (
    $result.TransportStatus -eq "COMPLETED" -and
    $job.Status -eq "COMPLETED" -and
    $result.AckReceived -eq $true -and
    $result.AckValid -eq $true
) {

    Write-Host "========================================"
    Write-Host " TEST-0010B-17A PASS"
    Write-Host ""
    Write-Host " JOB       : COMPLETED"
    Write-Host " TRANSPORT : COMPLETED"
    Write-Host " ACK       : MATCH"
    Write-Host "========================================"
}
elseif (
    $result.TransportStatus -eq "FAILED" -and
    $job.Status -eq "FAILED"
) {

    Write-Host "========================================"
    Write-Host " RESULT: FAILED BEFORE SEND"
    Write-Host " SAFE TO RETRY"
    Write-Host "========================================"
}
elseif (
    $result.TransportStatus -eq "UNKNOWN" -and
    $job.Status -eq "UNKNOWN"
) {

    Write-Host "========================================"
    Write-Host " RESULT: UNKNOWN"
    Write-Host " DO NOT AUTO-RETRY"
    Write-Host " MANUAL INTERVENTION REQUIRED"
    Write-Host "========================================"
}
else {

    Write-Host "========================================"
    Write-Host " TEST-0010B-17A NEEDS REVIEW"
    Write-Host ""
    Write-Host " Job/Transport state mismatch."
    Write-Host " DO NOT AUTO-RETRY."
    Write-Host "========================================"
}
}
finally {

    # ============================================================
    # CLEANUP
    # ============================================================

    if ($null -ne $g) {
        $g.Dispose()
        $g = $null
    }

    if ($null -ne $measureG) {
        $measureG.Dispose()
        $measureG = $null
    }

    if ($null -ne $bitmap) {
        $bitmap.Dispose()
        $bitmap = $null
    }

    if ($null -ne $measureBitmap) {
        $measureBitmap.Dispose()
        $measureBitmap = $null
    }

    if ($null -ne $pen) {
        $pen.Dispose()
        $pen = $null
    }

    if ($null -ne $wrapFormat) {
        $wrapFormat.Dispose()
        $wrapFormat = $null
    }

    if ($null -ne $fontHeader) {
        $fontHeader.Dispose()
        $fontHeader = $null
    }

    if ($null -ne $fontInfo) {
        $fontInfo.Dispose()
        $fontInfo = $null
    }

    if ($null -ne $fontQty) {
        $fontQty.Dispose()
        $fontQty = $null
    }

    if ($null -ne $fontItem) {
        $fontItem.Dispose()
        $fontItem = $null
    }

    if ($null -ne $fontNote) {
        $fontNote.Dispose()
        $fontNote = $null
    }

    if ($null -ne $fontFooter) {
        $fontFooter.Dispose()
        $fontFooter = $null
    }

    if ($null -ne (Get-Command Close-PrintGatewayJobManager -ErrorAction SilentlyContinue)) {
        Close-PrintGatewayJobManager
    }

    Write-Host ""
    Write-Host "TEST-0010B-17A finished."
}
