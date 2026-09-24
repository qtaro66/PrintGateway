# ============================================================
# EpsonTransport.ps1
# PrintGateway - Epson TCP Transport
#
# Responsibility:
#   - TCP connection to printer
#   - Send already prepared byte arrays
#
# NOT responsible for:
#   - Rendering
#   - Job state
#   - Process ID / ACK
#   - Automatic retry
# ============================================================

function Send-EpsonPrintData {

    [CmdletBinding()]

    param(
        [Parameter(Mandatory)]
        [string]$PrinterIp,

        [int]$PrinterPort = 9100,

        [Parameter(Mandatory)]
        [byte[]]$InitializeCommand,

        [Parameter(Mandatory)]
        [byte[]]$StoreHeader,

        [Parameter(Mandatory)]
        [byte[]]$RasterData,

        [Parameter(Mandatory)]
        [byte[]]$PrintGraphicsCommand,

        [Parameter(Mandatory)]
        [byte[]]$FeedCommand,

        [Parameter(Mandatory)]
        [byte[]]$CutCommand,

        [int]$ConnectTimeoutMs = 3000
    )

    # --------------------------------------------------------
    # Validate before opening TCP connection
    # --------------------------------------------------------

    if ($RasterData.Length -le 0) {
        throw "RasterData is empty."
    }

    if ($StoreHeader.Length -ne 15) {
        throw "Invalid GS ( L store header length."
    }

    if ($PrintGraphicsCommand.Length -ne 7) {
        throw "Invalid GS ( L print command length."
    }

    $client = [System.Net.Sockets.TcpClient]::new()
    $stream = $null

    # Conservative tracking:
    # once first payload write is attempted, an uncertain failure
    # must NOT be assumed safe to retry.
    $sendStarted = $false

    try {

        $client.SendTimeout = 5000
        $client.ReceiveTimeout = 5000

        Write-Host "[TRANSPORT] Connecting $PrinterIp`:$PrinterPort ..."

        $connectTask =
            $client.ConnectAsync(
                $PrinterIp,
                $PrinterPort
            )

        if (-not $connectTask.Wait($ConnectTimeoutMs)) {

            throw "Connection timeout after $ConnectTimeoutMs ms."
        }

        $null =
            $connectTask.GetAwaiter().GetResult()

        $stream =
            $client.GetStream()

        Write-Host "[TRANSPORT] Connected"

        # ----------------------------------------------------
        # From this point onward:
        # a failure is conservatively treated as UNKNOWN.
        # ----------------------------------------------------

        $sendStarted = $true

        Write-Host "[TRANSPORT] ESC @"

        $stream.Write(
            $InitializeCommand,
            0,
            $InitializeCommand.Length
        )

        Write-Host "[TRANSPORT] GS ( L header"

        $stream.Write(
            $StoreHeader,
            0,
            $StoreHeader.Length
        )

        Write-Host "[TRANSPORT] Raster data"

        $stream.Write(
            $RasterData,
            0,
            $RasterData.Length
        )

        $stream.Flush()

        Write-Host (
            "[TRANSPORT] {0} raster bytes accepted by socket" -f
            $RasterData.Length
        )

        Start-Sleep -Milliseconds 500

        Write-Host "[TRANSPORT] Print graphics"

        $stream.Write(
            $PrintGraphicsCommand,
            0,
            $PrintGraphicsCommand.Length
        )

        $stream.Flush()

        Start-Sleep -Milliseconds 1000

        Write-Host "[TRANSPORT] Feed"

        $stream.Write(
            $FeedCommand,
            0,
            $FeedCommand.Length
        )

        $stream.Flush()

        Start-Sleep -Milliseconds 300

        Write-Host "[TRANSPORT] Cut"

        $stream.Write(
            $CutCommand,
            0,
            $CutCommand.Length
        )

        $stream.Flush()

        # IMPORTANT:
        # SENT != COMPLETED
        #
        # We do not call this COMPLETED because B-14
        # has no Process ID acknowledgement yet.

        return [PSCustomObject]@{
            TransportStatus = "SENT"
            SendStarted     = $true
            RasterBytes     = $RasterData.Length
            Error           = $null
        }
    }
    catch {

        $message =
            $_.Exception.Message

        if ($sendStarted) {

            return [PSCustomObject]@{
                TransportStatus = "UNKNOWN"
                SendStarted     = $true
                RasterBytes     = $RasterData.Length
                Error           = $message
            }
        }
        else {

            return [PSCustomObject]@{
                TransportStatus = "FAILED"
                SendStarted     = $false
                RasterBytes     = 0
                Error           = $message
            }
        }
    }
    finally {

        if ($null -ne $stream) {
            $stream.Dispose()
        }

        $client.Dispose()
    }
}

Write-Verbose "EpsonTransport library loaded."

# ============================================================
# PROCESS ID / ACK SUPPORT
#
# Epson GS ( H Function 48
#
# Process ID:
#   exactly 4 ASCII characters
#
# Example:
#   "0015"
#
# Command:
#   1D 28 48 06 00 30 30 30 30 31 35
#
# Expected response:
#   37 22 30 30 31 35 00
#
# IMPORTANT:
#   Matching ACK = protocol-level completion.
# ============================================================


function New-EpsonProcessIdCommand {

    [CmdletBinding()]

    param(
        [Parameter(Mandatory)]
        [string]$ProcessId
    )

    # --------------------------------------------------------
    # Validate Process ID
    # --------------------------------------------------------

    if ($ProcessId.Length -ne 4) {
        throw "ProcessId must contain exactly 4 ASCII characters."
    }

    foreach ($char in $ProcessId.ToCharArray()) {

        if ([int][char]$char -gt 0x7F) {
            throw "ProcessId must contain ASCII characters only."
        }
    }

    $idBytes =
        [System.Text.Encoding]::ASCII.GetBytes(
            $ProcessId
        )

    # GS ( H
    # pL pH = 06 00
    # m      = 30h
    # fn     = 30h
    # d1-d4  = Process ID

    return [byte[]](
        0x1D,0x28,0x48,
        0x06,0x00,
        0x30,0x30,
        $idBytes[0],
        $idBytes[1],
        $idBytes[2],
        $idBytes[3]
    )
}


function Read-EpsonProcessIdAck {

    [CmdletBinding()]

    param(
        [Parameter(Mandatory)]
        [System.IO.Stream]$Stream,

        [Parameter(Mandatory)]
        [string]$ExpectedProcessId,

        [int]$TimeoutMs = 5000
    )

    if ($ExpectedProcessId.Length -ne 4) {
        throw "ExpectedProcessId must contain exactly 4 characters."
    }

    # --------------------------------------------------------
    # Expected ACK length = 7 bytes
    #
    # 37 22 xx xx xx xx 00
    # --------------------------------------------------------

    $ack =
        New-Object byte[] 7

    $offset = 0

    $stopwatch =
        [System.Diagnostics.Stopwatch]::StartNew()

    while (
        $offset -lt 7 -and
        $stopwatch.ElapsedMilliseconds -lt $TimeoutMs
    ) {

        if ($Stream.DataAvailable) {

            $read =
                $Stream.Read(
                    $ack,
                    $offset,
                    (7 - $offset)
                )

            if ($read -gt 0) {
                $offset += $read
            }
        }
        else {

            Start-Sleep -Milliseconds 10
        }
    }

    $stopwatch.Stop()

    # --------------------------------------------------------
    # Timeout / incomplete ACK
    # --------------------------------------------------------

    if ($offset -ne 7) {

        return [PSCustomObject]@{
            Valid             = $false
            Complete          = $false
            BytesReceived     = $offset
            RawBytes          = if ($offset -gt 0) { [byte[]]$ack[0..($offset - 1)] } else { [byte[]]@() }
            ReturnedProcessId = $null
            Error             = "ACK timeout or incomplete response."
            ElapsedMs         = $stopwatch.ElapsedMilliseconds
        }
    }

    # --------------------------------------------------------
    # Decode returned Process ID
    # --------------------------------------------------------

    $returnedProcessId =
        [System.Text.Encoding]::ASCII.GetString(
            $ack,
            2,
            4
        )

    # --------------------------------------------------------
    # Strict ACK validation
    #
    # Byte 0 = 37h
    # Byte 1 = 22h
    # Byte 2-5 = Process ID
    # Byte 6 = 00h
    # --------------------------------------------------------

    $prefixValid =
        ($ack[0] -eq 0x37) -and
        ($ack[1] -eq 0x22)

    $terminatorValid =
        ($ack[6] -eq 0x00)

    $processIdMatch =
        ($returnedProcessId -eq $ExpectedProcessId)

    $valid =
        $prefixValid -and
        $terminatorValid -and
        $processIdMatch

    $errorMessage = $null

    if (-not $prefixValid) {
        $errorMessage = "Invalid ACK prefix."
    }
    elseif (-not $terminatorValid) {
        $errorMessage = "Invalid ACK terminator."
    }
    elseif (-not $processIdMatch) {
        $errorMessage =
            "Process ID mismatch. Expected=$ExpectedProcessId Returned=$returnedProcessId"
    }

    return [PSCustomObject]@{
        Valid             = $valid
        Complete          = $true
        BytesReceived     = 7
        RawBytes          = $ack
        ReturnedProcessId = $returnedProcessId
        PrefixValid       = $prefixValid
        TerminatorValid   = $terminatorValid
        ProcessIdMatch    = $processIdMatch
        Error             = $errorMessage
        ElapsedMs         = $stopwatch.ElapsedMilliseconds
    }
}


function Send-EpsonPrintDataWithAck {

    [CmdletBinding()]

    param(
        [Parameter(Mandatory)]
        [string]$PrinterIp,

        [int]$PrinterPort = 9100,

        [Parameter(Mandatory)]
        [byte[]]$InitializeCommand,

        [Parameter(Mandatory)]
        [byte[]]$StoreHeader,

        [Parameter(Mandatory)]
        [byte[]]$RasterData,

        [Parameter(Mandatory)]
        [byte[]]$PrintGraphicsCommand,

        [Parameter(Mandatory)]
        [byte[]]$FeedCommand,

        [Parameter(Mandatory)]
        [byte[]]$CutCommand,

        [Parameter(Mandatory)]
        [string]$ProcessId,

        [int]$ConnectTimeoutMs = 3000,

        [int]$AckTimeoutMs = 5000
    )

    # --------------------------------------------------------
    # Validate BEFORE connection
    # --------------------------------------------------------

    if ($RasterData.Length -le 0) {
        throw "RasterData is empty."
    }

    if ($StoreHeader.Length -ne 15) {
        throw "Invalid GS ( L store header length."
    }

    if ($PrintGraphicsCommand.Length -ne 7) {
        throw "Invalid GS ( L print command length."
    }

    # Build this before connecting so an invalid Process ID
    # cannot create an uncertain printer state.

    $processIdCommand =
        New-EpsonProcessIdCommand `
            -ProcessId $ProcessId

    $client =
        [System.Net.Sockets.TcpClient]::new()

    $stream = $null

    $sendStarted = $false

    try {

        $client.SendTimeout    = 5000
        $client.ReceiveTimeout = $AckTimeoutMs

        Write-Host (
            "[TRANSPORT] Connecting {0}:{1} ..." -f
            $PrinterIp,
            $PrinterPort
        )

        $connectTask =
            $client.ConnectAsync(
                $PrinterIp,
                $PrinterPort
            )

        if (-not $connectTask.Wait($ConnectTimeoutMs)) {

            throw "Connection timeout after $ConnectTimeoutMs ms."
        }

        $null =
            $connectTask.GetAwaiter().GetResult()

        $stream =
            $client.GetStream()

        Write-Host "[TRANSPORT] Connected"

        # ====================================================
        # FIRST PAYLOAD WRITE
        #
        # From this point onward an uncertain failure
        # is classified UNKNOWN.
        # ====================================================

        $sendStarted = $true

        Write-Host "[TRANSPORT] ESC @"

        $stream.Write(
            $InitializeCommand,
            0,
            $InitializeCommand.Length
        )

        Write-Host "[TRANSPORT] GS ( L header"

        $stream.Write(
            $StoreHeader,
            0,
            $StoreHeader.Length
        )

        Write-Host "[TRANSPORT] Raster data"

        $stream.Write(
            $RasterData,
            0,
            $RasterData.Length
        )

        $stream.Flush()

        Write-Host (
            "[TRANSPORT] {0} raster bytes accepted by socket" -f
            $RasterData.Length
        )

        Start-Sleep -Milliseconds 500

        Write-Host "[TRANSPORT] Print graphics"

        $stream.Write(
            $PrintGraphicsCommand,
            0,
            $PrintGraphicsCommand.Length
        )

        $stream.Flush()

        Start-Sleep -Milliseconds 1000

        Write-Host "[TRANSPORT] Feed"

        $stream.Write(
            $FeedCommand,
            0,
            $FeedCommand.Length
        )

        $stream.Flush()

        Start-Sleep -Milliseconds 300

        Write-Host "[TRANSPORT] Cut"

        $stream.Write(
            $CutCommand,
            0,
            $CutCommand.Length
        )

        $stream.Flush()

        # ====================================================
        # PROCESS ID
        # ====================================================

        Write-Host (
            "[TRANSPORT] Process ID {0}" -f
            $ProcessId
        )

        $stream.Write(
            $processIdCommand,
            0,
            $processIdCommand.Length
        )

        $stream.Flush()

        # ====================================================
        # WAIT FOR ACK
        # ====================================================

        Write-Host "[TRANSPORT] Waiting for ACK ..."

        $ack =
            Read-EpsonProcessIdAck `
                -Stream $stream `
                -ExpectedProcessId $ProcessId `
                -TimeoutMs $AckTimeoutMs

        $rawHex = ""

        if ($null -ne $ack.RawBytes) {

            $rawHex =
                ($ack.RawBytes |
                    ForEach-Object {
                        "{0:X2}" -f $_
                    }) -join " "
        }

        Write-Host (
            "[TRANSPORT] ACK bytes: {0}" -f
            $rawHex
        )

        # ====================================================
        # COMPLETED
        # ====================================================

        if ($ack.Valid) {

            Write-Host (
                "[TRANSPORT] ACK MATCH: {0}" -f
                $ack.ReturnedProcessId
            )

            return [PSCustomObject]@{
                TransportStatus  = "COMPLETED"
                SendStarted      = $true
                RasterBytes      = $RasterData.Length
                ProcessId        = $ProcessId
                AckReceived      = $true
                AckValid         = $true
                AckBytes         = $ack.RawBytes
                ReturnedProcessId = $ack.ReturnedProcessId
                AckElapsedMs     = $ack.ElapsedMs
                Error            = $null
            }
        }

        # ====================================================
        # ACK missing / malformed / wrong ID
        #
        # We already sent payload.
        # Therefore DO NOT call this FAILED.
        # ====================================================

        return [PSCustomObject]@{
            TransportStatus  = "UNKNOWN"
            SendStarted      = $true
            RasterBytes      = $RasterData.Length
            ProcessId        = $ProcessId
            AckReceived      = $ack.Complete
            AckValid         = $false
            AckBytes         = $ack.RawBytes
            ReturnedProcessId = $ack.ReturnedProcessId
            AckElapsedMs     = $ack.ElapsedMs
            Error            = $ack.Error
        }
    }
    catch {

        $message =
            $_.Exception.Message

        if ($sendStarted) {

            return [PSCustomObject]@{
                TransportStatus   = "UNKNOWN"
                SendStarted       = $true
                RasterBytes       = $RasterData.Length
                ProcessId         = $ProcessId
                AckReceived       = $false
                AckValid          = $false
                AckBytes          = $null
                ReturnedProcessId = $null
                AckElapsedMs      = $null
                Error             = $message
            }
        }

        return [PSCustomObject]@{
            TransportStatus   = "FAILED"
            SendStarted       = $false
            RasterBytes       = 0
            ProcessId         = $ProcessId
            AckReceived       = $false
            AckValid          = $false
            AckBytes          = $null
            ReturnedProcessId = $null
            AckElapsedMs      = $null
            Error             = $message
        }
    }
    finally {

        if ($null -ne $stream) {
            $stream.Dispose()
        }

        $client.Dispose()
    }
}