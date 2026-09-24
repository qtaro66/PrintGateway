# ============================================================
# TEST-0010B-16A
# FAILURE BEFORE SEND
#
# Goal:
#   Verify that connection failure BEFORE any print data
#   is classified as:
#
#       FAILED
#       SendStarted = False
#       SAFE TO RETRY
#
# IMPORTANT:
#   Disconnect printer LAN cable BEFORE running this test.
# ============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$printerIp   = "192.0.2.10"
$printerPort = 9100
$processId   = "0016"

$transportLibrary = "C:\PrintGateway\Lib\EpsonTransport.ps1"

Write-Host ""
Write-Host "========================================"
Write-Host " TEST-0010B-16A"
Write-Host " FAILURE BEFORE SEND"
Write-Host "========================================"
Write-Host ""

# ------------------------------------------------------------
# Load Transport Library
# ------------------------------------------------------------

if (-not (Test-Path $transportLibrary)) {
    throw "Transport library not found: $transportLibrary"
}

. $transportLibrary

Write-Host "Transport library : $transportLibrary"
Write-Host "Printer           : ${printerIp}:$printerPort"
Write-Host "Process ID        : $processId"
Write-Host ""

# ------------------------------------------------------------
# Minimal dummy print payload
#
# These commands MUST NOT reach the printer in this test,
# because the network connection will fail first.
# ------------------------------------------------------------

$init = [byte[]](
    0x1B,0x40
)

# Minimal valid GS ( L graphics header:
# 8 dots wide x 8 dots high = 8 raster bytes

$storeHeader = [byte[]](
    0x1D,0x28,0x4C,
    0x12,0x00,
    0x30,0x70,
    0x30,0x01,0x01,0x31,
    0x08,0x00,
    0x08,0x00
)

$raster = [byte[]](
    0xFF,0xFF,0xFF,0xFF,
    0xFF,0xFF,0xFF,0xFF
)

$printGraphics = [byte[]](
    0x1D,0x28,0x4C,
    0x02,0x00,
    0x30,0x32
)

$feed = [byte[]](
    0x1B,0x64,0x03
)

$cut = [byte[]](
    0x1D,0x56,0x01
)

# ------------------------------------------------------------
# Validation before test
# ------------------------------------------------------------

if ($raster.Length -ne 8) {
    throw "Raster validation failed."
}

Write-Host "TEST PAYLOAD VALIDATION PASS"
Write-Host ""

Write-Host "================================================"
Write-Host " BEFORE CONTINUING:"
Write-Host ""
Write-Host " DISCONNECT THE LAN CABLE FROM THE PRINTER."
Write-Host ""
Write-Host " Printer must NOT be reachable at 192.0.2.10"
Write-Host "================================================"
Write-Host ""

Read-Host "Press ENTER after LAN cable is disconnected"

Write-Host ""
Write-Host "[TEST] Calling Send-EpsonPrintDataWithAck..."
Write-Host ""

# ------------------------------------------------------------
# Execute
# ------------------------------------------------------------

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

# ------------------------------------------------------------
# Display raw result
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================"
Write-Host " TEST-0010B-16A"
Write-Host " TRANSPORT RESULT"
Write-Host "========================================"
Write-Host ""

Write-Host "Transport status : $($result.TransportStatus)"
Write-Host "Send started     : $($result.SendStarted)"
Write-Host "Raster bytes     : $($result.RasterBytes)"
Write-Host "Process ID       : $($result.ProcessId)"
Write-Host "ACK received     : $($result.AckReceived)"
Write-Host "ACK valid        : $($result.AckValid)"

if ($null -ne $result.ReturnedProcessId) {
    Write-Host "Returned ID      : $($result.ReturnedProcessId)"
}

if ($null -ne $result.Error) {
    Write-Host "Error            : $($result.Error)"
}

Write-Host ""

# ------------------------------------------------------------
# TEST ASSERTIONS
# ------------------------------------------------------------

$pass = $true

if ($result.TransportStatus -ne "FAILED") {
    Write-Host "ASSERT FAIL: TransportStatus must be FAILED"
    $pass = $false
}

if ($result.SendStarted -ne $false) {
    Write-Host "ASSERT FAIL: SendStarted must be False"
    $pass = $false
}

if ($result.AckReceived -ne $false) {
    Write-Host "ASSERT FAIL: AckReceived must be False"
    $pass = $false
}

if ($result.AckValid -ne $false) {
    Write-Host "ASSERT FAIL: AckValid must be False"
    $pass = $false
}

Write-Host ""

if ($pass) {

    Write-Host "========================================"
    Write-Host " TEST-0010B-16A PASS"
    Write-Host ""
    Write-Host " RESULT: FAILED BEFORE SEND"
    Write-Host " SAFE TO RETRY"
    Write-Host "========================================"

}
else {

    Write-Host "========================================"
    Write-Host " TEST-0010B-16A FAIL"
    Write-Host ""
    Write-Host " RESULT DID NOT MATCH EXPECTED STATE"
    Write-Host " DO NOT CONTINUE TO B-16B"
    Write-Host "========================================"
}

Write-Host ""
Write-Host "TEST-0010B-16A finished."
