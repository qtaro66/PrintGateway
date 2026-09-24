# ============================================================
# TEST-0010B-16B
# FAILURE AFTER SEND STARTED
#
# Expected:
#   SendStarted     = True
#   TransportStatus = UNKNOWN
#   AckReceived     = False
#   AckValid        = False
#   DO NOT AUTO-RETRY
#
# IMPORTANT:
#   Start this test with LAN CONNECTED.
#   Disconnect LAN only when instructed.
# ============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$printerIp   = "192.0.2.10"
$printerPort = 9100
$processId   = "0016"

$client = $null
$stream = $null

$sendStarted     = $false
$bytesAccepted   = 0
$ackReceived     = $false
$ackValid        = $false
$returnedId      = $null
$transportStatus = "UNKNOWN"
$errorMessage    = $null

# ------------------------------------------------------------
# Commands
# ------------------------------------------------------------

$init = [byte[]](
    0x1B,0x40
)

# Some harmless ASCII data.
# This deliberately proves that the print stream has started.
$text = [System.Text.Encoding]::ASCII.GetBytes(
    "TEST-0010B-16B`nSEND STARTED`n"
)

# Feed + Cut
$feed = [byte[]](
    0x1B,0x64,0x03
)

$cut = [byte[]](
    0x1D,0x56,0x01
)

# Epson Process ID = 0016
$processIdCommand = [byte[]](
    0x1D,0x28,0x48,
    0x06,0x00,
    0x30,0x30,
    0x30,0x30,0x31,0x36
)

Write-Host ""
Write-Host "========================================"
Write-Host " TEST-0010B-16B"
Write-Host " FAILURE AFTER SEND STARTED"
Write-Host "========================================"
Write-Host ""

Write-Host "Printer    : ${printerIp}:$printerPort"
Write-Host "Process ID : $processId"
Write-Host ""

try {

    # --------------------------------------------------------
    # CONNECT
    # --------------------------------------------------------

    Write-Host "[1] Connecting..."

    $client = [System.Net.Sockets.TcpClient]::new()
    $client.SendTimeout    = 3000
    $client.ReceiveTimeout = 3000

    $connectTask = $client.ConnectAsync(
        $printerIp,
        $printerPort
    )

    if (-not $connectTask.Wait(3000)) {
        throw "Connection timeout after 3000 ms."
    }

    $null = $connectTask.GetAwaiter().GetResult()

    $stream = $client.GetStream()

    Write-Host "    Connected"
    Write-Host ""

    # --------------------------------------------------------
    # FIRST SEND
    # --------------------------------------------------------

    Write-Host "[2] Starting print stream..."

    # From this point onward, any uncertain failure must be
    # classified UNKNOWN.
    $sendStarted = $true

    $stream.Write(
        $init,
        0,
        $init.Length
    )

    $bytesAccepted += $init.Length

    $stream.Write(
        $text,
        0,
        $text.Length
    )

    $bytesAccepted += $text.Length

    $stream.Flush()

    Write-Host "    First data accepted by socket"
    Write-Host "    Bytes accepted : $bytesAccepted"
    Write-Host ""

    # --------------------------------------------------------
    # CONTROLLED FAILURE POINT
    # --------------------------------------------------------

    Write-Host "========================================"
    Write-Host " SEND HAS STARTED"
    Write-Host ""
    Write-Host " >>> DISCONNECT PRINTER LAN NOW <<<"
    Write-Host ""
    Write-Host " Wait about 3 seconds after unplugging."
    Write-Host " Then press ENTER."
    Write-Host "========================================"
    Write-Host ""

    Read-Host "Press ENTER after LAN is disconnected"

    # Give TCP stack a little more time to observe link loss.
    Start-Sleep -Seconds 2

    # --------------------------------------------------------
    # SECOND SEND
    # --------------------------------------------------------

    Write-Host ""
    Write-Host "[3] Attempting remaining print data..."

    $stream.Write(
        $feed,
        0,
        $feed.Length
    )

    $bytesAccepted += $feed.Length

    $stream.Write(
        $cut,
        0,
        $cut.Length
    )

    $bytesAccepted += $cut.Length

    $stream.Flush()

    Write-Host "    Feed/Cut Write returned"
    Write-Host ""

    # --------------------------------------------------------
    # PROCESS ID
    # --------------------------------------------------------

    Write-Host "[4] Sending Process ID $processId..."

    $stream.Write(
        $processIdCommand,
        0,
        $processIdCommand.Length
    )

    $bytesAccepted += $processIdCommand.Length

    $stream.Flush()

    # --------------------------------------------------------
    # ACK
    # --------------------------------------------------------

    Write-Host "[5] Waiting for ACK..."

    $ack = New-Object byte[] 7
    $offset = 0

    while ($offset -lt 7) {

        $read = $stream.Read(
            $ack,
            $offset,
            7 - $offset
        )

        if ($read -le 0) {
            throw "Connection closed before complete ACK."
        }

        $offset += $read
    }

    $ackReceived = $true

    Write-Host (
        "    ACK bytes: " +
        (($ack | ForEach-Object {
            "{0:X2}" -f $_
        }) -join " ")
    )

    # Validate:
    # 37 22 + 4 ASCII Process ID + 00

    $returnedId =
        [System.Text.Encoding]::ASCII.GetString(
            $ack,
            2,
            4
        )

    if (
        $ack[0] -eq 0x37 -and
        $ack[1] -eq 0x22 -and
        $ack[6] -eq 0x00 -and
        $returnedId -eq $processId
    ) {
        $ackValid = $true
        $transportStatus = "COMPLETED"
    }
    else {
        $transportStatus = "UNKNOWN"
    }
}
catch {

    $errorMessage = $_.Exception.Message

    if ($sendStarted) {
        $transportStatus = "UNKNOWN"
    }
    else {
        $transportStatus = "FAILED"
    }
}
finally {

    if ($null -ne $stream) {
        $stream.Dispose()
    }

    if ($null -ne $client) {
        $client.Dispose()
    }
}

# ------------------------------------------------------------
# RESULT
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================"
Write-Host " TEST-0010B-16B"
Write-Host " RESULT"
Write-Host "========================================"
Write-Host ""

Write-Host "Transport status : $transportStatus"
Write-Host "Send started     : $sendStarted"
Write-Host "Bytes accepted   : $bytesAccepted"
Write-Host "Process ID       : $processId"
Write-Host "ACK received     : $ackReceived"
Write-Host "ACK valid        : $ackValid"

if ($null -ne $returnedId) {
    Write-Host "Returned ID      : $returnedId"
}

if ($null -ne $errorMessage) {
    Write-Host "Error            : $errorMessage"
}

Write-Host ""

# ------------------------------------------------------------
# ASSERTIONS
# ------------------------------------------------------------

$pass =
    ($transportStatus -eq "UNKNOWN") -and
    ($sendStarted -eq $true) -and
    ($bytesAccepted -gt 0) -and
    ($ackValid -eq $false)

if ($pass) {

    Write-Host "========================================"
    Write-Host " TEST-0010B-16B PASS"
    Write-Host ""
    Write-Host " RESULT: UNKNOWN"
    Write-Host " DO NOT AUTO-RETRY"
    Write-Host " MANUAL INTERVENTION REQUIRED"
    Write-Host "========================================"
}
else {

    Write-Host "========================================"
    Write-Host " TEST-0010B-16B NEEDS REVIEW"
    Write-Host ""
    Write-Host " Expected UNKNOWN after send started."
    Write-Host " DO NOT RETRY THIS TEST JOB."
    Write-Host "========================================"
}

Write-Host ""
Write-Host "TEST-0010B-16B finished."
