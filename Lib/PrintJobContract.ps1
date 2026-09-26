Set-StrictMode -Version Latest

$script:PrintGatewayContractVersion = '1.0'
$script:PrintGatewayContractMaximumBytes = 262144
$script:PrintGatewayContractRequiredProperties = @(
    'contractVersion',
    'jobId',
    'processId',
    'printerId',
    'documentType',
    'templateId',
    'requestedAtUtc',
    'payload'
)
$script:PrintGatewayContractDocumentTypes = @(
    'RECEIPT',
    'KITCHEN_TICKET',
    'ORDER_SUMMARY'
)

function Assert-PrintGatewayJsonHasUniqueProperties {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Text.Json.JsonElement]$Element,

        [string]$Path = '$'
    )

    switch ($Element.ValueKind) {
        ([System.Text.Json.JsonValueKind]::Object) {
            $names = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::Ordinal
            )

            foreach ($property in $Element.EnumerateObject()) {
                if (-not $names.Add($property.Name)) {
                    throw "Duplicate JSON property '$($property.Name)' at $Path."
                }

                Assert-PrintGatewayJsonHasUniqueProperties `
                    -Element $property.Value `
                    -Path "$Path.$($property.Name)"
            }
        }

        ([System.Text.Json.JsonValueKind]::Array) {
            $index = 0
            foreach ($item in $Element.EnumerateArray()) {
                Assert-PrintGatewayJsonHasUniqueProperties `
                    -Element $item `
                    -Path "$Path[$index]"
                $index++
            }
        }
    }
}

function Write-PrintGatewayCanonicalJsonElement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Text.Json.Utf8JsonWriter]$Writer,

        [Parameter(Mandatory)]
        [System.Text.Json.JsonElement]$Element
    )

    switch ($Element.ValueKind) {
        ([System.Text.Json.JsonValueKind]::Object) {
            $Writer.WriteStartObject()
            $properties = [System.Collections.Generic.List[System.Text.Json.JsonProperty]]::new()

            foreach ($property in $Element.EnumerateObject()) {
                $properties.Add($property)
            }

            $properties.Sort(
                [System.Comparison[System.Text.Json.JsonProperty]] {
                    param($Left, $Right)
                    return [System.StringComparer]::Ordinal.Compare(
                        $Left.Name,
                        $Right.Name
                    )
                }
            )

            foreach ($property in $properties) {
                $Writer.WritePropertyName($property.Name)
                Write-PrintGatewayCanonicalJsonElement `
                    -Writer $Writer `
                    -Element $property.Value
            }

            $Writer.WriteEndObject()
        }

        ([System.Text.Json.JsonValueKind]::Array) {
            $Writer.WriteStartArray()
            foreach ($item in $Element.EnumerateArray()) {
                Write-PrintGatewayCanonicalJsonElement `
                    -Writer $Writer `
                    -Element $item
            }
            $Writer.WriteEndArray()
        }

        ([System.Text.Json.JsonValueKind]::String) {
            $Writer.WriteStringValue($Element.GetString())
        }

        ([System.Text.Json.JsonValueKind]::Number) {
            $Writer.WriteRawValue($Element.GetRawText(), $true)
        }

        ([System.Text.Json.JsonValueKind]::True) {
            $Writer.WriteBooleanValue($true)
        }

        ([System.Text.Json.JsonValueKind]::False) {
            $Writer.WriteBooleanValue($false)
        }

        ([System.Text.Json.JsonValueKind]::Null) {
            $Writer.WriteNullValue()
        }

        default {
            throw "Unsupported JSON value kind: $($Element.ValueKind)."
        }
    }
}

function ConvertTo-PrintGatewayCanonicalJsonBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Text.Json.JsonElement]$Element
    )

    $stream = [System.IO.MemoryStream]::new()
    $writer = [System.Text.Json.Utf8JsonWriter]::new($stream)

    try {
        Write-PrintGatewayCanonicalJsonElement -Writer $writer -Element $Element
        $writer.Flush()
        return $stream.ToArray()
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

function ConvertFrom-PrintGatewayJobJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Json,

        [ValidateRange(1, 1048576)]
        [int]$MaximumBytes = $script:PrintGatewayContractMaximumBytes
    )

    $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    if ($jsonBytes.Length -gt $MaximumBytes) {
        throw "Print job contract exceeds the maximum size of $MaximumBytes bytes."
    }

    $documentOptions = [System.Text.Json.JsonDocumentOptions]::new()
    $documentOptions.AllowTrailingCommas = $false
    $documentOptions.CommentHandling = [System.Text.Json.JsonCommentHandling]::Disallow
    $documentOptions.MaxDepth = 32

    try {
        $document = [System.Text.Json.JsonDocument]::Parse($Json, $documentOptions)
    }
    catch {
        throw "Print job contract is not valid JSON: $($_.Exception.Message)"
    }

    try {
        $root = $document.RootElement
        if ($root.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
            throw 'Print job contract root must be a JSON object.'
        }

        Assert-PrintGatewayJsonHasUniqueProperties -Element $root

        $properties = @{}
        foreach ($property in $root.EnumerateObject()) {
            if ($property.Name -notin $script:PrintGatewayContractRequiredProperties) {
                throw "Unknown print job contract property '$($property.Name)'."
            }

            $properties[$property.Name] = $property.Value
        }

        foreach ($requiredProperty in $script:PrintGatewayContractRequiredProperties) {
            if (-not $properties.ContainsKey($requiredProperty)) {
                throw "Missing required print job contract property '$requiredProperty'."
            }
        }

        foreach ($stringProperty in @(
            'contractVersion',
            'jobId',
            'processId',
            'printerId',
            'documentType',
            'templateId',
            'requestedAtUtc'
        )) {
            if ($properties[$stringProperty].ValueKind -ne [System.Text.Json.JsonValueKind]::String) {
                throw "Print job contract property '$stringProperty' must be a string."
            }
        }

        $contractVersion = $properties.contractVersion.GetString()
        $jobId = $properties.jobId.GetString()
        $processId = $properties.processId.GetString()
        $printerId = $properties.printerId.GetString()
        $documentType = $properties.documentType.GetString()
        $templateId = $properties.templateId.GetString()
        $requestedAtText = $properties.requestedAtUtc.GetString()

        if ($contractVersion -ne $script:PrintGatewayContractVersion) {
            throw "Unsupported print job contract version '$contractVersion'."
        }

        if ($jobId.Length -gt 128 -or $jobId -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]*$') {
            throw 'jobId must be 1-128 characters and use only letters, digits, dot, underscore, colon, or hyphen.'
        }

        if ($processId -notmatch '^\d{4}$') {
            throw 'processId must contain exactly 4 digits.'
        }

        if ($printerId.Length -gt 64 -or $printerId -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]*$') {
            throw 'printerId must be 1-64 characters and use only letters, digits, dot, underscore, colon, or hyphen.'
        }

        if ($documentType -notin $script:PrintGatewayContractDocumentTypes) {
            throw "Unsupported documentType '$documentType'."
        }

        if ($templateId.Length -gt 64 -or $templateId -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]*$') {
            throw 'templateId must be 1-64 characters and use only letters, digits, dot, underscore, colon, or hyphen.'
        }

        $requestedAtUtc = [DateTimeOffset]::MinValue
        $timestampHasUtcIsoShape = $requestedAtText -match (
            '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$'
        )
        $timestampIsValid = [DateTimeOffset]::TryParse(
            $requestedAtText,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$requestedAtUtc
        )

        if (-not $timestampHasUtcIsoShape -or
            -not $timestampIsValid -or
            $requestedAtUtc.Offset -ne [TimeSpan]::Zero) {
            throw 'requestedAtUtc must be a valid UTC ISO 8601 timestamp ending in Z.'
        }

        $payloadElement = $properties.payload
        if ($payloadElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
            throw 'payload must be a non-empty JSON object.'
        }

        $payloadPropertyCount = 0
        foreach ($payloadProperty in $payloadElement.EnumerateObject()) {
            $payloadPropertyCount++
            break
        }

        if ($payloadPropertyCount -eq 0) {
            throw 'payload must be a non-empty JSON object.'
        }

        $canonicalBytes = ConvertTo-PrintGatewayCanonicalJsonBytes -Element $root
        $requestFingerprint = [Convert]::ToHexString(
            [System.Security.Cryptography.SHA256]::HashData($canonicalBytes)
        ).ToLowerInvariant()

        [PSCustomObject]@{
            ContractVersion    = $contractVersion
            JobId              = $jobId
            ProcessId          = $processId
            PrinterId          = $printerId
            DocumentType       = $documentType
            TemplateId         = $templateId
            RequestedAtUtc     = $requestedAtUtc
            Payload            = $payloadElement.GetRawText() | ConvertFrom-Json -Depth 32
            CanonicalJson      = [System.Text.Encoding]::UTF8.GetString($canonicalBytes)
            RequestFingerprint = $requestFingerprint
        }
    }
    finally {
        $document.Dispose()
    }
}
