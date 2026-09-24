# ============================================================
# EpsonRaster.ps1
# PrintGateway - Epson Raster Library
#
# Baseline verified with Epson TM-T82X:
#   Width       : 576 dots
#   Bytes/row   : 72
#   Rendering   : AntiAliasGridFit
#   Threshold   : 180
#   Graphics    : GS ( L
#
# First library version:
#   - Configuration
#   - Bitmap -> 1-bit raster conversion
#   - GS ( L command construction
#
# No printer connection is performed when this file is loaded.
# ============================================================

Add-Type -AssemblyName System.Drawing

# ------------------------------------------------------------
# VERIFIED BASELINE
# ------------------------------------------------------------

$script:EpsonRasterWidth       = 576
$script:EpsonRasterBytesPerRow = 72
$script:EpsonRasterThreshold   = 180

# ------------------------------------------------------------
# Convert System.Drawing.Bitmap -> Epson 1-bit raster
# ------------------------------------------------------------

function ConvertTo-EpsonRaster {

    param(
        [Parameter(Mandatory)]
        [System.Drawing.Bitmap]$Bitmap,

        [int]$Threshold = $script:EpsonRasterThreshold
    )

    if ($Bitmap.Width -ne $script:EpsonRasterWidth) {
        throw "Bitmap width must be $($script:EpsonRasterWidth) dots. Actual: $($Bitmap.Width)"
    }

    $widthDots  = $Bitmap.Width
    $heightDots = $Bitmap.Height

    $rasterLength =
        $script:EpsonRasterBytesPerRow * $heightDots

    $raster =
        New-Object byte[] $rasterLength

    $blackPixels = 0

    for ($y = 0; $y -lt $heightDots; $y++) {

        for ($x = 0; $x -lt $widthDots; $x++) {

            $pixel = $Bitmap.GetPixel($x, $y)

            $luminance =
                (0.299 * $pixel.R) +
                (0.587 * $pixel.G) +
                (0.114 * $pixel.B)

            if ($luminance -lt $Threshold) {

                # Verified integer byte calculation.
                # Do not replace with division / rounding.
                $byteIndex =
                    ($y * $script:EpsonRasterBytesPerRow) +
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

    return [PSCustomObject]@{
        WidthDots   = $widthDots
        HeightDots  = $heightDots
        BytesPerRow = $script:EpsonRasterBytesPerRow
        Threshold   = $Threshold
        BlackPixels = $blackPixels
        Data        = $raster
    }
}

# ------------------------------------------------------------
# Build GS ( L Function 112 header
# ------------------------------------------------------------

function New-EpsonGraphicsStoreHeader {

    param(
        [Parameter(Mandatory)]
        [int]$WidthDots,

        [Parameter(Mandatory)]
        [int]$HeightDots,

        [Parameter(Mandatory)]
        [int]$RasterLength
    )

    if ($WidthDots -ne $script:EpsonRasterWidth) {
        throw "Width must be $($script:EpsonRasterWidth) dots."
    }

    $expectedLength =
        $script:EpsonRasterBytesPerRow * $HeightDots

    if ($RasterLength -ne $expectedLength) {
        throw "Raster length mismatch. Expected $expectedLength, actual $RasterLength."
    }

    $xL = $WidthDots -band 0xFF
    $xH = ($WidthDots -shr 8) -band 0xFF

    $yL = $HeightDots -band 0xFF
    $yH = ($HeightDots -shr 8) -band 0xFF

    $parameterLength =
        10 + $RasterLength

    $pL = $parameterLength -band 0xFF
    $pH = ($parameterLength -shr 8) -band 0xFF

    return [byte[]](
        0x1D,0x28,0x4C,
        $pL,$pH,
        0x30,0x70,
        0x30,0x01,0x01,0x31,
        $xL,$xH,
        $yL,$yH
    )
}

# ------------------------------------------------------------
# GS ( L Function 50
# Print graphics buffer
# ------------------------------------------------------------

function New-EpsonGraphicsPrintCommand {

    return [byte[]](
        0x1D,0x28,0x4C,
        0x02,0x00,
        0x30,0x32
    )
}

# ------------------------------------------------------------
# Standard ESC/POS commands
# ------------------------------------------------------------

function New-EpsonInitializeCommand {

    return [byte[]](
        0x1B,0x40
    )
}

function New-EpsonFeedCommand {

    param(
        [ValidateRange(0,255)]
        [int]$Lines = 4
    )

    return [byte[]](
        0x1B,
        0x64,
        [byte]$Lines
    )
}

function New-EpsonPartialCutCommand {

    return [byte[]](
        0x1D,0x56,0x01
    )
}

Write-Verbose "EpsonRaster library loaded."