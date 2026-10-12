[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PreviewPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$previewPathFull = [System.IO.Path]::GetFullPath($PreviewPath)
$directory = Split-Path -Parent $previewPathFull
$baseName = [System.IO.Path]::GetFileNameWithoutExtension($previewPathFull)
$metadataPath = Join-Path $directory ($baseName + '.metadata.json')
$monoPath = Join-Path $directory ($baseName + '.mono.png')
$rasterPath = Join-Path $directory ($baseName + '.raster.bin')
$payloadPath = Join-Path $directory ($baseName + '.escpos.bin')

foreach ($path in @($previewPathFull, $metadataPath, $monoPath, $rasterPath, $payloadPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Expected offline artifact not found: $path"
    }
}

$metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
$raster = [System.IO.File]::ReadAllBytes($rasterPath)
$payload = [System.IO.File]::ReadAllBytes($payloadPath)
$expectedRasterLength = [int]$metadata.bytesPerRow * [int]$metadata.heightDots

if ($raster.Length -ne $expectedRasterLength -or $raster.Length -ne [int]$metadata.rasterBytes) {
    throw "Raster length mismatch. Expected $expectedRasterLength, actual $($raster.Length)."
}
if ($payload.Length -ne [int]$metadata.payloadBytes) {
    throw "Payload length mismatch. Metadata $($metadata.payloadBytes), actual $($payload.Length)."
}

[byte[]]$expectedInit = 0x1B,0x40
[byte[]]$expectedPrint = 0x1D,0x28,0x4C,0x02,0x00,0x30,0x32
[byte[]]$expectedFeed = 0x1B,0x64,0x04
[byte[]]$expectedCut = 0x1D,0x56,0x01

function Assert-ByteSequence {
    param(
        [Parameter(Mandatory)][byte[]]$Actual,
        [Parameter(Mandatory)][int]$Offset,
        [Parameter(Mandatory)][byte[]]$Expected,
        [Parameter(Mandatory)][string]$Name
    )

    for ($index = 0; $index -lt $Expected.Length; $index++) {
        if ($Actual[$Offset + $index] -ne $Expected[$index]) {
            throw "$Name mismatch at payload offset $($Offset + $index)."
        }
    }
}

Assert-ByteSequence -Actual $payload -Offset 0 -Expected $expectedInit -Name 'Initialize command'
Assert-ByteSequence -Actual $payload -Offset 2 -Expected ([byte[]](0x1D,0x28,0x4C)) -Name 'GS ( L prefix'
Assert-ByteSequence -Actual $payload -Offset 7 -Expected ([byte[]](0x30,0x70,0x30,0x01,0x01,0x31)) -Name 'Function 112 parameters'

$parameterLength = [int]$payload[5] + ([int]$payload[6] -shl 8)
$widthDots = [int]$payload[13] + ([int]$payload[14] -shl 8)
$heightDots = [int]$payload[15] + ([int]$payload[16] -shl 8)
if ($parameterLength -ne (10 + $raster.Length)) {
    throw 'GS ( L parameter length does not match raster length.'
}
if ($widthDots -ne [int]$metadata.widthDots -or $heightDots -ne [int]$metadata.heightDots) {
    throw 'GS ( L dimensions do not match metadata.'
}

$rasterOffset = 17
for ($index = 0; $index -lt $raster.Length; $index++) {
    if ($payload[$rasterOffset + $index] -ne $raster[$index]) {
        throw "Payload raster differs from raster artifact at byte $index."
    }
}

$suffixOffset = $rasterOffset + $raster.Length
Assert-ByteSequence -Actual $payload -Offset $suffixOffset -Expected $expectedPrint -Name 'Function 50 print command'
$suffixOffset += $expectedPrint.Length
Assert-ByteSequence -Actual $payload -Offset $suffixOffset -Expected $expectedFeed -Name 'Feed command'
$suffixOffset += $expectedFeed.Length
Assert-ByteSequence -Actual $payload -Offset $suffixOffset -Expected $expectedCut -Name 'Partial-cut command'
$suffixOffset += $expectedCut.Length
if ($suffixOffset -ne $payload.Length) {
    throw 'Unexpected bytes exist after the partial-cut command.'
}

$hashChecks = @{
    previewPngSha256    = $previewPathFull
    monochromePngSha256 = $monoPath
    rasterSha256        = $rasterPath
    payloadSha256       = $payloadPath
}
foreach ($property in $hashChecks.Keys) {
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $hashChecks[$property]).Hash
    if ($actualHash -cne [string]$metadata.$property) {
        throw "SHA-256 mismatch for $property."
    }
}

if ([bool]$metadata.payloadIncludesDrawerPulse -or
    [bool]$metadata.payloadIncludesProcessId -or
    [bool]$metadata.payloadTransmitted) {
    throw 'Offline payload safety metadata is invalid.'
}

[pscustomobject]@{
    Valid = $true
    WidthDots = $widthDots
    HeightDots = $heightDots
    Threshold = [int]$metadata.threshold
    RasterBytes = $raster.Length
    PayloadBytes = $payload.Length
    PayloadSha256 = [string]$metadata.payloadSha256
    DrawerPulseIncluded = $false
    ProcessIdIncluded = $false
    Transmitted = $false
}
