Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$contractLibraryPath = 'C:\PrintGateway\Lib\PrintJobContract.ps1'

function Assert-Equal {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        $Expected,

        $Actual
    )

    if ($Expected -ne $Actual) {
        throw "Assertion failed for ${Name}: expected '$Expected', actual '$Actual'."
    }
}

function Assert-ThrowsLike {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [scriptblock]$Action,

        [Parameter(Mandatory)]
        [string]$Pattern
    )

    $message = $null
    try {
        & $Action
    }
    catch {
        $message = $_.Exception.Message
    }

    if ($null -eq $message -or $message -notlike $Pattern) {
        throw "Assertion failed for ${Name}: expected error '$Pattern', actual '$message'."
    }
}

if (-not (Test-Path -LiteralPath $contractLibraryPath -PathType Leaf)) {
    throw "Required file not found: $contractLibraryPath"
}

. $contractLibraryPath

$validJson = @'
{
  "contractVersion": "1.0",
  "jobId": "ORDER-20260926-0001",
  "processId": "0021",
  "printerId": "KITCHEN-01",
  "documentType": "KITCHEN_TICKET",
  "templateId": "kitchen-ticket-v1",
  "requestedAtUtc": "2026-09-26T06:00:00Z",
  "payload": {
    "table": "T01",
    "orderNumber": "A0001",
    "items": [{ "quantity": 1, "name": "Sample item" }]
  }
}
'@

$reorderedJson = @'
{
  "payload": {
    "items": [{ "name": "Sample item", "quantity": 1 }],
    "orderNumber": "A0001",
    "table": "T01"
  },
  "requestedAtUtc": "2026-09-26T06:00:00Z",
  "templateId": "kitchen-ticket-v1",
  "documentType": "KITCHEN_TICKET",
  "printerId": "KITCHEN-01",
  "processId": "0021",
  "jobId": "ORDER-20260926-0001",
  "contractVersion": "1.0"
}
'@

$emptyPayloadJson = @'
{
  "contractVersion": "1.0",
  "jobId": "ORDER-20260926-0001",
  "processId": "0021",
  "printerId": "KITCHEN-01",
  "documentType": "KITCHEN_TICKET",
  "templateId": "kitchen-ticket-v1",
  "requestedAtUtc": "2026-09-26T06:00:00Z",
  "payload": {}
}
'@

$spacedEmptyPayloadJson = @'
{
  "contractVersion": "1.0",
  "jobId": "ORDER-20260926-0001",
  "processId": "0021",
  "printerId": "KITCHEN-01",
  "documentType": "KITCHEN_TICKET",
  "templateId": "kitchen-ticket-v1",
  "requestedAtUtc": "2026-09-26T06:00:00Z",
  "payload": { }
}
'@

$job = ConvertFrom-PrintGatewayJobJson -Json $validJson
$reorderedJob = ConvertFrom-PrintGatewayJobJson -Json $reorderedJson
$fractionalTimestampJob = ConvertFrom-PrintGatewayJobJson `
    -Json ($validJson.Replace(
        '2026-09-26T06:00:00Z',
        '2026-09-26T06:00:00.1234567Z'
    ))

Assert-Equal -Name 'contract version' -Expected '1.0' -Actual $job.ContractVersion
Assert-Equal -Name 'job ID' -Expected 'ORDER-20260926-0001' -Actual $job.JobId
Assert-Equal -Name 'process ID' -Expected '0021' -Actual $job.ProcessId
Assert-Equal -Name 'printer ID' -Expected 'KITCHEN-01' -Actual $job.PrinterId
Assert-Equal -Name 'document type' -Expected 'KITCHEN_TICKET' -Actual $job.DocumentType
Assert-Equal -Name 'template ID' -Expected 'kitchen-ticket-v1' -Actual $job.TemplateId
Assert-Equal -Name 'fingerprint length' -Expected 64 -Actual $job.RequestFingerprint.Length
Assert-Equal `
    -Name 'seven-digit fractional timestamp accepted' `
    -Expected 2026 `
    -Actual $fractionalTimestampJob.RequestedAtUtc.Year
Assert-Equal `
    -Name 'canonical fingerprint ignores property order' `
    -Expected $job.RequestFingerprint `
    -Actual $reorderedJob.RequestFingerprint

Assert-ThrowsLike `
    -Name 'unsupported version blocked' `
    -Pattern '*Unsupported print job contract version*' `
    -Action { ConvertFrom-PrintGatewayJobJson -Json ($validJson.Replace('"1.0"', '"2.0"')) }

Assert-ThrowsLike `
    -Name 'invalid process ID blocked' `
    -Pattern '*processId must contain exactly 4 digits*' `
    -Action { ConvertFrom-PrintGatewayJobJson -Json ($validJson.Replace('"0021"', '"21"')) }

Assert-ThrowsLike `
    -Name 'Arabic-Indic process ID blocked' `
    -Pattern '*processId must contain exactly 4 digits*' `
    -Action { ConvertFrom-PrintGatewayJobJson -Json ($validJson.Replace('"0021"', '"٠٠٢١"')) }

Assert-ThrowsLike `
    -Name 'full-width process ID blocked' `
    -Pattern '*processId must contain exactly 4 digits*' `
    -Action { ConvertFrom-PrintGatewayJobJson -Json ($validJson.Replace('"0021"', '"００２１"')) }

Assert-ThrowsLike `
    -Name 'non-UTC timestamp blocked' `
    -Pattern '*requestedAtUtc must be a valid UTC*' `
    -Action { ConvertFrom-PrintGatewayJobJson -Json ($validJson.Replace('2026-09-26T06:00:00Z', '2026-09-26T13:00:00+07:00')) }

Assert-ThrowsLike `
    -Name 'non-ISO timestamp blocked' `
    -Pattern '*requestedAtUtc must be a valid UTC*' `
    -Action { ConvertFrom-PrintGatewayJobJson -Json ($validJson.Replace('2026-09-26T06:00:00Z', '09/26/2026 06:00:00Z')) }

Assert-ThrowsLike `
    -Name 'eight-digit fractional timestamp blocked' `
    -Pattern '*requestedAtUtc must be a valid UTC*' `
    -Action { ConvertFrom-PrintGatewayJobJson -Json ($validJson.Replace('2026-09-26T06:00:00Z', '2026-09-26T06:00:00.12345678Z')) }

Assert-ThrowsLike `
    -Name 'unknown top-level property blocked' `
    -Pattern '*Unknown print job contract property*' `
    -Action { ConvertFrom-PrintGatewayJobJson -Json ($validJson.Replace('"payload": {', '"unexpected": true, "payload": {')) }

Assert-ThrowsLike `
    -Name 'wrong-case property blocked' `
    -Pattern '*Unknown print job contract property*' `
    -Action { ConvertFrom-PrintGatewayJobJson -Json ($validJson.Replace('"jobId":', '"JOBID":')) }

Assert-ThrowsLike `
    -Name 'wrong-case document type blocked' `
    -Pattern '*Unsupported documentType*' `
    -Action { ConvertFrom-PrintGatewayJobJson -Json ($validJson.Replace('"KITCHEN_TICKET"', '"kitchen_ticket"')) }

Assert-ThrowsLike `
    -Name 'duplicate nested property blocked' `
    -Pattern '*Duplicate JSON property*' `
    -Action { ConvertFrom-PrintGatewayJobJson -Json ($validJson.Replace('"table": "T01"', '"table": "T01", "table": "T02"')) }

Assert-ThrowsLike `
    -Name 'empty payload blocked' `
    -Pattern '*payload must be a non-empty JSON object*' `
    -Action { ConvertFrom-PrintGatewayJobJson -Json $emptyPayloadJson }

Assert-ThrowsLike `
    -Name 'spaced empty payload blocked' `
    -Pattern '*payload must be a non-empty JSON object*' `
    -Action { ConvertFrom-PrintGatewayJobJson -Json $spacedEmptyPayloadJson }

Assert-ThrowsLike `
    -Name 'maximum size enforced' `
    -Pattern '*exceeds the maximum size*' `
    -Action { ConvertFrom-PrintGatewayJobJson -Json $validJson -MaximumBytes 32 }

Write-Output 'TEST-0020A-POS-PRINT-CONTRACT: PASS'
Write-Output 'Verified: strict v1 envelope validation, duplicate-key rejection, UTC timestamps, size limit, and stable request fingerprinting.'
